-- ============================================================
-- 179 Qualifying is not the race, and the race starts clean
--
-- Asked plainly: does the system know the difference between qualifying
-- and a race? It did not. Race mode opened two hours before the scheduled
-- start and qualifying happens inside that, so a qualifying session was
-- ordered by laps completed, shown with a Gap column, and labelled Pos.
-- Ordering qualifying by laps completed is meaningless in exactly the way
-- 171 described for practice: whoever has been circulating longest goes
-- top whatever their pace.
--
-- The timed race itself was never the problem. Nothing counts laps to
-- decide what session this is; the mode comes from starts_at and
-- duration_hours, both wall-clock, which is what a six hour race wants.
--
-- Two parts.
--
-- 1. The window splits at the scheduled start. Before it is qualifying,
--    from it the race. No new column: it uses the schedule already kept.
--    live_field needs no change at all, because it already orders every
--    mode that is not 'race' by best lap, and the page already shows Best
--    rather than Gap for them.
--
-- 2. The race starts with nobody holding a qualifying time.
--
-- The second part is the one that needed thinking about, because the
-- obvious answer does not work. The beacon already wipes live_positions
-- whenever the mode changes, which clears our copy. It does not clear
-- GT7's: best_lap_ms is written from the game's own best-lap field on
-- every beacon, so the next beacon 1.5 seconds later hands the qualifying
-- time straight back. And the mode flips at starts_at while the host
-- starts the race some minutes later, so that wipe lands before the green
-- flag with the cars still sitting in the lobby. Whatever the game does
-- with its own field, the wipe is too early to be the answer.
--
-- So during a race the figures come from the car's own evidence instead:
--
--   * A completed lap is the only thing that sets a best lap. 177 already
--     established that a lap actually driven is better evidence than the
--     game's best-lap field; in a race it is now the ONLY evidence, which
--     is what makes a qualifying time impossible to inherit.
--
--   * Nothing counts until the car has shown it is racing. A car is taken
--     as racing when its lap counter drops, which is a race starting, or
--     when its lap counter rises while the mode is already race, which is
--     a lap completed in front of us. Until one of those, its best and
--     last are held empty rather than filled from whatever the game is
--     reporting in the lobby.
--
--   * A lap counter dropping resets that car: lap, best, last and the fuel
--     accounting from 178, which is measured per lap and would otherwise
--     carry a qualifying baseline into the first race lap.
--
-- Scoped so it cannot hurt a reconnection. Only the FIRST drop counts, and
-- only before the car has been seen racing. After that, lap stays
-- GREATEST as it is today, which is what protects a driver who drops out
-- and rejoins mid-race from losing their position.
--
-- In the likely case, where GT7 resets its lap counter at the green flag,
-- nothing is lost: the drop is seen on the first beacon after green, the
-- car is cleared and marked racing in the same statement, and its first
-- flying lap counts. If the game turns out NOT to reset the counter, the
-- car is instead marked racing by its first completed lap and that one lap
-- does not count towards its best. Losing one lap is the safe side of that
-- choice, since the alternative is inheriting a qualifying time for the
-- whole race.
-- ============================================================

-- Whether this car has been seen racing since the session became a race.
-- False for every existing row, which is correct: a row written before
-- this migration belongs to a session that is already running, and the
-- next completed lap marks it.
ALTER TABLE live_positions
    ADD COLUMN IF NOT EXISTS race_started boolean NOT NULL DEFAULT false;


-- ---- qualifying, then the race ----
CREATE OR REPLACE FUNCTION public.live_active_event()
RETURNS TABLE (event_id uuid, is_test boolean, mode text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH race_day AS (SELECT public.live_is_race_day() AS today),
    candidate AS (
        SELECT e.id,
               e.starts_at,
               COALESCE(now() BETWEEN e.starts_at - interval '2 hours'
                                  AND e.starts_at + (e.duration_hours * interval '1 hour')
                                      + interval '2 hours', false) AS in_race,
               COALESCE(now() < e.starts_at, false)                AS before_start,
               COALESCE(e.live_test_until IS NOT NULL AND now() < e.live_test_until, false) AS in_test,
               (e.live_practice_always
                OR COALESCE(public.live_in_practice(e.live_practice_from, e.live_practice_to), false))
                   AND NOT (SELECT today FROM race_day) AS in_practice
        FROM   events e
        WHERE  e.status <> 'completed'
          AND  e.status <> 'cancelled'
    )
    SELECT id,
           NOT in_race,
           -- The two hours before the start are qualifying. Not a test and
           -- not practice: it is a live session on race day, it simply is
           -- not the race, and what separates the two is that one is ranked
           -- by pace and the other by distance covered.
           CASE WHEN in_race AND before_start THEN 'qualifying'
                WHEN in_race                  THEN 'race'
                WHEN in_test                  THEN 'test'
                ELSE 'practice' END
    FROM   candidate
    WHERE  in_race OR in_test OR in_practice
    ORDER  BY in_race DESC, in_test DESC, starts_at
    LIMIT  1;
$$;

GRANT EXECUTE ON FUNCTION public.live_active_event() TO anon, authenticated;


-- ---- the beacon ----
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
    v_prev_lap  int;
    v_at_start  real;
    v_burn      real;
    v_used      real;
    v_drawn_by  uuid;
    v_elsewhere boolean := false;
    v_client    text;
    v_started   boolean;
    v_racing    boolean;
    v_restart   boolean;
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

    SELECT updated_at, lap, fuel_at_lap_start, burn_per_lap, race_started
      INTO v_last, v_prev_lap, v_at_start, v_burn, v_started
      FROM live_positions
     WHERE event_id = v_event_id AND driver_id = v_driver_id;

    -- Clear out reporters that have stopped, in every session but the race.
    -- A car that loses its connection during a race is still in the race and
    -- its laps still count, so it stays on the timing screen flagged Offline
    -- until the race ends. Qualifying is not the race: somebody who closes
    -- their app between runs should leave the screen like anyone else.
    IF v_mode <> 'race' THEN
        DELETE FROM live_positions
         WHERE event_id = v_event_id
           AND updated_at < now() - interval '10 minutes';
    END IF;

    IF v_last IS NOT NULL AND now() - v_last < interval '1.2 seconds' THEN
        RETURN jsonb_build_object('ok', true, 'reporting', true, 'throttled', true);
    END IF;

    -- A race starting, as the car itself reports it: its lap counter has
    -- gone backwards and it has not been seen racing yet. Only the first
    -- one counts, so a driver who drops out and rejoins mid-race keeps
    -- everything, which is what GREATEST on lap has always been for.
    v_racing  := v_mode = 'race';
    v_restart := v_racing
             AND NOT COALESCE(v_started, false)
             AND v_prev_lap IS NOT NULL
             AND COALESCE(p_lap, 0) < v_prev_lap;

    -- Fuel burn, measured a lap at a time. Worked out here rather than from
    -- a single reading, because one reading says how much is left and
    -- nothing about how long it will last.
    --
    -- Only on a lap tick, and only from a full lap: the figure wanted is
    -- "what a lap costs", so an in-lap or an out-lap would both lie. A stop
    -- shows up as fuel going UP, which is not a burn rate and resets the
    -- baseline instead of recording a negative one.
    IF v_restart THEN
        -- The green flag. Whatever was measured was measured across the end
        -- of qualifying, and a tank topped up between the two makes it worse
        -- than useless: it starts again from here.
        v_at_start := p_fuel_pct;
        v_burn     := NULL;
    ELSIF p_fuel_pct IS NOT NULL AND p_lap IS NOT NULL THEN
        IF v_prev_lap IS NULL OR p_lap <> v_prev_lap THEN
            v_used := CASE WHEN v_at_start IS NULL THEN NULL
                           ELSE v_at_start - p_fuel_pct END;
            IF v_used IS NOT NULL AND v_used > 0 AND v_prev_lap IS NOT NULL
               AND p_lap = v_prev_lap + 1 THEN
                -- A third weight on the newest lap, so one unusual lap moves
                -- the figure without owning it. A race lap is a race lap:
                -- after three or four of them this settles.
                v_burn := CASE WHEN v_burn IS NULL OR v_burn <= 0 THEN v_used
                               ELSE v_burn * 2.0 / 3.0 + v_used / 3.0 END;
            END IF;
            v_at_start := p_fuel_pct;
        END IF;
    END IF;

    INSERT INTO live_positions AS lp (
        event_id, driver_id, lobby_number, lap, lap_ms, last_lap_ms,
        best_lap_ms, x, y, z, speed_kph, on_track, fuel_pct, laps_in_race,
        client, fuel_at_lap_start, burn_per_lap, race_started, updated_at
    ) VALUES (
        v_event_id, v_driver_id, v_lobby, COALESCE(p_lap, 0), p_lap_ms,
        -- In a race, a car brand new to the screen has not been seen racing
        -- yet, so what the game is reporting might be a qualifying time it
        -- is still holding. It starts empty and fills from laps driven in
        -- front of us. In every other session the game's own figures are
        -- exactly what is wanted, and immediately.
        CASE WHEN v_racing THEN NULL ELSE p_last_lap_ms END,
        CASE WHEN v_racing THEN NULL
             ELSE LEAST(p_best_lap_ms,
                        CASE WHEN p_last_lap_ms >= 20000 THEN p_last_lap_ms END) END,
        p_x, p_y, p_z, p_speed_kph, COALESCE(p_on_track, true),
        p_fuel_pct, p_laps_in_race, v_client, v_at_start, v_burn,
        NOT v_racing, now()
    )
    ON CONFLICT (event_id, driver_id) DO UPDATE SET
        lobby_number = COALESCE(EXCLUDED.lobby_number, lp.lobby_number),
        -- A race starting takes the car's own number; anything else keeps
        -- the highest seen, which is what protects a reconnection.
        lap          = CASE WHEN v_restart THEN COALESCE(EXCLUDED.lap, 0)
                            ELSE GREATEST(lp.lap, COALESCE(EXCLUDED.lap, 0)) END,
        -- Seen racing: either the race just started under it, or it has
        -- completed a lap while we were watching and the mode was already
        -- race. Every SET here reads the row as it was, so the beacon that
        -- marks a car racing is itself still treated as before.
        race_started = lp.race_started
                    OR v_restart
                    OR (v_racing AND COALESCE(EXCLUDED.lap, 0) > lp.lap),
        lap_ms       = EXCLUDED.lap_ms,
        -- The incoming values are read from the parameters here rather than
        -- from EXCLUDED, because the INSERT above deliberately writes NULL
        -- into these two for a brand new row in a race, and EXCLUDED is that
        -- row. Using it meant a completed lap never got to vote and the best
        -- lap stayed empty for the whole race, which the test caught.
        last_lap_ms  = CASE WHEN v_restart THEN NULL
                            WHEN v_racing AND NOT lp.race_started THEN NULL
                            ELSE COALESCE(p_last_lap_ms, lp.last_lap_ms) END,
        -- A lap that was actually driven is proof. GT7 reported a best of
        -- 8:07.307 in the same breath as a completed lap of 8:03.379, and the
        -- screen showed both, which cannot be true of anything. Whatever
        -- causes that in the game, a completed lap is better evidence than
        -- the game's own best field.
        --
        -- In a race it is now the only evidence. The game's best-lap field
        -- is not consulted at all, because it is the one thing that can
        -- still be holding a qualifying time after the lights go out, and
        -- there is no way from here to tell whether it is.
        --
        -- LEAST ignores nulls in Postgres, so a packet carrying no best, or
        -- no last, simply does not vote.
        --
        -- The floor is there because this would otherwise be poisoned for the
        -- rest of a session by one bogus short lap, where a bogus Last only
        -- shows until the next one. No GT7 circuit has a lap under twenty
        -- seconds, so nothing real is excluded.
        best_lap_ms  = CASE
            WHEN v_restart THEN NULL
            WHEN v_racing AND NOT lp.race_started THEN NULL
            WHEN v_racing THEN LEAST(lp.best_lap_ms,
                                     CASE WHEN p_last_lap_ms >= 20000
                                          THEN p_last_lap_ms END)
            ELSE LEAST(COALESCE(p_best_lap_ms, lp.best_lap_ms),
                       COALESCE(lp.best_lap_ms, p_best_lap_ms),
                       CASE WHEN p_last_lap_ms >= 20000
                            THEN p_last_lap_ms END) END,
        x            = EXCLUDED.x,
        y            = EXCLUDED.y,
        z            = EXCLUDED.z,
        speed_kph    = EXCLUDED.speed_kph,
        on_track     = EXCLUDED.on_track,
        fuel_pct     = COALESCE(EXCLUDED.fuel_pct, lp.fuel_pct),
        laps_in_race = COALESCE(EXCLUDED.laps_in_race, lp.laps_in_race),
        client       = COALESCE(EXCLUDED.client, lp.client),
        fuel_at_lap_start = EXCLUDED.fuel_at_lap_start,
        burn_per_lap      = EXCLUDED.burn_per_lap,
        updated_at   = now();

    -- A race starting throws the car's distance round the lap away too. It
    -- was measured against qualifying and the scan below has not run yet
    -- for this beacon, so leaving it would order the formation lap by where
    -- everybody happened to be when qualifying ended.
    IF v_restart THEN
        UPDATE live_positions SET track_seq = NULL, progress_m = NULL
         WHERE event_id = v_event_id AND driver_id = v_driver_id;
    END IF;

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
                IF v_lap_from IS NULL AND p_lap IS NOT NULL THEN
                    UPDATE events SET shape_lap_from = p_lap WHERE id = v_event_id;
                    v_lap_from := p_lap;
                END IF;

                -- A race starting resets the drawer's lap baseline as well,
                -- for the same reason it resets everything else: the lap the
                -- trace was counting from belongs to the session before it.
                IF v_restart THEN
                    UPDATE events SET shape_lap_from = COALESCE(p_lap, 0)
                     WHERE id = v_event_id;
                    v_lap_from := COALESCE(p_lap, 0);
                END IF;

                IF v_step IS NOT NULL AND v_step > public.live_track_step_m() THEN
                    IF COALESCE(v_pinned, false) THEN
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
                            v_step   := NULL;
                        ELSIF v_points >= public.live_track_min_shape_points() THEN
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

                IF NOT v_elsewhere AND NOT COALESCE(v_pinned, false)
                   AND (v_shape IS NULL OR NOT EXISTS (
                       SELECT 1 FROM live_positions
                        WHERE event_id = v_event_id AND driver_id = v_shape
                          AND updated_at > now() - interval '2 minutes'
                   )) THEN
                    SELECT driver_id INTO v_drawn_by
                      FROM live_track_path WHERE event_id = v_event_id
                     ORDER BY seq DESC LIMIT 1;

                    IF v_points > 0
                       AND COALESCE(v_drawn_by, v_shape) IS DISTINCT FROM v_driver_id THEN
                        DELETE FROM live_track_path WHERE event_id = v_event_id;
                        UPDATE events SET shape_armed = false WHERE id = v_event_id;
                        v_points := 0;
                        v_step   := NULL;
                        v_armed  := false;
                    END IF;

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
        'race_started', COALESCE(v_restart, false),
        'next_ms', public.live_beacon_interval_ms(p_on_track)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_beacon(text, int, int, int, int, real, real, int, boolean, real, int, real, text)
    TO anon, authenticated;
