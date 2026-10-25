-- ============================================================
-- 161 Practice can simply stay open until race day
--
-- 158 made practice a nightly window because the one-off test window it
-- replaced had a four hour cap, and a nightly schedule was the smallest
-- step away from that. It is the wrong shape. Drivers are not going to
-- check whether it is past six before deciding to try their connector, and
-- a page that says "come back at 18:00" to somebody sat at their console at
-- five o'clock is just an obstacle.
--
-- So a round can now be open continuously instead, right up to the day it
-- races, which 159 already stands practice down for. Nothing needs to close
-- it: the round completes and practice ends with it, because every practice
-- lookup ignores completed and cancelled rounds.
--
-- The nightly form is kept rather than removed. It costs one branch, and an
-- always-open window is the wrong answer for a round weeks away, or if a
-- quiet overnight page ever becomes a reason to restrict it.
--
-- Shape of it:
--
--   live_practice_always = true,  times NULL   -> open until race day
--   live_practice_always = false, times set    -> open those hours nightly
--   live_practice_always = false, times NULL   -> off
--
-- live_practice_set() takes NULL for both times to mean always, so the
-- admin console keeps one control rather than gaining a second.
-- ============================================================

ALTER TABLE events ADD COLUMN IF NOT EXISTS live_practice_always boolean NOT NULL DEFAULT false;


-- ---- is practice on right now ----
-- The race-day guard from 159 still applies to both forms: race day belongs
-- to the race whether practice is nightly or continuous.
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
               (e.live_practice_always
                OR COALESCE(public.live_in_practice(e.live_practice_from, e.live_practice_to), false))
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


-- ---- what the portal and the live page say about it ----
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
    SELECT e.id, e.name, e.round, e.circuit_name, e.starts_at,
           e.live_practice_from AS p_from, e.live_practice_to AS p_to,
           e.live_practice_always AS p_always
      INTO v_e
      FROM events e
     WHERE e.status <> 'completed'
       AND e.status <> 'cancelled'
       AND (e.live_practice_always
            OR (e.live_practice_from IS NOT NULL AND e.live_practice_to IS NOT NULL))
     ORDER BY e.starts_at
     LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('enabled', false);
    END IF;

    v_race_day := public.live_is_race_day();

    IF v_e.p_always THEN
        -- Nothing to count down to: it is open now and stays open until the
        -- round races, so the page is told when that is instead.
        RETURN jsonb_build_object(
            'enabled',      true,
            'always',       true,
            'open',         NOT v_race_day,
            'race_day',     v_race_day,
            'event_id',     v_e.id,
            'event_name',   v_e.name,
            'round',        v_e.round,
            'circuit_name', v_e.circuit_name,
            'until',        v_e.starts_at,
            'tz',           v_tz
        );
    END IF;

    v_local := now() AT TIME ZONE v_tz;
    v_day   := date_trunc('day', v_local);
    v_open  := public.live_in_practice(v_e.p_from, v_e.p_to) AND NOT v_race_day;

    v_at := (v_day + CASE WHEN v_open THEN v_e.p_to ELSE v_e.p_from END) AT TIME ZONE v_tz;
    IF v_at <= now() THEN
        v_at := (v_day + interval '1 day'
                 + CASE WHEN v_open THEN v_e.p_to ELSE v_e.p_from END) AT TIME ZONE v_tz;
    END IF;

    RETURN jsonb_build_object(
        'enabled',      true,
        'always',       false,
        'open',         v_open,
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


-- ---- setting it ----
-- Both times NULL now means "open until race day" rather than being refused,
-- so one control covers both shapes.
CREATE OR REPLACE FUNCTION public.live_practice_set(
    p_event_id uuid,
    p_from     time DEFAULT NULL,
    p_to       time DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_span interval;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
    END IF;

    IF p_from IS NULL AND p_to IS NULL THEN
        UPDATE events
           SET live_practice_always = true,
               live_practice_from   = NULL,
               live_practice_to     = NULL
         WHERE id = p_event_id;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('ok', false, 'error', 'No such event.');
        END IF;
        RETURN jsonb_build_object('ok', true, 'always', true, 'tz', public.live_practice_tz());
    END IF;

    IF p_from IS NULL OR p_to IS NULL OR p_from = p_to THEN
        RETURN jsonb_build_object('ok', false,
            'error', 'Give both times, or neither to stay open until race day.');
    END IF;

    v_span := CASE WHEN p_to > p_from THEN p_to - p_from
                   ELSE (p_to + interval '24 hours') - p_from END;
    IF v_span > (public.live_practice_max_hours() * interval '1 hour') THEN
        RETURN jsonb_build_object('ok', false,
            'error', format('Keep it to %s hours or less, or give no times to stay open until race day.',
                            public.live_practice_max_hours()));
    END IF;

    UPDATE events
       SET live_practice_always = false,
           live_practice_from   = p_from,
           live_practice_to     = p_to
     WHERE id = p_event_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'No such event.');
    END IF;

    RETURN jsonb_build_object('ok', true, 'always', false,
        'from', to_char(p_from, 'HH24:MI'), 'to', to_char(p_to, 'HH24:MI'),
        'tz', public.live_practice_tz());
END;
$$;

CREATE OR REPLACE FUNCTION public.live_practice_clear(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cleared int;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
    END IF;

    UPDATE events
       SET live_practice_always = false,
           live_practice_from   = NULL,
           live_practice_to     = NULL
     WHERE id = p_event_id;

    DELETE FROM live_positions WHERE event_id = p_event_id;
    GET DIAGNOSTICS v_cleared = ROW_COUNT;

    RETURN jsonb_build_object('ok', true, 'cleared', v_cleared);
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_practice_set(uuid, time, time) TO authenticated;
GRANT EXECUTE ON FUNCTION public.live_practice_clear(uuid)           TO authenticated;
