-- ============================================================
-- 57 Compute Elo per lobby instead of per event
-- The previous compute_elo_for_event pooled every result_drivers row
-- for the event into one pairwise calculation. When an event runs
-- across multiple lobbies (e.g. 50 drivers split 4 × ~13), the P1 in
-- Lobby 1 was counted as having "beaten" everyone in lobbies 2, 3, 4
-- — they weren't even on track at the same time. That made the leader
-- gain +784 (49 pairs × 16) in a single event.
--
-- Lobby allocation already groups drivers by skill, so the right model
-- is: each lobby is its own race for Elo. Pairwise comparisons happen
-- only between drivers who shared a lobby. Cross-lobby deltas always
-- collapse to zero.
--
-- Implementation: pull entries.lobby_number into the temp table and
-- restrict the pair join to rows with the same lobby_number. Drivers
-- on unassigned entries (lobby_number IS NULL) are treated as a single
-- "lobby 0" pool — same behaviour as before for one-lobby events.
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
    -- Wipe this event's existing rows first so repeat runs are idempotent.
    DELETE FROM driver_ratings WHERE event_id = p_event_id;

    DROP TABLE IF EXISTS _gtec_elo_tmp;
    CREATE TEMP TABLE _gtec_elo_tmp ON COMMIT DROP AS
    SELECT
        rd.driver_id,
        COALESCE(en.lobby_number, 0) AS lobby_number,
        ROW_NUMBER() OVER (
            PARTITION BY COALESCE(en.lobby_number, 0)
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

    -- Pairwise comparisons restricted to drivers who shared a lobby.
    FOR v_pair IN
        SELECT
            w.driver_id     AS w_id,
            w.rating_before AS w_rat,
            l.driver_id     AS l_id,
            l.rating_before AS l_rat
        FROM _gtec_elo_tmp w
        JOIN _gtec_elo_tmp l
          ON w.lobby_number = l.lobby_number
         AND w.finish_rank  < l.finish_rank
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
