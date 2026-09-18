-- ============================================================
-- 30 Points deduction → standings
-- Adds a penalties.points_amount column so admins can record the
-- exact deduction (in points) for a points_deduction penalty, and
-- updates driver_standings + team_standings to subtract those
-- deductions per season.
-- ============================================================

ALTER TABLE penalties
    ADD COLUMN IF NOT EXISTS points_amount int
        CHECK (points_amount IS NULL OR points_amount > 0);


-- ============================================================
-- driver_standings: subtract per-driver points_deduction sums
-- ============================================================
DROP VIEW IF EXISTS driver_standings CASCADE;
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
    LEFT   JOIN team_seasons ts ON ts.team_id = en.team_id AND ts.season_id = s.id
    ORDER  BY rd.driver_id, s.id, ev.starts_at DESC
),
deductions AS (
    SELECT
        p.driver_id,
        ev.season_id,
        SUM(COALESCE(p.points_amount, 0))::int AS amount
    FROM   penalties p
    JOIN   events    ev ON ev.id = p.event_id
    WHERE  p.penalty_type = 'points_deduction'
      AND  p.driver_id    IS NOT NULL
      AND  p.points_amount IS NOT NULL
    GROUP  BY p.driver_id, ev.season_id
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
    (COALESCE(SUM(rd.points_awarded), 0) - COALESCE(MAX(ded.amount), 0))::numeric(10,2) AS points,
    COALESCE(MAX(ded.amount), 0)                        AS points_deducted,
    COUNT(DISTINCT res.event_id)                        AS races,
    COUNT(*) FILTER (WHERE rd.finish_position = 1)      AS wins,
    COUNT(*) FILTER (WHERE rd.finish_position BETWEEN 1 AND 3) AS podiums,
    COUNT(*) FILTER (WHERE rd.pole_point)               AS poles,
    COUNT(*) FILTER (WHERE rd.fastest_lap_point)        AS fastest_laps
FROM   result_drivers rd
JOIN   results res ON res.id = rd.result_id
JOIN   events  ev  ON ev.id  = res.event_id
JOIN   seasons s   ON s.id   = ev.season_id
JOIN   drivers d   ON d.id   = rd.driver_id
LEFT   JOIN driver_season_team dst ON dst.driver_id = d.id AND dst.season_id = s.id
LEFT   JOIN teams         t ON t.id = dst.team_id
LEFT   JOIN manufacturers m ON m.id = dst.manufacturer_id
LEFT   JOIN deductions ded ON ded.driver_id = d.id AND ded.season_id = s.id
GROUP  BY d.id, s.id, s.year, dst.team_id, t.name, t.slug,
          dst.manufacturer_id, m.name, m.brand_color, m.logo_url;

GRANT SELECT ON driver_standings TO anon, authenticated;


-- ============================================================
-- team_standings: subtract per-team points_deduction sums.
-- A penalty applies to the team whose entry it was recorded against
-- (penalties.entry_id → entries.team_id), in that entry's season.
-- ============================================================
DROP VIEW IF EXISTS team_standings;
CREATE VIEW team_standings AS
WITH team_deductions AS (
    SELECT
        en.team_id,
        ev.season_id,
        SUM(COALESCE(p.points_amount, 0))::int AS amount
    FROM   penalties p
    JOIN   entries   en ON en.id = p.entry_id
    JOIN   events    ev ON ev.id = p.event_id
    WHERE  p.penalty_type = 'points_deduction'
      AND  p.points_amount IS NOT NULL
      AND  en.team_id IS NOT NULL
    GROUP  BY en.team_id, ev.season_id
)
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
    (COALESCE(SUM(res.points_awarded), 0) - COALESCE(MAX(ded.amount), 0))::int AS points,
    COALESCE(MAX(ded.amount), 0)                        AS points_deducted,
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
LEFT   JOIN team_seasons ts ON ts.team_id = t.id AND ts.season_id = s.id
LEFT   JOIN manufacturers m ON m.id = ts.manufacturer_id
LEFT   JOIN team_deductions ded ON ded.team_id = t.id AND ded.season_id = s.id
GROUP  BY t.id, s.id, s.year, ts.manufacturer_id, m.name, m.brand_color, m.logo_url;

GRANT SELECT ON team_standings TO anon, authenticated;
