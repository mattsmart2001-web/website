-- ============================================================
-- 61 Secret badges — server-side detection
-- Three hidden achievements computed in one RPC. Each is a single
-- existence check joined to driver_ratings (for "300+ above you")
-- and the lobby cohort (so multi-lobby events only count drivers
-- who actually shared the same race).
--   * giant_killer       — beat a driver 300+ Elo above you
--   * david_vs_goliath   — win a race as the lowest-rated driver in
--                          the lobby
--   * giant_slayer       — beat the championship leader (within the
--                          same season, leader as of the start of
--                          that round)
-- ============================================================

-- Helper: who was leading the championship in season S going INTO
-- event E (i.e. counting points from earlier events only)?
CREATE OR REPLACE FUNCTION championship_leader_before(p_event_id uuid)
RETURNS uuid AS $$
    SELECT rd.driver_id
    FROM   result_drivers rd
    JOIN   results res ON res.id = rd.result_id
    JOIN   events  ev  ON ev.id  = res.event_id
    WHERE  ev.season_id = (SELECT season_id FROM events WHERE id = p_event_id)
      AND  ev.starts_at < (SELECT starts_at FROM events WHERE id = p_event_id)
    GROUP  BY rd.driver_id
    HAVING SUM(COALESCE(rd.points_awarded, 0)) > 0
    ORDER  BY SUM(COALESCE(rd.points_awarded, 0)) DESC
    LIMIT  1;
$$ LANGUAGE sql STABLE;

GRANT EXECUTE ON FUNCTION championship_leader_before(uuid) TO anon, authenticated;


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
    -- One-shot CTE of every driver result paired with their pre-race
    -- rating + the entry's lobby_number. Same shape feeds all three
    -- checks below.
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
            -- David vs Goliath
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
