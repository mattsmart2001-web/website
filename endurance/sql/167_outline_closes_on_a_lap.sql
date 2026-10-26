-- ============================================================
-- 167 The outline closes on a completed lap, not on a shape
--
-- 163 decided an outline was finished by geometry: the newest point coming
-- back within 200 m of somewhere the path had been at least sixty points
-- earlier. On the Nordschleife that fires in the middle of a lap. The
-- circuit runs close to itself in several places and crosses UNDER itself at
-- Breidscheid, where two bits of track are a few metres apart in x and z and
-- only separated by height.
--
-- So the outline declared itself complete partway round, froze, and the page
-- then judged every car against that fragment and called them strays. The
-- reported symptom was the line stopping dead exactly where it approached
-- another part of the track.
--
-- Tightening the radius cannot fix it. At an underpass the horizontal
-- distance is near zero, so no threshold separates "back where I was" from
-- "passing beneath where I was". Adding height, or requiring the car to be
-- travelling the same way as before, both help and both still guess.
--
-- There is nothing to guess. GT7 reports the lap number and the beacon has
-- been carrying it all along. A lap is complete when the lap counter says it
-- is, which is the only authority on the matter that exists.
--
-- So: the lap is recorded when a car takes the shape job on, and the outline
-- closes when that car's lap counter has moved past it. No radius, no
-- geometry, nothing to tune.
--
-- If a session never increments the lap counter, the outline simply never
-- closes and keeps growing until live_track_path_max() bounds it, which is
-- how it behaved before closure existed at all. The page then leaves stray
-- detection switched off, and the beacon's own proximity test goes on
-- protecting the outline. That is the right way to fail.
-- ============================================================

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS shape_closed   boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS shape_lap_from int;


-- Now a stored fact rather than a measurement. Clearing the outline clears
-- it too, which live_track_clear below takes care of.
CREATE OR REPLACE FUNCTION public.live_track_closed(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT COALESCE(shape_closed, false) FROM events WHERE id = p_event_id;
$$;

GRANT EXECUTE ON FUNCTION public.live_track_closed(uuid) TO anon, authenticated;


-- The page needs this without fetching every point to work it out itself,
-- and a geometric guess on the client has exactly the same flaw.
CREATE OR REPLACE FUNCTION public.live_track_state(p_event_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH e AS (
        SELECT COALESCE(p_event_id, (SELECT event_id FROM live_active_event())) AS id
    )
    SELECT jsonb_build_object(
        'event_id', (SELECT id FROM e),
        'points',   (SELECT COUNT(*) FROM live_track_path WHERE event_id = (SELECT id FROM e)),
        'closed',   COALESCE((SELECT shape_closed FROM events WHERE id = (SELECT id FROM e)), false)
    );
$$;

GRANT EXECUTE ON FUNCTION public.live_track_state(uuid) TO anon, authenticated;


-- Clearing the outline must un-close it, or nothing can ever be captured
-- again for that round.
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
           shape_lap_from  = NULL
     WHERE id = p_event_id;

    RETURN jsonb_build_object('ok', true, 'cleared', v_gone);
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_track_clear(uuid) TO authenticated;


-- ============================================================
-- The beacon. Closure is now driven by the lap counter.
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

    IF COALESCE(p_on_track, true) AND p_x IS NOT NULL AND p_z IS NOT NULL THEN
        SELECT COUNT(*) INTO v_points FROM live_track_path WHERE event_id = v_event_id;
        SELECT shape_driver_id, shape_closed, shape_lap_from
          INTO v_shape, v_closed, v_lap_from
          FROM events WHERE id = v_event_id;

        IF NOT COALESCE(v_closed, false) THEN
            SELECT x, z INTO v_lastx, v_lastz
              FROM live_track_path WHERE event_id = v_event_id
             ORDER BY seq DESC LIMIT 1;
            v_step := CASE WHEN v_lastx IS NULL THEN NULL
                           ELSE sqrt(power(p_x - v_lastx, 2) + power(p_z - v_lastz, 2)) END;

            IF v_shape = v_driver_id THEN
                IF v_step IS NOT NULL AND v_step > public.live_track_step_m() THEN
                    UPDATE events SET shape_driver_id = NULL, shape_lap_from = NULL
                     WHERE id = v_event_id;
                    v_elsewhere := true;
                ELSE
                    v_shape_ok := true;

                    -- The lap counter is the only authority on whether a lap
                    -- is finished. Geometry cannot tell a completed lap from
                    -- a circuit passing under itself.
                    IF v_lap_from IS NOT NULL
                       AND p_lap IS NOT NULL
                       AND p_lap > v_lap_from
                       AND v_points >= public.live_track_min_shape_points() THEN
                        UPDATE events SET shape_closed = true WHERE id = v_event_id;
                        v_closed := true;
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
                          AND updated_at > now() - interval '2 minutes'
                   )) THEN
                    -- Taking the job on starts the lap count from here, since
                    -- this car's lap numbering is its own.
                    UPDATE events
                       SET shape_driver_id = v_driver_id,
                           shape_lap_from  = p_lap
                     WHERE id = v_event_id;
                    v_shape_ok := true;
                END IF;
            END IF;

            IF v_shape_ok
               AND NOT COALESCE(v_closed, false)
               AND v_points < public.live_track_path_max()
               AND (v_step IS NULL OR v_step >= public.live_track_min_step_m()) THEN
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
        'outline_closed', COALESCE(v_closed, false),
        'elsewhere', v_elsewhere,
        'next_ms', public.live_beacon_interval_ms(p_on_track)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_beacon(text, int, int, int, int, real, real, int, boolean, real, int, real, text)
    TO anon, authenticated;
