-- ============================================================
-- 09 Manufacturer logos
-- Storage bucket for manufacturer badge images, and views updated
-- to expose manufacturer_logo_url alongside brand_color.
-- ============================================================

-- Storage bucket for manufacturer logos
INSERT INTO storage.buckets (id, name, public)
VALUES ('gtec-manufacturers', 'gtec-manufacturers', true)
ON CONFLICT DO NOTHING;

CREATE POLICY "public read gtec-manufacturers" ON storage.objects
    FOR SELECT TO public USING (bucket_id = 'gtec-manufacturers');

CREATE POLICY "auth upload gtec-manufacturers" ON storage.objects
    FOR INSERT TO authenticated WITH CHECK (bucket_id = 'gtec-manufacturers');

CREATE POLICY "auth update gtec-manufacturers" ON storage.objects
    FOR UPDATE TO authenticated USING (bucket_id = 'gtec-manufacturers');

CREATE POLICY "auth delete gtec-manufacturers" ON storage.objects
    FOR DELETE TO authenticated USING (bucket_id = 'gtec-manufacturers');


-- ============================================================
-- Re-create standings views to include manufacturer_logo_url
-- ============================================================
DROP VIEW IF EXISTS driver_standings;
CREATE VIEW driver_standings AS
WITH driver_season_team AS (
    SELECT DISTINCT ON (rd.driver_id, s.id)
        rd.driver_id,
        s.id  AS season_id,
        en.team_id,
        ts.manufacturer_id
    FROM   result_drivers rd
    JOIN   results res    ON res.id = rd.result_id
    JOIN   entries en     ON en.id  = res.entry_id
    JOIN   events  ev     ON ev.id  = res.event_id
    JOIN   seasons s      ON s.id   = ev.season_id
    LEFT JOIN team_seasons ts ON ts.team_id = en.team_id AND ts.season_id = s.id
    ORDER BY rd.driver_id, s.id, ev.starts_at DESC
)
SELECT
    d.id                                                AS driver_id,
    d.display_name                                      AS driver_name,
    d.slug                                              AS driver_slug,
    d.nationality                                       AS nationality,
    d.career_number                                     AS career_number,
    s.id                                                AS season_id,
    s.year                                              AS season_year,
    dst.team_id                                         AS team_id,
    t.name                                              AS team_name,
    t.slug                                              AS team_slug,
    dst.manufacturer_id                                 AS manufacturer_id,
    m.name                                              AS manufacturer_name,
    m.brand_color                                       AS brand_color,
    m.logo_url                                          AS manufacturer_logo_url,
    COALESCE(SUM(res.points_awarded * rd.points_share), 0)::numeric(10,2) AS points,
    COUNT(DISTINCT res.event_id)                        AS races,
    COUNT(*) FILTER (WHERE res.finish_position = 1)     AS wins,
    COUNT(*) FILTER (WHERE res.finish_position BETWEEN 1 AND 3) AS podiums,
    COUNT(*) FILTER (WHERE res.pole_point)              AS poles,
    COUNT(*) FILTER (WHERE res.fastest_lap_point)       AS fastest_laps
FROM   result_drivers rd
JOIN   results res ON res.id = rd.result_id
JOIN   events  ev  ON ev.id  = res.event_id
JOIN   seasons s   ON s.id   = ev.season_id
JOIN   drivers d   ON d.id   = rd.driver_id
LEFT JOIN driver_season_team dst ON dst.driver_id = d.id AND dst.season_id = s.id
LEFT JOIN teams         t ON t.id = dst.team_id
LEFT JOIN manufacturers m ON m.id = dst.manufacturer_id
GROUP BY d.id, s.id, s.year, dst.team_id, t.name, t.slug,
         dst.manufacturer_id, m.name, m.brand_color, m.logo_url;


DROP VIEW IF EXISTS team_standings;
CREATE VIEW team_standings AS
SELECT
    t.id                                                AS team_id,
    t.name                                              AS team_name,
    t.slug                                              AS team_slug,
    s.id                                                AS season_id,
    s.year                                              AS season_year,
    ts.manufacturer_id                                  AS manufacturer_id,
    m.name                                              AS manufacturer_name,
    m.brand_color                                       AS brand_color,
    m.logo_url                                          AS manufacturer_logo_url,
    COALESCE(SUM(res.points_awarded), 0)::int           AS points,
    COUNT(DISTINCT res.event_id)                        AS races,
    COUNT(*) FILTER (WHERE res.finish_position = 1)     AS wins,
    COUNT(*) FILTER (WHERE res.finish_position BETWEEN 1 AND 3) AS podiums,
    COUNT(*) FILTER (WHERE res.pole_point)              AS poles,
    COUNT(*) FILTER (WHERE res.fastest_lap_point)       AS fastest_laps
FROM   results res
JOIN   entries en       ON en.id = res.entry_id
JOIN   events  ev       ON ev.id = res.event_id
JOIN   seasons s        ON s.id  = ev.season_id
JOIN   teams   t        ON t.id  = en.team_id
LEFT JOIN team_seasons ts ON ts.team_id = t.id AND ts.season_id = s.id
LEFT JOIN manufacturers m ON m.id = ts.manufacturer_id
GROUP BY t.id, s.id, s.year, ts.manufacturer_id, m.name, m.brand_color, m.logo_url;

GRANT SELECT ON driver_standings TO anon, authenticated;
GRANT SELECT ON team_standings   TO anon, authenticated;


-- Refresh driver_current_ratings to expose manufacturer_logo_url too
DROP VIEW IF EXISTS driver_current_ratings;
CREATE VIEW driver_current_ratings AS
WITH latest AS (
    SELECT DISTINCT ON (driver_id)
        driver_id,
        rating_after  AS rating,
        delta         AS last_delta,
        event_id      AS last_event_id,
        created_at    AS last_rated_at
    FROM driver_ratings
    ORDER BY driver_id, created_at DESC
),
peak AS (
    SELECT driver_id, MAX(rating_after) AS peak_rating
    FROM   driver_ratings
    GROUP  BY driver_id
)
SELECT
    d.id            AS driver_id,
    d.display_name  AS driver_name,
    d.slug          AS driver_slug,
    d.nationality,
    d.career_number,
    d.photo_url,
    t.id            AS team_id,
    t.name          AS team_name,
    t.slug          AS team_slug,
    m.name          AS manufacturer_name,
    m.brand_color,
    m.logo_url      AS manufacturer_logo_url,
    COALESCE(l.rating,       1500) AS rating,
    COALESCE(p.peak_rating,  1500) AS peak_rating,
    l.last_delta,
    l.last_rated_at
FROM   drivers       d
LEFT JOIN latest     l ON l.driver_id = d.id
LEFT JOIN peak       p ON p.driver_id = d.id
LEFT JOIN teams      t ON t.id = d.current_team_id
LEFT JOIN manufacturers m ON m.id = d.current_manufacturer_id;

GRANT SELECT ON driver_current_ratings TO anon, authenticated;
