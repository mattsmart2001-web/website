-- ============================================================
-- 37 Team standings = sum of driver points; per-event podiums/wins
-- counted once even if two team-mates land in top 3 of the event.
-- ============================================================

DROP VIEW IF EXISTS team_standings;
CREATE VIEW team_standings AS
WITH team_event_summary AS (
    SELECT
        en.team_id,
        s.id  AS season_id,
        ev.id AS event_id,
        SUM(COALESCE(rd.points_awarded, 0))::int       AS event_points,
        BOOL_OR(rd.finish_position = 1)                AS had_win,
        BOOL_OR(rd.finish_position BETWEEN 1 AND 3)    AS had_podium,
        BOOL_OR(rd.pole_point)                         AS had_pole,
        BOOL_OR(rd.fastest_lap_point)                  AS had_fl
    FROM   result_drivers rd
    JOIN   results res ON res.id = rd.result_id
    JOIN   entries en  ON en.id  = res.entry_id
    JOIN   events  ev  ON ev.id  = res.event_id
    JOIN   seasons s   ON s.id   = ev.season_id
    WHERE  en.team_id IS NOT NULL
    GROUP  BY en.team_id, s.id, ev.id
),
team_deductions AS (
    SELECT
        en.team_id,
        ev.season_id,
        SUM(COALESCE(p.points_amount, 0))::int AS amount
    FROM   penalties p
    JOIN   entries   en ON en.id = p.entry_id
    JOIN   events    ev ON ev.id = p.event_id
    WHERE  p.penalty_type   = 'points_deduction'
      AND  p.points_amount  IS NOT NULL
      AND  en.team_id       IS NOT NULL
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
    (COALESCE(SUM(tes.event_points), 0) - COALESCE(MAX(ded.amount), 0))::int AS points,
    COALESCE(MAX(ded.amount), 0)                        AS points_deducted,
    COUNT(DISTINCT tes.event_id)                        AS races,
    COUNT(*) FILTER (WHERE tes.had_win)                 AS wins,
    COUNT(*) FILTER (WHERE tes.had_podium)              AS podiums,
    COUNT(*) FILTER (WHERE tes.had_pole)                AS poles,
    COUNT(*) FILTER (WHERE tes.had_fl)                  AS fastest_laps
FROM   teams t
JOIN   team_event_summary tes ON tes.team_id = t.id
JOIN   seasons            s   ON s.id        = tes.season_id
LEFT   JOIN team_seasons   ts ON ts.team_id  = t.id AND ts.season_id = s.id
LEFT   JOIN manufacturers  m  ON m.id        = ts.manufacturer_id
LEFT   JOIN team_deductions ded ON ded.team_id = t.id AND ded.season_id = s.id
GROUP  BY t.id, s.id, s.year, ts.manufacturer_id, m.name, m.brand_color, m.logo_url;

GRANT SELECT ON team_standings TO anon, authenticated;
