-- ============================================================
-- 119 races / starts count only rounds actually started
--
-- driver_career_stats.starts and driver_standings.races counted every
-- event a driver had a result row in — including a DNS (entered, on the
-- grid, but never started). That handed a "start" to no-shows, which in
-- turn earned them the Debut badge (starts >= 1) and, via a Season 1
-- standings row, the Founding Member badge.
--
-- Fix: count a round only when the driver took the start — any result
-- whose status is not 'dns' or 'withdrawn' (i.e. classified / dnf / dsq),
-- matching how the Health Check now defines "raced". A DNS driver now has
-- starts = 0 / races = 0, so those badges no longer apply to them.
--
-- Only the two count expressions change; the view columns are otherwise
-- identical, so CREATE OR REPLACE keeps every dependent happy.
-- ============================================================

CREATE OR REPLACE VIEW driver_career_stats AS
SELECT
    d.id                                                            AS driver_id,
    d.display_name                                                  AS driver_name,
    d.slug                                                          AS driver_slug,
    d.nationality,
    d.career_number,
    d.photo_url,
    COUNT(DISTINCT res.event_id) FILTER (
        WHERE COALESCE(rd.status, 'classified') NOT IN ('dns', 'withdrawn'))              AS starts,
    COUNT(*) FILTER (WHERE rd.finish_position = 1
                       AND COALESCE(rd.status, 'classified') = 'classified')              AS wins,
    COUNT(*) FILTER (WHERE rd.finish_position BETWEEN 1 AND 3
                       AND COALESCE(rd.status, 'classified') = 'classified')              AS podiums,
    COUNT(*) FILTER (WHERE rd.pole_point
                       AND COALESCE(rd.status, 'classified') = 'classified')              AS poles,
    COUNT(*) FILTER (WHERE rd.fastest_lap_point
                       AND COALESCE(rd.status, 'classified') = 'classified')              AS fastest_laps,
    COUNT(*) FILTER (WHERE COALESCE(rd.status, 'classified') = 'classified')              AS finishes,
    COUNT(*) FILTER (WHERE rd.status = 'dnf')                                             AS dnfs,
    COALESCE(SUM(rd.points_awarded), 0)::numeric(10,2)                                    AS career_points
FROM   drivers d
LEFT JOIN result_drivers rd ON rd.driver_id = d.id
LEFT JOIN results res ON res.id = rd.result_id
GROUP BY d.id;

GRANT SELECT ON driver_career_stats TO anon, authenticated;


CREATE OR REPLACE VIEW driver_standings AS
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
    SELECT p.driver_id, ev.season_id, COALESCE(p.points_amount, 0)::int AS amount
    FROM   penalties p JOIN events ev ON ev.id = p.event_id
    WHERE  p.penalty_type = 'points_deduction'
      AND  p.driver_id IS NOT NULL AND p.points_amount IS NOT NULL
    UNION ALL
    SELECT ed.driver_id, ev.season_id, COALESCE(p.points_amount, 0)::int AS amount
    FROM   penalties p
    JOIN   events ev ON ev.id = p.event_id
    JOIN   entries en ON en.id = p.entry_id
    JOIN   entry_drivers ed ON ed.entry_id = en.id
    WHERE  p.penalty_type = 'points_deduction'
      AND  p.driver_id IS NULL AND p.points_amount IS NOT NULL
),
deductions_total AS (
    SELECT driver_id, season_id, SUM(amount)::int AS amount
    FROM   deductions GROUP BY driver_id, season_id
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
    COUNT(DISTINCT res.event_id) FILTER (
        WHERE COALESCE(rd.status, 'classified') NOT IN ('dns', 'withdrawn'))            AS races,
    COUNT(*) FILTER (WHERE rd.finish_position = 1
                       AND COALESCE(rd.status, 'classified') = 'classified')           AS wins,
    COUNT(*) FILTER (WHERE rd.finish_position BETWEEN 1 AND 3
                       AND COALESCE(rd.status, 'classified') = 'classified')           AS podiums,
    COUNT(*) FILTER (WHERE rd.pole_point
                       AND COALESCE(rd.status, 'classified') = 'classified')           AS poles,
    COUNT(*) FILTER (WHERE rd.fastest_lap_point
                       AND COALESCE(rd.status, 'classified') = 'classified')           AS fastest_laps
FROM   result_drivers rd
JOIN   results res ON res.id = rd.result_id
JOIN   events  ev  ON ev.id  = res.event_id
JOIN   seasons s   ON s.id   = ev.season_id
JOIN   drivers d   ON d.id   = rd.driver_id
LEFT   JOIN driver_season_team dst ON dst.driver_id = d.id AND dst.season_id = s.id
LEFT   JOIN teams         t ON t.id = dst.team_id
LEFT   JOIN manufacturers m ON m.id = dst.manufacturer_id
LEFT   JOIN deductions_total ded ON ded.driver_id = d.id AND ded.season_id = s.id
GROUP  BY d.id, s.id, s.year, dst.team_id, t.name, t.slug,
          dst.manufacturer_id, m.name, m.brand_color, m.logo_url;

GRANT SELECT ON driver_standings TO anon, authenticated;
