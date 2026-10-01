-- ============================================================
-- 138 Pin the new Elo rules to Round 5 onward
--
-- Migration 137 replaced compute_elo_for_event outright, so the new
-- scale and the disconnect rule apply to whatever event is computed
-- next. That matches what the grid has been told, since Rounds 1 to 4
-- are already scored and nothing recomputes them on its own: applying
-- 137 did not touch a single stored rating.
--
-- It does leave a trap. If anyone presses Compute Elo on an earlier
-- round later on, to correct a result or re-run a whole season, that
-- round would silently be rescored under rules it was never raced
-- under, and every rating after it would carry the difference forward.
-- The league said "from Round 5", so the function should say it too.
--
-- compute_elo_for_event now reads the event's own date:
--
--   * before the cutoff  -> exactly the old behaviour from migration
--                           116. K = 20 per pairing, no normalisation,
--                           a disconnect scored as a DNF. An old round
--                           recomputes to the numbers it originally
--                           got.
--   * on or after        -> the migration 137 behaviour. K = 40 divided
--                           by the split's field size, and up to two
--                           excused disconnects per driver per season.
--
-- >>> CHECK THIS DATE against Round 5 before running. It is set to the
-- >>> start of Saturday 3 October 2026. Anything starting on or after
-- >>> it races under the new rules, including every future season.
-- ============================================================

CREATE OR REPLACE FUNCTION compute_elo_for_event(p_event_id uuid)
RETURNS json AS $$
DECLARE
    -- The changeover. Events before this keep the rules they raced under.
    v_new_rules_from constant timestamptz := timestamptz '2026-10-03 00:00:00+00';

    v_k_old    constant numeric := 20;   -- per pairing, as migrations 92/116
    v_k_new    constant numeric := 40;   -- per race, split across the field
    v_free_dcs constant int     := 2;    -- excused disconnects per season

    v_starts_at timestamptz;
    v_new       boolean;
    v_k         numeric;
    v_expected  numeric;
    v_delta     numeric;
    v_pair      record;
    v_count     int;
    v_excused   int;
BEGIN
    SELECT starts_at INTO v_starts_at FROM events WHERE id = p_event_id;
    IF NOT FOUND THEN
        RETURN json_build_object('error', 'Event not found.');
    END IF;

    -- An event with no date is treated as historic, so a missing date can
    -- never silently rescore an old round under the new scale.
    v_new := v_starts_at IS NOT NULL AND v_starts_at >= v_new_rules_from;
    v_k   := CASE WHEN v_new THEN v_k_new ELSE v_k_old END;

    -- Idempotent: wipe this event's ratings so a recompute rebuilds
    -- cleanly and drops rows for drivers who are no longer rated.
    DELETE FROM driver_ratings WHERE event_id = p_event_id;

    DROP TABLE IF EXISTS _gtec_elo_tmp;
    CREATE TEMP TABLE _gtec_elo_tmp ON COMMIT DROP AS
    WITH ev AS (
        SELECT id, season_id, starts_at FROM events WHERE id = p_event_id
    ),
    -- Everyone with a result in this event, status normalised to text.
    this_event AS (
        SELECT rd.driver_id,
               en.lobby_number,
               COALESCE(rd.status, res.status::text, 'classified')     AS st,
               COALESCE(rd.finish_position, res.finish_position, 9999) AS fin,
               COALESCE(rd.laps_driven, res.laps_completed, 0)         AS laps
        FROM   result_drivers rd
        JOIN   results res ON res.id = rd.result_id
        JOIN   entries en  ON en.id  = res.entry_id
        WHERE  res.event_id = p_event_id
    ),
    -- Excused disconnects already used this season, in earlier rounds.
    -- Counted from stored statuses rather than from ratings, so events can
    -- be recomputed in any order and still agree.
    prior_dc AS (
        SELECT rd.driver_id, COUNT(*) AS used
        FROM   result_drivers rd
        JOIN   results res ON res.id = rd.result_id
        JOIN   events  e2  ON e2.id  = res.event_id
        CROSS  JOIN ev
        WHERE  e2.season_id = ev.season_id
          AND  e2.id       <> ev.id
          AND  e2.starts_at < ev.starts_at
          -- The allowance belongs to the new rules. A pre-cutoff round that
          -- an admin later tags 'dc' was already scored as a DNF, so it must
          -- not also eat a slot.
          AND  e2.starts_at >= v_new_rules_from
          AND  COALESCE(rd.status, res.status::text) = 'dc'
        GROUP  BY rd.driver_id
    ),
    effective AS (
        SELECT t.*,
               CASE
                   -- Before the changeover a disconnect was simply a DNF.
                   WHEN NOT v_new AND t.st = 'dc' THEN 'dnf'
                   -- Past the season's allowance it is a DNF again.
                   WHEN t.st = 'dc' AND COALESCE(p.used, 0) >= v_free_dcs THEN 'dnf'
                   ELSE t.st
               END AS eff
        FROM   this_event t
        LEFT   JOIN prior_dc p ON p.driver_id = t.driver_id
    )
    SELECT
        driver_id,
        lobby_number,
        ROW_NUMBER() OVER (
            PARTITION BY lobby_number
            ORDER BY CASE eff WHEN 'classified' THEN 0 WHEN 'dnf' THEN 1 ELSE 2 END,
                     fin,
                     laps DESC
        ) AS finish_rank,
        -- Window functions run after WHERE, so this counts rated drivers only.
        COUNT(*) OVER (PARTITION BY lobby_number) AS split_size,
        get_driver_rating(driver_id)              AS rating_before,
        0::numeric                                AS elo_delta
    FROM   effective
    -- Only drivers who raced to a finish or a retirement. Excused
    -- disconnects join DNS / DSQ / withdrawn in sitting the round out.
    WHERE  eff IN ('classified', 'dnf');

    GET DIAGNOSTICS v_count = ROW_COUNT;

    SELECT COUNT(*) INTO v_excused
    FROM   result_drivers rd
    JOIN   results res ON res.id = rd.result_id
    WHERE  res.event_id = p_event_id
      AND  COALESCE(rd.status, res.status::text) = 'dc'
      AND  rd.driver_id NOT IN (SELECT driver_id FROM _gtec_elo_tmp);

    IF v_count = 0 THEN
        RETURN json_build_object(
            'error', 'No classified/DNF drivers found for this event. Run Recompute Points first.'
        );
    END IF;

    IF v_count = 1 THEN
        RETURN json_build_object(
            'error', 'Only one rated driver — need at least two for Elo calculation.'
        );
    END IF;

    FOR v_pair IN
        SELECT w.driver_id     AS w_id,
               w.rating_before AS w_rat,
               l.driver_id     AS l_id,
               l.rating_before AS l_rat,
               w.split_size    AS n
        FROM _gtec_elo_tmp w
        JOIN _gtec_elo_tmp l
            ON w.lobby_number IS NOT DISTINCT FROM l.lobby_number
           AND w.finish_rank < l.finish_rank
    LOOP
        v_expected := 1.0 / (1.0 + POWER(
            10.0,
            (v_pair.l_rat::numeric - v_pair.w_rat::numeric) / 400.0
        ));
        -- New rules spread K across the field so a big lobby is not worth
        -- more than a small one. Old rules spent K on every pairing.
        v_delta := (v_k / CASE WHEN v_new THEN GREATEST(v_pair.n - 1, 1) ELSE 1 END)
                   * (1.0 - v_expected);

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

    RETURN json_build_object(
        'success',             true,
        'rules',               CASE WHEN v_new THEN 'round 5 onward' ELSE 'pre-round 5' END,
        'drivers_rated',       v_count,
        'disconnects_excused', COALESCE(v_excused, 0)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
