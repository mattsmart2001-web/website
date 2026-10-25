-- ============================================================
-- 62 More secret badges — Unfinished Business, Phoenix, Comeback King,
-- Last to First, Mr Consistent. Extends the RPC from mig 61 to compute
-- all eight in a single call.
-- ============================================================

CREATE OR REPLACE FUNCTION driver_secret_badges(p_driver_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_giant_killer       bool := false;
    v_david_goliath      bool := false;
    v_giant_slayer       bool := false;
    v_unfinished_biz     bool := false;
    v_phoenix            bool := false;
    v_comeback_king      bool := false;
    v_last_to_first      bool := false;
    v_mr_consistent      bool := false;
BEGIN
    WITH ev AS (
        SELECT
            rd.driver_id,
            res.event_id,
            evt.season_id,
            evt.starts_at,
            en.lobby_number,
            rd.finish_position,
            COALESCE(rd.status, 'classified') AS status,
            dr.rating_before,
            rd.result_id,
            res.entry_id
        FROM   result_drivers rd
        JOIN   results res ON res.id = rd.result_id
        JOIN   entries en  ON en.id  = res.entry_id
        JOIN   events  evt ON evt.id = res.event_id
        LEFT   JOIN driver_ratings dr ON dr.driver_id = rd.driver_id AND dr.event_id = res.event_id
        WHERE  rd.finish_position IS NOT NULL
    )
    SELECT
        /* Giant Killer */ EXISTS (
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
        /* David vs Goliath */ EXISTS (
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
        /* Giant Slayer */ EXISTS (
            SELECT 1
            FROM   ev me
            JOIN   ev them ON them.event_id   = me.event_id
                          AND them.lobby_number IS NOT DISTINCT FROM me.lobby_number
                          AND them.driver_id <> me.driver_id
            WHERE  me.driver_id = p_driver_id
              AND  me.status = 'classified'
              AND  me.finish_position < them.finish_position
              AND  them.driver_id = championship_leader_before(me.event_id)
        ),
        /* Unfinished Business — beat them this round; they beat you in
           the previous round you both raced in within the same season
           and the same split. */
        EXISTS (
            WITH me_ev AS (
                SELECT * FROM ev WHERE driver_id = p_driver_id AND status = 'classified'
            )
            SELECT 1
            FROM   me_ev me
            JOIN   ev them ON them.event_id   = me.event_id
                          AND them.lobby_number IS NOT DISTINCT FROM me.lobby_number
                          AND them.driver_id <> p_driver_id
                          AND me.finish_position < them.finish_position
            JOIN LATERAL (
                SELECT id, starts_at FROM events e
                WHERE e.season_id = me.season_id
                  AND e.starts_at < me.starts_at
                  AND EXISTS (SELECT 1 FROM ev x WHERE x.driver_id = p_driver_id AND x.event_id = e.id)
                ORDER BY e.starts_at DESC
                LIMIT 1
            ) prev_e ON true
            JOIN ev me_prev   ON me_prev.driver_id   = p_driver_id     AND me_prev.event_id   = prev_e.id
            JOIN ev them_prev ON them_prev.driver_id = them.driver_id  AND them_prev.event_id = prev_e.id
                             AND them_prev.lobby_number IS NOT DISTINCT FROM me_prev.lobby_number
            WHERE  them_prev.finish_position < me_prev.finish_position
        ),
        /* Phoenix — peak rating → dropped 1000+ → climbed back to peak.
           Uses rating_after values across the whole history. */
        EXISTS (
            SELECT 1
            FROM   driver_ratings peak
            WHERE  peak.driver_id = p_driver_id
              AND  EXISTS (
                  SELECT 1 FROM driver_ratings trough
                  WHERE  trough.driver_id  = p_driver_id
                    AND  trough.created_at > peak.created_at
                    AND  peak.rating_after - trough.rating_after >= 1000
                    AND  EXISTS (
                        SELECT 1 FROM driver_ratings recov
                        WHERE recov.driver_id  = p_driver_id
                          AND recov.created_at > trough.created_at
                          AND recov.rating_after >= peak.rating_after
                    )
              )
        ),
        /* Comeback King — qualifying_position - finish_position ≥ 10. */
        EXISTS (
            SELECT 1
            FROM   ev me
            JOIN   qualifying_results q ON q.event_id  = me.event_id
                                        AND q.entry_id = me.entry_id
                                        AND q.driver_id = me.driver_id
            WHERE  me.driver_id = p_driver_id
              AND  me.status = 'classified'
              AND  q.position IS NOT NULL
              AND  (q.position - me.finish_position) >= 10
        ),
        /* Last to First — qualified slowest in split, won the race. */
        EXISTS (
            SELECT 1
            FROM   ev me
            JOIN   qualifying_results q ON q.event_id  = me.event_id
                                        AND q.entry_id = me.entry_id
                                        AND q.driver_id = me.driver_id
            WHERE  me.driver_id = p_driver_id
              AND  me.status = 'classified'
              AND  me.finish_position = 1
              AND  q.position IS NOT NULL
              AND  q.position = (
                       SELECT MAX(q2.position)
                       FROM   qualifying_results q2
                       JOIN   entries en2 ON en2.id = q2.entry_id
                       WHERE  q2.event_id = me.event_id
                         AND  en2.lobby_number IS NOT DISTINCT FROM me.lobby_number
                         AND  q2.position IS NOT NULL
                   )
        ),
        /* Mr Consistent — 5 consecutive classified top-10 finishes in
           the driver's own race timeline (calendar gaps don't break
           the streak; only a worse-than-10 / DNF does). Classic
           gap-and-island trick: a contiguous run shares a constant
           (rn - hn) where hn is the row number within "hits". */
        EXISTS (
            WITH ordered AS (
                SELECT
                    ev.starts_at,
                    (me.finish_position BETWEEN 1 AND 10 AND me.status = 'classified') AS hit,
                    ROW_NUMBER() OVER (ORDER BY ev.starts_at) AS rn
                FROM   ev me
                JOIN   events ev ON ev.id = me.event_id
                WHERE  me.driver_id = p_driver_id
            ),
            hits AS (
                SELECT *,
                       ROW_NUMBER() OVER (ORDER BY starts_at) AS hn
                FROM   ordered
                WHERE  hit
            )
            SELECT 1
            FROM   hits
            GROUP  BY (rn - hn)
            HAVING COUNT(*) >= 5
        )
    INTO  v_giant_killer, v_david_goliath, v_giant_slayer,
          v_unfinished_biz, v_phoenix, v_comeback_king,
          v_last_to_first, v_mr_consistent;

    RETURN jsonb_build_object(
        'giant_killer',        v_giant_killer,
        'david_vs_goliath',    v_david_goliath,
        'giant_slayer',        v_giant_slayer,
        'unfinished_business', v_unfinished_biz,
        'phoenix',             v_phoenix,
        'comeback_king',       v_comeback_king,
        'last_to_first',       v_last_to_first,
        'mr_consistent',       v_mr_consistent
    );
END;
$$;

GRANT EXECUTE ON FUNCTION driver_secret_badges(uuid) TO anon, authenticated;
