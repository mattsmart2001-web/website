-- ============================================================
-- 198 Setting aside a driver who has gone home
--
-- 197 put the control on the live board, which is where the problem is
-- noticed. It is not where the problem ends up. A driver who takes a Gr.1
-- round for five laps and then quits has no live_positions row any more,
-- so there is no board row to press, and their line sits on the chart and
-- in the lap log for the rest of the evening with nothing to do about it.
--
-- Three small things, then, and no new idea:
--
--   live_lap_void and live_lap_unvoid take a null mode, meaning every
--   session of that round the driver has laps in. The lap log can be read
--   with the session picker on "Everything", and from there "this driver's
--   times" is a statement about the round rather than about one evening.
--   Spelled out as rows per mode rather than a null stored in the table,
--   so every reader keeps the plain equality test it already has and
--   nothing has to learn what a null mode means.
--
--   live_field carries void_rev: a number that changes whenever the voids
--   for this round and session change. The live page holds laps it has
--   already pulled down, and the feed is incremental, so a void set from
--   somewhere else would otherwise leave that line drawn until somebody
--   reloaded. One integer, on a poll that is already happening, against a
--   table with a handful of rows.
--
--   live_lap_void_list takes a null mode already and is public, which is
--   what lets a page offer the way back for a driver who is no longer in
--   anything it can see.
-- ============================================================

-- ---- void, across one session or all of them ----
DROP FUNCTION IF EXISTS public.live_lap_void(uuid, uuid, text, text);

CREATE FUNCTION public.live_lap_void(p_event_id  uuid,
                                     p_driver_id uuid,
                                     p_mode      text DEFAULT NULL,
                                     p_reason    text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_modes text[];
    v_laps  int;
    v_name  text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM user_roles ur
                    WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
        RAISE EXCEPTION 'Admins only';
    END IF;
    IF p_mode IS NOT NULL AND p_mode NOT IN ('practice', 'race', 'test') THEN
        RAISE EXCEPTION 'Unknown session mode: %', p_mode;
    END IF;

    SELECT d.display_name INTO v_name FROM drivers d WHERE d.id = p_driver_id;
    IF v_name IS NULL THEN
        RAISE EXCEPTION 'No such driver';
    END IF;

    IF p_mode IS NOT NULL THEN
        v_modes := ARRAY[p_mode];
    ELSE
        -- Every session of this round they actually have laps in. A driver
        -- with nothing logged gets nothing written, which is the honest
        -- answer: there is nothing of theirs to set aside.
        SELECT COALESCE(array_agg(DISTINCT l.mode), '{}')
          INTO v_modes
          FROM live_laps l
         WHERE l.event_id = p_event_id AND l.driver_id = p_driver_id;
    END IF;

    INSERT INTO live_lap_voids (event_id, driver_id, mode, reason, created_by)
    SELECT p_event_id, p_driver_id, m, NULLIF(btrim(p_reason), ''), auth.uid()
      FROM unnest(v_modes) AS m
    ON CONFLICT (event_id, driver_id, mode) DO UPDATE
        SET reason     = EXCLUDED.reason,
            created_at = now(),
            created_by = EXCLUDED.created_by;

    SELECT count(*)::int INTO v_laps
      FROM live_laps l
     WHERE l.event_id = p_event_id
       AND l.driver_id = p_driver_id
       AND l.mode = ANY (v_modes);

    RETURN jsonb_build_object('ok', true, 'driver', v_name,
                              'laps', v_laps, 'modes', to_jsonb(v_modes));
END $$;

GRANT EXECUTE ON FUNCTION public.live_lap_void(uuid, uuid, text, text)
    TO authenticated;


-- ---- and back again ----
DROP FUNCTION IF EXISTS public.live_lap_unvoid(uuid, uuid, text);

CREATE FUNCTION public.live_lap_unvoid(p_event_id  uuid,
                                       p_driver_id uuid,
                                       p_mode      text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_gone int;
    v_name text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM user_roles ur
                    WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
        RAISE EXCEPTION 'Admins only';
    END IF;

    DELETE FROM live_lap_voids v
     WHERE v.event_id = p_event_id
       AND v.driver_id = p_driver_id
       AND (p_mode IS NULL OR v.mode = p_mode);
    GET DIAGNOSTICS v_gone = ROW_COUNT;

    SELECT d.display_name INTO v_name FROM drivers d WHERE d.id = p_driver_id;
    RETURN jsonb_build_object('ok', true, 'driver', v_name,
                              'restored', v_gone > 0, 'sessions', v_gone);
END $$;

GRANT EXECUTE ON FUNCTION public.live_lap_unvoid(uuid, uuid, text)
    TO authenticated;


-- ---- the board, now saying when the voids changed ----
--
-- void_rev is a signature, not a count: a void set and then lifted leaves
-- the count where it started, so the newest created_at goes into it too.
-- Seconds are plenty, because the thing it guards against is a page
-- holding a stale line for minutes.
--
-- Null when there are none at all, which is the ordinary case and costs
-- the poll nothing.
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
    burn_per_lap  real,
    times_void    boolean,
    void_rev      bigint
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH active AS (SELECT * FROM live_active_event()),
    target AS (
        SELECT COALESCE(p_event_id, (SELECT a.event_id FROM active a)) AS id,
               COALESCE((SELECT a.is_test FROM active a), false)       AS is_test,
               COALESCE((SELECT a.mode    FROM active a), 'race')      AS mode
    ),
    rev AS (
        SELECT (count(*) * 1000000000
                + COALESCE(EXTRACT(EPOCH FROM max(v.created_at))::bigint, 0)) AS n
          FROM live_lap_voids v, target
         WHERE v.event_id = target.id AND v.mode = target.mode
    ),
    pos AS (
        SELECT lp.*, target.id AS t_id, target.is_test AS t_test,
               target.mode AS t_mode,
               EXISTS (SELECT 1 FROM live_lap_voids v
                        WHERE v.event_id  = lp.event_id
                          AND v.driver_id = lp.driver_id
                          AND v.mode      = target.mode) AS void
          FROM live_positions lp
          JOIN target ON target.id = lp.event_id
    )
    SELECT
        e.id, e.name, e.round, r.t_test, r.t_mode,
        d.id, d.display_name, en.car_number, d.career_number,
        t.name, t.id, m.brand_color,
        r.lobby_number, r.lap, r.lap_ms,
        CASE WHEN r.void THEN NULL ELSE r.last_lap_ms END,
        CASE WHEN r.void THEN NULL ELSE r.best_lap_ms END,
        r.x, r.y, r.z, r.speed_kph, r.on_track, r.fuel_pct, r.laps_in_race,
        r.client,
        (EXTRACT(EPOCH FROM (now() - r.updated_at)) * 1000)::int,
        r.progress_m, e.lap_length_m, r.burn_per_lap, r.void,
        (SELECT NULLIF(rev.n, 0) FROM rev)
    FROM   pos r
    JOIN   events  e     ON e.id = r.event_id
    JOIN   drivers d     ON d.id = r.driver_id
    LEFT   JOIN entries en ON en.event_id = r.event_id
            AND EXISTS (SELECT 1 FROM entry_drivers ed
                         WHERE ed.entry_id = en.id AND ed.driver_id = r.driver_id)
    LEFT   JOIN teams t  ON t.id = d.current_team_id
    LEFT   JOIN manufacturers m
            ON m.id = COALESCE(d.current_manufacturer_id, t.manufacturer_id)
    ORDER BY r.lobby_number,
             CASE WHEN r.t_mode =  'race' THEN r.lap         END DESC NULLS LAST,
             CASE WHEN r.t_mode =  'race' THEN r.progress_m  END DESC NULLS LAST,
             CASE WHEN r.t_mode =  'race' THEN r.lap_ms      END DESC NULLS LAST,
             CASE WHEN r.t_mode <> 'race' THEN
                 CASE WHEN r.void THEN NULL ELSE r.best_lap_ms END
             END ASC NULLS LAST,
             r.driver_id;
$$;

GRANT EXECUTE ON FUNCTION public.live_field(uuid) TO anon, authenticated;
