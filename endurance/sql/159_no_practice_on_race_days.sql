-- ============================================================
-- 159 No practice window on a race day
--
-- 158 let a round carry a nightly practice window and left the priority
-- order to keep it clear of a race. That holds up while a race window is
-- open, which runs from two hours before the start to two hours after the
-- scheduled finish: a race always wins there, so nothing is disturbed
-- during a round that runs to time.
--
-- Two reasons to stand practice down for the whole day anyway.
--
-- The policy one, which is the main one: race day belongs to the race. A
-- public page inviting people to a practice session on the morning of a
-- round, or an hour after one has finished, is noise at exactly the moment
-- the page should be about the race and its result.
--
-- The technical one, which is narrow but real: an endurance round that
-- overruns, or is restarted, can still have cars circulating after its
-- window has shut. With an evening practice window open, the first beacon
-- past that point starts a new session, which clears the field and relabels
-- a race still being run as Practice. Rare, and the one case where the page
-- would actively say something false.
--
-- So practice is suppressed across the whole local day a round occupies,
-- start to finish, which also keeps it out of the small hours of a race
-- that runs past midnight. Any round racing silences it, not only the round
-- the window is attached to, since there is only ever one live page.
--
-- Costs one extra lookup per beacon on a table of a few dozen rows.
-- ============================================================

CREATE OR REPLACE FUNCTION public.live_is_race_day()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (
        SELECT 1
        FROM   events e
        WHERE  e.status <> 'completed'
          AND  e.status <> 'cancelled'
          AND  e.starts_at IS NOT NULL
          AND  (now() AT TIME ZONE public.live_practice_tz())::date
               BETWEEN (e.starts_at AT TIME ZONE public.live_practice_tz())::date
                   AND ((e.starts_at + (COALESCE(e.duration_hours, 0) * interval '1 hour'))
                        AT TIME ZONE public.live_practice_tz())::date
    );
$$;

GRANT EXECUTE ON FUNCTION public.live_is_race_day() TO anon, authenticated;


-- Same shape as 158, so this replaces rather than drops. A race window and
-- an admin test window are untouched: only the standing practice window is
-- stood down for the day.
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
               COALESCE(e.live_test_until IS NOT NULL AND now() < e.live_test_until, false) AS in_test,
               COALESCE(public.live_in_practice(e.live_practice_from, e.live_practice_to), false)
                   AND NOT (SELECT today FROM race_day) AS in_practice
        FROM   events e
        WHERE  e.status <> 'completed'
          AND  e.status <> 'cancelled'
    )
    SELECT id,
           NOT in_race,
           CASE WHEN in_race THEN 'race' WHEN in_test THEN 'test' ELSE 'practice' END
    FROM   candidate
    WHERE  in_race OR in_test OR in_practice
    ORDER  BY in_race DESC, in_test DESC, starts_at
    LIMIT  1;
$$;

GRANT EXECUTE ON FUNCTION public.live_active_event() TO anon, authenticated;


-- The page needs to know the difference between "not six o'clock yet" and
-- "stood down because there is a race on", because they want different
-- words. 'open' stays the honest answer to "can I drive right now".
CREATE OR REPLACE FUNCTION public.live_practice_window()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_tz       text := public.live_practice_tz();
    v_e        record;
    v_local    timestamp;
    v_day      timestamp;
    v_race_day boolean;
    v_open     boolean;
    v_at       timestamptz;
BEGIN
    SELECT e.id, e.name, e.round, e.circuit_name,
           e.live_practice_from AS p_from, e.live_practice_to AS p_to
      INTO v_e
      FROM events e
     WHERE e.status <> 'completed'
       AND e.status <> 'cancelled'
       AND e.live_practice_from IS NOT NULL
       AND e.live_practice_to   IS NOT NULL
     ORDER BY e.starts_at
     LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('enabled', false);
    END IF;

    v_local    := now() AT TIME ZONE v_tz;
    v_day      := date_trunc('day', v_local);
    v_race_day := public.live_is_race_day();
    v_open     := public.live_in_practice(v_e.p_from, v_e.p_to) AND NOT v_race_day;

    v_at := (v_day + CASE WHEN v_open THEN v_e.p_to ELSE v_e.p_from END) AT TIME ZONE v_tz;
    IF v_at <= now() THEN
        v_at := (v_day + interval '1 day'
                 + CASE WHEN v_open THEN v_e.p_to ELSE v_e.p_from END) AT TIME ZONE v_tz;
    END IF;

    RETURN jsonb_build_object(
        'enabled',      true,
        'open',         v_open,
        -- Set when the schedule exists but is stood down for the day.
        'race_day',     v_race_day,
        'event_id',     v_e.id,
        'event_name',   v_e.name,
        'round',        v_e.round,
        'circuit_name', v_e.circuit_name,
        'from',         to_char(v_e.p_from, 'HH24:MI'),
        'to',           to_char(v_e.p_to,   'HH24:MI'),
        'at',           v_at,
        'tz',           v_tz
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_practice_window() TO anon, authenticated;
