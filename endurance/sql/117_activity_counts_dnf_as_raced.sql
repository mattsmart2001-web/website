-- ============================================================
-- 117 driver_activity_report: a DNF counts as having raced
--
-- The Health Check's "Never Raced" list is driven by
-- driver_activity_report.last_raced_at, which only counted a driver as
-- having raced when they had a *classified* result. That wrongly swept
-- up drivers who took the start but retired (DNF) — and DSQ — treating
-- them as if they'd never raced.
--
-- New rule: "raced" = took the start. Count any result whose status is
-- NOT 'dns' or 'withdrawn' (i.e. classified, dnf, dsq). A DNS (on the
-- grid but didn't start) or a withdrawal still counts as not having
-- raced, so those drivers correctly remain on the Never Raced list /
-- No-Show Watch. Only the two "raced"-counting columns change; the row
-- shape is identical to migration 87.
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
              AND COALESCE(rd.status, 'classified') NOT IN ('dns', 'withdrawn')
    GROUP  BY d.id, d.display_name, d.psn_id, t.name, d.user_id
    ORDER  BY last_raced_at ASC NULLS FIRST, d.display_name;
$$;

GRANT EXECUTE ON FUNCTION driver_activity_report() TO authenticated;
