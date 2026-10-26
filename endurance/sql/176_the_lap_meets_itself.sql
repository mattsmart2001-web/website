-- ============================================================
-- 176 The lap meets itself at the line
--
-- A finished outline had a small gap at the start/finish straight, and the
-- badge read "complete" at the moment of crossing while the map had not
-- drawn that last stretch. Both are the same thing: the point from the
-- beacon that detected the crossing was never stored.
--
-- The order was: see that the lap counter has gone round, mark the outline
-- closed, and then fall through to the step that appends a point, which
-- refuses to run on a closed outline. So the stored line stopped at the
-- beacon BEFORE the line and started at the first one after the previous
-- crossing, leaving out whatever the car covered across the line itself.
-- Flat out past the pits that is around a hundred metres, which is exactly
-- the size of gap reported.
--
-- The crossing point is now appended before the outline is marked closed,
-- and before the measurement, which has to see every point. Since it is the
-- first point reported after the car crossed the line, it sits at the same
-- place on the circuit as the very first stored point, so the line now runs
-- a full lap and its two ends meet.
--
-- The page draws the ends joined as well, which is a separate fix of the
-- same gap and is not in here: a closed outline is a loop and was being
-- drawn as a line, so even a complete lap would have shown one segment
-- missing. Drawing it as a loop also means the stray guard knows that the
-- stretch across the line is track, so a car sitting on it is not asked
-- whether it is at another circuit.
--
-- Outlines already closed keep their gap. There is no honest way to invent
-- the point that was never recorded, and retracing is two laps.
-- ============================================================

-- The same, for the server's own distance-to-the-line check, so that it
-- agrees with the page about the stretch across the start/finish straight.
CREATE OR REPLACE FUNCTION public.live_track_distance(p_event_id uuid, p_x real, p_z real)
RETURNS double precision LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH pts AS (
        SELECT seq, x, z FROM live_track_path WHERE event_id = p_event_id
    ),
    seg AS (
        SELECT x AS x1, z AS z1,
               LEAD(x) OVER (ORDER BY seq) AS x2,
               LEAD(z) OVER (ORDER BY seq) AS z2
        FROM   pts
        UNION ALL
        -- The segment that closes the loop, last point back to first, which
        -- exists only once the lap is finished. Before that the two ends are
        -- nowhere near each other and this would be a chord across the
        -- circuit, so it is only offered when the outline is closed.
        SELECT l.x, l.z, f.x, f.z
          FROM (SELECT x, z FROM pts ORDER BY seq DESC LIMIT 1) l,
               (SELECT x, z FROM pts ORDER BY seq ASC  LIMIT 1) f
         WHERE COALESCE((SELECT shape_closed FROM events WHERE id = p_event_id), false)
    ),
    real_seg AS (
        SELECT x1, z1, x2, z2,
               power(x2 - x1, 2) + power(z2 - z1, 2) AS l2
        FROM   seg WHERE x2 IS NOT NULL
    ),
    proj AS (
        SELECT CASE
                 WHEN l2 <= 0 THEN 0.0
                 ELSE GREATEST(0.0, LEAST(1.0,
                        ((p_x - x1) * (x2 - x1) + (p_z - z1) * (z2 - z1)) / l2))
               END AS t,
               x1, z1, x2, z2
        FROM   real_seg
        WHERE  l2 <= power(public.live_track_step_m(), 2)
    )
    SELECT MIN(sqrt(power(p_x - (x1 + t * (x2 - x1)), 2)
                  + power(p_z - (z1 + t * (z2 - z1)), 2)))
    FROM   proj;
$$;

GRANT EXECUTE ON FUNCTION public.live_track_distance(uuid, real, real) TO anon, authenticated;


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

    -- Clear out reporters that have stopped, in practice and test sessions
    -- only. This used to be conditional on the CALLING driver having been
    -- away fifteen minutes themselves, which meant that as long as a few
    -- people kept reporting steadily it never ran at all, and a driver who
    -- closed their app stayed in the list for the rest of the evening.
    --
    -- Ten minutes, so a row reads Offline on the page for five minutes
    -- before it goes, rather than vanishing the moment someone quits.
    --
    -- Never in a race. A car that loses its connection is still in the race
    -- and its laps still count, so it stays on the timing screen flagged
    -- Offline until the race ends.
    IF v_mode <> 'race' THEN
        DELETE FROM live_positions
         WHERE event_id = v_event_id
           AND updated_at < now() - interval '10 minutes';
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
                -- The lap this drawer started on. An admin naming a drawer
                -- cannot know what lap their game is on, so live_track_start
                -- leaves it empty and the drawer's first beacon fills it in.
                -- Without this it stays empty, the test below for a crossing
                -- can never be true, and the trace runs for ever: points pile
                -- up, the badge says "restarts at the line" lap after lap, and
                -- the map never saves. Reported after two laps and 677 points.
                IF v_lap_from IS NULL AND p_lap IS NOT NULL THEN
                    UPDATE events SET shape_lap_from = p_lap WHERE id = v_event_id;
                    v_lap_from := p_lap;
                END IF;

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
                            -- This beacon's own point first. It is the first
                            -- one reported after the car crossed the line,
                            -- which is the same place on the circuit as the
                            -- very first stored point, so with it the line
                            -- runs a full lap and its two ends meet. Without
                            -- it the trace stopped at the beacon BEFORE the
                            -- crossing and the map had a gap at the
                            -- start/finish straight the width of whatever the
                            -- car covered in between: flat out at the
                            -- Nordschleife, about a hundred metres of it.
                            --
                            -- Appended here rather than left to the step at
                            -- the end of this function, because that step
                            -- refuses to run once the outline is closed, and
                            -- the measurement below has to see every point.
                            INSERT INTO live_track_path (event_id, seq, x, y, z, driver_id)
                            SELECT v_event_id,
                                   COALESCE((SELECT MAX(seq) FROM live_track_path
                                              WHERE event_id = v_event_id), 0) + 1,
                                   p_x, p_y, p_z, v_driver_id;

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

                -- A named drawer keeps the job until an admin says
                -- otherwise. It used to lapse after five minutes of silence,
                -- on the reasoning that a pin held for someone who had gone
                -- to bed would block the map for everyone. That reasoning was
                -- wrong, and it cost a driver two laps of work: he traced the
                -- map, stopped reporting, and the next car to beacon took the
                -- job and wiped the trace under the rule below. Nobody
                -- touched anything.
                --
                -- Naming someone means the map waits for them. The block is
                -- visible, since the admin badge shows whose map it is, and
                -- an admin releases it with Start Track Map or Clear Map
                -- Outline. A block somebody can see and undo beats work
                -- being destroyed by a rule they cannot.
                IF NOT v_elsewhere AND NOT COALESCE(v_pinned, false)
                   AND (v_shape IS NULL OR NOT EXISTS (
                       SELECT 1 FROM live_positions
                        WHERE event_id = v_event_id AND driver_id = v_shape
                          AND updated_at > now() - interval '2 minutes'
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

                    -- Points with nobody recorded against them are the
                    -- current drawer's: they were laid down by a beacon from
                    -- before 170, which did not record who drew them, and 170
                    -- could only attribute the ones whose round still had a
                    -- shape driver set. Reading them as nobody's made them
                    -- different from EVERY driver, so the next handover wiped
                    -- them, and so did the drawer taking their own job back.
                    IF v_points > 0
                       AND COALESCE(v_drawn_by, v_shape) IS DISTINCT FROM v_driver_id THEN
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
