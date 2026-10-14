-- ============================================================
-- 118 driver_activity_report: last_raced_at must reflect actual starts
--
-- Bug: last_raced_at was MAX(ev.starts_at) over the driver's ENTRIES,
-- with no tie to whether they actually raced. So any driver who was
-- entered got a non-null last_raced_at even if they DNS'd — which made
-- the Health Check's "never raced" test (!last_raced_at) only ever catch
-- drivers with zero entries. DNS drivers (on the grid, never started)
-- were therefore invisible in Never Raced.
--
-- Fix: only count an event toward last_raced_at when the driver has a
-- "started" result there (rd is the result_drivers row already filtered
-- to statuses that count as raced — classified/dnf/dsq, i.e. not
-- dns/withdrawn — from migration 117). Now a driver who was entered but
-- never started has last_raced_at = NULL and shows up correctly, while
-- anyone who took a start does not.
-- ============================================================

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
        MAX(ev.starts_at) FILTER (WHERE rd.id IS NOT NULL)   AS last_raced_at
    FROM   drivers d
    LEFT   JOIN teams t ON t.id = d.current_team_id
    LEFT   JOIN entry_drivers ed ON ed.driver_id = d.id
    LEFT   JOIN entries en ON en.id = ed.entry_id
    LEFT   JOIN events ev ON ev.id = en.event_id
    LEFT   JOIN results res ON res.entry_id = en.id
    LEFT   JOIN result_drivers rd
               ON rd.result_id = res.id
              AND rd.driver_id = d.id
              AND COALESCE(rd.status, 'classified') NOT IN ('dns', 'withdrawn')
    GROUP  BY d.id, d.display_name, d.psn_id, t.name, d.user_id
    ORDER  BY last_raced_at ASC NULLS FIRST, d.display_name;
$$;

GRANT EXECUTE ON FUNCTION driver_activity_report() TO authenticated;
