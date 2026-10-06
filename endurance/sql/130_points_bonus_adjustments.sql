-- ============================================================
-- 130 Discretionary points bonuses (additive adjustments)
--
-- The penalties tool could only DEDUCT points (points_deduction).
-- This adds a matching 'points_bonus' type so admins can AWARD points
-- with a reason (e.g. "original pole"), and folds it into the driver
-- and team standings alongside deductions.
--
-- Bonuses mirror the deduction cascade exactly, so team == sum of its
-- drivers still holds:
--   * driver-specific bonus (driver_id set) → that driver only
--   * whole-team bonus (driver_id NULL)      → once per driver on the
--                                              entry (entry_drivers)
--
-- The new enum label is compared via ::text so this whole migration is
-- safe to run in a single transaction (no "unsafe use of new value").
-- ============================================================

ALTER TYPE penalty_type ADD VALUE IF NOT EXISTS 'points_bonus';


-- ============================================================
-- driver_standings: net deductions AND bonuses per driver
--   (rebuilt from 119, only the adjustment CTEs + points math change,
--    plus a new points_bonus column)
-- ============================================================
CREATE OR REPLACE VIEW driver_standings AS
WITH driver_season_team AS (
    SELECT DISTINCT ON (rd.driver_id, s.id)
        rd.driver_id, s.id AS season_id, en.team_id, ts.manufacturer_id
    FROM   result_drivers rd
    JOIN   results res ON res.id = rd.result_id
    JOIN   entries en  ON en.id  = res.entry_id
    JOIN   events  ev  ON ev.id  = res.event_id
    JOIN   seasons s   ON s.id   = ev.season_id
    LEFT   JOIN team_seasons ts ON ts.team_id = en.team_id AND ts.season_id = s.id
    ORDER  BY rd.driver_id, s.id, ev.starts_at DESC
),
-- Every points adjustment (deduction or bonus), signed, resolved to the
-- driver(s) it affects — a whole-entry adjustment cascades per driver.
adjustments AS (
    SELECT p.driver_id, ev.season_id,
           CASE WHEN p.penalty_type::text = 'points_bonus'
                THEN  COALESCE(p.points_amount, 0)
                ELSE -COALESCE(p.points_amount, 0) END AS delta
    FROM   penalties p JOIN events ev ON ev.id = p.event_id
    WHERE  p.penalty_type::text IN ('points_deduction', 'points_bonus')
      AND  p.driver_id IS NOT NULL AND p.points_amount IS NOT NULL
    UNION ALL
    SELECT ed.driver_id, ev.season_id,
           CASE WHEN p.penalty_type::text = 'points_bonus'
                THEN  COALESCE(p.points_amount, 0)
                ELSE -COALESCE(p.points_amount, 0) END AS delta
    FROM   penalties p
    JOIN   events ev ON ev.id = p.event_id
    JOIN   entries en ON en.id = p.entry_id
    JOIN   entry_drivers ed ON ed.entry_id = en.id
    WHERE  p.penalty_type::text IN ('points_deduction', 'points_bonus')
      AND  p.driver_id IS NULL AND p.points_amount IS NOT NULL
),
adj_total AS (
    SELECT driver_id, season_id,
           SUM(delta)::int                                       AS net,
           SUM(CASE WHEN delta < 0 THEN -delta ELSE 0 END)::int  AS deducted,
           SUM(CASE WHEN delta > 0 THEN  delta ELSE 0 END)::int  AS bonus
    FROM   adjustments GROUP BY driver_id, season_id
)
SELECT
    d.id AS driver_id, d.display_name AS driver_name, d.slug AS driver_slug,
    d.nationality, d.career_number,
    s.id AS season_id, s.year AS season_year,
    dst.team_id, t.name AS team_name, t.slug AS team_slug,
    dst.manufacturer_id, m.name AS manufacturer_name, m.brand_color, m.logo_url AS manufacturer_logo_url,
    (COALESCE(SUM(rd.points_awarded), 0) + COALESCE(MAX(adj.net), 0))::numeric(10,2) AS points,
    COALESCE(MAX(adj.deducted), 0)                      AS points_deducted,
    COUNT(DISTINCT res.event_id) FILTER (
        WHERE COALESCE(rd.status, 'classified') NOT IN ('dns', 'withdrawn'))            AS races,
    COUNT(*) FILTER (WHERE rd.finish_position = 1
                       AND COALESCE(rd.status, 'classified') = 'classified')           AS wins,
    COUNT(*) FILTER (WHERE rd.finish_position BETWEEN 1 AND 3
                       AND COALESCE(rd.status, 'classified') = 'classified')           AS podiums,
    COUNT(*) FILTER (WHERE rd.pole_point
                       AND COALESCE(rd.status, 'classified') = 'classified')           AS poles,
    COUNT(*) FILTER (WHERE rd.fastest_lap_point
                       AND COALESCE(rd.status, 'classified') = 'classified')           AS fastest_laps,
    -- Appended at the end so CREATE OR REPLACE VIEW accepts the new column.
    COALESCE(MAX(adj.bonus), 0)                         AS points_bonus
FROM   result_drivers rd
JOIN   results res ON res.id = rd.result_id
JOIN   events  ev  ON ev.id  = res.event_id
JOIN   seasons s   ON s.id   = ev.season_id
JOIN   drivers d   ON d.id   = rd.driver_id
LEFT   JOIN driver_season_team dst ON dst.driver_id = d.id AND dst.season_id = s.id
LEFT   JOIN teams         t ON t.id = dst.team_id
LEFT   JOIN manufacturers m ON m.id = dst.manufacturer_id
LEFT   JOIN adj_total adj ON adj.driver_id = d.id AND adj.season_id = s.id
GROUP  BY d.id, s.id, s.year, dst.team_id, t.name, t.slug,
          dst.manufacturer_id, m.name, m.brand_color, m.logo_url;

GRANT SELECT ON driver_standings TO anon, authenticated;


-- ============================================================
-- team_standings: net deductions AND bonuses per team
--   (rebuilt from 128, adjustment CTE generalised to signed deltas,
--    both types cascading per driver like before)
-- ============================================================
DROP VIEW IF EXISTS team_standings;
CREATE VIEW team_standings AS
WITH per_driver_event AS (
    SELECT
        en.team_id, s.id AS season_id, ev.id AS event_id,
        COALESCE(rd.points_awarded, 0)::int AS driver_points,
        (rd.finish_position = 1        AND COALESCE(rd.status, 'classified') = 'classified') AS is_win,
        (rd.finish_position BETWEEN 1 AND 3 AND COALESCE(rd.status, 'classified') = 'classified') AS is_podium,
        (rd.pole_point                 AND COALESCE(rd.status, 'classified') = 'classified') AS is_pole,
        (rd.fastest_lap_point          AND COALESCE(rd.status, 'classified') = 'classified') AS is_fl
    FROM   result_drivers rd
    JOIN   results res ON res.id = rd.result_id
    JOIN   entries en  ON en.id  = res.entry_id
    JOIN   events  ev  ON ev.id  = res.event_id
    JOIN   seasons s   ON s.id   = ev.season_id
    WHERE  en.team_id IS NOT NULL
),
team_adjustments AS (
    SELECT team_id, season_id,
           SUM(delta)::int                                       AS net,
           SUM(CASE WHEN delta < 0 THEN -delta ELSE 0 END)::int  AS deducted,
           SUM(CASE WHEN delta > 0 THEN  delta ELSE 0 END)::int  AS bonus
    FROM (
        -- Driver-specific adjustment: the team gains/loses it once.
        SELECT en.team_id, ev.season_id,
               CASE WHEN p.penalty_type::text = 'points_bonus'
                    THEN  COALESCE(p.points_amount, 0)
                    ELSE -COALESCE(p.points_amount, 0) END AS delta
        FROM   penalties p
        JOIN   entries en ON en.id = p.entry_id
        JOIN   events  ev ON ev.id = p.event_id
        WHERE  p.penalty_type::text IN ('points_deduction', 'points_bonus')
          AND  p.points_amount IS NOT NULL AND p.driver_id IS NOT NULL AND en.team_id IS NOT NULL
        UNION ALL
        -- Whole-team adjustment: cascades to every driver on the entry.
        SELECT en.team_id, ev.season_id,
               CASE WHEN p.penalty_type::text = 'points_bonus'
                    THEN  COALESCE(p.points_amount, 0)
                    ELSE -COALESCE(p.points_amount, 0) END AS delta
        FROM   penalties p
        JOIN   entries en ON en.id = p.entry_id
        JOIN   events  ev ON ev.id = p.event_id
        JOIN   entry_drivers ed ON ed.entry_id = en.id
        WHERE  p.penalty_type::text IN ('points_deduction', 'points_bonus')
          AND  p.points_amount IS NOT NULL AND p.driver_id IS NULL AND en.team_id IS NOT NULL
    ) x
    GROUP  BY team_id, season_id
)
SELECT
    t.id AS team_id, t.name AS team_name, t.slug AS team_slug,
    s.id AS season_id, s.year AS season_year,
    ts.manufacturer_id, m.name AS manufacturer_name, m.brand_color, m.logo_url AS manufacturer_logo_url,
    (SUM(pde.driver_points) + COALESCE(MAX(adj.net), 0))::int AS points,
    COALESCE(MAX(adj.deducted), 0)                     AS points_deducted,
    COALESCE(MAX(adj.bonus), 0)                        AS points_bonus,
    COUNT(DISTINCT pde.event_id)                       AS races,
    COUNT(*) FILTER (WHERE pde.is_win)                 AS wins,
    COUNT(*) FILTER (WHERE pde.is_podium)              AS podiums,
    COUNT(*) FILTER (WHERE pde.is_pole)                AS poles,
    COUNT(*) FILTER (WHERE pde.is_fl)                  AS fastest_laps
FROM   teams t
JOIN   per_driver_event pde ON pde.team_id = t.id
JOIN   seasons          s   ON s.id        = pde.season_id
LEFT   JOIN team_seasons   ts ON ts.team_id  = t.id AND ts.season_id = s.id
LEFT   JOIN manufacturers  m  ON m.id        = ts.manufacturer_id
LEFT   JOIN team_adjustments adj ON adj.team_id = t.id AND adj.season_id = s.id
GROUP  BY t.id, s.id, s.year, ts.manufacturer_id, m.name, m.brand_color, m.logo_url;

GRANT SELECT ON team_standings TO anon, authenticated;
