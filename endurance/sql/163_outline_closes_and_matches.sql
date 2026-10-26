-- ============================================================
-- 163 The outline closes, and new points must be on it
--
-- 162 guarded the outline with a bounding box: a position well outside the
-- shape already traced was taken to be another circuit. That test cannot
-- work, and a driver who went to Sugo proved it by having Sugo drawn
-- through the middle of the Nordschleife.
--
-- GT7's coordinates are per-track and roughly centred on each circuit's own
-- origin. They are not a shared world space. So every circuit overlaps every
-- other, and a 3.7 km track sits comfortably inside a 6.2 km one. The
-- bounding box of the Nordschleife contains the whole of Sugo. There was
-- never a distance at which that test would have fired.
--
-- The test in 162 passed because the fixture put the stray 40 km away, which
-- is a place no GT7 circuit is. The data was wrong in the one way that
-- mattered.
--
-- Two changes, and the first makes the problem mostly disappear:
--
--   1. The outline closes. A circuit is a loop: once the path has come back
--      round to where it started, it is finished, and nothing more is
--      appended for the rest of the round. The window in which corruption is
--      even possible shrinks from "the whole week" to "the first lap".
--
--      Derived rather than stored, so it needs no column and resets by
--      itself whenever the path is cleared: a path of enough points whose
--      last point is back near its first one is a completed lap.
--
--   2. Taking over the shape job requires being on the traced line, by
--      distance to the nearest point rather than to a bounding box. A car on
--      this circuit is always within a track's width of where cars have
--      already been. A car at another circuit is, with overwhelming
--      likelihood, not. The car already holding the job keeps extending by
--      continuity, which is what lets a part of the lap nobody has driven yet
--      still be traced.
--
-- Between them: the first lap is captured as before, and from the moment it
-- closes the outline is immutable until an admin clears it.
-- ============================================================

-- How close the path has to come back to its start to count as a lap, and
-- how many points before that is even asked. 60 points at 1.5 seconds is
-- around 90 seconds of driving, which is a lap of a short circuit and a
-- third of a Nordschleife one, so it cannot close on the first corner.
CREATE OR REPLACE FUNCTION public.live_track_closure_m()
RETURNS real LANGUAGE sql IMMUTABLE AS $$ SELECT 200::real; $$;

-- How near the traced line a car must be to take over drawing it. A track is
-- maybe 15 m wide and racing lines vary, so 80 m is generous for "on this
-- circuit" while still being a thousandth of the space between two circuits
-- that merely overlap in coordinates.
CREATE OR REPLACE FUNCTION public.live_track_match_m()
RETURNS real LANGUAGE sql IMMUTABLE AS $$ SELECT 80::real; $$;

GRANT EXECUTE ON FUNCTION public.live_track_closure_m() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.live_track_match_m()   TO anon, authenticated;


-- Has this round's outline come back round to where it started? Derived from
-- the path itself, so clearing the path un-closes it with no extra state.
CREATE OR REPLACE FUNCTION public.live_track_closed(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH p AS (
        SELECT COUNT(*) AS n,
               MIN(seq) AS lo,
               MAX(seq) AS hi
        FROM   live_track_path WHERE event_id = p_event_id
    )
    SELECT CASE
        WHEN (SELECT n FROM p) < public.live_track_min_shape_points() THEN false
        ELSE (
            SELECT sqrt(power(l.x - f.x, 2) + power(l.z - f.z, 2)) <= public.live_track_closure_m()
            FROM   live_track_path f, live_track_path l
            WHERE  f.event_id = p_event_id AND f.seq = (SELECT lo FROM p)
              AND  l.event_id = p_event_id AND l.seq = (SELECT hi FROM p)
        )
    END;
$$;

GRANT EXECUTE ON FUNCTION public.live_track_closed(uuid) TO anon, authenticated;


-- How far a position is from the traced line.
--
-- To the LINE, not to the nearest recorded point. At racing speed a beacon
-- every 1.5 seconds leaves points 80 to 170 m apart, so a car sitting
-- squarely on the track but midway between two of them is up to 85 m from
-- either, which is further than the match radius. Measuring against the
-- points alone would therefore reject cars that are plainly on the circuit,
-- and the threshold would have to be loosened until it stopped telling two
-- circuits apart.
--
-- Segments longer than a plausible step are skipped: those are the jumps
-- where the shape job handed from one car to another, and the straight line
-- across them is not track.
CREATE OR REPLACE FUNCTION public.live_track_distance(p_event_id uuid, p_x real, p_z real)
RETURNS double precision LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH seg AS (
        SELECT x AS x1, z AS z1,
               LEAD(x) OVER (ORDER BY seq) AS x2,
               LEAD(z) OVER (ORDER BY seq) AS z2
        FROM   live_track_path WHERE event_id = p_event_id
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


-- ============================================================
-- The beacon. Only the outline block differs from 162.
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
    v_lastx     real; v_lastz real;
    v_near      double precision;
    v_closed    boolean := false;
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
        SELECT COUNT(*) INTO v_points FROM live_track_path WHERE event_id = v_event_id;
        v_closed := public.live_track_closed(v_event_id);

        IF NOT v_closed THEN
            SELECT shape_driver_id INTO v_shape FROM events WHERE id = v_event_id;

            -- The two tests are alternatives, not both, and which one applies
            -- depends on whether this car is already drawing the line.
            --
            --   Already drawing it  -> continuity. Its next point is new
            --      track by definition, so it is never near an existing one;
            --      that is the whole purpose of holding the job.
            --
            --   Taking it on        -> proximity to the line. It joins
            --      wherever it happens to be on the circuit, so it is never
            --      continuous with the last point; the resulting jump is
            --      expected and the page already breaks the line across it.
            --
            -- Getting this backwards stops tracing dead at exactly
            -- min_shape_points and refuses every legitimate handover.
            IF v_shape = v_driver_id THEN
                SELECT x, z INTO v_lastx, v_lastz
                  FROM live_track_path WHERE event_id = v_event_id
                 ORDER BY seq DESC LIMIT 1;

                IF v_lastx IS NOT NULL
                   AND sqrt(power(p_x - v_lastx, 2) + power(p_z - v_lastz, 2))
                       > public.live_track_step_m() THEN
                    -- Teleported while holding the job: a restart, the lobby,
                    -- or a different circuit. Hand it back, and the proximity
                    -- test applies to this car from its next beacon onward.
                    UPDATE events SET shape_driver_id = NULL WHERE id = v_event_id;
                    v_elsewhere := true;
                ELSE
                    v_shape_ok := true;
                END IF;

            ELSE
                -- Distance to the nearest traced point, not to a bounding
                -- box. GT7's coordinates are per-circuit and centred on each
                -- track's own origin, so circuits overlap in space: the
                -- Nordschleife's bounding box contains the whole of Sugo.
                -- Only proximity to the line itself tells them apart.
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
        -- The outline is a finished lap and is not taking any more points.
        'outline_closed', COALESCE(v_closed, false),
        'elsewhere', v_elsewhere,
        'next_ms', public.live_beacon_interval_ms(p_on_track)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_beacon(text, int, int, int, int, real, real, int, boolean, real, int, real)
    TO anon, authenticated;
