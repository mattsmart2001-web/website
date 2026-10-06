-- ============================================================
-- 128 Whole-team point penalties deduct once PER DRIVER
--
-- The team championship is the sum of its drivers' points
-- (see 58: SUM(pde.driver_points)). A points_deduction penalty
-- recorded against a whole team (penalties.driver_id IS NULL)
-- already CASCADES to every driver on the entry on the driver
-- side (see 32), so a 2-point team penalty on a 2-driver entry
-- removes 2 from each driver = 4 from the drivers' pool.
--
-- team_standings, however, subtracted the raw points_amount just
-- once (2), so the team total no longer matched the sum of its
-- drivers. This recreates team_standings (identical to 58 in every
-- other respect) with a team_deductions CTE that mirrors the driver
-- cascade:
--   * driver-specific penalty  → the team loses it once (that driver)
--   * whole-team penalty        → the team loses it once per driver
--                                 on the entry (entry_drivers)
-- so team points == sum of driver points again.
-- ============================================================

DROP VIEW IF EXISTS team_standings;
CREATE VIEW team_standings AS
WITH per_driver_event AS (
    -- One row per driver-result, carrying its team membership at the
    -- time of the event (en.team_id) so a driver who switched teams
    -- mid-season scores into the team they raced for that round.
    SELECT
        en.team_id,
        s.id  AS season_id,
        ev.id AS event_id,
        COALESCE(rd.points_awarded, 0)::int AS driver_points,
        (rd.finish_position = 1
            AND COALESCE(rd.status, 'classified') = 'classified')  AS is_win,
        (rd.finish_position BETWEEN 1 AND 3
            AND COALESCE(rd.status, 'classified') = 'classified')  AS is_podium,
        (rd.pole_point
            AND COALESCE(rd.status, 'classified') = 'classified')  AS is_pole,
        (rd.fastest_lap_point
            AND COALESCE(rd.status, 'classified') = 'classified')  AS is_fl
    FROM   result_drivers rd
    JOIN   results res ON res.id = rd.result_id
    JOIN   entries en  ON en.id  = res.entry_id
    JOIN   events  ev  ON ev.id  = res.event_id
    JOIN   seasons s   ON s.id   = ev.season_id
    WHERE  en.team_id IS NOT NULL
),
team_deductions AS (
    SELECT team_id, season_id, SUM(amount)::int AS amount
    FROM (
        -- Driver-specific deduction: the team loses it once (the one
        -- driver whose points it came off).
        SELECT
            en.team_id,
            ev.season_id,
            COALESCE(p.points_amount, 0) AS amount
        FROM   penalties p
        JOIN   entries en ON en.id = p.entry_id
        JOIN   events  ev ON ev.id = p.event_id
        WHERE  p.penalty_type  = 'points_deduction'
          AND  p.points_amount IS NOT NULL
          AND  p.driver_id     IS NOT NULL
          AND  en.team_id      IS NOT NULL

        UNION ALL

        -- Whole-team deduction: cascades to every driver on the entry,
        -- so the team (sum of its drivers) loses it once per driver.
        SELECT
            en.team_id,
            ev.season_id,
            COALESCE(p.points_amount, 0) AS amount
        FROM   penalties      p
        JOIN   entries        en ON en.id = p.entry_id
        JOIN   events         ev ON ev.id = p.event_id
        JOIN   entry_drivers  ed ON ed.entry_id = en.id
        WHERE  p.penalty_type  = 'points_deduction'
          AND  p.points_amount IS NOT NULL
          AND  p.driver_id     IS NULL
          AND  en.team_id      IS NOT NULL
    ) x
    GROUP  BY team_id, season_id
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
    (SUM(pde.driver_points) - COALESCE(MAX(ded.amount), 0))::int AS points,
    COALESCE(MAX(ded.amount), 0)                        AS points_deducted,
    -- Races: one tally per event the team appeared in, not per driver.
    COUNT(DISTINCT pde.event_id)                        AS races,
    -- Wins / podiums / poles / FLs: per driver, like F1's constructor
    -- record book reads.
    COUNT(*) FILTER (WHERE pde.is_win)                  AS wins,
    COUNT(*) FILTER (WHERE pde.is_podium)               AS podiums,
    COUNT(*) FILTER (WHERE pde.is_pole)                 AS poles,
    COUNT(*) FILTER (WHERE pde.is_fl)                   AS fastest_laps
FROM   teams t
JOIN   per_driver_event pde ON pde.team_id = t.id
JOIN   seasons          s   ON s.id        = pde.season_id
LEFT   JOIN team_seasons   ts ON ts.team_id  = t.id AND ts.season_id = s.id
LEFT   JOIN manufacturers  m  ON m.id        = ts.manufacturer_id
LEFT   JOIN team_deductions ded ON ded.team_id = t.id AND ded.season_id = s.id
GROUP  BY t.id, s.id, s.year, ts.manufacturer_id, m.name, m.brand_color, m.logo_url;

GRANT SELECT ON team_standings TO anon, authenticated;
