-- ============================================================
-- 137 Elo: bound a race's worth, and stop a disconnect wrecking a season
--
-- Drivers were unhappy that a disconnect costs an enormous amount of
-- rating. Running the old formula over a representative 13-car split
-- shows they were right, and by more than the complaint suggested:
--
--     clean P1                 +46
--     clean P4                 +20
--     clean P13 (raced, last)  -46
--     P4 driver disconnects   -160
--
-- One disconnect costs 180 points where a clean P4 earns 20, so it took
-- nine clean races at the same level to undo, and it was three and a
-- half times worse than genuinely finishing last. Elo tiers are 200
-- points wide, so a dropped connection cost most of a tier.
--
-- The cause was not the DNF rule. K = 20 is a chess constant meant to
-- bound ONE GAME, and migrations 92/116 applied it per PAIRING in a
-- round robin. A 13-car split is 12 pairings, so one race could move a
-- rating by twelve chess games' worth, and finishing last meant losing
-- every pairing you were favoured in at once.
--
-- The same bug made splits incomparable, which nobody had reported:
--
--     split of  8   P1-to-last swing   50
--     split of 13   P1-to-last swing   91
--     split of 20   P1-to-last swing  150
--
-- Same relative performance, three times the rating movement, purely
-- because of how many cars were in the lobby. A driver in a big split
-- was playing for higher stakes every round.
--
-- Three changes:
--
--   1. K is normalised by the split's field size, so one race is worth
--      at most ±K whatever the lobby size. K also rises 20 → 40, which
--      with normalisation means a race moves a rating by at most 40
--      instead of up to 150. A DNF now costs roughly 30, not 180.
--
--   2. A new 'dc' status, neutral for rating. A disconnect is not a
--      skill signal, so a driver who suffers one is left out of the
--      rating pass entirely, exactly as DNS and DSQ already are since
--      migration 116 — their rating does not move, and nobody else's
--      moves because of them either. It is still a DNF for points:
--      Elo measures pace, the championship measures turning up.
--
--   3. Neutral disconnects are capped at 2 per driver per season. The
--      third and beyond are rated as an ordinary DNF. The count reads
--      from stored statuses rather than from ratings, so recomputing
--      events in any order gives the same answer.
--
-- 'dc' is set by an admin on the result, never by the driver, so a bad
-- race cannot be laundered by pulling the plug.
--
-- After applying, run Compute Elo again on every scored event of the
-- active season in chronological order.
-- ============================================================

-- Entry-level status. result_drivers.status is plain text and needs no
-- change; this keeps the entry-level enum in step. Every comparison in
-- this file is on text, so the new label is safe to use immediately.
ALTER TYPE result_status ADD VALUE IF NOT EXISTS 'dc';


CREATE OR REPLACE FUNCTION compute_elo_for_event(p_event_id uuid)
RETURNS json AS $$
DECLARE
    v_k        constant numeric := 40;   -- most one race can move a rating
    v_free_dcs constant int     := 2;    -- neutral disconnects per season
    v_expected numeric;
    v_delta    numeric;
    v_pair     record;
    v_count    int;
    v_excused  int;
BEGIN
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
    -- Disconnects already used this season, in rounds before this one.
    prior_dc AS (
        SELECT rd.driver_id, COUNT(*) AS used
        FROM   result_drivers rd
        JOIN   results res ON res.id = rd.result_id
        JOIN   events  e2  ON e2.id  = res.event_id
        CROSS  JOIN ev
        WHERE  e2.season_id = ev.season_id
          AND  e2.id       <> ev.id
          AND  e2.starts_at < ev.starts_at
          AND  COALESCE(rd.status, res.status::text) = 'dc'
        GROUP  BY rd.driver_id
    ),
    -- A disconnect past the season's allowance is rated as a DNF.
    effective AS (
        SELECT t.*,
               CASE WHEN t.st = 'dc' AND COALESCE(p.used, 0) >= v_free_dcs
                    THEN 'dnf' ELSE t.st END AS eff
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
    -- Only drivers who actually raced to a finish or a retirement. Excused
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

    -- Only pair drivers who raced in the same lobby, and divide K by that
    -- lobby's field size so the totals do not grow with the entry list.
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
        v_delta := (v_k / GREATEST(v_pair.n - 1, 1)) * (1.0 - v_expected);

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
        'drivers_rated',       v_count,
        'disconnects_excused', COALESCE(v_excused, 0)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
