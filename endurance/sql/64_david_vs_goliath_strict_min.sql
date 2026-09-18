-- ============================================================
-- 64 David vs Goliath: require a strict rating gap in the lobby
--
-- Round 1 has every driver on the seed Elo (1500), so the previous
-- "lowest-rated = winner" check fires for whoever wins, even though
-- nobody is meaningfully an underdog. After round 2, ratings diverge
-- and the badge becomes earnable in the spirit of its name.
--
-- Fix: require the winner's pre-race rating to be strictly less than
-- at least one other classified driver in the same lobby. Equal-rated
-- fields (round 1, or unlikely later ties) no longer satisfy it.
-- ============================================================

CREATE OR REPLACE FUNCTION driver_secret_badges(p_driver_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_giant_killer  bool := false;
    v_david_goliath bool := false;
    v_giant_slayer  bool := false;
BEGIN
    WITH ev AS (
        SELECT
            rd.driver_id,
            res.event_id,
            en.lobby_number,
            rd.finish_position,
            COALESCE(rd.status, 'classified') AS status,
            dr.rating_before
        FROM   result_drivers rd
        JOIN   results res ON res.id = rd.result_id
        JOIN   entries en  ON en.id  = res.entry_id
        LEFT   JOIN driver_ratings dr ON dr.driver_id = rd.driver_id AND dr.event_id = res.event_id
        WHERE  rd.finish_position IS NOT NULL
    )
    SELECT
        EXISTS (
            -- Giant Killer
            SELECT 1
            FROM   ev me
            JOIN   ev them ON them.event_id   = me.event_id
                          AND them.lobby_number IS NOT DISTINCT FROM me.lobby_number
                          AND them.driver_id <> me.driver_id
            WHERE  me.driver_id = p_driver_id
              AND  me.status = 'classified'
              AND  me.finish_position < them.finish_position
              AND  me.rating_before IS NOT NULL
              AND  them.rating_before IS NOT NULL
              AND  them.rating_before >= me.rating_before + 300
        ),
        EXISTS (
            -- David vs Goliath: win as the lowest-rated driver AND
            -- have at least one rival in the lobby with a strictly
            -- higher pre-race rating, so the field isn't flat.
            SELECT 1
            FROM   ev me
            WHERE  me.driver_id = p_driver_id
              AND  me.status = 'classified'
              AND  me.finish_position = 1
              AND  me.rating_before IS NOT NULL
              AND  me.rating_before = (
                       SELECT MIN(o.rating_before)
                       FROM   ev o
                       WHERE  o.event_id = me.event_id
                         AND  o.lobby_number IS NOT DISTINCT FROM me.lobby_number
                         AND  o.rating_before IS NOT NULL
                   )
              AND  EXISTS (
                       SELECT 1 FROM ev o
                       WHERE o.event_id = me.event_id
                         AND o.lobby_number IS NOT DISTINCT FROM me.lobby_number
                         AND o.driver_id <> me.driver_id
                         AND o.rating_before IS NOT NULL
                         AND o.rating_before > me.rating_before
                   )
        ),
        EXISTS (
            -- Giant Slayer
            SELECT 1
            FROM   ev me
            JOIN   ev them ON them.event_id   = me.event_id
                          AND them.lobby_number IS NOT DISTINCT FROM me.lobby_number
                          AND them.driver_id <> me.driver_id
            WHERE  me.driver_id = p_driver_id
              AND  me.status = 'classified'
              AND  me.finish_position < them.finish_position
              AND  them.driver_id = championship_leader_before(me.event_id)
        )
    INTO v_giant_killer, v_david_goliath, v_giant_slayer;

    RETURN jsonb_build_object(
        'giant_killer',     v_giant_killer,
        'david_vs_goliath', v_david_goliath,
        'giant_slayer',     v_giant_slayer
    );
END;
$$;

GRANT EXECUTE ON FUNCTION driver_secret_badges(uuid) TO anon, authenticated;
