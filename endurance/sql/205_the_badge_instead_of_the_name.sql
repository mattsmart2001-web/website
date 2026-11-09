-- ============================================================
-- 205 The badge instead of the name
--
-- The board prints the car on every row, and in a one-make field that is
-- the longest thing on the line saying the least. "Lancer Evolution Final
-- Gr.3" is twenty-seven characters of driver column; the marque's badge is
-- sixteen pixels and says the same thing, because 202 established the fact
-- this rests on: each manufacturer in GTEC fields exactly one car, so the
-- badge and the car name carry identical information.
--
-- So the board can show the badge and keep the name for the tooltip, and
-- the driver's name gets the room back. The rest of the site has drawn
-- manufacturer logos at exactly this size since 09, with a fall back to
-- the brand colour when a manufacturer has no logo recorded, so nothing
-- here is new ground.
--
-- Two columns, appended at the end, on 202's and 203's reasoning: every
-- column already there keeps its position, so the page and the migration
-- can go out in either order and there is no window where the board is
-- broken. A board that has not had this run shows no badge and is
-- otherwise exactly as it was.
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
    car_name      text,
    -- The marque and its badge, appended on the same reasoning as 202's
    -- car_name and 203's manufacturer_name: every column already here
    -- keeps its position, so the board works whether or not this has run.
    manufacturer_name text,
    manufacturer_logo_url text
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
        COALESCE(m.car_name, m.name),
        -- Both off the same manufacturers row as the car and the colour, so
        -- the badge on a row and the colour of its rail cannot disagree.
        m.name, m.logo_url
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
