-- ============================================================
-- 92 Fair split promotion/relegation
--
-- Three related fixes to the Elo engine:
--
-- 1. dr_sr_seed(dr, sr): the DR/SR -> Elo mapping the admin UI's
--    auto-allocator already uses client-side (DR_TO_ELO / SR_TO_BONUS
--    in endurance/admin/index.html) is ported into SQL, so an unraced
--    driver's rating reflects their GT7 skill instead of a flat 1500.
--
-- 2. get_driver_rating() and driver_current_ratings now fall back to
--    dr_sr_seed() instead of a hardcoded 1500. This is the actual
--    persisted/displayed rating, not just the allocator's estimate,
--    so Round 1 Elo math starts from realistic priors and the
--    "provisional" rating shown on driver cards is consistent with it.
--
-- 3. compute_elo_for_event now only pairs drivers who raced in the same
--    lobby/split. Previously the pairwise comparison ranked every
--    result_driver in the event by raw finish_position with no
--    partition by lobby, so (e.g.) the winner of a weak Split 7 was
--    treated as having "beaten" the back-marker of a strong Split 1,
--    gaining Elo at their expense despite never racing them.
--
-- Also lowers K from 32 to 20 so per-race swings are smaller and less
-- likely to bounce a driver a split they don't belong in off one race.
-- ============================================================

CREATE OR REPLACE FUNCTION dr_sr_seed(p_dr_letter text, p_sr_letter text)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT
        COALESCE(
            CASE p_dr_letter
                WHEN 'E'  THEN 800
                WHEN 'D'  THEN 1100
                WHEN 'C'  THEN 1300
                WHEN 'B'  THEN 1500
                WHEN 'A'  THEN 1700
                WHEN 'A+' THEN 1850
                WHEN 'S'  THEN 2000
                ELSE NULL
            END, 1500
        )
        +
        COALESCE(
            CASE p_sr_letter
                WHEN 'E' THEN -75
                WHEN 'D' THEN -45
                WHEN 'C' THEN -15
                WHEN 'B' THEN 15
                WHEN 'A' THEN 45
                WHEN 'S' THEN 75
                ELSE NULL
            END, 0
        );
$$;


-- ============================================================
-- get_driver_rating: fall back to DR/SR seed, not flat 1500
-- ============================================================
CREATE OR REPLACE FUNCTION get_driver_rating(p_driver_id uuid)
RETURNS int AS $$
    SELECT COALESCE(
        (SELECT rating_after
         FROM   driver_ratings
         WHERE  driver_id = p_driver_id
         ORDER  BY created_at DESC
         LIMIT  1),
        (SELECT dr_sr_seed(gt7_dr_rating, gt7_sr_rating)
         FROM   drivers
         WHERE  id = p_driver_id),
        1500
    );
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ============================================================
-- driver_current_ratings: same fallback, so the "provisional" rating
-- shown on driver cards / standings matches what get_driver_rating()
-- will actually use once that driver's first race is scored.
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
    m.logo_url      AS manufacturer_logo_url,
    COALESCE(l.rating,      dr_sr_seed(d.gt7_dr_rating, d.gt7_sr_rating)) AS rating,
    COALESCE(p.peak_rating, dr_sr_seed(d.gt7_dr_rating, d.gt7_sr_rating)) AS peak_rating,
    l.last_delta,
    l.last_rated_at
FROM   drivers       d
LEFT JOIN latest     l ON l.driver_id = d.id
LEFT JOIN peak       p ON p.driver_id = d.id
LEFT JOIN teams      t ON t.id = d.current_team_id
LEFT JOIN manufacturers m ON m.id = d.current_manufacturer_id;

GRANT SELECT ON driver_current_ratings TO anon, authenticated;


-- ============================================================
-- compute_elo_for_event: split-scoped pairing + K=20
-- ============================================================
CREATE OR REPLACE FUNCTION compute_elo_for_event(p_event_id uuid)
RETURNS json AS $$
DECLARE
    v_k        constant numeric := 20;
    v_expected numeric;
    v_delta    numeric;
    v_pair     record;
    v_count    int;
BEGIN
    DROP TABLE IF EXISTS _gtec_elo_tmp;
    CREATE TEMP TABLE _gtec_elo_tmp ON COMMIT DROP AS
    SELECT
        rd.driver_id,
        en.lobby_number                  AS lobby_number,
        ROW_NUMBER() OVER (
            PARTITION BY en.lobby_number
            ORDER BY
                CASE COALESCE(rd.status, res.status::text)
                    WHEN 'classified' THEN 0
                    WHEN 'dnf'        THEN 1
                    ELSE 2
                END,
                COALESCE(rd.finish_position, res.finish_position, 9999),
                COALESCE(rd.laps_driven, res.laps_completed, 0) DESC
        ) AS finish_rank,
        get_driver_rating(rd.driver_id) AS rating_before,
        0::numeric                       AS elo_delta
    FROM result_drivers rd
    JOIN results        res ON res.id = rd.result_id
    JOIN entries        en  ON en.id  = res.entry_id
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

    -- Only pair drivers who raced in the same lobby/split — a driver's
    -- rating should never move because of someone they never raced.
    FOR v_pair IN
        SELECT
            w.driver_id     AS w_id,
            w.rating_before AS w_rat,
            l.driver_id     AS l_id,
            l.rating_before AS l_rat
        FROM _gtec_elo_tmp w
        JOIN _gtec_elo_tmp l
            ON w.lobby_number IS NOT DISTINCT FROM l.lobby_number
           AND w.finish_rank < l.finish_rank
    LOOP
        v_expected := 1.0 / (1.0 + POWER(
            10.0,
            (v_pair.l_rat::numeric - v_pair.w_rat::numeric) / 400.0
        ));
        v_delta := v_k * (1.0 - v_expected);

        UPDATE _gtec_elo_tmp SET elo_delta = elo_delta + v_delta WHERE driver_id = v_pair.w_id;
        UPDATE _gtec_elo_tmp SET elo_delta = elo_delta - v_delta WHERE driver_id = v_pair.l_id;
    END LOOP;

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
