-- ============================================================
-- 193 A car we have never seen on track has no position at all
--
-- Craigo was still on the map after 192: a faded marker halfway round the
-- circuit, for a driver who had never been out in this session.
--
-- 185 holds a car's position when it is not on track, because what GT7
-- streams to a driver in the menus is the game's own camera rather than the
-- car. It does that in the clause that updates an existing row, and only
-- there. The clause that creates one takes the position as given, so the
-- very first beacon from a driver sitting in the menus wrote the camera's
-- position into the row as if it were a car, and there it stayed: 185 then
-- dutifully held it, forever, because holding is what it does.
--
-- A car has a position once it has been seen on track and not before. Until
-- then it has none, the map does not draw it, and the timing screen lists
-- it as In menus, which is exactly what it is.
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
    v_log_lap   boolean;
    v_near_m    double precision;
    v_on_line   boolean;
    v_off_line  boolean;
    v_near_n    int;
    v_far_n     int;
    v_raw_prev  int;      -- GT7's counter as last seen
    v_step_laps int;      -- how far it moved, forwards only
    v_restarted boolean;  -- it went backwards: a new session under the car
    v_lap_now   int;      -- this car's own lap count for the round
    v_lap_seq   int;      -- and which of their laps this round this one is
    v_live_car  boolean;  -- on track, so worth listening to at all
    v_here      boolean;
    v_floor_ms  int;
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
           fuel_base_ok, lap_watched, lap_near, lap_far,
           -- The raw counter as last seen. A row written before this
           -- migration has none, and is treated as a car arriving: its lap
           -- count is kept, and the next crossing starts the log again.
           COALESCE(log_lap, lap)
      INTO v_last, v_prev_lap, v_at_start, v_burn, v_started, v_base_ok,
           v_watched, v_near_n, v_far_n, v_raw_prev
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

    -- Where this car is in relation to the circuit being timed. One scan of
    -- the stored outline, at most 2,000 rows of three numbers, once per car
    -- per beacon, and it answers two questions at once: the nearest point is
    -- how far round the lap the car has got, and how far away that point is
    -- says whether this is the right circuit at all. The scan used to sit at
    -- the end of this function and was only ever used for the first of them.
    --
    -- Only once the outline is a finished lap: a part-traced line starts
    -- nowhere in particular, so a distance along it would mean nothing, and
    -- a car driving into track nobody has covered yet is not lost, it is
    -- first. Only while on track, because a car in its pit box or in the
    -- menus has no position on the circuit and keeps the last one it had.
    IF COALESCE(p_on_track, true) AND p_x IS NOT NULL AND p_z IS NOT NULL
       AND COALESCE((SELECT shape_closed FROM events WHERE id = v_event_id), false) THEN
        SELECT seq, dist_m, sqrt(power(x - p_x, 2) + power(z - p_z, 2))
          INTO v_seq, v_prog, v_near_m
          FROM live_track_path
         WHERE event_id = v_event_id
         ORDER BY power(x - p_x, 2) + power(z - p_z, 2)
         LIMIT 1;
    END IF;
    v_on_line  := v_near_m IS NOT NULL AND v_near_m <= public.live_track_near_m();
    v_off_line := v_near_m IS NOT NULL AND v_near_m >  public.live_track_near_m();

    -- Was the lap now ending driven here? From the tally kept across it,
    -- which is why this reads the stored counters and not the beacon in
    -- hand: that one is the crossing itself. A car with nothing measurable
    -- behind it is a round with no outline traced, and then the question
    -- cannot be asked and is not held against the driver.
    v_here := COALESCE(v_near_n, 0) + COALESCE(v_far_n, 0) = 0
           OR COALESCE(v_near_n, 0) >= (COALESCE(v_near_n, 0) + COALESCE(v_far_n, 0))
                                       * public.live_lap_on_line();
    -- Below this, a time coming back from GT7 is not a lap of this round.
    v_floor_ms := public.live_lap_floor_ms(v_event_id);

    -- How GT7's own counter has moved since the last beacon, which is the
    -- one question everything below is really asking.
    --
    -- Backwards means a session has restarted under this car: the green
    -- flag, or a driver who dropped out and rejoined the lobby. Forwards by
    -- one is a lap. Forwards by more than one is a reporter that was asleep
    -- while the car kept going, which happens when a phone locks, and those
    -- laps are real even though their times are lost.
    --
    -- And none of it is asked at all of a car that is not on track. What the
    -- game streams to a driver sitting in the menus belongs to wherever they
    -- are in the game, not to this session: a custom race somewhere else
    -- reports its own lap, and with a cumulative count every forward step of
    -- it would be added to a race distance here. 185 holds the position and
    -- the speed of a car that is away for the same reason; this is the rest
    -- of that rule.
    v_live_car  := COALESCE(p_on_track, true);
    v_restarted := v_live_car AND p_lap IS NOT NULL AND v_raw_prev IS NOT NULL
               AND p_lap < v_raw_prev;
    v_step_laps := CASE WHEN NOT v_live_car OR p_lap IS NULL
                          OR v_raw_prev IS NULL THEN 0
                        ELSE GREATEST(0, p_lap - v_raw_prev) END;
    -- This car's own count for the round: it moves with the counter while
    -- the counter is going forwards, and holds while a session restarts
    -- under it, or while the driver is away. GREATEST used to do this job
    -- and could only do half of it, since a car that rejoined on lap one
    -- counted up from one again and never got back past the figure it had
    -- when it dropped.
    --
    -- With no raw counter recorded yet, GT7's number is taken at face value,
    -- because a car arriving has to start somewhere and that is the best
    -- thing we have. The first number believed is therefore the first one a
    -- car reports while actually on track, since nothing is recorded for a
    -- driver who is still in the menus.
    v_lap_now := CASE WHEN NOT v_live_car    THEN COALESCE(v_prev_lap, 0)
                      WHEN v_raw_prev IS NULL THEN COALESCE(p_lap, v_prev_lap, 0)
                      ELSE v_prev_lap + v_step_laps END;

    -- A race starting, as the car itself reports it: its lap counter has
    -- gone backwards and it has not been seen racing yet. Only the first
    -- one counts, so a driver who drops out and rejoins mid-race keeps
    -- everything, which is what the lap count above is for.
    v_racing  := v_mode = 'race';
    v_restart := v_racing
             AND NOT COALESCE(v_started, false)
             AND v_restarted;
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
    --
    -- Measured against the RAW counter, not against this car's round total.
    -- Those two used to be the same number, and the day they stop agreeing
    -- is the day a driver rejoins: the round total is held where it was, so
    -- every beacon afterwards looked like a crossing and no beacon ever
    -- looked like an advance of exactly one.
    v_crossed := v_live_car AND p_lap IS NOT NULL AND v_raw_prev IS NOT NULL
             AND p_lap <> v_raw_prev;
    -- Worth writing down: a lap that ADVANCED by exactly one, that we
    -- watched from the crossing before it, and whose time is a lap time.
    --
    -- The "exactly one" matters more than it looks. v_crossed is true for
    -- any change, and a counter that has restarted would otherwise look
    -- like a crossing on every beacon, taking a row every second and a half
    -- for the rest of the race.
    --
    -- And that it was a lap of this circuit: driven here, in a time a lap of
    -- this length could be driven in. A driver who spends a practice window
    -- at another track is reporting perfectly good laps of somewhere else,
    -- and the round's log is not the place for them.
    v_log_lap := v_crossed
             AND COALESCE(v_watched, false)
             AND v_step_laps = 1
             AND p_last_lap_ms IS NOT NULL
             AND p_last_lap_ms >= v_floor_ms
             AND v_here;
    IF v_restarted THEN
        -- A session has restarted under this car: the green flag, or a
        -- driver who has just rejoined the lobby. Either way the car in
        -- front of us is not the car we were measuring a moment ago. The
        -- fuel baseline goes, and so does the right to call the lap now in
        -- progress a watched one, since we did not see it begin.
        v_at_start := p_fuel_pct;
        v_base_ok  := false;
        -- The green flag is the exception: a race starts at the line, so the
        -- lap about to be driven is a whole one and we are watching it from
        -- the beginning.
        v_watched  := v_restart;
        -- The measured burn survives a rejoin, because it is a fact about
        -- this car at this circuit and the car has not changed. The green
        -- flag is different: whatever was measured was measured across the
        -- end of qualifying, and a tank topped up between the two makes it
        -- worse than useless.
        IF v_restart THEN v_burn := NULL; END IF;
    ELSIF p_fuel_pct IS NOT NULL AND p_lap IS NOT NULL THEN
        IF v_raw_prev IS NULL OR p_lap <> v_raw_prev THEN
            v_used := CASE WHEN v_at_start IS NULL THEN NULL
                           ELSE v_at_start - p_fuel_pct END;
            IF COALESCE(v_base_ok, false)
               AND v_used IS NOT NULL AND v_used > 0
               AND v_step_laps = 1
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
            v_base_ok  := v_raw_prev IS NOT NULL;
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
        fuel_base_ok, lap_watched, lap_near, lap_far, log_lap, updated_at
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
        -- Only from a car that is actually out there. A driver whose first
        -- beacon arrives while they are in the menus has no position: what
        -- the packet carries then is the lobby camera, and writing it here
        -- put a marker on the circuit for somebody who had never driven it.
        -- 185 holds the last position of a car that goes away, and held
        -- that one too, because holding is what it does.
        CASE WHEN v_live_car THEN p_x END,
        CASE WHEN v_live_car THEN p_y END,
        CASE WHEN v_live_car THEN p_z END,
        CASE WHEN v_live_car THEN p_speed_kph ELSE 0 END,
        COALESCE(p_on_track, true),
        p_fuel_pct, p_laps_in_race, v_client, v_at_start, v_burn,
        NOT v_racing, COALESCE(v_base_ok, false), false,
        CASE WHEN v_on_line THEN 1 ELSE 0 END,
        CASE WHEN v_off_line THEN 1 ELSE 0 END,
        CASE WHEN v_live_car THEN p_lap END, now()
    )
    ON CONFLICT (event_id, driver_id) DO UPDATE SET
        lobby_number = COALESCE(EXCLUDED.lobby_number, lp.lobby_number),
        -- The car's own lap count for this round, worked out above: it moves
        -- by however far GT7's counter moved forwards, and holds while a
        -- session restarts under it. A race starting takes the car's own
        -- number, because that is the point at which the count begins.
        lap          = CASE WHEN v_restart THEN COALESCE(p_lap, 0)
                            ELSE v_lap_now END,
        -- And what GT7 last said, which is the thing every judgement above
        -- is made against. Kept raw: it follows the counter down as well as
        -- up, which is the whole point of having it. Only from a car on
        -- track, so the baseline a returning driver is measured against is
        -- the last number they reported while actually driving.
        log_lap      = CASE WHEN COALESCE(EXCLUDED.on_track, true)
                            THEN COALESCE(p_lap, lp.log_lap)
                            ELSE lp.log_lap END,
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
                            -- Nor is a lap time from a car that is not out
                            -- there this car's last lap. It belongs to
                            -- whatever they are doing instead.
                            WHEN NOT COALESCE(EXCLUDED.on_track, true)
                                 THEN lp.last_lap_ms
                            -- A counter that has just restarted under a car
                            -- already racing is a driver who has rejoined,
                            -- and what the game reports on that beacon is
                            -- the lap they were on when they left or the
                            -- part of one they have driven since. Neither is
                            -- this car's last lap.
                            WHEN v_restarted AND NOT v_restart
                                 THEN lp.last_lap_ms
                            WHEN NOT COALESCE(lp.lap_watched, false)
                                 THEN lp.last_lap_ms
                            -- A lap driven at another circuit is a real lap
                            -- time of somewhere else, and belongs in this
                            -- column no more than it belongs in the log.
                            WHEN NOT v_here THEN lp.last_lap_ms
                            -- A lap of this circuit cannot be quicker than
                            -- the circuit is long, so a figure below the
                            -- floor is not a lap and does not replace the
                            -- one on screen. 177 applied a floor where a
                            -- completed lap votes for a best and nowhere
                            -- else, which left Last free to show a 1.2
                            -- second lap until the next one arrived.
                            WHEN p_last_lap_ms IS NOT NULL
                                 AND p_last_lap_ms < v_floor_ms THEN lp.last_lap_ms
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
        -- shows until the next one. It is now the length of this circuit at
        -- 400 km/h rather than a flat twenty seconds, which is the same idea
        -- applied with the one fact about the round that is actually known:
        -- a minute is a plausible lap of somewhere, and an impossible lap of
        -- the Nordschleife.
        --
        -- A best is also refused outright while the car is not here. Laps of
        -- another circuit are quicker than laps of this one far more often
        -- than not, and this column only ever falls, so one of them would
        -- own the screen for the rest of the session.
        best_lap_ms  = CASE
            WHEN v_restart THEN NULL
            WHEN NOT COALESCE(EXCLUDED.on_track, true) THEN lp.best_lap_ms
            WHEN v_restarted AND NOT v_restart THEN lp.best_lap_ms
            WHEN NOT COALESCE(lp.lap_watched, false) THEN lp.best_lap_ms
            WHEN NOT v_here THEN lp.best_lap_ms
            WHEN v_racing THEN LEAST(lp.best_lap_ms,
                                     CASE WHEN p_last_lap_ms >= v_floor_ms
                                          THEN p_last_lap_ms END)
            -- Outside a race the game's own best is trusted, which is
            -- what gives a practice screen a time straight away. It gets
            -- the same floor as everything else: 177 put the floor on the
            -- completed-lap vote only, so a bogus best from the game walked
            -- straight past it, and in practice it would then be pinned
            -- there for the session since this only ever falls.
            ELSE LEAST(COALESCE(CASE WHEN p_best_lap_ms >= v_floor_ms
                                     THEN p_best_lap_ms END, lp.best_lap_ms),
                       COALESCE(lp.best_lap_ms,
                                CASE WHEN p_best_lap_ms >= v_floor_ms
                                     THEN p_best_lap_ms END),
                       CASE WHEN p_last_lap_ms >= v_floor_ms
                            THEN p_last_lap_ms END) END,
        -- Only while the car is on track. GT7 keeps streaming a position
        -- after a driver leaves the session, and what it streams is not the
        -- car: in the lobby it follows the game's own camera, so the dot
        -- flew around a circuit the driver was not on. A car that is away
        -- keeps the last place it actually was, which is the same rule the
        -- distance round the lap has always had and for the same reason.
        x            = CASE WHEN COALESCE(EXCLUDED.on_track, true)
                            THEN EXCLUDED.x ELSE lp.x END,
        y            = CASE WHEN COALESCE(EXCLUDED.on_track, true)
                            THEN EXCLUDED.y ELSE lp.y END,
        z            = CASE WHEN COALESCE(EXCLUDED.on_track, true)
                            THEN EXCLUDED.z ELSE lp.z END,
        -- Same for the speed. A car in the menus reading 188 kph on the
        -- timing screen is the camera's speed, not the driver's.
        speed_kph    = CASE WHEN COALESCE(EXCLUDED.on_track, true)
                            THEN EXCLUDED.speed_kph ELSE 0 END,
        on_track     = EXCLUDED.on_track,
        fuel_pct     = COALESCE(EXCLUDED.fuel_pct, lp.fuel_pct),
        -- The other half of what was on screen, and from the same place: a
        -- driver in the menus with a 2 lap race set up made the timing
        -- screen read "lap 8 of 2".
        laps_in_race = CASE WHEN COALESCE(EXCLUDED.on_track, true)
                            THEN COALESCE(EXCLUDED.laps_in_race, lp.laps_in_race)
                            ELSE lp.laps_in_race END,
        client       = COALESCE(EXCLUDED.client, lp.client),
        fuel_at_lap_start = EXCLUDED.fuel_at_lap_start,
        burn_per_lap      = EXCLUDED.burn_per_lap,
        fuel_base_ok      = EXCLUDED.fuel_base_ok,
        -- From its first crossing on, this car's laps are whole ones.
        --
        -- The green flag keeps that, because a race starts at the line: the
        -- lap the car is about to drive begins where we are watching, so it
        -- is a whole lap and its time is the first time of the race. A
        -- rejoin is the opposite. The driver comes back somewhere out on the
        -- circuit, mid-lap, and GT7 will hand us a time for the part of it
        -- they drove, which is the 184 case exactly: we did not see that lap
        -- begin, so it does not count and nor does the next thing the game
        -- says about their best.
        lap_watched       = CASE WHEN v_restart   THEN true
                                 WHEN v_restarted THEN false
                                 ELSE lp.lap_watched OR v_crossed END,
        -- The tally for the lap now being driven. A crossing starts it again
        -- from nothing, so what these hold is always a statement about one
        -- lap, and this beacon counts towards the lap it belongs to.
        lap_near     = CASE WHEN v_crossed THEN 0 ELSE lp.lap_near END
                     + CASE WHEN v_on_line  THEN 1 ELSE 0 END,
        lap_far      = CASE WHEN v_crossed THEN 0 ELSE lp.lap_far END
                     + CASE WHEN v_off_line THEN 1 ELSE 0 END,
        updated_at   = now();

    -- A race starting throws the car's distance round the lap away too. It
    -- was measured against qualifying, so leaving it would order the
    -- formation lap by where everybody happened to be when qualifying
    -- ended. This beacon's own figure is written back a few lines below.
    IF v_restart THEN
        UPDATE live_positions SET track_seq = NULL, progress_m = NULL
         WHERE event_id = v_event_id AND driver_id = v_driver_id;
    END IF;

    -- One row per lap, kept. Everything the live screen knows is otherwise
    -- overwritten by the next beacon and gone when the session ends: a six
    -- hour race across ten splits sends something like 2.3 million updates
    -- and used to leave 160 rows behind. This is about seven thousand rows a
    -- round, which is nothing, and it is what any stat about pace has to be
    -- built on.
    IF v_log_lap THEN
        -- Which of this driver's laps of the round this is. Counted from the
        -- log itself, so it carries across everything GT7's own numbering
        -- does afterwards: a driver who practises for five laps tonight and
        -- comes back tomorrow continues at six, where the game hands us a
        -- lap one again and a chart drawn against that would put tomorrow on
        -- top of tonight. One count per completed lap, so once every eight
        -- minutes per car, against an index on exactly these columns.
        SELECT count(*) + 1 INTO v_lap_seq
          FROM live_laps
         WHERE event_id = v_event_id AND driver_id = v_driver_id
           AND mode = v_mode;

        INSERT INTO live_laps (event_id, driver_id, lobby_number, lap, lap_ms,
                               fuel_pct, mode, session_from, seq)
        VALUES (v_event_id, v_driver_id, v_lobby,
                -- The car's own count for the round is the lap now being
                -- driven, so the lap that has just ended is the one before
                -- it. Taken from that rather than from GT7's counter, which
                -- after a rejoin is counting from one and says nothing about
                -- where in the race this lap happened.
                v_lap_now - 1, p_last_lap_ms, p_fuel_pct, v_mode, v_live_from,
                v_lap_seq);
    END IF;

    UPDATE live_timing_tokens SET last_used_at = now() WHERE token = p_token;

    -- How far round the lap this car is, which is what turns the number in
    -- the first column from a place in a list into a position. Found by the
    -- one scan at the top of this function, and written here, after the
    -- insert above and after a race start has cleared what qualifying left
    -- behind.
    IF v_seq IS NOT NULL THEN
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
        -- Reported back for whatever asks. It used to be answerable only
        -- while the outline was being drawn, since deciding who may draw it
        -- was all it was ever for; now that every beacon is measured against
        -- the finished line as well, it is true for as long as the car is
        -- somewhere else. The live screen works this out for itself from the
        -- positions it already has, which is why it has been flagging
        -- Another track all along while the server went on recording laps.
        'elsewhere', v_elsewhere OR v_off_line,
        'race_started', COALESCE(v_restart, false),
        'next_ms', public.live_beacon_interval_ms(p_on_track)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_beacon(text, int, int, int, int, real, real, int, boolean, real, int, real, text)
    TO anon, authenticated;


-- ---- and the laps already written down ----
-- The only test that can be applied backwards. live_laps keeps times, not
-- positions, so where a car was is gone; how long its lap took is not, and
-- a lap quicker than this circuit can physically be driven was not a lap of
-- it. Rounds with no outline traced have a floor of twenty seconds and are
-- effectively untouched.
--
-- Anything left over is a wrong-circuit lap slow enough to pass for one of
-- these, which no rule here can tell from the real thing. Those go by hand:
--
--   DELETE FROM live_laps
--    WHERE event_id = '<round>' AND driver_id = '<driver>' AND mode = 'practice';
DO $$
DECLARE v_gone int;
BEGIN
    WITH swept AS (
        DELETE FROM live_laps l
         USING events e
         WHERE e.id = l.event_id
           AND l.lap_ms < public.live_lap_floor_ms(e.id)
        RETURNING 1
    )
    SELECT count(*) INTO v_gone FROM swept;
    RAISE NOTICE 'swept % lap(s) that were too quick to be laps of their circuit', v_gone;
END $$;




-- ---- and the one already on the map ----
-- Rows written before this carry whatever the first beacon handed over,
-- and nothing in them says which of those was a car and which was a camera.
-- Every car that is away right now is therefore cleared: a position is a
-- thing we have seen, and these are things we have merely been told.
--
-- Self-healing by design. A driver who is genuinely parked vanishes from
-- the map until their next beacon on track, which is one lap at worst and
-- usually seconds, and a driver who was never out there stops appearing on
-- a circuit they have not driven.
UPDATE live_positions
   SET x = NULL, y = NULL, z = NULL, speed_kph = 0,
       track_seq = NULL, progress_m = NULL
 WHERE on_track IS NOT TRUE;
