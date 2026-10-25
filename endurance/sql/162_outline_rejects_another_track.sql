-- ============================================================
-- 162 The outline refuses positions from another track
--
-- A driver who leaves the connector running and goes off to hotlap Spa on a
-- Tuesday is still a paired driver sending valid beacons, and practice on
-- the next round is open. Three things follow, and the third is the one
-- that cannot be undone:
--
--   1. They appear in the live table as a practice car. Cosmetic.
--   2. The map's auto-fit spans every position it has, so one car on
--      another circuit stretches the frame across both and the real track
--      shrinks to a squiggle. Annoying, and fixed on the page.
--   3. If the current shape source goes quiet for two minutes, the next
--      beacon takes the job over, and that could be them. Their positions
--      are then appended to this round's stored outline, permanently.
--
-- GT7 never says which circuit you are on, and it does not need to. A car
-- moving more than a few hundred metres between two beacons 1.5 seconds
-- apart is not driving, it has been teleported: a track change, a restart,
-- or a return to the lobby. And once a few hundred points have traced a
-- circuit, a position well outside that box is categorically not on it.
--
-- So a point is appended only when it is continuous with the last one, or
-- lands inside the shape the path has already established. Either is true of
-- a car on this track, including the jump when the shape job hands over to
-- a different car. Neither is true of a car at Spa.
--
-- A car judged to be elsewhere also cannot take over the shape job, so it
-- can neither start nor continue a corrupt outline, and the beacon says so
-- in its reply rather than silently ignoring half of what it was sent.
--
-- The guard only applies once there is a shape to compare against, so the
-- first laps of a new round are captured exactly as before.
-- ============================================================

-- Furthest a car can credibly move between two beacons. 300 km/h over 1.5
-- seconds is 125 m, so this tolerates a couple of missed beacons as well.
CREATE OR REPLACE FUNCTION public.live_track_step_m()
RETURNS real LANGUAGE sql IMMUTABLE AS $$ SELECT 400::real; $$;

-- How many points before the path is treated as a shape worth defending.
-- Roughly a third of a Nordschleife lap at 1.5s, and a whole lap of most
-- circuits, by which point the bounding box is meaningful.
CREATE OR REPLACE FUNCTION public.live_track_min_shape_points()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 60; $$;

GRANT EXECUTE ON FUNCTION public.live_track_step_m()            TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.live_track_min_shape_points()  TO anon, authenticated;


-- The escape hatch that makes the guard safe to have. If a round's circuit
-- is changed, or a bad outline gets in before the guard has a shape to
-- defend, nothing could ever replace it: every later point would be judged
-- against the wrong track. This clears the outline and nothing else, so the
-- cars, the schedule and the session all carry on.
CREATE OR REPLACE FUNCTION public.live_track_clear(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_gone int;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
    END IF;

    DELETE FROM live_track_path WHERE event_id = p_event_id;
    GET DIAGNOSTICS v_gone = ROW_COUNT;
    -- Release the shape job too, or the same car carries on from where it
    -- left off and re-draws exactly what was just cleared.
    UPDATE events SET shape_driver_id = NULL WHERE id = p_event_id;

    RETURN jsonb_build_object('ok', true, 'cleared', v_gone);
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_track_clear(uuid) TO authenticated;


-- ============================================================
-- The beacon, with the guard. Everything else is unchanged from 161.
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
    v_minx      real; v_maxx real; v_minz real; v_maxz real;
    v_lastx     real; v_lastz real;
    v_diag      double precision;
    v_pad       double precision;
    v_elsewhere boolean := false;
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

    -- ---- the track outline ----
    IF COALESCE(p_on_track, true) AND p_x IS NOT NULL AND p_z IS NOT NULL THEN
        SELECT COUNT(*), MIN(x), MAX(x), MIN(z), MAX(z)
          INTO v_points, v_minx, v_maxx, v_minz, v_maxz
          FROM live_track_path WHERE event_id = v_event_id;

        -- Is this position anywhere near the circuit this round has traced?
        -- Only asked once there is a shape to ask about, so a brand new
        -- round still captures its first laps exactly as before.
        IF v_points >= public.live_track_min_shape_points() THEN
            SELECT x, z INTO v_lastx, v_lastz
              FROM live_track_path WHERE event_id = v_event_id
             ORDER BY seq DESC LIMIT 1;

            v_diag := sqrt(power(v_maxx - v_minx, 2) + power(v_maxz - v_minz, 2));
            -- A quarter of the circuit's own diagonal, which is wide enough
            -- for a long pit lane or a section not yet traced, and nowhere
            -- near wide enough to reach a different venue.
            v_pad  := GREATEST(v_diag * 0.25, 500);

            v_elsewhere := NOT (
                -- Continuous with the last point: ordinary driving.
                (v_lastx IS NOT NULL
                 AND sqrt(power(p_x - v_lastx, 2) + power(p_z - v_lastz, 2))
                     <= public.live_track_step_m())
                -- Or inside the shape already traced, which is what a
                -- handover to a different car on the same track looks like.
                OR (p_x BETWEEN v_minx - v_pad AND v_maxx + v_pad
                AND p_z BETWEEN v_minz - v_pad AND v_maxz + v_pad)
            );
        END IF;

        -- A car that wandered off while holding the shape job must give it
        -- up. Its own points are refused, and because it is still beaconing
        -- every 1.5 seconds its position never goes stale, so the two minute
        -- handover would never fire and the outline would freeze for good
        -- while somebody hotlaps another circuit.
        IF v_elsewhere THEN
            UPDATE events SET shape_driver_id = NULL
             WHERE id = v_event_id AND shape_driver_id = v_driver_id;
        END IF;

        IF NOT v_elsewhere THEN
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

            IF v_shape_ok AND v_points < public.live_track_path_max() THEN
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
        'mode', v_mode,
        'no_entry', NOT v_entered,
        'shaping', COALESCE(v_shape_ok, false),
        -- Said out loud rather than quietly dropping half of what was sent:
        -- this car is not on the circuit this round is being run at.
        'elsewhere', v_elsewhere,
        'next_ms', public.live_beacon_interval_ms(p_on_track)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_beacon(text, int, int, int, int, real, real, int, boolean, real, int, real)
    TO anon, authenticated;
