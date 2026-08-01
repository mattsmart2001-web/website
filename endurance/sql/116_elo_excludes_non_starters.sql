-- ============================================================
-- 116 Elo ignores DNS / DSQ / withdrawn drivers
--
-- compute_elo_for_event (migration 92) built its ranking table from
-- EVERY result_drivers row for the event, including drivers who didn't
-- race. Non-starters were ranked last (status ELSE 2), so they lost to
-- everyone who raced — but they still "beat" any other non-participant
-- in the same split (another DNS/DSQ/withdrawn), which handed them a
-- positive Elo delta. A driver who never took the start should not gain
-- (or lose) rating at all.
--
-- Two fixes:
--   1. Only rank drivers whose result is 'classified' or 'dnf' — i.e.
--      they actually competed. DNS / DSQ / withdrawn are excluded, so
--      they neither move nor are "beaten" for rating purposes.
--   2. Restore the idempotent DELETE at the top (migration 92 relied on
--      an upsert, which left stale rating rows behind for drivers who
--      are no longer rated). Clearing the event's rows first means a
--      recompute drops the erroneous non-starter ratings automatically.
--
-- Everything else matches migration 92: K = 20 and split-scoped pairing
-- (drivers are only compared against others in their own split).
--
-- After applying, run Compute Elo again on any affected event (Round 1,
-- and any later scored events in chronological order).
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
    -- Idempotent: wipe this event's ratings first so a recompute rebuilds
    -- cleanly and drops rows for drivers who are no longer rated (e.g. the
    -- non-starters now excluded below).
    DELETE FROM driver_ratings WHERE event_id = p_event_id;

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
    WHERE res.event_id = p_event_id
      -- Only drivers who actually competed. DNS / DSQ / withdrawn are out.
      AND COALESCE(rd.status, res.status::text, 'classified') IN ('classified', 'dnf');

    GET DIAGNOSTICS v_count = ROW_COUNT;

    IF v_count = 0 THEN
        RETURN json_build_object(
            'error', 'No classified/DNF drivers found for this event. Run Recompute Points first.'
        );
    END IF;

    IF v_count = 1 THEN
        RETURN json_build_object(
            'error', 'Only one classified/DNF driver — need at least two for Elo calculation.'
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
