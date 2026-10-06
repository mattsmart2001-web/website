-- ============================================================
-- 58 Team standings: count team-mate podiums separately
-- The team_standings view collapsed each event's team-mate finishes
-- into single booleans (BOOL_OR …) so a 1-2 split — or a "P3 in
-- Lobby 1 and P3 in Lobby 2" with both team-mates — counted as 1
-- podium for the team. With multi-lobby racing that's wrong: each
-- driver's podium is a separate, individually-earned result.
--
-- Switch wins / podiums / poles / fastest laps to per-driver counts
-- (same rule driver_standings already uses). Races stays per-event
-- (COUNT DISTINCT event_id) so a team showing up to one round with
-- both team-mates still reads as 1 race, not 2.
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
    SELECT
        en.team_id,
        ev.season_id,
        SUM(COALESCE(p.points_amount, 0))::int AS amount
    FROM   penalties p
    JOIN   entries en ON en.id = p.entry_id
    JOIN   events  ev ON ev.id = p.event_id
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
