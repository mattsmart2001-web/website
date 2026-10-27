-- ============================================================
-- 184 Only a lap we watched counts
--
-- Reported from the live page: 6:53.744 at the Nordschleife 24h layout,
-- where nobody breaks eight minutes, shown as both Last and Best. The car
-- beside it read 8:08.117.
--
-- Matt took it for a reporter that started late. It is not quite that: GT7
-- times a lap itself, so our app starting mid-lap cannot shorten one. What
-- can is the DRIVER's session starting partway round the circuit, which
-- happens every time somebody joins an open practice lobby mid-lap. GT7
-- then calls the run from wherever they appeared to the line a lap, and
-- reports its time. Nothing in the packet marks it as a part lap.
--
-- But we know whether we were watching for the whole of it. A lap time is
-- taken only from a lap bounded by two crossings we both saw: a car's first
-- reported lap is discarded, whatever it says, and every one after it is a
-- whole lap by construction.
--
-- This is 183's rule applied to the lap time rather than to the fuel, which
-- is where it should have gone in the first place. Both bugs were the same
-- bug: the first thing a car tells us about an interval we did not watch
-- the start of.
--
-- Two separate flags, because the conditions genuinely differ. A pit stop
-- destroys a fuel measurement, since an in-lap and an out-lap do not cost
-- what a lap costs; it does not make the out-lap's TIME untrue, only slow,
-- and a slow lap can never be a best anyway.
--
-- The cost is that a car shows no Last and no Best until it completes its
-- second lap on the timing screen. At the Nordschleife that is eight
-- minutes of dashes, against a figure that is wrong and that a viewer has
-- no way to know is wrong.
--
-- Said plainly, because it undoes something asked for: 182 made the press
-- authoritative so that a car's figures counted from its first beacon of
-- the race, and this puts one lap of that back. On race day the button is
-- pressed on lap two with every car on a whole lap of its own, so the lap
-- being refused is a real one. But nothing in the packet distinguishes that
-- from the 6:53, and the 6:53 is what a viewer saw. Eight minutes of dashes
-- in a six hour race, with the lap count, position and gaps all correct
-- throughout, against a wrong time nobody can tell is wrong.
--
-- The race start itself is untouched: the button still clears everything,
-- and the lap counter dropping still resets a car.
-- ============================================================

ALTER TABLE live_positions
    ADD COLUMN IF NOT EXISTS lap_watched boolean NOT NULL DEFAULT false;

-- Anything already stored may have come from a part lap, and best_lap_ms
-- only ever falls, so a bad one would never be displaced. Cleared; the next
-- whole lap sets it again.
UPDATE live_positions SET last_lap_ms = NULL, best_lap_ms = NULL,
                          lap_watched = false;


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
    v_live_from timestamptz;
    v_settled   boolean;
    v_base_ok   boolean;
    v_watched   boolean;
    v_crossed   boolean;
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

    SELECT live_session_mode, race_live_from
      INTO v_prev_mode, v_live_from
      FROM events WHERE id = v_event_id;
    IF v_prev_mode IS DISTINCT FROM v_mode THEN
        DELETE FROM live_positions WHERE event_id = v_event_id;
        UPDATE events SET live_session_mode = v_mode WHERE id = v_event_id;
    END IF;

    SELECT updated_at, lap, fuel_at_lap_start, burn_per_lap, race_started,
           fuel_base_ok, lap_watched
      INTO v_last, v_prev_lap, v_at_start, v_burn, v_started, v_base_ok,
           v_watched
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
    -- Whether enough time has passed since the button that every split must
    -- be racing by now. Until it has, a completed lap proves nothing: it
    -- looks identical whether it was driven in the race or in a qualifying
    -- session that another split has not finished yet.
    v_settled := v_racing
             AND (v_live_from IS NULL
                  OR now() > v_live_from + public.live_race_settle());

    -- Fuel burn, measured a lap at a time. Worked out here rather than from
    -- a single reading, because one reading says how much is left and
    -- nothing about how long it will last.
    --
    -- Only on a lap tick, and only from a full lap: the figure wanted is
    -- "what a lap costs", so an in-lap or an out-lap would both lie. A stop
    -- shows up as fuel going UP, which is not a burn rate and resets the
    -- baseline instead of recording a negative one.
    -- A line crossing, and whether the lap it ends is one we watched from
    -- the crossing before it. GT7 times a lap itself, so a reporter starting
    -- late cannot shorten one; what can is the DRIVER's session starting
    -- partway round, which is what happens every time somebody joins an open
    -- lobby mid-lap. GT7 then calls the run from there to the line a lap and
    -- reports its time, and a 6:53 appeared on a circuit where nobody breaks
    -- eight minutes. Nothing in the packet says that lap was a part lap. But
    -- we know whether we were watching for the whole of it, and we were not.
    v_crossed := p_lap IS NOT NULL AND v_prev_lap IS NOT NULL
             AND p_lap <> v_prev_lap;
    IF v_restart THEN
        -- The green flag. Whatever was measured was measured across the end
        -- of qualifying, and a tank topped up between the two makes it worse
        -- than useless: it starts again from here.
        v_at_start := p_fuel_pct;
        v_burn     := NULL;
        v_base_ok  := false;
        v_watched  := false;
    ELSIF p_fuel_pct IS NOT NULL AND p_lap IS NOT NULL THEN
        IF v_prev_lap IS NULL OR p_lap <> v_prev_lap THEN
            v_used := CASE WHEN v_at_start IS NULL THEN NULL
                           ELSE v_at_start - p_fuel_pct END;
            IF COALESCE(v_base_ok, false)
               AND v_used IS NOT NULL AND v_used > 0 AND v_prev_lap IS NOT NULL
               AND p_lap = v_prev_lap + 1
               AND v_used >= public.live_fuel_min_burn() THEN
                -- A third weight on the newest lap, so one unusual lap moves
                -- the figure without owning it. A race lap is a race lap:
                -- after three or four of them this settles.
                v_burn := CASE WHEN v_burn IS NULL OR v_burn <= 0 THEN v_used
                               ELSE v_burn * 2.0 / 3.0 + v_used / 3.0 END;
            END IF;
            -- This crossing is a proper baseline whatever happened before it,
            -- so the NEXT lap can be measured even when this one could not.
            -- Except on a reporter's very first beacon, which is not a
            -- crossing at all: it is wherever the car happened to be when
            -- the app was opened. Marking that good was what let the
            -- reported case through, and only the floor below caught it; an
            -- app opened three minutes before the line would have recorded a
            -- real-looking burn that was far too small and nothing would
            -- have noticed.
            v_at_start := p_fuel_pct;
            v_base_ok  := v_prev_lap IS NOT NULL;
        END IF;
        -- A car in its pit box or in the menus breaks the chain: the lap it
        -- comes back on is an out-lap, and the one it went in on was an
        -- in-lap. Neither costs what a lap costs, which is the figure wanted.
        IF NOT COALESCE(p_on_track, true) THEN
            v_base_ok := false;
        END IF;
    END IF;

    INSERT INTO live_positions AS lp (
        event_id, driver_id, lobby_number, lap, lap_ms, last_lap_ms,
        best_lap_ms, x, y, z, speed_kph, on_track, fuel_pct, laps_in_race,
        client, fuel_at_lap_start, burn_per_lap, race_started,
        fuel_base_ok, lap_watched, updated_at
    ) VALUES (
        v_event_id, v_driver_id, v_lobby, COALESCE(p_lap, 0), p_lap_ms,
        NULL,
        -- Even on a car's first beacon the game's own best-lap field is not
        -- consulted during a race, because that is the field that can still
        -- be holding a qualifying time. The lap it has just completed is
        -- taken at face value: the button is pressed once every split is
        -- racing, so that lap was driven in the race.
        -- and nor is the lap it is carrying, which we did not watch.
        NULL,
        p_x, p_y, p_z, p_speed_kph, COALESCE(p_on_track, true),
        p_fuel_pct, p_laps_in_race, v_client, v_at_start, v_burn,
        NOT v_racing, COALESCE(v_base_ok, false), false, now()
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
        -- A car is taken as racing when its lap counter drops, which is a
        -- race starting under it and is proof whenever it happens, or when
        -- it completes a lap once every split must be green. The second half
        -- used to apply from the moment the button was pressed, and with ten
        -- splits that was wrong: a split still qualifying would be marked
        -- racing by its next qualifying lap, inherit that time as its race
        -- best, and then have its own green flag ignored as a reconnection,
        -- running the whole race with its lap count inflated by however far
        -- into qualifying it had got.
        race_started = lp.race_started
                    OR v_restart
                    OR (v_settled AND COALESCE(EXCLUDED.lap, 0) > lp.lap),
        lap_ms       = EXCLUDED.lap_ms,
        -- The incoming values are read from the parameters here rather than
        -- from EXCLUDED, because the INSERT above deliberately writes NULL
        -- into these two for a brand new row in a race, and EXCLUDED is that
        -- row. Using it meant a completed lap never got to vote and the best
        -- lap stayed empty for the whole race, which the test caught.
        -- A lap time is only taken from a lap we watched end to end. The
        -- first one a car reports is whatever GT7 was timing when its
        -- session began, which may be a part lap, and there is no way to
        -- tell from the packet. The next one is a whole lap by construction.
        last_lap_ms  = CASE WHEN v_restart THEN NULL
                            WHEN NOT COALESCE(lp.lap_watched, false)
                                 THEN lp.last_lap_ms
                            -- No GT7 circuit has a lap under twenty seconds,
                            -- so a figure below it is not a lap and does not
                            -- replace the one on screen. 177 applied this
                            -- floor where a completed lap votes for a best
                            -- and nowhere else, which left Last free to show
                            -- a 1.2 second lap until the next one arrived.
                            WHEN p_last_lap_ms IS NOT NULL
                                 AND p_last_lap_ms < 20000 THEN lp.last_lap_ms
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
            WHEN NOT COALESCE(lp.lap_watched, false) THEN lp.best_lap_ms
            WHEN v_racing THEN LEAST(lp.best_lap_ms,
                                     CASE WHEN p_last_lap_ms >= 20000
                                          THEN p_last_lap_ms END)
            -- Outside a race the game's own best is trusted, which is
            -- what gives a practice screen a time straight away. It gets
            -- the same floor as everything else: 177 put the floor on the
            -- completed-lap vote only, so a bogus best from the game walked
            -- straight past it, and in practice it would then be pinned
            -- there for the session since this only ever falls.
            ELSE LEAST(COALESCE(CASE WHEN p_best_lap_ms >= 20000
                                     THEN p_best_lap_ms END, lp.best_lap_ms),
                       COALESCE(lp.best_lap_ms,
                                CASE WHEN p_best_lap_ms >= 20000
                                     THEN p_best_lap_ms END),
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
        fuel_base_ok      = EXCLUDED.fuel_base_ok,
        -- From its first crossing on, this car's laps are whole ones.
        lap_watched       = lp.lap_watched OR v_crossed,
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
