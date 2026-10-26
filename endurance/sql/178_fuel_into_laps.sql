-- ============================================================
-- 178 How many laps that fuel is worth
--
-- The fuel bar says how much is in the tank and nothing about how long it
-- will last, which during a six hour race is the question everybody is
-- actually asking. The comment on it has said since it was written that
-- turning a percentage into laps remaining "needs each driver's own
-- consumption, which is a later job and not worth faking from one reading".
-- This is that job: the consumption is now measured rather than guessed.
--
-- The beacon records the fuel level at each lap tick and takes the
-- difference a lap later. That gives what a lap costs this car, at this
-- driver's pace, in this stint. A third weight on the newest lap, so one
-- unusual lap moves the figure without owning it, and it settles after
-- three or four.
--
-- What is deliberately NOT counted:
--   a stop, which shows up as fuel going UP. That is not a burn rate; it
--   resets the baseline instead of recording a negative one.
--   a lap that is not the next one. A skipped lap number means a reset or a
--   reconnection, and the fuel either side of it is not one lap apart.
--   a race with fuel consumption off, where the burn is zero and no
--   estimate is offered at all rather than an infinite one.
--
-- The page divides what is left by the burn and shows laps remaining under
-- the fuel bar, where Last already carries the current lap beneath it. No
-- new column: at 1180px with the map beside it there is no room for one,
-- which is the same reason sectors were dropped.
-- ============================================================

ALTER TABLE live_positions
    ADD COLUMN IF NOT EXISTS fuel_at_lap_start real,
    ADD COLUMN IF NOT EXISTS burn_per_lap      real;


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
    lap_length_m  real,
    burn_per_lap  real
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
        lp.progress_m, e.lap_length_m, lp.burn_per_lap
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
    v_prev_lap  int;
    v_at_start  real;
    v_burn      real;
    v_used      real;
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

    SELECT updated_at, lap, fuel_at_lap_start, burn_per_lap
      INTO v_last, v_prev_lap, v_at_start, v_burn
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

    -- Fuel burn, measured a lap at a time. Worked out here rather than from
    -- a single reading, because one reading says how much is left and
    -- nothing about how long it will last.
    --
    -- Only on a lap tick, and only from a full lap: the figure wanted is
    -- "what a lap costs", so an in-lap or an out-lap would both lie. A stop
    -- shows up as fuel going UP, which is not a burn rate and resets the
    -- baseline instead of recording a negative one.
    IF p_fuel_pct IS NOT NULL AND p_lap IS NOT NULL THEN
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
        client, fuel_at_lap_start, burn_per_lap, updated_at
    ) VALUES (
        v_event_id, v_driver_id, v_lobby, COALESCE(p_lap, 0), p_lap_ms, p_last_lap_ms,
        -- The same rule as the conflict clause below. A first beacon can
        -- carry the impossible pair just as readily as a later one, and
        -- only patching the update path left exactly that hole.
        LEAST(p_best_lap_ms,
              CASE WHEN p_last_lap_ms >= 20000 THEN p_last_lap_ms END),
        p_x, p_y, p_z, p_speed_kph, COALESCE(p_on_track, true),
        p_fuel_pct, p_laps_in_race, v_client, v_at_start, v_burn, now()
    )
    ON CONFLICT (event_id, driver_id) DO UPDATE SET
        lobby_number = COALESCE(EXCLUDED.lobby_number, lp.lobby_number),
        lap          = GREATEST(lp.lap, COALESCE(EXCLUDED.lap, 0)),
        lap_ms       = EXCLUDED.lap_ms,
        last_lap_ms  = COALESCE(EXCLUDED.last_lap_ms, lp.last_lap_ms),
        -- A lap that was actually driven is proof. GT7 reported a best of
        -- 8:07.307 in the same breath as a completed lap of 8:03.379, and the
        -- screen showed both, which cannot be true of anything. Whatever
        -- causes that in the game, a completed lap is better evidence than
        -- the game's own best field, so it counts too.
        --
        -- LEAST ignores nulls in Postgres, so a packet carrying no best, or
        -- no last, simply does not vote.
        --
        -- The floor is there because this would otherwise be poisoned for the
        -- rest of a session by one bogus short lap, where a bogus Last only
        -- shows until the next one. No GT7 circuit has a lap under twenty
        -- seconds, so nothing real is excluded.
        best_lap_ms  = LEAST(COALESCE(EXCLUDED.best_lap_ms, lp.best_lap_ms),
                             COALESCE(lp.best_lap_ms, EXCLUDED.best_lap_ms),
                             CASE WHEN EXCLUDED.last_lap_ms >= 20000
                                  THEN EXCLUDED.last_lap_ms END),
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
