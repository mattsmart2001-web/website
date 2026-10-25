-- =============================================================
-- Gran Turismo GTEC — Elo rating engine (Phase 8)
-- =============================================================
-- Apply after 04_standings.sql.
-- Adds:
--   * get_driver_rating(driver_id)  — current rating (1500 if unrated)
--   * compute_elo_for_event(event_id) — pairwise Elo for all result_drivers
--   * driver_current_ratings VIEW   — latest rating per driver + peak + delta
-- =============================================================
-- Algorithm: pairwise Elo (K=32, base=1500).
-- Every pair of drivers is treated as a 1v1 match. Driver with
-- the better effective finish position "wins". DNF beats DNS/DSQ.
-- Classified > DNF > other non-finishers for ordering.
-- Ratings are clamped to [800, 3000].
-- =============================================================


-- ============================================================
-- 1. get_driver_rating(driver_id)
-- ============================================================
CREATE OR REPLACE FUNCTION get_driver_rating(p_driver_id uuid)
RETURNS int AS $$
    SELECT COALESCE(
        (SELECT rating_after
         FROM   driver_ratings
         WHERE  driver_id = p_driver_id
         ORDER  BY created_at DESC
         LIMIT  1),
        1500
    );
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ============================================================
-- 2. compute_elo_for_event(event_id)
-- ============================================================
CREATE OR REPLACE FUNCTION compute_elo_for_event(p_event_id uuid)
RETURNS json AS $$
DECLARE
    v_k        constant numeric := 32;
    v_expected numeric;
    v_delta    numeric;
    v_pair     record;
    v_count    int;
BEGIN
    -- Build effective finish order from result_drivers for this event.
    -- Classified entries rank by finish_position, then DNF by laps
    -- completed (descending), then remaining statuses last.
    DROP TABLE IF EXISTS _gtec_elo_tmp;
    CREATE TEMP TABLE _gtec_elo_tmp ON COMMIT DROP AS
    SELECT
        rd.driver_id,
        ROW_NUMBER() OVER (
            ORDER BY
                CASE res.status
                    WHEN 'classified' THEN 0
                    WHEN 'dnf'        THEN 1
                    ELSE 2
                END,
                COALESCE(res.finish_position, 9999),
                COALESCE(res.laps_completed, 0) DESC
        ) AS finish_rank,
        get_driver_rating(rd.driver_id) AS rating_before,
        0::numeric                       AS elo_delta
    FROM result_drivers rd
    JOIN results        res ON res.id = rd.result_id
    WHERE res.event_id = p_event_id;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    IF v_count = 0 THEN
        RETURN json_build_object(
            'error', 'No result_drivers found for this event. Run Recompute Points first.'
        );
    END IF;

    IF v_count = 1 THEN
        RETURN json_build_object(
            'error', 'Only one driver in results — need at least two for Elo calculation.'
        );
    END IF;

    -- Pairwise comparison: every driver who finished ahead "beats" everyone below.
    FOR v_pair IN
        SELECT
            w.driver_id     AS w_id,
            w.rating_before AS w_rat,
            l.driver_id     AS l_id,
            l.rating_before AS l_rat
        FROM _gtec_elo_tmp w
        JOIN _gtec_elo_tmp l ON w.finish_rank < l.finish_rank
    LOOP
        v_expected := 1.0 / (1.0 + POWER(
            10.0,
            (v_pair.l_rat::numeric - v_pair.w_rat::numeric) / 400.0
        ));
        v_delta := v_k * (1.0 - v_expected);

        UPDATE _gtec_elo_tmp SET elo_delta = elo_delta + v_delta WHERE driver_id = v_pair.w_id;
        UPDATE _gtec_elo_tmp SET elo_delta = elo_delta - v_delta WHERE driver_id = v_pair.l_id;
    END LOOP;

    -- Persist ratings, clamped to [800, 3000].
    INSERT INTO driver_ratings (driver_id, event_id, rating_before, rating_after, delta)
    SELECT
        driver_id,
        p_event_id,
        rating_before,
        GREATEST(800, LEAST(3000, rating_before + ROUND(elo_delta)::int)),
        ROUND(elo_delta)::int
    FROM _gtec_elo_tmp
    ON CONFLICT (driver_id, event_id) DO UPDATE
        SET rating_before = EXCLUDED.rating_before,
            rating_after  = EXCLUDED.rating_after,
            delta         = EXCLUDED.delta;

    RETURN json_build_object('success', true, 'drivers_rated', v_count);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================================
-- 3. driver_current_ratings VIEW
-- ============================================================
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
