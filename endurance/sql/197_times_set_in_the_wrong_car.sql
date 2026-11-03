-- ============================================================
-- 197 Times set in the wrong car
--
-- Live timing reads GT7 and believes it. That is the right default and it
-- is the whole reason the board can be trusted: nothing on it is typed in
-- by anybody. But GT7 tells us how quick a lap was and never tells us what
-- the lap was driven in, so a driver who takes a Gr.1 car round a practice
-- session sets a time that is perfectly real and completely meaningless
-- next to the rest of the field. It lands on the chart as a line a minute
-- below everybody else's and drags the y axis down with it, which makes
-- the board worse for the two hundred people who were doing it properly.
--
-- There is no test that catches this from the telemetry. "Suspiciously
-- quick" is not a test: a quick driver on a good lap and a Gr.1 on a bad
-- one are the same number, and a board that quietly deletes the fastest
-- lap of the evening because it was fast is worse than one that shows a
-- Gr.1. 189 already refuses times that are physically impossible for the
-- circuit, which is as far as arithmetic can honestly go. Past that it
-- needs a person who knows what happened, which is an admin.
--
-- So: an admin can set a driver's times aside for a session. One row per
-- (event, driver, mode), and while it exists that driver's laps in that
-- session are not in the chart, not in the log, not in the pace table and
-- not in their Best or Last on the board. Standing rather than a sweep of
-- the rows that exist now, because the driver is usually still out there
-- in the Gr.1 while the admin is doing it, and a sweep would have to be
-- repeated every few minutes until they got bored.
--
-- What it deliberately does NOT do:
--
--   Hide the car. They are on track, they are a car other drivers will
--   meet at the Karussell, and the map is a safety tool as much as a
--   timing one. The car stays, the lap counter stays, the times go, and
--   the board says so rather than leaving a blank nobody can explain.
--
--   Delete anything. The laps stay in live_laps exactly as recorded.
--   Lifting the void puts them straight back, which matters because the
--   usual reason to lift it is that the admin got the wrong driver.
--
--   Touch a race. Nothing stops it being used in one, but a race result
--   is decided by stewards off GT7's own replays, not by this. This is
--   for keeping the live board honest while it is on air.
--
-- The page needs to know, which is why live_field grows a times_void
-- column. Without it a viewer sees a car lapping with no Best and assumes
-- the reporter is broken.
-- ============================================================

-- ---- the standing void ----
--
-- Keyed on the session as well as the round, so setting aside a Gr.1
-- practice run does not reach into the race three weeks later. mode is
-- 'practice', 'race' or 'test', the same three values live_laps.mode and
-- live_active_event() already use.
CREATE TABLE IF NOT EXISTS live_lap_voids (
    event_id   uuid NOT NULL REFERENCES events(id)  ON DELETE CASCADE,
    driver_id  uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    mode       text NOT NULL,
    -- Shown to the admin who lifts it, possibly weeks later, possibly a
    -- different admin. "Gr.1" is enough; the point is that it is not blank.
    reason     text,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid,
    PRIMARY KEY (event_id, driver_id, mode)
);

ALTER TABLE live_lap_voids ENABLE ROW LEVEL SECURITY;

-- Read is public, exactly like live_laps: the board says out loud that a
-- car's times are set aside, so there is nothing here to keep from anyone.
-- Writes are closed to everybody and go through the two RPCs below.
DROP POLICY IF EXISTS "public read lap voids" ON live_lap_voids;
CREATE POLICY "public read lap voids" ON live_lap_voids
    FOR SELECT TO anon, authenticated USING (true);


-- Whether this driver's times in this session are set aside. One place, so
-- the four readers below cannot drift apart.
CREATE OR REPLACE FUNCTION public.live_lap_voided(p_event_id uuid,
                                                  p_driver_id uuid,
                                                  p_mode text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (SELECT 1 FROM live_lap_voids v
                    WHERE v.event_id  = p_event_id
                      AND v.driver_id = p_driver_id
                      AND v.mode      = p_mode);
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_voided(uuid, uuid, text)
    TO anon, authenticated;


-- ---- setting a driver's times aside ----
--
-- Admin only, and says how many laps it covered so the admin can tell at
-- once whether they picked the right driver. Idempotent: calling it twice
-- updates the reason rather than failing.
CREATE OR REPLACE FUNCTION public.live_lap_void(p_event_id  uuid,
                                                p_driver_id uuid,
                                                p_mode      text,
                                                p_reason    text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_laps int;
    v_name text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM user_roles ur
                    WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
        RAISE EXCEPTION 'Admins only';
    END IF;
    IF p_mode IS NULL OR p_mode NOT IN ('practice', 'race', 'test') THEN
        RAISE EXCEPTION 'Unknown session mode: %', p_mode;
    END IF;

    SELECT d.display_name INTO v_name FROM drivers d WHERE d.id = p_driver_id;
    IF v_name IS NULL THEN
        RAISE EXCEPTION 'No such driver';
    END IF;

    INSERT INTO live_lap_voids (event_id, driver_id, mode, reason, created_by)
    VALUES (p_event_id, p_driver_id, p_mode, NULLIF(btrim(p_reason), ''), auth.uid())
    ON CONFLICT (event_id, driver_id, mode) DO UPDATE
        SET reason     = EXCLUDED.reason,
            created_at = now(),
            created_by = EXCLUDED.created_by;

    SELECT count(*)::int INTO v_laps
      FROM live_laps l
     WHERE l.event_id = p_event_id
       AND l.driver_id = p_driver_id
       AND l.mode = p_mode;

    RETURN jsonb_build_object('ok', true, 'driver', v_name, 'laps', v_laps);
END $$;

GRANT EXECUTE ON FUNCTION public.live_lap_void(uuid, uuid, text, text)
    TO authenticated;


-- ---- putting them back ----
CREATE OR REPLACE FUNCTION public.live_lap_unvoid(p_event_id  uuid,
                                                  p_driver_id uuid,
                                                  p_mode      text)
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
       AND v.mode = p_mode;
    GET DIAGNOSTICS v_gone = ROW_COUNT;

    SELECT d.display_name INTO v_name FROM drivers d WHERE d.id = p_driver_id;
    RETURN jsonb_build_object('ok', true, 'driver', v_name,
                              'restored', v_gone > 0);
END $$;

GRANT EXECUTE ON FUNCTION public.live_lap_unvoid(uuid, uuid, text)
    TO authenticated;


-- ---- what is currently set aside ----
--
-- Public, because the live page needs it to offer the admin a way back and
-- because there is nothing secret in it. Carries the lap count so the list
-- reads as "Wezzle, 11 laps, Gr.1" rather than a bare name.
CREATE OR REPLACE FUNCTION public.live_lap_void_list(p_event_id uuid,
                                                     p_mode     text DEFAULT NULL)
RETURNS TABLE (
    driver_id    uuid,
    display_name text,
    mode         text,
    reason       text,
    laps         int,
    created_at   timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT v.driver_id, d.display_name, v.mode, v.reason,
           (SELECT count(*)::int FROM live_laps l
             WHERE l.event_id = v.event_id
               AND l.driver_id = v.driver_id
               AND l.mode = v.mode),
           v.created_at
      FROM live_lap_voids v
      JOIN drivers d ON d.id = v.driver_id
     WHERE v.event_id = p_event_id
       AND (p_mode IS NULL OR v.mode = p_mode)
     ORDER BY d.display_name;
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_void_list(uuid, text)
    TO anon, authenticated;


-- ============================================================
-- The four readers
--
-- Every one of them gains the same clause. Written out rather than wrapped
-- in a view because these are the functions the pages call by name, and a
-- reader that quietly forgot the clause would put a Gr.1 back on one
-- screen and not another, which is worse than not having the feature.
-- ============================================================

-- ---- the chart on the live page ----
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
       AND NOT EXISTS (SELECT 1 FROM live_lap_voids v
                        WHERE v.event_id  = l.event_id
                          AND v.driver_id = l.driver_id
                          AND v.mode      = l.mode)
     ORDER BY l.id;
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_feed(uuid, text, bigint) TO anon, authenticated;


-- ---- the lap log page ----
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
       AND NOT EXISTS (SELECT 1 FROM live_lap_voids v
                        WHERE v.event_id  = l.event_id
                          AND v.driver_id = l.driver_id
                          AND v.mode      = l.mode)
     ORDER BY d.display_name, l.id;
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_log(uuid, text) TO anon, authenticated;


-- ---- the pace table ----
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
           AND NOT EXISTS (SELECT 1 FROM live_lap_voids v
                            WHERE v.event_id  = l.event_id
                              AND v.driver_id = l.driver_id
                              AND v.mode      = l.mode)
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


-- ---- the board ----
--
-- Best and Last are blanked, and times_void says why, so a car lapping
-- with two dashes beside it reads as a decision somebody made rather than
-- a reporter that has half broken.
--
-- Note which figures are NOT touched. The lap counter is GT7's count of
-- laps that car has driven, and it drove them. The fuel is what is in the
-- tank. The position is where the car is. All three remain true whatever
-- it is being driven in; only the times are the claim being set aside.
--
-- Practice order is by best lap, so a voided car sorts to the bottom with
-- everybody else who has no time yet. That is the right place for it.
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
    times_void    boolean
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH active AS (SELECT * FROM live_active_event()),
    target AS (
        SELECT COALESCE(p_event_id, (SELECT a.event_id FROM active a)) AS id,
               COALESCE((SELECT a.is_test FROM active a), false)       AS is_test,
               COALESCE((SELECT a.mode    FROM active a), 'race')      AS mode
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
        r.progress_m, e.lap_length_m, r.burn_per_lap, r.void
    FROM   pos r
    JOIN   events  e     ON e.id = r.event_id
    JOIN   drivers d     ON d.id = r.driver_id
    LEFT   JOIN entries en ON en.event_id = r.event_id
            AND EXISTS (SELECT 1 FROM entry_drivers ed
                         WHERE ed.entry_id = en.id AND ed.driver_id = r.driver_id)
    LEFT   JOIN teams t  ON t.id = d.current_team_id
    LEFT   JOIN manufacturers m
            ON m.id = COALESCE(d.current_manufacturer_id, t.manufacturer_id)
    -- Unchanged from 178 except that a voided car's best is already null by
    -- the time the sort sees it, so it falls to the bottom of a practice
    -- board rather than staying on top with a time nobody is counting.
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


-- ---- a driver's own history ----
--
-- Race only, so a practice void never reaches it, but applied anyway: a
-- void that stopped working the moment it was looked at from a different
-- page would be a trap.
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
           AND NOT EXISTS (SELECT 1 FROM live_lap_voids v
                            WHERE v.event_id  = l.event_id
                              AND v.driver_id = l.driver_id
                              AND v.mode      = l.mode)
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
