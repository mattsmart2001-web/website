-- ============================================================
-- 158 A standing practice window for live timing
--
-- 151 gave an admin a one-off test window, which is right for checking the
-- plumbing and wrong for letting the drivers try it: somebody has to open
-- it, it expires after four hours, and closing it wipes the captured track
-- outline.
--
-- A round can now carry a nightly window instead — 18:00 to 22:00, say —
-- held as a local time of day rather than a timestamp, so it reopens every
-- evening on its own and follows the clocks through the summer change. Any
-- paired driver can report during it, entered or not, exactly as in a test
-- window, which is the point: the drivers who most need a dry run are the
-- ones not yet on a grid.
--
-- Three things a standing window needs that a one-off did not:
--
--   1. A name of its own. "Test" is honest for an admin poking at it and
--      wrong for an open practice session, so the mode is now carried
--      through to the page as 'race', 'test' or 'practice' instead of one
--      is_test flag. is_test stays, meaning "not a real race", so nothing
--      that reads it has to change.
--
--   2. Somewhere to say when it is next open. A window nobody knows about
--      gets no feedback, so live_practice_window() hands the portal and the
--      live page the schedule and the next opening time.
--
--   3. Cleaning up after itself. Nobody closes a nightly window, so last
--      night's cars would still be sat on the page. The beacon clears them
--      when a session starts, and clears the lot whenever a round moves
--      between practice, test and race, which is what stops Friday's
--      practice leaking into Saturday's race.
--
-- The track outline is deliberately kept across all of that. It is the same
-- circuit, so a week of practice means the map is already drawn when the
-- race starts.
-- ============================================================

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS live_practice_from time,
    ADD COLUMN IF NOT EXISTS live_practice_to   time,
    -- Which kind of session the last beacon belonged to. Only used to spot
    -- the change, so it is never read by anything the drivers see.
    ADD COLUMN IF NOT EXISTS live_session_mode  text;


-- The league runs on UK time and the window is a wall-clock one: six in the
-- evening stays six in the evening either side of the March change, which
-- storing an offset would not.
CREATE OR REPLACE FUNCTION public.live_practice_tz()
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public AS $$
    SELECT 'Europe/London';
$$;

-- Longest window allowed. Not a technical limit now that sessions clean up
-- after themselves, but a round left permanently open would show up as a
-- live session on the public page every day of the week.
CREATE OR REPLACE FUNCTION public.live_practice_max_hours()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 8; $$;

GRANT EXECUTE ON FUNCTION public.live_practice_tz()        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.live_practice_max_hours() TO anon, authenticated;


-- ---- is the window open right now ----
-- Handles a window that runs past midnight, which 18:00 to 22:00 does not
-- but 22:00 to 01:00 would, so the schedule is not quietly restricted to
-- the shape we happen to want first.
CREATE OR REPLACE FUNCTION public.live_in_practice(p_from time, p_to time)
RETURNS boolean LANGUAGE sql STABLE SET search_path = public AS $$
    WITH t AS (SELECT (now() AT TIME ZONE public.live_practice_tz())::time AS local)
    SELECT CASE
        WHEN p_from IS NULL OR p_to IS NULL OR p_from = p_to THEN false
        WHEN p_from < p_to THEN (SELECT local FROM t) >= p_from AND (SELECT local FROM t) < p_to
        ELSE                    (SELECT local FROM t) >= p_from OR  (SELECT local FROM t) < p_to
    END;
$$;

GRANT EXECUTE ON FUNCTION public.live_in_practice(time, time) TO anon, authenticated;


-- ============================================================
-- One definition of "which round is live", now with a mode.
-- Return type changes, so it has to be dropped rather than replaced.
-- ============================================================
DROP FUNCTION IF EXISTS public.live_active_event();

CREATE FUNCTION public.live_active_event()
RETURNS TABLE (event_id uuid, is_test boolean, mode text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH candidate AS (
        SELECT e.id,
               e.starts_at,
               COALESCE(now() BETWEEN e.starts_at - interval '2 hours'
                                  AND e.starts_at + (e.duration_hours * interval '1 hour')
                                      + interval '2 hours', false) AS in_race,
               COALESCE(e.live_test_until IS NOT NULL AND now() < e.live_test_until, false) AS in_test,
               COALESCE(public.live_in_practice(e.live_practice_from, e.live_practice_to), false) AS in_practice
        FROM   events e
        WHERE  e.status <> 'completed'
          AND  e.status <> 'cancelled'
    )
    SELECT id,
           NOT in_race,
           CASE WHEN in_race THEN 'race' WHEN in_test THEN 'test' ELSE 'practice' END
    FROM   candidate
    WHERE  in_race OR in_test OR in_practice
    -- A genuine race beats everything, and an admin's test beats a standing
    -- practice window, so neither can be hidden by the other.
    ORDER  BY in_race DESC, in_test DESC, starts_at
    LIMIT  1;
$$;

GRANT EXECUTE ON FUNCTION public.live_active_event() TO anon, authenticated;


-- ============================================================
-- What the portal and the live page need in order to say when practice is
-- on. Returns the schedule whether or not it is open at the moment, since
-- "back at six" is the useful answer at five o'clock.
-- ============================================================
CREATE OR REPLACE FUNCTION public.live_practice_window()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_tz    text := public.live_practice_tz();
    v_e     record;
    v_local timestamp;
    v_day   timestamp;
    v_open  boolean;
    v_at    timestamptz;
BEGIN
    SELECT e.id, e.name, e.round, e.circuit_name,
           e.live_practice_from AS p_from, e.live_practice_to AS p_to
      INTO v_e
      FROM events e
     WHERE e.status <> 'completed'
       AND e.status <> 'cancelled'
       AND e.live_practice_from IS NOT NULL
       AND e.live_practice_to   IS NOT NULL
     ORDER BY e.starts_at
     LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('enabled', false);
    END IF;

    v_local := now() AT TIME ZONE v_tz;
    v_day   := date_trunc('day', v_local);
    v_open  := public.live_in_practice(v_e.p_from, v_e.p_to);

    -- When it closes if it is open, when it next opens if it is not. Built in
    -- local time and converted once, so adding a day never lands an hour out
    -- across a clock change.
    v_at := (v_day + CASE WHEN v_open THEN v_e.p_to ELSE v_e.p_from END) AT TIME ZONE v_tz;
    IF v_at <= now() THEN
        v_at := (v_day + interval '1 day'
                 + CASE WHEN v_open THEN v_e.p_to ELSE v_e.p_from END) AT TIME ZONE v_tz;
    END IF;

    RETURN jsonb_build_object(
        'enabled',      true,
        'open',         v_open,
        'event_id',     v_e.id,
        'event_name',   v_e.name,
        'round',        v_e.round,
        'circuit_name', v_e.circuit_name,
        'from',         to_char(v_e.p_from, 'HH24:MI'),
        'to',           to_char(v_e.p_to,   'HH24:MI'),
        -- Closing time while open, next opening time while shut.
        'at',           v_at,
        'tz',           v_tz
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_practice_window() TO anon, authenticated;


-- ---- set and clear the schedule ----
CREATE OR REPLACE FUNCTION public.live_practice_set(p_event_id uuid, p_from time, p_to time)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_span interval;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
    END IF;
    IF p_from IS NULL OR p_to IS NULL OR p_from = p_to THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Give a start and an end time.');
    END IF;

    v_span := CASE WHEN p_to > p_from THEN p_to - p_from
                   ELSE (p_to + interval '24 hours') - p_from END;
    IF v_span > (public.live_practice_max_hours() * interval '1 hour') THEN
        RETURN jsonb_build_object('ok', false,
            'error', format('Keep it to %s hours or less.', public.live_practice_max_hours()));
    END IF;

    UPDATE events
       SET live_practice_from = p_from,
           live_practice_to   = p_to
     WHERE id = p_event_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'No such event.');
    END IF;

    RETURN jsonb_build_object(
        'ok',   true,
        'from', to_char(p_from, 'HH24:MI'),
        'to',   to_char(p_to,   'HH24:MI'),
        'tz',   public.live_practice_tz()
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.live_practice_clear(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cleared int;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
    END IF;

    UPDATE events SET live_practice_from = NULL, live_practice_to = NULL WHERE id = p_event_id;

    -- Clear the cars, as ending a test does. The outline stays: it is this
    -- round's circuit either way, and having it already drawn on race day is
    -- the one lasting benefit of a week of practice.
    DELETE FROM live_positions WHERE event_id = p_event_id;
    GET DIAGNOSTICS v_cleared = ROW_COUNT;

    RETURN jsonb_build_object('ok', true, 'cleared', v_cleared);
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_practice_set(uuid, time, time) TO authenticated;
GRANT EXECUTE ON FUNCTION public.live_practice_clear(uuid)           TO authenticated;


-- ============================================================
-- The beacon: carries the mode, and keeps one session's cars out of the
-- next one's.
-- ============================================================
CREATE OR REPLACE FUNCTION public.live_beacon(
    p_token        text,
    p_lap          int     DEFAULT NULL,
    p_lap_ms       int     DEFAULT NULL,
    p_last_lap_ms  int     DEFAULT NULL,
    p_best_lap_ms  int     DEFAULT NULL,
    p_x            real    DEFAULT NULL,
    p_z            real    DEFAULT NULL,
    p_speed_kph    int     DEFAULT NULL,
    p_on_track     boolean DEFAULT true,
    p_fuel_pct     real    DEFAULT NULL,
    p_laps_in_race int     DEFAULT NULL,
    p_y            real    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_driver_id uuid;
    v_event_id  uuid;
    v_is_test   boolean;
    v_mode      text;
    v_prev_mode text;
    v_lobby     int;
    v_entered   boolean;
    v_last      timestamptz;
    v_shape     uuid;
    v_shape_ok  boolean;
    v_points    int;
BEGIN
    SELECT driver_id INTO v_driver_id
      FROM live_timing_tokens
     WHERE token = p_token AND revoked_at IS NULL;

    IF v_driver_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not paired.');
    END IF;

    SELECT event_id, is_test, mode INTO v_event_id, v_is_test, v_mode FROM live_active_event();

    IF v_event_id IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'reporting', false,
            'reason', 'No race in progress.',
            'next_ms', public.live_beacon_idle_ms());
    END IF;

    SELECT en.lobby_number INTO v_lobby
      FROM entries en
      JOIN entry_drivers ed ON ed.entry_id = en.id
     WHERE en.event_id = v_event_id AND ed.driver_id = v_driver_id
     LIMIT 1;
    v_entered := FOUND;

    IF NOT v_entered AND NOT COALESCE(v_is_test, false) THEN
        RETURN jsonb_build_object('ok', true, 'reporting', false,
            'reason', 'Not entered for this round.',
            'next_ms', public.live_beacon_idle_ms());
    END IF;

    -- A round that has moved between practice, test and race has started a
    -- different session, and the previous one's cars are not part of it. This
    -- is what keeps last night's practice off race day.
    SELECT live_session_mode INTO v_prev_mode FROM events WHERE id = v_event_id;
    IF v_prev_mode IS DISTINCT FROM v_mode THEN
        DELETE FROM live_positions WHERE event_id = v_event_id;
        UPDATE events SET live_session_mode = v_mode WHERE id = v_event_id;
    END IF;

    SELECT updated_at INTO v_last
      FROM live_positions
     WHERE event_id = v_event_id AND driver_id = v_driver_id;

    -- First beacon of a session, so sweep up anything left over from the last
    -- one — a nightly window is never closed by hand. Only outside a race,
    -- where a car that has stopped reporting is a retirement worth showing
    -- rather than yesterday's leftovers.
    IF v_mode <> 'race' AND (v_last IS NULL OR now() - v_last > interval '15 minutes') THEN
        DELETE FROM live_positions
         WHERE event_id = v_event_id AND updated_at < now() - interval '15 minutes';
    END IF;

    IF v_last IS NOT NULL AND now() - v_last < interval '1.2 seconds' THEN
        RETURN jsonb_build_object('ok', true, 'reporting', true, 'throttled', true);
    END IF;

    INSERT INTO live_positions AS lp (
        event_id, driver_id, lobby_number, lap, lap_ms, last_lap_ms,
        best_lap_ms, x, y, z, speed_kph, on_track, fuel_pct, laps_in_race, updated_at
    ) VALUES (
        v_event_id, v_driver_id, v_lobby, COALESCE(p_lap, 0), p_lap_ms, p_last_lap_ms,
        p_best_lap_ms, p_x, p_y, p_z, p_speed_kph, COALESCE(p_on_track, true),
        p_fuel_pct, p_laps_in_race, now()
    )
    ON CONFLICT (event_id, driver_id) DO UPDATE SET
        lobby_number = COALESCE(EXCLUDED.lobby_number, lp.lobby_number),
        lap          = GREATEST(lp.lap, COALESCE(EXCLUDED.lap, 0)),
        lap_ms       = EXCLUDED.lap_ms,
        last_lap_ms  = COALESCE(EXCLUDED.last_lap_ms, lp.last_lap_ms),
        best_lap_ms  = LEAST(COALESCE(EXCLUDED.best_lap_ms, lp.best_lap_ms),
                             COALESCE(lp.best_lap_ms, EXCLUDED.best_lap_ms)),
        x            = EXCLUDED.x,
        y            = EXCLUDED.y,
        z            = EXCLUDED.z,
        speed_kph    = EXCLUDED.speed_kph,
        on_track     = EXCLUDED.on_track,
        fuel_pct     = COALESCE(EXCLUDED.fuel_pct, lp.fuel_pct),
        laps_in_race = COALESCE(EXCLUDED.laps_in_race, lp.laps_in_race),
        updated_at   = now();

    UPDATE live_timing_tokens SET last_used_at = now() WHERE token = p_token;

    IF COALESCE(p_on_track, true) AND p_x IS NOT NULL AND p_z IS NOT NULL THEN
        SELECT shape_driver_id INTO v_shape FROM events WHERE id = v_event_id;

        IF v_shape IS NULL OR NOT EXISTS (
               SELECT 1 FROM live_positions
                WHERE event_id = v_event_id AND driver_id = v_shape
                  AND updated_at > now() - interval '2 minutes'
           ) THEN
            UPDATE events SET shape_driver_id = v_driver_id WHERE id = v_event_id;
            v_shape := v_driver_id;
        END IF;

        v_shape_ok := (v_shape = v_driver_id);

        IF v_shape_ok THEN
            SELECT COUNT(*) INTO v_points FROM live_track_path WHERE event_id = v_event_id;
            IF v_points < public.live_track_path_max() THEN
                INSERT INTO live_track_path (event_id, seq, x, y, z)
                SELECT v_event_id,
                       COALESCE((SELECT MAX(seq) FROM live_track_path WHERE event_id = v_event_id), 0) + 1,
                       p_x, p_y, p_z;
            END IF;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'reporting', true,
        'test', COALESCE(v_is_test, false),
        -- 'race', 'test' or 'practice', so a reporter can say which.
        'mode', v_mode,
        'no_entry', NOT v_entered,
        'shaping', COALESCE(v_shape_ok, false),
        'next_ms', public.live_beacon_interval_ms(p_on_track)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_beacon(text, int, int, int, int, real, real, int, boolean, real, int, real)
    TO anon, authenticated;


-- ============================================================
-- The field, with the mode carried through so the page can name the session
-- rather than calling an open practice evening a test.
-- ============================================================
DROP FUNCTION IF EXISTS public.live_field(uuid);

CREATE FUNCTION public.live_field(p_event_id uuid DEFAULT NULL)
RETURNS TABLE (
    event_id     uuid,
    event_name   text,
    round        int,
    is_test      boolean,
    mode         text,
    driver_id    uuid,
    display_name text,
    car_number   int,
    team_name    text,
    lobby_number int,
    lap          int,
    lap_ms       int,
    last_lap_ms  int,
    best_lap_ms  int,
    x            real,
    y            real,
    z            real,
    speed_kph    int,
    on_track     boolean,
    fuel_pct     real,
    laps_in_race int,
    age_ms       int
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH active AS (SELECT * FROM live_active_event()),
    target AS (
        SELECT COALESCE(p_event_id, (SELECT a.event_id FROM active a)) AS id,
               COALESCE((SELECT a.is_test FROM active a), false)       AS is_test,
               COALESCE((SELECT a.mode    FROM active a), 'race')      AS mode
    )
    SELECT
        e.id, e.name, e.round, target.is_test, target.mode,
        d.id, d.display_name, en.car_number, t.name,
        lp.lobby_number, lp.lap, lp.lap_ms, lp.last_lap_ms, lp.best_lap_ms,
        lp.x, lp.y, lp.z, lp.speed_kph, lp.on_track, lp.fuel_pct, lp.laps_in_race,
        (EXTRACT(EPOCH FROM (now() - lp.updated_at)) * 1000)::int
    FROM   live_positions lp
    JOIN   target        ON target.id = lp.event_id
    JOIN   events  e     ON e.id = lp.event_id
    JOIN   drivers d     ON d.id = lp.driver_id
    LEFT   JOIN entries en ON en.event_id = lp.event_id
            AND EXISTS (SELECT 1 FROM entry_drivers ed
                         WHERE ed.entry_id = en.id AND ed.driver_id = lp.driver_id)
    LEFT   JOIN teams t  ON t.id = d.current_team_id
    ORDER BY lp.lobby_number, lp.lap DESC;
$$;

GRANT EXECUTE ON FUNCTION public.live_field(uuid) TO anon, authenticated;
