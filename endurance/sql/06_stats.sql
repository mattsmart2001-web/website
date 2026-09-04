-- =============================================================
-- Gran Turismo GTEC — Statistics + Hall of Fame (Phase 9)
-- =============================================================
-- Apply after 05_elo.sql.
-- Adds:
--   * driver_career_stats VIEW  — all-time per-driver totals
--   * circuit_records     VIEW  — best qualifying lap per circuit
--   * refresh_hall_of_fame() RPC — recomputes auto-generated HoF rows
-- =============================================================


-- ============================================================
-- 1. driver_career_stats VIEW
-- ============================================================
DROP VIEW IF EXISTS driver_career_stats;
CREATE VIEW driver_career_stats AS
SELECT
    d.id                                                            AS driver_id,
    d.display_name                                                  AS driver_name,
    d.slug                                                          AS driver_slug,
    d.nationality,
    d.career_number,
    d.photo_url,
    COUNT(DISTINCT res.event_id)                                    AS starts,
    COUNT(*) FILTER (WHERE res.finish_position = 1)                 AS wins,
    COUNT(*) FILTER (WHERE res.finish_position BETWEEN 1 AND 3)     AS podiums,
    COUNT(*) FILTER (WHERE res.pole_point)                          AS poles,
    COUNT(*) FILTER (WHERE res.fastest_lap_point)                   AS fastest_laps,
    COUNT(*) FILTER (WHERE res.status = 'classified')               AS finishes,
    COUNT(*) FILTER (WHERE res.status = 'dnf')                      AS dnfs,
    COALESCE(SUM(res.points_awarded * rd.points_share), 0)::numeric(10,2)       AS career_points,
    COALESCE(SUM(ev.duration_hours * rd.points_share), 0)::numeric(10,1)        AS race_hours
FROM   drivers d
LEFT JOIN result_drivers rd ON rd.driver_id = d.id
LEFT JOIN results res ON res.id = rd.result_id
LEFT JOIN events  ev  ON ev.id = res.event_id
GROUP BY d.id;

GRANT SELECT ON driver_career_stats TO anon, authenticated;


-- ============================================================
-- 2. circuit_records VIEW
-- ============================================================
-- Best (lowest) qualifying lap per circuit_name with the driver who
-- set it. Picked from qualifying_results which carry the lap times.
-- ============================================================
DROP VIEW IF EXISTS circuit_records;
CREATE VIEW circuit_records AS
WITH ranked AS (
    SELECT
        ev.circuit_name,
        ev.circuit_country,
        q.best_lap_ms,
        en.team_id,
        en.car_number,
        ev.id        AS event_id,
        ev.name      AS event_name,
        ev.starts_at,
        ed.driver_id,
        ROW_NUMBER() OVER (
            PARTITION BY ev.circuit_name
            ORDER BY q.best_lap_ms
        ) AS rn
    FROM   qualifying_results q
    JOIN   entries            en  ON en.id  = q.entry_id
    JOIN   events             ev  ON ev.id  = q.event_id
    LEFT JOIN entry_drivers   ed  ON ed.entry_id = en.id AND ed.stint_role = 'starting'
    WHERE  q.best_lap_ms IS NOT NULL
)
SELECT
    r.circuit_name,
    r.circuit_country,
    r.best_lap_ms,
    r.event_id,
    r.event_name,
    r.starts_at,
    d.id            AS driver_id,
    d.display_name  AS driver_name,
    d.slug          AS driver_slug,
    t.id            AS team_id,
    t.name          AS team_name,
    t.slug          AS team_slug,
    m.name          AS manufacturer_name,
    m.brand_color
FROM   ranked r
LEFT JOIN drivers       d ON d.id = r.driver_id
LEFT JOIN teams         t ON t.id = r.team_id
LEFT JOIN manufacturers m ON m.id = t.manufacturer_id
WHERE  r.rn = 1;

GRANT SELECT ON circuit_records TO anon, authenticated;


-- ============================================================
-- 3. refresh_hall_of_fame()
-- ============================================================
-- Wipes auto-generated rows from hall_of_fame_records then re-inserts
-- the all-time #1 per applicable category. Manual entries
-- (auto_generated = false) are preserved.
-- Admin-only RPC.
-- ============================================================
CREATE OR REPLACE FUNCTION refresh_hall_of_fame()
RETURNS json AS $$
DECLARE
    v_inserted int := 0;
    v_row      record;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN json_build_object('error', 'Admin role required.');
    END IF;

    DELETE FROM hall_of_fame_records WHERE auto_generated = true;

    -- Most wins
    SELECT driver_id, driver_name, wins INTO v_row
    FROM   driver_career_stats
    WHERE  wins > 0
    ORDER  BY wins DESC, driver_name
    LIMIT  1;
    IF FOUND THEN
        INSERT INTO hall_of_fame_records (category, driver_id, value, context, auto_generated, sort_order)
        VALUES ('most_wins', v_row.driver_id, v_row.wins::text || ' wins', v_row.driver_name, true, 1);
        v_inserted := v_inserted + 1;
    END IF;

    -- Highest rating (peak)
    SELECT dr.driver_id, d.display_name AS driver_name, MAX(dr.rating_after) AS peak INTO v_row
    FROM   driver_ratings dr
    JOIN   drivers d ON d.id = dr.driver_id
    GROUP  BY dr.driver_id, d.display_name
    ORDER  BY peak DESC, d.display_name
    LIMIT  1;
    IF FOUND THEN
        INSERT INTO hall_of_fame_records (category, driver_id, value, context, auto_generated, sort_order)
        VALUES ('highest_rating', v_row.driver_id, v_row.peak::text || ' Elo', 'Peak — ' || v_row.driver_name, true, 2);
        v_inserted := v_inserted + 1;
    END IF;

    -- Most race hours
    SELECT driver_id, driver_name, race_hours INTO v_row
    FROM   driver_career_stats
    WHERE  race_hours > 0
    ORDER  BY race_hours DESC, driver_name
    LIMIT  1;
    IF FOUND THEN
        INSERT INTO hall_of_fame_records (category, driver_id, value, context, auto_generated, sort_order)
        VALUES ('most_race_hours', v_row.driver_id, v_row.race_hours::text || ' h', v_row.driver_name, true, 3);
        v_inserted := v_inserted + 1;
    END IF;

    -- Fastest lap (best qualifying lap, all-time, any circuit)
    DECLARE
        v_cr record;
    BEGIN
        SELECT cr.driver_id, cr.driver_name, cr.best_lap_ms, cr.circuit_name, cr.event_id INTO v_cr
        FROM   circuit_records cr
        ORDER  BY cr.best_lap_ms ASC
        LIMIT  1;
        IF FOUND THEN
            INSERT INTO hall_of_fame_records (category, driver_id, value, context, event_id, auto_generated, sort_order)
            VALUES (
                'fastest_lap',
                v_cr.driver_id,
                LPAD(FLOOR(v_cr.best_lap_ms / 60000)::text, 1, '0') || ':' ||
                LPAD(FLOOR((v_cr.best_lap_ms % 60000) / 1000)::text, 2, '0') || '.' ||
                LPAD((v_cr.best_lap_ms % 1000)::text, 3, '0'),
                v_cr.driver_name || ' — ' || v_cr.circuit_name,
                v_cr.event_id,
                true, 4
            );
            v_inserted := v_inserted + 1;
        END IF;
    END;

    -- Longest current win streak
    DECLARE
        v_streak record;
    BEGIN
        WITH ordered AS (
            SELECT
                rd.driver_id,
                ev.starts_at,
                (res.finish_position = 1) AS is_win,
                ROW_NUMBER() OVER (PARTITION BY rd.driver_id ORDER BY ev.starts_at) AS rn,
                ROW_NUMBER() OVER (PARTITION BY rd.driver_id, (res.finish_position = 1) ORDER BY ev.starts_at) AS win_rn
            FROM result_drivers rd
            JOIN results res ON res.id = rd.result_id
            JOIN events  ev  ON ev.id = res.event_id
        ),
        streaks AS (
            SELECT driver_id, COUNT(*) AS streak
            FROM   ordered
            WHERE  is_win
            GROUP  BY driver_id, rn - win_rn
        )
        SELECT s.driver_id, d.display_name AS driver_name, MAX(s.streak) AS best
        INTO   v_streak
        FROM   streaks s
        JOIN   drivers d ON d.id = s.driver_id
        GROUP  BY s.driver_id, d.display_name
        ORDER  BY best DESC, d.display_name
        LIMIT  1;
        IF FOUND AND v_streak.best > 1 THEN
            INSERT INTO hall_of_fame_records (category, driver_id, value, context, auto_generated, sort_order)
            VALUES ('longest_win_streak', v_streak.driver_id, v_streak.best::text || ' in a row', v_streak.driver_name, true, 5);
            v_inserted := v_inserted + 1;
        END IF;
    END;

    -- Most consecutive finishes (classified)
    DECLARE
        v_fin record;
    BEGIN
        WITH ordered AS (
            SELECT
                rd.driver_id,
                ev.starts_at,
                (res.status = 'classified') AS is_fin,
                ROW_NUMBER() OVER (PARTITION BY rd.driver_id ORDER BY ev.starts_at) AS rn,
                ROW_NUMBER() OVER (PARTITION BY rd.driver_id, (res.status = 'classified') ORDER BY ev.starts_at) AS fin_rn
            FROM result_drivers rd
            JOIN results res ON res.id = rd.result_id
            JOIN events  ev  ON ev.id = res.event_id
        ),
        streaks AS (
            SELECT driver_id, COUNT(*) AS streak
            FROM   ordered
            WHERE  is_fin
            GROUP  BY driver_id, rn - fin_rn
        )
        SELECT s.driver_id, d.display_name AS driver_name, MAX(s.streak) AS best
        INTO   v_fin
        FROM   streaks s
        JOIN   drivers d ON d.id = s.driver_id
        GROUP  BY s.driver_id, d.display_name
        ORDER  BY best DESC, d.display_name
        LIMIT  1;
        IF FOUND AND v_fin.best > 1 THEN
            INSERT INTO hall_of_fame_records (category, driver_id, value, context, auto_generated, sort_order)
            VALUES ('most_consecutive_finishes', v_fin.driver_id, v_fin.best::text || ' classified', v_fin.driver_name, true, 6);
            v_inserted := v_inserted + 1;
        END IF;
    END;

    RETURN json_build_object('success', true, 'records_inserted', v_inserted);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
