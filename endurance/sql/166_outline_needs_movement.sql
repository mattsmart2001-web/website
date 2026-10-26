-- ============================================================
-- 166 A stationary car is not a lap
--
-- Round 7's outline was sixty points at one position. min_x and max_x both
-- -1297, min_z and max_z both 2072, span zero. A car sat in the pits sent
-- the same coordinate sixty times and every one of them was stored.
--
-- Two separate faults let that happen, and together they produce exactly
-- the reported symptom: the map starts drawing, instantly says "Another
-- track", and stops.
--
--   1. Nothing stopped a point being appended when the car had not moved.
--      The continuity test only asked whether the new point was NEAR the
--      last one, so zero metres sailed through as the most continuous
--      position imaginable.
--
--   2. live_track_closed() asked whether the path had come back round to
--      where it started. Zero metres from the start satisfies that, so a
--      car that never left the start reads identically to a car that
--      completed a lap. The outline then freezes, since a closed outline
--      accepts nothing further, and every car on the actual circuit is
--      hundreds of metres from the single stored dot, so the page calls
--      them all strays and stops drawing them.
--
-- So: a point has to represent movement, and a closed loop has to enclose
-- something. A lap that encloses nothing is not a lap however neatly it
-- ends where it began.
--
-- An outline already ruined this way is not repaired by this migration; it
-- is still sixty points at one spot, and still closed under the old rule
-- until it is cleared. Clear Map Outline, then drive.
-- ============================================================

-- Shortest move that counts as having gone somewhere. At 1.5 seconds a car
-- doing 24 km/h covers 10 m, and the slowest corner of any GT7 circuit is
-- quicker than that, so 5 m rejects standing still and pit-box crawling
-- while never rejecting a car that is actually circulating.
CREATE OR REPLACE FUNCTION public.live_track_min_step_m()
RETURNS real LANGUAGE sql IMMUTABLE AS $$ SELECT 5::real; $$;

-- Smallest a finished circuit can be, corner to corner. Every GT7 track is
-- kilometres across; this only has to be large enough that a stationary car,
-- a pit lane shuffle or a spin cannot pass for a lap.
CREATE OR REPLACE FUNCTION public.live_track_min_span_m()
RETURNS real LANGUAGE sql IMMUTABLE AS $$ SELECT 500::real; $$;

GRANT EXECUTE ON FUNCTION public.live_track_min_step_m() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.live_track_min_span_m() TO anon, authenticated;


-- ---- a loop that encloses nothing is not a lap ----
-- Closed when the newest point has come back to somewhere the path has
-- already been, and far enough back to be a lap rather than the last corner.
--
-- Against ANY earlier point, not against the first one. The first point is
-- wherever the car happened to be when it started reporting, which is
-- normally its pit box, and a car never returns to its pit box mid-lap. The
-- lap closes where it rejoined the track, which is some way into the path.
-- Testing first-against-last meant a completed lap did not register as one.
CREATE OR REPLACE FUNCTION public.live_track_closed(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH p AS (
        SELECT COUNT(*) AS n, MAX(seq) AS hi,
               -- How far the path actually reaches, which is the part the
               -- old test never asked about at all.
               sqrt(power(MAX(x) - MIN(x), 2) + power(MAX(z) - MIN(z), 2)) AS span
        FROM   live_track_path WHERE event_id = p_event_id
    ),
    newest AS (
        SELECT x, z FROM live_track_path
         WHERE event_id = p_event_id ORDER BY seq DESC LIMIT 1
    )
    SELECT CASE
        WHEN (SELECT n FROM p) < public.live_track_min_shape_points() THEN false
        WHEN (SELECT span FROM p) < public.live_track_min_span_m()    THEN false
        ELSE EXISTS (
            SELECT 1
            FROM   live_track_path t, newest l
            WHERE  t.event_id = p_event_id
              -- Far enough back that this is a loop and not simply the
              -- previous few seconds of track.
              AND  t.seq <= (SELECT hi FROM p) - public.live_track_min_shape_points()
              AND  sqrt(power(t.x - l.x, 2) + power(t.z - l.z, 2))
                   <= public.live_track_closure_m()
        )
    END;
$$;

GRANT EXECUTE ON FUNCTION public.live_track_closed(uuid) TO anon, authenticated;


-- ============================================================
-- The beacon. Only the append condition differs from 165: a point now has
-- to represent movement before it is stored.
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
        v_closed := public.live_track_closed(v_event_id);

        IF NOT v_closed THEN
            SELECT shape_driver_id INTO v_shape FROM events WHERE id = v_event_id;
            SELECT x, z INTO v_lastx, v_lastz
              FROM live_track_path WHERE event_id = v_event_id
             ORDER BY seq DESC LIMIT 1;
            v_step := CASE WHEN v_lastx IS NULL THEN NULL
                           ELSE sqrt(power(p_x - v_lastx, 2) + power(p_z - v_lastz, 2)) END;

            IF v_shape = v_driver_id THEN
                IF v_step IS NOT NULL AND v_step > public.live_track_step_m() THEN
                    -- Teleported while holding the job.
                    UPDATE events SET shape_driver_id = NULL WHERE id = v_event_id;
                    v_elsewhere := true;
                ELSE
                    v_shape_ok := true;
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
                    UPDATE events SET shape_driver_id = v_driver_id WHERE id = v_event_id;
                    v_shape_ok := true;
                END IF;
            END IF;

            -- The point has to be somewhere new. A car sat in its pit box
            -- reports the same coordinate every 1.5 seconds, and storing
            -- those built an "outline" of sixty identical points that then
            -- counted as a completed lap.
            IF v_shape_ok
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
