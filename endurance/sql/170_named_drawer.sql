-- ============================================================
-- 170 A named drawer, and a handover that starts the lap again
--
-- Two problems, both about the same thing: one car should trace one lap,
-- deliberately.
--
-- There was never any selection of who draws the map. The job went to
-- whichever car's beacon arrived first once it was free, so clearing the
-- outline with four drivers out was a coin toss between four people, and
-- the admin who wanted to drive it themselves had no way to say so. Now
-- live_track_start names a driver: it clears whatever was there and hands
-- them the job, and nobody else can take it while they keep reporting.
--
-- The pin lapses after five minutes of silence rather than holding the map
-- for a driver who has gone to bed. Two minutes for anyone who merely
-- picked the job up by arriving first, as before.
--
-- And a handover no longer continues someone else's half-traced lap. It
-- used to, and the next crossing of the line would then close an outline
-- made of two cars' sections with a seam wherever they failed to meet,
-- which is exactly the gap 169 set out to remove, reached by another road.
-- Any change of drawer now starts the lap again.
--
-- Judged by who drew the last point rather than who held the job, because
-- the holder is released by the jump guard and often takes it straight
-- back, and that must not wipe their own work. So the path records who
-- drew each point, which is worth having anyway: the map can say who
-- traced it.
-- ============================================================

ALTER TABLE live_track_path
    ADD COLUMN IF NOT EXISTS driver_id uuid;

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS shape_pinned boolean NOT NULL DEFAULT false;

-- Points already on file were drawn by whoever holds the job, as far as
-- anyone can now tell. Attributing them to that driver stops the first
-- handover after this migration wiping a trace that was going fine.
UPDATE live_track_path p
   SET driver_id = e.shape_driver_id
  FROM events e
 WHERE e.id = p.event_id
   AND p.driver_id IS NULL
   AND e.shape_driver_id IS NOT NULL;


-- Start a track map, with a named driver to draw it. Everything stored for
-- the round goes, and the job is theirs until they stop reporting for five
-- minutes.
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
           shape_pinned    = true
     WHERE id = p_event_id;

    RETURN jsonb_build_object('ok', true, 'cleared', v_gone, 'driver', v_name);
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_track_start(uuid, uuid) TO authenticated;


-- Clearing releases the pin as well, or the next trace would be held for
-- whoever was named last time.
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
           shape_pinned    = false
     WHERE id = p_event_id;

    RETURN jsonb_build_object('ok', true, 'cleared', v_gone);
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_track_clear(uuid) TO authenticated;


-- The state, now including who is drawing it and whether they were named.
CREATE OR REPLACE FUNCTION public.live_track_state(p_event_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH e AS (
        SELECT COALESCE(p_event_id, (SELECT event_id FROM live_active_event())) AS id
    )
    SELECT jsonb_build_object(
        'event_id', (SELECT id FROM e),
        'points',   (SELECT COUNT(*) FROM live_track_path WHERE event_id = (SELECT id FROM e)),
        'closed',   COALESCE((SELECT shape_closed FROM events WHERE id = (SELECT id FROM e)), false),
        'armed',    COALESCE((SELECT shape_armed  FROM events WHERE id = (SELECT id FROM e)), false),
        'pinned',   COALESCE((SELECT shape_pinned FROM events WHERE id = (SELECT id FROM e)), false),
        'drawn_by', (SELECT d.display_name FROM events ev
                       JOIN drivers d ON d.id = ev.shape_driver_id
                      WHERE ev.id = (SELECT id FROM e))
    );
$$;

GRANT EXECUTE ON FUNCTION public.live_track_state(uuid) TO anon, authenticated;


-- ============================================================
-- The beacon. Unchanged from 169 except the drawer rules above.
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
    v_armed     boolean;
    v_pinned    boolean;
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
