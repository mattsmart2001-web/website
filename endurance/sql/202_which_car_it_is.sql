-- ============================================================
-- 202 Which car it is
--
-- The board has always known what colour a car is and never what it is.
-- Each manufacturer in GTEC fields exactly one car and 74 recorded its
-- name against them, so the information has been sitting one column away
-- the whole time: live_field already joins manufacturers to pick the dot
-- colour, and this takes the car name off the same row.
--
-- Same source for both, which is the point. The car and the colour come
-- from one place -- the driver's own manufacturer if they have one, their
-- team's otherwise -- so they cannot drift apart, and the colours on the
-- map stop being a code nobody can read.
--
-- It is the car they are ENTERED in. GT7 reports what is actually loaded,
-- at offset 0xF4, and the desktop connector already reads it, but it has
-- never been sent to the server and neither phone reporter looks at it.
-- So this is the rule, not the evidence: it says what they should be in.
-- That is the right thing on a timing screen and the wrong thing to steward
-- from, and it is why 197's set-aside is a decision a person makes.
--
-- Both functions grow one column, appended at the end rather than slotted
-- in beside the related ones. That is deliberate: every column that was
-- already there keeps its position, so a page built against the old shape
-- carries on working untouched, and this can be run before or after the
-- pages that use it with no window where the two disagree.
--
-- live_lap_log and live_lap_summary are both read by the lap log page and
-- only by it, and that page already copies the car number from one onto
-- the other. So only the summary learns about cars; the page carries it
-- across to the table and the chart the same way.
-- ============================================================

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
    void_rev      bigint,
    -- The car this driver is entered in. Appended rather than slotted in
    -- beside brand_color, so the column order of everything that was
    -- already here is untouched and a page built against the old shape
    -- carries on working.
    car_name      text
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
        (SELECT NULLIF(rev.n, 0) FROM rev),
        -- Off the manufacturers row that already picks the car's colour on
        -- the map, so the name and the colour can never disagree. The
        -- manufacturer's own name when no car is recorded against it,
        -- which is what every other page on the site falls back to.
        COALESCE(m.car_name, m.name)
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
    spread_ms    int,
    car_name     text
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
               WHERE m.lap_ms <= m.own_best * 1.07), 0)::int,
           -- Same source as the live board: the driver's own manufacturer
           -- if they have one, otherwise their team's.
           COALESCE(mf.car_name, mf.name)
      FROM mine m
      JOIN drivers d ON d.id = m.driver_id
      LEFT JOIN teams t ON t.id = d.current_team_id
      LEFT JOIN manufacturers mf
             ON mf.id = COALESCE(d.current_manufacturer_id, t.manufacturer_id)
     GROUP BY m.driver_id, d.display_name, mf.car_name, mf.name
     ORDER BY min(m.lap_ms);
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_summary(uuid, text) TO anon, authenticated;
