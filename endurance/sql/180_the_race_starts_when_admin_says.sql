-- ============================================================
-- 180 The race starts when admin says it does
--
-- 179 split the race window at the scheduled start and guessed the green
-- flag from each car's lap counter. It worked, and it was solving the
-- wrong problem: the system was trying to deduce a moment that a person
-- knows exactly. Matt's own proposal, and it is better.
--
--   Practice runs as it does now and stops on race day.
--   Race day shows nothing. Qualifying is not recorded at all.
--   Admin presses Start Race just before the lights go out.
--   From that moment it records and shows the race, and nothing else.
--
-- What this removes: the two hours before the scheduled start that used to
-- be live, the qualifying mode and its ordering, and the dependence on
-- starts_at being accurate to the minute. starts_at is back to being the
-- published schedule rather than a trigger.
--
-- What it keeps from 179, because a button does not fix it: GT7 can still
-- be holding a best lap from qualifying, and it reports that field on
-- every beacon. So in a race the best lap is set only by a lap actually
-- completed, never by the game's own best-lap field, and a car's figures
-- do not count until it has completed a lap since the button was pressed.
--
-- The lap-counter reset is kept too. The button is pressed just BEFORE the
-- green flag, with the cars still in the lobby on their qualifying lap
-- numbers, so without it a car that qualified on lap 14 would carry lap 14
-- into the race and never shake it off, GREATEST being what it is.
--
-- Pressing it again clears everything and starts over, which is what a red
-- flag needs.
--
-- Run 179 first. Its beacon changes and its race_started column are what
-- this relies on; what 180 replaces is only how the race begins and ends.
-- ============================================================

-- When admin started the race. Null means not started, which is what makes
-- race day blank until somebody says otherwise.
ALTER TABLE events
    ADD COLUMN IF NOT EXISTS race_live_from timestamptz;


-- ---- the button ----
CREATE OR REPLACE FUNCTION public.live_race_start(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_gone int; v_name text; v_round int;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
    END IF;

    SELECT name, round INTO v_name, v_round FROM events WHERE id = p_event_id;
    IF v_name IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'No such round.');
    END IF;

    -- Everything from qualifying goes. Pressing this a second time is a
    -- restart, so it has to clear just as thoroughly as the first press.
    DELETE FROM live_positions WHERE event_id = p_event_id;
    GET DIAGNOSTICS v_gone = ROW_COUNT;

    UPDATE events
       SET race_live_from    = now(),
           live_session_mode = 'race'
     WHERE id = p_event_id;

    RETURN jsonb_build_object('ok', true, 'cleared', v_gone,
                              'round', v_round, 'name', v_name,
                              'from', now());
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_race_start(uuid) TO authenticated;


-- ---- and off again ----
--
-- Not an undo. A pair: one button puts the timing live, the other takes it
-- off, and between them admin decides what the public sees at any moment
-- rather than inferring it from a schedule. Off is the right answer to a
-- press made too early, to a session abandoned, and to anything on screen
-- that should not be.
CREATE OR REPLACE FUNCTION public.live_race_stop(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_gone int;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
    END IF;

    DELETE FROM live_positions WHERE event_id = p_event_id;
    GET DIAGNOSTICS v_gone = ROW_COUNT;

    UPDATE events
       SET race_live_from    = NULL,
           live_session_mode = NULL
     WHERE id = p_event_id;

    RETURN jsonb_build_object('ok', true, 'cleared', v_gone);
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_race_stop(uuid) TO authenticated;


-- ---- what is live now ----
CREATE OR REPLACE FUNCTION public.live_active_event()
RETURNS TABLE (event_id uuid, is_test boolean, mode text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH race_day AS (SELECT public.live_is_race_day() AS today),
    candidate AS (
        SELECT e.id,
               e.starts_at,
               -- The race runs from the moment it was started, for its own
               -- duration plus two hours of slack, rather than from a time
               -- somebody typed into a form weeks ago. A race that starts
               -- twenty minutes late now finishes twenty minutes late, which
               -- is what actually happens.
               COALESCE(e.race_live_from IS NOT NULL
                        AND now() < e.race_live_from
                                  + (COALESCE(e.duration_hours, 6) * interval '1 hour')
                                  + interval '2 hours', false) AS in_race,
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
           CASE WHEN in_race THEN 'race'
                WHEN in_test THEN 'test'
                ELSE 'practice' END
    FROM   candidate
    WHERE  in_race OR in_test OR in_practice
    ORDER  BY in_race DESC, in_test DESC, starts_at
    LIMIT  1;
$$;

GRANT EXECUTE ON FUNCTION public.live_active_event() TO anon, authenticated;


-- ---- what admin sees on the button ----
CREATE OR REPLACE FUNCTION public.live_race_state(p_event_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT jsonb_build_object(
        'started',  e.race_live_from IS NOT NULL,
        'from',     e.race_live_from,
        'running',  e.race_live_from IS NOT NULL
                    AND now() < e.race_live_from
                              + (COALESCE(e.duration_hours, 6) * interval '1 hour')
                              + interval '2 hours',
        'reporting', (SELECT count(*) FROM live_positions lp WHERE lp.event_id = e.id)
    )
    FROM events e WHERE e.id = p_event_id;
$$;

GRANT EXECUTE ON FUNCTION public.live_race_state(uuid) TO authenticated;
