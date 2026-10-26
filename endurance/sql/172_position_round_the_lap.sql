-- ============================================================
-- 172 Distance round the lap, so the first column is a position
--
-- The number in the first column of each split was the row's place in the
-- list. During a race that reads as position, and it was not one: cars on
-- the same lap were separated by time into the lap, which assumes everyone
-- is going at the same speed, so a car that had pitted or spun ranked
-- ahead of one genuinely in front of it.
--
-- Now it is measured. Since 169 the stored outline is a lap that starts at
-- the start/finish line, so a car's nearest point along it is how far round
-- it has got. Laps completed plus that is a true order among the cars that
-- are reporting, and the same number gives gaps.
--
-- Two things make it cheap. The distances along the outline are worked out
-- once, when the lap closes, not on every read. And each car's place on it
-- is worked out by the beacon, once per car per beacon, rather than by
-- live_field, which every viewer calls every poll.
--
-- What it still is not: a position in the RACE. Only drivers who have
-- paired a reporter are on this list at all, so a car showing 1 is first of
-- those reporting and could be eighth on the road. The page says so, and
-- says it differently depending on whether a split is fully covered.
-- ============================================================

ALTER TABLE live_track_path
    ADD COLUMN IF NOT EXISTS dist_m real;

ALTER TABLE live_positions
    ADD COLUMN IF NOT EXISTS track_seq  int,
    ADD COLUMN IF NOT EXISTS progress_m real;

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS lap_length_m real;


-- Walk the stored outline and record how far round the lap each point is.
-- Called once, when the lap closes. An outline that closed before this
-- migration has no distances, so an admin clearing and retracing it is how
-- those rounds get them; until then the order falls back to time into the
-- lap, exactly as it did before.
CREATE OR REPLACE FUNCTION public.live_track_measure(p_event_id uuid)
RETURNS real LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_total real;
BEGIN
    WITH ordered AS (
        SELECT seq, x, z,
               LAG(x) OVER (ORDER BY seq) AS prev_x,
               LAG(z) OVER (ORDER BY seq) AS prev_z
          FROM live_track_path WHERE event_id = p_event_id
    ), run AS (
        SELECT seq,
               SUM(COALESCE(sqrt(power(x - prev_x, 2) + power(z - prev_z, 2)), 0))
                   OVER (ORDER BY seq) AS d
          FROM ordered
    )
    UPDATE live_track_path p
       SET dist_m = run.d::real
      FROM run
     WHERE p.event_id = p_event_id AND p.seq = run.seq;

    -- The lap is the traced line plus the step from the last point back to
    -- the first, which is the bit that closes it and is never stored.
    SELECT (SELECT MAX(dist_m) FROM live_track_path WHERE event_id = p_event_id)
         + COALESCE((
             SELECT sqrt(power(l.x - f.x, 2) + power(l.z - f.z, 2))
               FROM (SELECT x, z FROM live_track_path WHERE event_id = p_event_id
                      ORDER BY seq DESC LIMIT 1) l,
                    (SELECT x, z FROM live_track_path WHERE event_id = p_event_id
                      ORDER BY seq ASC  LIMIT 1) f), 0)
      INTO v_total;

    UPDATE events SET lap_length_m = v_total WHERE id = p_event_id;
    RETURN v_total;
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_track_measure(uuid) TO authenticated;


-- Clearing the outline drops the measurement with it.
CREATE OR REPLACE FUNCTION public.live_track_clear(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_gone int;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
    END IF;

    DELETE FROM live_track_path WHERE event_id = p_event_id;
    GET DIAGNOSTICS v_gone = ROW_COUNT;
    UPDATE events
       SET shape_driver_id = NULL,
           shape_closed    = false,
           shape_lap_from  = NULL,
           shape_armed     = false,
           shape_pinned    = false,
           lap_length_m    = NULL
     WHERE id = p_event_id;
    UPDATE live_positions
       SET track_seq = NULL, progress_m = NULL
     WHERE event_id = p_event_id;

    RETURN jsonb_build_object('ok', true, 'cleared', v_gone);
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_track_clear(uuid) TO authenticated;


-- Starting a map does the same, since it clears the outline too.
CREATE OR REPLACE FUNCTION public.live_track_start(p_event_id uuid, p_driver_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_gone int; v_name text;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
    END IF;

    SELECT display_name INTO v_name FROM drivers WHERE id = p_driver_id;
    IF v_name IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'No such driver.');
    END IF;

    DELETE FROM live_track_path WHERE event_id = p_event_id;
    GET DIAGNOSTICS v_gone = ROW_COUNT;

    UPDATE events
       SET shape_driver_id = p_driver_id,
           shape_closed    = false,
           shape_lap_from  = NULL,
           shape_armed     = false,
           shape_pinned    = true,
           lap_length_m    = NULL
     WHERE id = p_event_id;
    UPDATE live_positions
       SET track_seq = NULL, progress_m = NULL
     WHERE event_id = p_event_id;

    RETURN jsonb_build_object('ok', true, 'cleared', v_gone, 'driver', v_name);
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_track_start(uuid, uuid) TO authenticated;


-- How many of a split's entered cars are actually reporting, so the page can
-- tell the difference between a position and a place in a list.
CREATE OR REPLACE FUNCTION public.live_split_coverage(p_event_id uuid DEFAULT NULL)
RETURNS TABLE (lobby_number int, entered int, reporting int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH target AS (
        SELECT COALESCE(p_event_id, (SELECT event_id FROM live_active_event())) AS id
    ), cars AS (
        SELECT en.lobby_number, en.id AS entry_id
          FROM entries en, target
         WHERE en.event_id = target.id
           AND COALESCE(en.status, 'confirmed') <> 'withdrawn'
           AND en.lobby_number IS NOT NULL
    )
    SELECT c.lobby_number,
           COUNT(*)::int,
           COUNT(*) FILTER (WHERE EXISTS (
               SELECT 1 FROM live_positions lp, target
                WHERE lp.event_id = target.id
                  AND lp.updated_at > now() - interval '30 seconds'
                  AND EXISTS (SELECT 1 FROM entry_drivers ed
                               WHERE ed.entry_id = c.entry_id
                                 AND ed.driver_id = lp.driver_id)))::int
      FROM cars c
     GROUP BY c.lobby_number
     ORDER BY c.lobby_number;
$$;

GRANT EXECUTE ON FUNCTION public.live_split_coverage(uuid) TO anon, authenticated;


DROP FUNCTION IF EXISTS public.live_field(uuid);

CREATE FUNCTION public.live_field(p_event_id uuid DEFAULT NULL)
RETURNS TABLE (
    event_id      uuid,
    event_name    text,
    round         int,
    is_test       boolean,
    mode          text,
    driver_id     uuid,
    display_name  text,
    car_number    int,
    career_number int,
    team_name     text,
    team_id       uuid,
    brand_color   text,
    lobby_number  int,
    lap           int,
    lap_ms        int,
    last_lap_ms   int,
    best_lap_ms   int,
    x             real,
    y             real,
    z             real,
    speed_kph     int,
    on_track      boolean,
    fuel_pct      real,
    laps_in_race  int,
    client        text,
    age_ms        int,
    progress_m    real,
    lap_length_m  real
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
        d.id, d.display_name, en.car_number, d.career_number,
        t.name, t.id, m.brand_color,
        lp.lobby_number, lp.lap, lp.lap_ms, lp.last_lap_ms, lp.best_lap_ms,
        lp.x, lp.y, lp.z, lp.speed_kph, lp.on_track, lp.fuel_pct, lp.laps_in_race,
        lp.client,
        (EXTRACT(EPOCH FROM (now() - lp.updated_at)) * 1000)::int,
        lp.progress_m, e.lap_length_m
    FROM   live_positions lp
    JOIN   target        ON target.id = lp.event_id
    JOIN   events  e     ON e.id = lp.event_id
    JOIN   drivers d     ON d.id = lp.driver_id
    LEFT   JOIN entries en ON en.event_id = lp.event_id
            AND EXISTS (SELECT 1 FROM entry_drivers ed
                         WHERE ed.entry_id = en.id AND ed.driver_id = lp.driver_id)
    LEFT   JOIN teams t  ON t.id = d.current_team_id
    -- The manufacturer the driver is actually running, which is the team's
    -- unless they have one of their own set.
    LEFT   JOIN manufacturers m
            ON m.id = COALESCE(d.current_manufacturer_id, t.manufacturer_id)
    -- Ordered by whatever the session is actually about.
    --
    -- In a race that is laps completed, then how far into the current lap,
    -- which is a decent guess at running order when the cars are going at
    -- similar speeds and is honest about being a guess. A real one needs
    -- distance round the lap, which has only just become possible: since
    -- 169 the stored outline starts at the start/finish line, so a car's
    -- nearest point on it IS its progress. Worth doing properly, and best
    -- done by the beacon once per car rather than by every viewer's poll.
    --
    -- In practice it is the best lap, because laps completed in a practice
    -- session is not a ranking of anything. Someone who joined an hour ago
    -- has thirty and someone who joined at the last corner has one, and the
    -- order rearranges itself every time anybody crosses the line. Fastest
    -- first is what a practice screen is for, and it holds still.
    --
    -- Drivers with no lap time yet go to the bottom rather than the top.
    -- driver_id last so that nothing can tie.
    ORDER BY lp.lobby_number,
             CASE WHEN target.mode =  'race' THEN lp.lap         END DESC NULLS LAST,
             -- Measured, where there is a measurement: distance round the
             -- lap, from the car's nearest point on the stored outline. Time
             -- into the lap stays as the fallback for a round whose outline
             -- is not finished yet, and is a guess, as its comment in 171
             -- said.
             CASE WHEN target.mode =  'race' THEN lp.progress_m  END DESC NULLS LAST,
             CASE WHEN target.mode =  'race' THEN lp.lap_ms      END DESC NULLS LAST,
             CASE WHEN target.mode <> 'race' THEN lp.best_lap_ms END ASC  NULLS LAST,
             lp.driver_id;
$$;

GRANT EXECUTE ON FUNCTION public.live_field(uuid) TO anon, authenticated;


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
    p_y            real    DEFAULT NULL,
    p_client       text    DEFAULT NULL
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
    v_lastx     real; v_lastz real;
    v_step      double precision;
    v_near      double precision;
    v_closed    boolean := false;
    v_lap_from  int;
    v_armed     boolean;
    v_pinned    boolean;
    v_seq       int;
    v_prog      real;
    v_drawn_by  uuid;
    v_elsewhere boolean := false;
    v_client    text;
BEGIN
    SELECT driver_id INTO v_driver_id
      FROM live_timing_tokens
     WHERE token = p_token AND revoked_at IS NULL;

    IF v_driver_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not paired.');
    END IF;

    v_client := public.live_client_slug(p_client);

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

    SELECT live_session_mode INTO v_prev_mode FROM events WHERE id = v_event_id;
    IF v_prev_mode IS DISTINCT FROM v_mode THEN
        DELETE FROM live_positions WHERE event_id = v_event_id;
        UPDATE events SET live_session_mode = v_mode WHERE id = v_event_id;
    END IF;

    SELECT updated_at INTO v_last
      FROM live_positions
     WHERE event_id = v_event_id AND driver_id = v_driver_id;

    IF v_mode <> 'race' AND (v_last IS NULL OR now() - v_last > interval '15 minutes') THEN
        DELETE FROM live_positions
         WHERE event_id = v_event_id AND updated_at < now() - interval '15 minutes';
    END IF;

    IF v_last IS NOT NULL AND now() - v_last < interval '1.2 seconds' THEN
        RETURN jsonb_build_object('ok', true, 'reporting', true, 'throttled', true);
    END IF;

    INSERT INTO live_positions AS lp (
        event_id, driver_id, lobby_number, lap, lap_ms, last_lap_ms,
        best_lap_ms, x, y, z, speed_kph, on_track, fuel_pct, laps_in_race,
        client, updated_at
    ) VALUES (
        v_event_id, v_driver_id, v_lobby, COALESCE(p_lap, 0), p_lap_ms, p_last_lap_ms,
        p_best_lap_ms, p_x, p_y, p_z, p_speed_kph, COALESCE(p_on_track, true),
        p_fuel_pct, p_laps_in_race, v_client, now()
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
        client       = COALESCE(EXCLUDED.client, lp.client),
        updated_at   = now();

    UPDATE live_timing_tokens SET last_used_at = now() WHERE token = p_token;

    -- How far round the lap this car is, which is what turns the number in
    -- the first column from a place in a list into a position. Only once the
    -- outline is a finished lap: before that it is a part-traced line that
    -- starts nowhere in particular, so a distance along it would mean
    -- nothing. Only while on track, because a car in its pit box has no
    -- position on the circuit and should keep the last one it had.
    --
    -- A scan of the stored points, which is at most 2,000 rows of three
    -- numbers. Done here, once per car per beacon, rather than in live_field,
    -- which every viewer calls every poll.
    IF COALESCE(p_on_track, true) AND p_x IS NOT NULL AND p_z IS NOT NULL
       AND COALESCE((SELECT shape_closed FROM events WHERE id = v_event_id), false) THEN
        SELECT seq, dist_m INTO v_seq, v_prog
          FROM live_track_path
         WHERE event_id = v_event_id
         ORDER BY power(x - p_x, 2) + power(z - p_z, 2)
         LIMIT 1;
        UPDATE live_positions
           SET track_seq = v_seq, progress_m = v_prog
         WHERE event_id = v_event_id AND driver_id = v_driver_id;
    END IF;

    IF COALESCE(p_on_track, true) AND p_x IS NOT NULL AND p_z IS NOT NULL THEN
        SELECT COUNT(*) INTO v_points FROM live_track_path WHERE event_id = v_event_id;
        SELECT shape_driver_id, shape_closed, shape_lap_from, shape_armed, shape_pinned
          INTO v_shape, v_closed, v_lap_from, v_armed, v_pinned
          FROM events WHERE id = v_event_id;

        IF NOT COALESCE(v_closed, false) THEN
            SELECT x, z INTO v_lastx, v_lastz
              FROM live_track_path WHERE event_id = v_event_id
             ORDER BY seq DESC LIMIT 1;
            v_step := CASE WHEN v_lastx IS NULL THEN NULL
                           ELSE sqrt(power(p_x - v_lastx, 2) + power(p_z - v_lastz, 2)) END;

            IF v_shape = v_driver_id THEN
                IF v_step IS NOT NULL AND v_step > public.live_track_step_m() THEN
                    IF COALESCE(v_pinned, false) THEN
                        -- An admin named this driver, so a jump is them being
                        -- put back in the pits or resetting, not a reason to
                        -- hand the map to somebody else. Start their lap
                        -- again from here and keep the job with them.
                        --
                        -- The flip side, stated because it is a real one: a
                        -- named drawer who goes off to another circuit will
                        -- trace that circuit. Naming them is the admin saying
                        -- they trust them to drive this one.
                        DELETE FROM live_track_path WHERE event_id = v_event_id;
                        UPDATE events SET shape_armed    = false,
                                          shape_lap_from = p_lap
                         WHERE id = v_event_id;
                        v_points    := 0;
                        v_step      := NULL;
                        v_armed     := false;
                        v_shape_ok  := true;
                    ELSE
                        UPDATE events SET shape_driver_id = NULL, shape_lap_from = NULL
                         WHERE id = v_event_id;
                        v_elsewhere := true;
                    END IF;
                ELSE
                    v_shape_ok := true;

                    -- The lap counter is the only authority on whether a
                    -- lap is finished. Geometry cannot tell a completed lap
                    -- from a circuit passing under itself.
                    --
                    -- The first crossing does not finish the outline, it
                    -- starts it. A car picks the job up wherever it happens
                    -- to be, which is normally its pit box, so a trace from
                    -- there to the line carried the pit lane as though it
                    -- were track and stopped short of where it began: a gap
                    -- on the map between the line and the pit exit, and a
                    -- pit lane drawn as part of the circuit. So the first
                    -- crossing throws away what has been collected and
                    -- starts again at the line, and the next one, a full lap
                    -- later, closes it.
                    IF v_lap_from IS NOT NULL
                       AND p_lap IS NOT NULL
                       AND p_lap > v_lap_from THEN
                        IF NOT COALESCE(v_armed, false) THEN
                            DELETE FROM live_track_path WHERE event_id = v_event_id;
                            UPDATE events
                               SET shape_lap_from = p_lap,
                                   shape_armed    = true
                             WHERE id = v_event_id;
                            v_points := 0;
                            -- The step was measured against a point that no
                            -- longer exists, so this one starts the line.
                            v_step   := NULL;
                        ELSIF v_points >= public.live_track_min_shape_points() THEN
                            UPDATE events SET shape_closed = true WHERE id = v_event_id;
                            v_closed := true;
                            PERFORM public.live_track_measure(v_event_id);
                        END IF;
                    END IF;
                END IF;

            ELSE
                IF v_points >= public.live_track_min_shape_points() THEN
                    v_near := public.live_track_distance(v_event_id, p_x, p_z);
                    v_elsewhere := COALESCE(v_near, 0) > public.live_track_match_m();
                END IF;

                IF NOT v_elsewhere AND (v_shape IS NULL OR NOT EXISTS (
                       SELECT 1 FROM live_positions
                        WHERE event_id = v_event_id AND driver_id = v_shape
                          AND updated_at > now() - CASE
                                WHEN COALESCE(v_pinned, false) THEN interval '5 minutes'
                                ELSE interval '2 minutes' END
                   )) THEN
                    -- A handover starts the lap again rather than continuing
                    -- someone else's. Inheriting a half-traced lap and closing
                    -- it at the next crossing leaves a seam wherever the two
                    -- cars' sections fail to meet, which is the gap this was
                    -- all meant to remove, arrived at by another route.
                    --
                    -- Judged by who drew the last point rather than by who
                    -- held the job, so a driver who lost it to the jump guard
                    -- and immediately took it back does not wipe their own
                    -- work.
                    SELECT driver_id INTO v_drawn_by
                      FROM live_track_path WHERE event_id = v_event_id
                     ORDER BY seq DESC LIMIT 1;

                    IF v_points > 0 AND v_drawn_by IS DISTINCT FROM v_driver_id THEN
                        DELETE FROM live_track_path WHERE event_id = v_event_id;
                        UPDATE events SET shape_armed = false WHERE id = v_event_id;
                        v_points := 0;
                        v_step   := NULL;
                        v_armed  := false;
                    END IF;

                    -- Taking the job on starts the lap count from here, since
                    -- this car's lap numbering is its own. It also releases
                    -- any pin: whoever was named has gone quiet long enough
                    -- that holding the map for them would just block it.
                    UPDATE events
                       SET shape_driver_id = v_driver_id,
                           shape_lap_from  = p_lap,
                           shape_pinned    = false
                     WHERE id = v_event_id;
                    v_shape_ok := true;
                END IF;
            END IF;

            IF v_shape_ok
               AND NOT COALESCE(v_closed, false)
               AND v_points < public.live_track_path_max()
               AND (v_step IS NULL OR v_step >= public.live_track_min_step_m()) THEN
                INSERT INTO live_track_path (event_id, seq, x, y, z, driver_id)
                SELECT v_event_id,
                       COALESCE((SELECT MAX(seq) FROM live_track_path WHERE event_id = v_event_id), 0) + 1,
                       p_x, p_y, p_z, v_driver_id;
            END IF;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'reporting', true,
        'test', COALESCE(v_is_test, false),
        'mode', v_mode,
        'no_entry', NOT v_entered,
        'shaping', COALESCE(v_shape_ok, false),
        'outline_closed', COALESCE(v_closed, false),
        'elsewhere', v_elsewhere,
        'next_ms', public.live_beacon_interval_ms(p_on_track)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_beacon(text, int, int, int, int, real, real, int, boolean, real, int, real, text)
    TO anon, authenticated;
