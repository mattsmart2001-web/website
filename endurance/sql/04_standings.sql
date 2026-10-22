-- =============================================================
-- Gran Turismo GTEC — points calc + standings (Phase 6)
-- =============================================================
-- Apply after 01_schema.sql + 02_seed_defaults.sql + 03_driver_claim_tokens.sql.
-- Adds:
--   * compute_event_points(event_id) RPC — recalculates points_awarded
--     for every result of an event using the season's points_system,
--     and rebuilds result_drivers from entry_drivers with equal share.
--   * driver_standings VIEW — per-driver season totals.
--   * team_standings   VIEW — per-team season totals.
-- =============================================================


-- ============================================================
-- 1. compute_event_points(event_id)
-- ============================================================
CREATE OR REPLACE FUNCTION compute_event_points(p_event_id uuid)
RETURNS json AS $$
DECLARE
    v_season_id uuid;
    v_ps        points_systems%ROWTYPE;
    r           record;
    pts         int;
    fl_bonus    int;
    pole_bonus  int;
BEGIN
    SELECT season_id INTO v_season_id FROM events WHERE id = p_event_id;
    IF v_season_id IS NULL THEN
        RETURN json_build_object('error', 'Event not found');
    END IF;

    SELECT ps.* INTO v_ps
    FROM   seasons s JOIN points_systems ps ON ps.id = s.points_system_id
    WHERE  s.id = v_season_id;

    IF v_ps IS NULL THEN
        RETURN json_build_object('error', 'Season has no points system');
    END IF;

    -- For each result row in the event, recompute points_awarded
    FOR r IN SELECT * FROM results WHERE event_id = p_event_id LOOP
        pts := COALESCE((
            SELECT (elem->>'points')::int
            FROM   jsonb_array_elements(v_ps.points) AS elem
            WHERE  (elem->>'position')::int = r.finish_position
        ), 0);

        fl_bonus := 0;
        IF r.fastest_lap_point THEN
            IF NOT v_ps.finish_required_for_fl OR r.status = 'classified' THEN
                fl_bonus := v_ps.fastest_lap_points;
            END IF;
        END IF;

        pole_bonus := CASE WHEN r.pole_point THEN v_ps.pole_points ELSE 0 END;

        UPDATE results
        SET    points_awarded = pts + fl_bonus + pole_bonus
        WHERE  id = r.id;
    END LOOP;

    -- Rebuild result_drivers from entry_drivers (starting drivers only,
    -- equal points share). Admins can later customise the share if needed.
    DELETE FROM result_drivers
    WHERE  result_id IN (SELECT id FROM results WHERE event_id = p_event_id);

    INSERT INTO result_drivers (result_id, driver_id, points_share)
    SELECT
        res.id,
        ed.driver_id,
        ROUND(1.0 / NULLIF(COUNT(*) OVER (PARTITION BY res.id), 0), 4)
    FROM   results res
    JOIN   entry_drivers ed ON ed.entry_id = res.entry_id
    WHERE  res.event_id = p_event_id
      AND  ed.stint_role = 'starting';

    RETURN json_build_object('success', true, 'event_id', p_event_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================================
-- 2. driver_standings VIEW
-- ============================================================
-- Aggregates points per driver per season. For the displayed team /
-- manufacturer, picks the team from the driver's MOST RECENT entry
-- in that season (handles mid-season transfers gracefully).
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
         dst.manufacturer_id, m.name, m.brand_color;


-- ============================================================
-- 3. team_standings VIEW
-- ============================================================
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
GROUP BY t.id, s.id, s.year, ts.manufacturer_id, m.name, m.brand_color;


-- ============================================================
-- 4. Grant public SELECT on the views (RLS-free, derived data)
-- ============================================================
GRANT SELECT ON driver_standings TO anon, authenticated;
GRANT SELECT ON team_standings   TO anon, authenticated;
