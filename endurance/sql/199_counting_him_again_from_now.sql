-- ============================================================
-- 199 Counting him again from now
--
-- 197 and 198 give a void two states: a driver's times are counted, or
-- they are not. That is the wrong shape for what actually happens. A
-- driver takes a Gr.1 round for five laps, gets told, swaps into the car
-- he is entered in and goes back out. His new laps are real and belong on
-- the board; his old ones are not and do not. With two states the only way
-- to get the new ones back is to lift the void, which brings the Gr.1 laps
-- back with them.
--
-- So a void gains a line: "through". Null means what it has always meant,
-- everything that driver does in this session, past and to come. A time in
-- it means everything up to that moment and nothing after, which is what
-- somebody pressing "count him from now on" is asking for.
--
--   A  nothing set aside
--   B  set aside            (through null)       -> B from A
--   C  counting from T      (through = T)        -> C from B, B from C
--
-- A is reached from either by counting everything again, which is the undo
-- for having picked the wrong driver rather than the route back for a
-- driver who has mended his ways.
--
-- The cut is "now" and not "when he changed car", because nothing in the
-- telemetry says when he changed car. A lap already written down was
-- driven before the admin pressed the button; a lap written down after it
-- was finished after. The lap in progress at that moment counts, which is
-- right: he was already in the proper car when it started.
--
-- One thing this forces. While a driver is in state C the board cannot use
-- GT7's own best lap for him, because GT7 is still reporting the Gr.1 time
-- and will keep reporting it until he leaves the lobby. His Best and Last
-- come off the lap log instead, counting only the laps on this side of the
-- cut. That is a narrower source than GT7's figure, since the log holds
-- only laps watched from one crossing to the next, and it is the only one
-- that can answer the question honestly.
--
-- The predicate now has two halves, and five readers apply it. Written
-- once as live_lap_kept and called from all five rather than copied, which
-- is the thing 197 said it was avoiding and was wrong to: a reader that
-- quietly keeps the old one-sided test is exactly the bug nobody finds.
-- Plain SQL with no SECURITY DEFINER and no SET, so the planner inlines it
-- into each caller instead of running it a row at a time.
-- ============================================================

ALTER TABLE live_lap_voids
    ADD COLUMN IF NOT EXISTS through timestamptz;

COMMENT ON COLUMN live_lap_voids.through IS
    'Null: every lap of this session, past and to come, is set aside. '
    'Set: laps recorded at or before this moment are set aside and later '
    'ones count, which is a driver who has gone back to the right car.';


-- Whether one lap of one driver survives the voids on it. The one place
-- the rule is written down.
CREATE OR REPLACE FUNCTION public.live_lap_kept(p_event_id    uuid,
                                                p_driver_id   uuid,
                                                p_mode        text,
                                                p_recorded_at timestamptz)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS (
        SELECT 1 FROM public.live_lap_voids v
         WHERE v.event_id  = p_event_id
           AND v.driver_id = p_driver_id
           AND v.mode      = p_mode
           AND (v.through IS NULL OR p_recorded_at <= v.through));
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_kept(uuid, uuid, text, timestamptz)
    TO anon, authenticated;


-- ---- set aside: everything, again ----
--
-- Unchanged but for one line: a driver who was being counted from a cut
-- and has gone back to whatever he was doing goes back to a plain void,
-- so through is cleared rather than left where it was.
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
        SELECT COALESCE(array_agg(DISTINCT l.mode), '{}')
          INTO v_modes
          FROM live_laps l
         WHERE l.event_id = p_event_id AND l.driver_id = p_driver_id;
    END IF;

    INSERT INTO live_lap_voids (event_id, driver_id, mode, reason, created_by, through)
    SELECT p_event_id, p_driver_id, m, NULLIF(btrim(p_reason), ''), auth.uid(), NULL
      FROM unnest(v_modes) AS m
    ON CONFLICT (event_id, driver_id, mode) DO UPDATE
        SET reason     = EXCLUDED.reason,
            created_at = now(),
            created_by = EXCLUDED.created_by,
            through    = NULL;

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


-- ---- count him again, from now ----
--
-- Only touches voids that already exist. A driver who is not set aside is
-- already being counted and there is nothing here to do for him, which is
-- said back rather than silently written.
CREATE OR REPLACE FUNCTION public.live_lap_resume(p_event_id  uuid,
                                                  p_driver_id uuid,
                                                  p_mode      text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_cut  timestamptz := now();
    v_rows int;
    v_name text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM user_roles ur
                    WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
        RAISE EXCEPTION 'Admins only';
    END IF;

    UPDATE live_lap_voids v
       SET through = v_cut
     WHERE v.event_id = p_event_id
       AND v.driver_id = p_driver_id
       AND (p_mode IS NULL OR v.mode = p_mode);
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    SELECT d.display_name INTO v_name FROM drivers d WHERE d.id = p_driver_id;
    RETURN jsonb_build_object('ok', true, 'driver', v_name,
                              'sessions', v_rows,
                              'from', CASE WHEN v_rows > 0 THEN v_cut END);
END $$;

GRANT EXECUTE ON FUNCTION public.live_lap_resume(uuid, uuid, text)
    TO authenticated;


-- ---- what is set aside, and from when ----
DROP FUNCTION IF EXISTS public.live_lap_void_list(uuid, text);

CREATE FUNCTION public.live_lap_void_list(p_event_id uuid,
                                          p_mode     text DEFAULT NULL)
RETURNS TABLE (
    driver_id    uuid,
    display_name text,
    mode         text,
    reason       text,
    -- How many of their laps this is keeping off the board, which is not
    -- all of their laps once a cut has been set.
    laps         int,
    -- And how many are being counted on the other side of that cut, so a
    -- page can say "5 set aside, 3 counted" rather than implying the
    -- driver is still in disgrace.
    kept         int,
    through      timestamptz,
    created_at   timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT v.driver_id, d.display_name, v.mode, v.reason,
           (SELECT count(*)::int FROM live_laps l
             WHERE l.event_id = v.event_id AND l.driver_id = v.driver_id
               AND l.mode = v.mode
               AND (v.through IS NULL OR l.recorded_at <= v.through)),
           (SELECT count(*)::int FROM live_laps l
             WHERE l.event_id = v.event_id AND l.driver_id = v.driver_id
               AND l.mode = v.mode
               AND v.through IS NOT NULL AND l.recorded_at > v.through),
           v.through, v.created_at
      FROM live_lap_voids v
      JOIN drivers d ON d.id = v.driver_id
     WHERE v.event_id = p_event_id
       AND (p_mode IS NULL OR v.mode = p_mode)
     ORDER BY d.display_name;
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_void_list(uuid, text)
    TO anon, authenticated;


-- ============================================================
-- The five readers, all now asking live_lap_kept
-- ============================================================

DROP FUNCTION IF EXISTS public.live_lap_feed(uuid, text, bigint);

CREATE FUNCTION public.live_lap_feed(p_event_id uuid,
                                     p_mode     text   DEFAULT NULL,
                                     p_after_id bigint DEFAULT NULL)
RETURNS TABLE (
    id           bigint,
    driver_id    uuid,
    display_name text,
    car_number   int,
    lobby_number int,
    lap          int,
    seq          int,
    lap_ms       int,
    fuel_pct     real,
    mode         text,
    recorded_at  timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT l.id, l.driver_id, d.display_name, en.car_number, l.lobby_number,
           l.lap, l.seq, l.lap_ms, l.fuel_pct, l.mode, l.recorded_at
      FROM live_laps l
      JOIN drivers d ON d.id = l.driver_id
      LEFT JOIN entries en ON en.event_id = l.event_id
            AND EXISTS (SELECT 1 FROM entry_drivers ed
                         WHERE ed.entry_id = en.id AND ed.driver_id = l.driver_id)
     WHERE l.event_id = p_event_id
       AND (p_mode     IS NULL OR l.mode = p_mode)
       AND (p_after_id IS NULL OR l.id > p_after_id)
       AND live_lap_kept(l.event_id, l.driver_id, l.mode, l.recorded_at)
     ORDER BY l.id;
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_feed(uuid, text, bigint) TO anon, authenticated;


DROP FUNCTION IF EXISTS public.live_lap_log(uuid, text);

CREATE FUNCTION public.live_lap_log(p_event_id uuid,
                                    p_mode text DEFAULT 'race')
RETURNS TABLE (
    driver_id    uuid,
    display_name text,
    car_number   int,
    lobby_number int,
    lap          int,
    seq          int,
    lap_ms       int,
    fuel_pct     real,
    mode         text,
    session_from timestamptz,
    recorded_at  timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT l.driver_id, d.display_name, en.car_number, l.lobby_number,
           l.lap, l.seq, l.lap_ms, l.fuel_pct, l.mode, l.session_from,
           l.recorded_at
      FROM live_laps l
      JOIN drivers d ON d.id = l.driver_id
      LEFT JOIN entries en ON en.event_id = l.event_id
            AND EXISTS (SELECT 1 FROM entry_drivers ed
                         WHERE ed.entry_id = en.id AND ed.driver_id = l.driver_id)
     WHERE l.event_id = p_event_id
       AND (p_mode IS NULL OR l.mode = p_mode)
       AND live_lap_kept(l.event_id, l.driver_id, l.mode, l.recorded_at)
     ORDER BY d.display_name, l.id;
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_log(uuid, text) TO anon, authenticated;


DROP FUNCTION IF EXISTS public.live_lap_summary(uuid, text);

CREATE FUNCTION public.live_lap_summary(p_event_id uuid,
                                        p_mode text DEFAULT 'race')
RETURNS TABLE (
    driver_id    uuid,
    display_name text,
    lobby_number int,
    laps         int,
    clean_laps   int,
    best_ms      int,
    median_ms    int,
    mean_ms      int,
    spread_ms    int
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH mine AS (
        SELECT l.*, min(l.lap_ms) OVER (PARTITION BY l.driver_id) AS own_best
          FROM live_laps l
         WHERE l.event_id = p_event_id
           AND (p_mode IS NULL OR l.mode = p_mode)
           AND live_lap_kept(l.event_id, l.driver_id, l.mode, l.recorded_at)
    )
    SELECT m.driver_id, d.display_name, max(m.lobby_number),
           count(*)::int,
           count(*) FILTER (WHERE m.lap_ms <= m.own_best * 1.07)::int,
           min(m.lap_ms)::int,
           percentile_cont(0.5) WITHIN GROUP (
               ORDER BY m.lap_ms) FILTER (WHERE m.lap_ms <= m.own_best * 1.07)::int,
           avg(m.lap_ms) FILTER (WHERE m.lap_ms <= m.own_best * 1.07)::int,
           COALESCE(stddev_pop(m.lap_ms) FILTER (
               WHERE m.lap_ms <= m.own_best * 1.07), 0)::int
      FROM mine m
      JOIN drivers d ON d.id = m.driver_id
     GROUP BY m.driver_id, d.display_name
     ORDER BY min(m.lap_ms);
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_summary(uuid, text) TO anon, authenticated;


CREATE OR REPLACE FUNCTION public.my_lap_rounds()
RETURNS TABLE (
    event_id     uuid,
    round        int,
    name         text,
    circuit_name text,
    starts_at    timestamptz,
    laps         int,
    clean_laps   int,
    best_ms      int,
    median_ms    int,
    spread_ms    int,
    best_rank    int,
    split_cars   int
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH me AS (
        SELECT d.id FROM drivers d WHERE d.user_id = auth.uid()
    ),
    kept AS (
        SELECT l.* FROM live_laps l
         WHERE l.mode = 'race'
           AND live_lap_kept(l.event_id, l.driver_id, l.mode, l.recorded_at)
    ),
    mine AS (
        SELECT k.*, min(k.lap_ms) OVER (PARTITION BY k.event_id) AS own_best
          FROM kept k
         WHERE k.driver_id = (SELECT id FROM me)
    ),
    agg AS (
        SELECT m.event_id,
               count(*)::int                                       AS laps,
               count(*) FILTER (WHERE m.lap_ms <= m.own_best * 1.07)::int AS clean_laps,
               min(m.lap_ms)::int                                   AS best_ms,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY m.lap_ms)
                   FILTER (WHERE m.lap_ms <= m.own_best * 1.07)::int AS median_ms,
               COALESCE(stddev_pop(m.lap_ms) FILTER (
                   WHERE m.lap_ms <= m.own_best * 1.07), 0)::int     AS spread_ms,
               max(m.lobby_number)                                  AS lobby_number
          FROM mine m
         GROUP BY m.event_id
    ),
    field AS (
        SELECT k.event_id, k.lobby_number, k.driver_id, min(k.lap_ms) AS best_ms
          FROM kept k
         GROUP BY k.event_id, k.lobby_number, k.driver_id
    )
    SELECT a.event_id, e.round, e.name, e.circuit_name, e.starts_at,
           a.laps, a.clean_laps, a.best_ms, a.median_ms, a.spread_ms,
           (SELECT count(*)::int + 1 FROM field f
             WHERE f.event_id = a.event_id
               AND f.lobby_number IS NOT DISTINCT FROM a.lobby_number
               AND f.best_ms < a.best_ms),
           (SELECT count(*)::int FROM field f
             WHERE f.event_id = a.event_id
               AND f.lobby_number IS NOT DISTINCT FROM a.lobby_number)
      FROM agg a
      JOIN events e ON e.id = a.event_id
     ORDER BY e.starts_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.my_lap_rounds() TO authenticated;


-- ---- the board ----
--
-- times_void is the full void only. times_from carries the cut, and the
-- two are mutually exclusive by construction: a row has a through or it
-- does not.
--
-- Where there is a cut, Best and Last come off the lap log rather than
-- live_positions, because GT7 is still holding the Gr.1 best and will
-- until he leaves the lobby. Two subqueries, inside a CASE so they are not
-- run for the ninety nine drivers who are not in this state at all.
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
    times_from    timestamptz,
    void_rev      bigint
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH active AS (SELECT * FROM live_active_event()),
    target AS (
        SELECT COALESCE(p_event_id, (SELECT a.event_id FROM active a)) AS id,
               COALESCE((SELECT a.is_test FROM active a), false)       AS is_test,
               COALESCE((SELECT a.mode    FROM active a), 'race')      AS mode
    ),
    -- A signature of the voids, so a page already open knows to read the
    -- feed again. The newest change counts, which is a created_at or a
    -- through, whichever is later; GREATEST skips the nulls.
    rev AS (
        SELECT (count(*) * 1000000000
                + COALESCE(EXTRACT(EPOCH FROM GREATEST(max(v.created_at),
                                                       max(v.through)))::bigint, 0)) AS n
          FROM live_lap_voids v, target
         WHERE v.event_id = target.id AND v.mode = target.mode
    ),
    pos AS (
        SELECT lp.*, target.id AS t_id, target.is_test AS t_test,
               target.mode AS t_mode,
               EXISTS (SELECT 1 FROM live_lap_voids v
                        WHERE v.event_id  = lp.event_id
                          AND v.driver_id = lp.driver_id
                          AND v.mode      = target.mode
                          AND v.through IS NULL)                      AS void,
               (SELECT v.through FROM live_lap_voids v
                 WHERE v.event_id  = lp.event_id
                   AND v.driver_id = lp.driver_id
                   AND v.mode      = target.mode
                   AND v.through IS NOT NULL)                         AS cut
          FROM live_positions lp
          JOIN target ON target.id = lp.event_id
    )
    SELECT
        e.id, e.name, e.round, r.t_test, r.t_mode,
        d.id, d.display_name, en.car_number, d.career_number,
        t.name, t.id, m.brand_color,
        r.lobby_number, r.lap, r.lap_ms,
        CASE WHEN r.void THEN NULL
             WHEN r.cut IS NOT NULL THEN
                 (SELECT l.lap_ms FROM live_laps l
                   WHERE l.event_id = r.event_id AND l.driver_id = r.driver_id
                     AND l.mode = r.t_mode AND l.recorded_at > r.cut
                   ORDER BY l.id DESC LIMIT 1)
             ELSE r.last_lap_ms END,
        CASE WHEN r.void THEN NULL
             WHEN r.cut IS NOT NULL THEN
                 (SELECT min(l.lap_ms)::int FROM live_laps l
                   WHERE l.event_id = r.event_id AND l.driver_id = r.driver_id
                     AND l.mode = r.t_mode AND l.recorded_at > r.cut)
             ELSE r.best_lap_ms END,
        r.x, r.y, r.z, r.speed_kph, r.on_track, r.fuel_pct, r.laps_in_race,
        r.client,
        (EXTRACT(EPOCH FROM (now() - r.updated_at)) * 1000)::int,
        r.progress_m, e.lap_length_m, r.burn_per_lap, r.void, r.cut,
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
    -- Practice order is by best lap, and a driver being counted from a cut
    -- sorts on the best of the laps that are being counted, which is the
    -- figure the column is showing him.
    ORDER BY r.lobby_number,
             CASE WHEN r.t_mode =  'race' THEN r.lap         END DESC NULLS LAST,
             CASE WHEN r.t_mode =  'race' THEN r.progress_m  END DESC NULLS LAST,
             CASE WHEN r.t_mode =  'race' THEN r.lap_ms      END DESC NULLS LAST,
             CASE WHEN r.t_mode <> 'race' THEN
                 CASE WHEN r.void THEN NULL
                      WHEN r.cut IS NOT NULL THEN
                          (SELECT min(l.lap_ms)::int FROM live_laps l
                            WHERE l.event_id = r.event_id AND l.driver_id = r.driver_id
                              AND l.mode = r.t_mode AND l.recorded_at > r.cut)
                      ELSE r.best_lap_ms END
             END ASC NULLS LAST,
             r.driver_id;
$$;

GRANT EXECUTE ON FUNCTION public.live_field(uuid) TO anon, authenticated;
