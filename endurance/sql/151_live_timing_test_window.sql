-- ============================================================
-- 151 A test window for live timing
--
-- 149 decides whether a round is on from the clock: two hours either side
-- of the race. That is right for drivers, and useless for testing, since
-- the only way to see the thing work was to wait for Saturday or shift a
-- real event's start time and risk notifications, split generation and
-- the public calendar.
--
-- An admin can now open a short live window on a chosen event instead.
-- Nothing about the event changes: no fake round on the calendar, no
-- altered start time, and it closes itself when it expires.
--
-- Both the beacon and the page now resolve "which round is live" through
-- one helper rather than repeating the window logic, so the two can no
-- longer disagree about it. A real race always beats a test window left
-- open by accident.
--
-- The page is told when it is showing a test, so a viewer who wanders in
-- sees "Test" rather than being misled into thinking a race is running.
-- ============================================================

ALTER TABLE events ADD COLUMN IF NOT EXISTS live_test_until timestamptz;


-- ---- one definition of "live", used by everything ----
CREATE OR REPLACE FUNCTION public.live_active_event()
RETURNS TABLE (event_id uuid, is_test boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH candidate AS (
        SELECT e.id,
               e.starts_at,
               (now() BETWEEN e.starts_at - interval '2 hours'
                          AND e.starts_at + (e.duration_hours * interval '1 hour')
                              + interval '2 hours') AS in_race_window,
               (e.live_test_until IS NOT NULL AND now() < e.live_test_until) AS in_test_window
        FROM   events e
        WHERE  e.status <> 'completed'
          AND  e.status <> 'cancelled'
    )
    SELECT id, NOT in_race_window
    FROM   candidate
    WHERE  in_race_window OR in_test_window
    -- A genuine race wins, so a forgotten test window can never hide one.
    ORDER  BY in_race_window DESC, starts_at
    LIMIT  1;
$$;

GRANT EXECUTE ON FUNCTION public.live_active_event() TO anon, authenticated;


-- ---- open and close a test window ----
CREATE OR REPLACE FUNCTION public.live_test_open(p_event_id uuid, p_minutes int DEFAULT 60)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_until timestamptz;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
    END IF;
    -- Capped at four hours. A window left open for a week would quietly
    -- keep accepting beacons and show stale cars to anyone visiting.
    IF p_minutes IS NULL OR p_minutes < 1 OR p_minutes > 240 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Pick between 1 and 240 minutes.');
    END IF;

    v_until := now() + (p_minutes * interval '1 minute');
    UPDATE events SET live_test_until = v_until WHERE id = p_event_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'No such event.');
    END IF;

    RETURN jsonb_build_object('ok', true, 'until', v_until, 'minutes', p_minutes);
END;
$$;

CREATE OR REPLACE FUNCTION public.live_test_close(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cleared int;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
    END IF;

    UPDATE events SET live_test_until = NULL WHERE id = p_event_id;
    -- Clear the cars too, so a test never leaves anything behind to be
    -- mistaken for a real result later.
    DELETE FROM live_positions WHERE event_id = p_event_id;
    GET DIAGNOSTICS v_cleared = ROW_COUNT;

    RETURN jsonb_build_object('ok', true, 'cleared', v_cleared);
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_test_open(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.live_test_close(uuid)      TO authenticated;


-- ============================================================
-- Rebuild the two functions that resolved the window themselves.
-- ============================================================
CREATE OR REPLACE FUNCTION public.live_beacon(
    p_token       text,
    p_lap         int     DEFAULT NULL,
    p_lap_ms      int     DEFAULT NULL,
    p_last_lap_ms int     DEFAULT NULL,
    p_best_lap_ms int     DEFAULT NULL,
    p_x           real    DEFAULT NULL,
    p_z           real    DEFAULT NULL,
    p_speed_kph   int     DEFAULT NULL,
    p_on_track    boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_driver_id uuid;
    v_event_id  uuid;
    v_is_test   boolean;
    v_lobby     int;
    v_last      timestamptz;
BEGIN
    SELECT driver_id INTO v_driver_id
      FROM live_timing_tokens
     WHERE token = p_token AND revoked_at IS NULL;

    IF v_driver_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not paired.');
    END IF;

    SELECT event_id, is_test INTO v_event_id, v_is_test FROM live_active_event();

    IF v_event_id IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'reporting', false, 'reason', 'No race in progress.');
    END IF;

    SELECT en.lobby_number INTO v_lobby
      FROM entries en
      JOIN entry_drivers ed ON ed.entry_id = en.id
     WHERE en.event_id = v_event_id AND ed.driver_id = v_driver_id
     LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', true, 'reporting', false, 'reason', 'Not entered for this round.');
    END IF;

    SELECT updated_at INTO v_last
      FROM live_positions
     WHERE event_id = v_event_id AND driver_id = v_driver_id;

    IF v_last IS NOT NULL AND now() - v_last < interval '1.5 seconds' THEN
        RETURN jsonb_build_object('ok', true, 'reporting', true, 'throttled', true);
    END IF;

    INSERT INTO live_positions AS lp (
        event_id, driver_id, lobby_number, lap, lap_ms, last_lap_ms,
        best_lap_ms, x, z, speed_kph, on_track, updated_at
    ) VALUES (
        v_event_id, v_driver_id, v_lobby, COALESCE(p_lap, 0), p_lap_ms, p_last_lap_ms,
        p_best_lap_ms, p_x, p_z, p_speed_kph, COALESCE(p_on_track, true), now()
    )
    ON CONFLICT (event_id, driver_id) DO UPDATE SET
        lobby_number = COALESCE(EXCLUDED.lobby_number, lp.lobby_number),
        lap          = GREATEST(lp.lap, COALESCE(EXCLUDED.lap, 0)),
        lap_ms       = EXCLUDED.lap_ms,
        last_lap_ms  = COALESCE(EXCLUDED.last_lap_ms, lp.last_lap_ms),
        best_lap_ms  = LEAST(COALESCE(EXCLUDED.best_lap_ms, lp.best_lap_ms),
                             COALESCE(lp.best_lap_ms, EXCLUDED.best_lap_ms)),
        x            = EXCLUDED.x,
        z            = EXCLUDED.z,
        speed_kph    = EXCLUDED.speed_kph,
        on_track     = EXCLUDED.on_track,
        updated_at   = now();

    UPDATE live_timing_tokens SET last_used_at = now() WHERE token = p_token;

    RETURN jsonb_build_object(
        'ok', true,
        'reporting', true,
        -- Says so plainly, so a driver testing knows this is not a real race.
        'test', COALESCE(v_is_test, false),
        'next_ms', CASE WHEN COALESCE(p_on_track, true) THEN 3000 ELSE 15000 END
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_beacon(text, int, int, int, int, real, real, int, boolean)
    TO anon, authenticated;


DROP FUNCTION IF EXISTS public.live_field(uuid);

CREATE OR REPLACE FUNCTION public.live_field(p_event_id uuid DEFAULT NULL)
RETURNS TABLE (
    event_id     uuid,
    event_name   text,
    round        int,
    is_test      boolean,
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
    z            real,
    speed_kph    int,
    on_track     boolean,
    age_ms       int
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH active AS (SELECT * FROM live_active_event()),
    target AS (
        SELECT COALESCE(p_event_id, (SELECT a.event_id FROM active a)) AS id,
               COALESCE((SELECT a.is_test FROM active a), false)       AS is_test
    )
    SELECT
        e.id, e.name, e.round, target.is_test,
        d.id, d.display_name, en.car_number, t.name,
        lp.lobby_number, lp.lap, lp.lap_ms, lp.last_lap_ms, lp.best_lap_ms,
        lp.x, lp.z, lp.speed_kph, lp.on_track,
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
