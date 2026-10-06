-- ============================================================
-- 53 circuit_records should pick the truly fastest lap, not just quali
-- The view only looked at qualifying_results.best_lap_ms, so if a
-- driver set a faster lap during the race (recorded on
-- result_drivers.fastest_lap_ms from mig 34), the Hall of Fame still
-- showed the pole lap as the "Fastest Lap" record. Union the two
-- sources and pick the lowest per circuit.
-- ============================================================

DROP VIEW IF EXISTS circuit_records;
CREATE VIEW circuit_records AS
WITH all_laps AS (
    -- Qualifying laps
    SELECT
        ev.circuit_name,
        ev.circuit_country,
        q.best_lap_ms,
        ev.id        AS event_id,
        ev.name      AS event_name,
        ev.starts_at,
        en.team_id,
        en.car_number,
        q.driver_id
    FROM   qualifying_results q
    JOIN   entries en ON en.id = q.entry_id
    JOIN   events  ev ON ev.id = q.event_id
    WHERE  q.best_lap_ms IS NOT NULL
      AND  q.driver_id IS NOT NULL

    UNION ALL

    -- Race laps (per-driver fastest_lap_ms from migration 34)
    SELECT
        ev.circuit_name,
        ev.circuit_country,
        rd.fastest_lap_ms AS best_lap_ms,
        ev.id            AS event_id,
        ev.name          AS event_name,
        ev.starts_at,
        en.team_id,
        en.car_number,
        rd.driver_id
    FROM   result_drivers rd
    JOIN   results res ON res.id = rd.result_id
    JOIN   entries en  ON en.id  = res.entry_id
    JOIN   events  ev  ON ev.id  = res.event_id
    WHERE  rd.fastest_lap_ms IS NOT NULL
      AND  rd.driver_id IS NOT NULL
),
ranked AS (
    SELECT
        circuit_name,
        circuit_country,
        best_lap_ms,
        event_id,
        event_name,
        starts_at,
        team_id,
        car_number,
        driver_id,
        ROW_NUMBER() OVER (
            PARTITION BY circuit_name
            ORDER BY best_lap_ms
        ) AS rn
    FROM   all_laps
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
