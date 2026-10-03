-- ============================================================
-- 52 Stop compute_elo from compounding on re-runs
-- get_driver_rating() returns the latest rating_after across all
-- events, so running Compute Elo a second time for the same event
-- read the *previous run's* result as the rating going in, then
-- piled another set of deltas on top. Each re-run pushed P1 a
-- couple hundred Elo higher (e.g. 1500 → 1740 → 1880 → 1963).
--
-- Fix: before computing, wipe the driver_ratings rows for this
-- event so get_driver_rating falls back to whatever the rating was
-- going INTO the event (its true rating_before).
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
    -- Critical: clear this event's existing rows first so re-runs are
    -- idempotent. Without this, get_driver_rating() would read the
    -- previous run's rating_after as the new rating_before and
    -- compound the deltas every time the button got pressed.
    DELETE FROM driver_ratings WHERE event_id = p_event_id;

    DROP TABLE IF EXISTS _gtec_elo_tmp;
    CREATE TEMP TABLE _gtec_elo_tmp ON COMMIT DROP AS
    SELECT
        rd.driver_id,
        ROW_NUMBER() OVER (
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

    INSERT INTO driver_ratings (driver_id, event_id, rating_before, rating_after, delta)
    SELECT
        driver_id,
        p_event_id,
        rating_before,
        GREATEST(800, LEAST(3000, rating_before + ROUND(elo_delta)::int)),
        ROUND(elo_delta)::int
    FROM _gtec_elo_tmp;

    RETURN json_build_object('success', true, 'drivers_rated', v_count);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
