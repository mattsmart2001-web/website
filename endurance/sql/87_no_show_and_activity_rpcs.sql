-- ============================================================
-- 87 No-show watch & driver activity report RPCs
--
-- driver_no_show_watch(p_lookback)
--   Returns drivers entered in the last p_lookback completed
--   events who have 2+ no-shows (entered but no non-DNS result).
--
-- driver_activity_report()
--   Returns every driver with their all-time entry/race counts
--   and last-raced date, sorted least active first. Used for the
--   admin "dead wood" filter across seasons.
-- ============================================================

CREATE OR REPLACE FUNCTION driver_no_show_watch(p_lookback int DEFAULT 5)
RETURNS TABLE(
    driver_id      uuid,
    display_name   text,
    psn_id         text,
    team_name      text,
    events_entered int,
    events_raced   int,
    no_shows       int
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH recent_events AS (
        SELECT id
        FROM   events
        WHERE  status = 'completed'
        ORDER  BY starts_at DESC
        LIMIT  p_lookback
    ),
    entered AS (
        SELECT ed.driver_id, en.event_id
        FROM   entry_drivers ed
        JOIN   entries en ON en.id = ed.entry_id
        WHERE  en.event_id IN (SELECT id FROM recent_events)
    ),
    raced AS (
        SELECT rd.driver_id, res.event_id
        FROM   result_drivers rd
        JOIN   results res ON res.id = rd.result_id
        WHERE  res.event_id IN (SELECT id FROM recent_events)
          AND  COALESCE(rd.status, 'classified') <> 'dns'
    )
    SELECT
        d.id,
        d.display_name,
        d.psn_id,
        t.name                                            AS team_name,
        COUNT(DISTINCT e.event_id)::int                  AS events_entered,
        COUNT(DISTINCT r.event_id)::int                  AS events_raced,
        (COUNT(DISTINCT e.event_id)
         - COUNT(DISTINCT r.event_id))::int              AS no_shows
    FROM   drivers d
    LEFT   JOIN teams t ON t.id = d.current_team_id
    JOIN   entered e ON e.driver_id = d.id
    LEFT   JOIN raced r ON r.driver_id = d.id AND r.event_id = e.event_id
    GROUP  BY d.id, d.display_name, d.psn_id, t.name
    HAVING COUNT(DISTINCT e.event_id) - COUNT(DISTINCT r.event_id) >= 2
    ORDER  BY no_shows DESC, d.display_name;
$$;

GRANT EXECUTE ON FUNCTION driver_no_show_watch(int) TO authenticated;


CREATE OR REPLACE FUNCTION driver_activity_report()
RETURNS TABLE(
    driver_id     uuid,
    display_name  text,
    psn_id        text,
    team_name     text,
    is_claimed    boolean,
    total_entered int,
    total_raced   int,
    last_raced_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        d.id,
        d.display_name,
        d.psn_id,
        t.name                                                AS team_name,
        (d.user_id IS NOT NULL)                              AS is_claimed,
        COUNT(DISTINCT ed.entry_id)::int                     AS total_entered,
        COUNT(DISTINCT rd.id)::int                           AS total_raced,
        MAX(ev.starts_at)                                    AS last_raced_at
    FROM   drivers d
    LEFT   JOIN teams t ON t.id = d.current_team_id
    LEFT   JOIN entry_drivers ed ON ed.driver_id = d.id
    LEFT   JOIN entries en ON en.id = ed.entry_id
    LEFT   JOIN events ev ON ev.id = en.event_id
    LEFT   JOIN results res ON res.entry_id = en.id
    LEFT   JOIN result_drivers rd
               ON rd.result_id = res.id
              AND rd.driver_id = d.id
              AND COALESCE(rd.status, 'classified') = 'classified'
    GROUP  BY d.id, d.display_name, d.psn_id, t.name, d.user_id
    ORDER  BY last_raced_at ASC NULLS FIRST, d.display_name;
$$;

GRANT EXECUTE ON FUNCTION driver_activity_report() TO authenticated;
