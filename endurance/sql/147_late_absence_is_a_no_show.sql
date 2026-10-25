-- ============================================================
-- 147 A late absence flag does not excuse a no-show
--
-- 145 treated any absence row as excusing a missed race. Looking at the
-- real data, every one of the 38 cases where a driver was entered, held
-- an absence row and did not start was flagged LATE: around seven on race
-- day itself, the rest one to three days out, all after the entry list
-- existed. Flagged early enough and the driver is never entered at all,
-- because 88's auto-register skips them, so there is no DNS to excuse.
--
-- The league's position is that a late flag does not undo the hole in
-- the grid. Splits are built days ahead and are not regenerated, so a
-- driver who pulls out after the grid is published has still cost their
-- split a car and their team-mate a partner.
--
-- The cutoff is 48 hours before the start, which is what regulation 3.7
-- already promises: lobby allocations are published "no later than 48
-- hours before the event is due to start". A flag inside that window is
-- therefore a flag after the grid was out.
--
-- Where splits were generated earlier than 48 hours, this is more
-- generous to the driver than reality. That is deliberate: this figure
-- can cost someone a round under 6.4, so it errs toward the driver.
--
-- Note 6.4 needs a matching deadline in writing before this is enforced.
-- As published it says only "drivers who tick that they are not
-- available", with no timing attached.
-- ============================================================

-- Both functions gain a `late` column, and CREATE OR REPLACE cannot
-- change a return type, so both are dropped first. Nothing depends on
-- either but the console's own RPC calls.
DROP FUNCTION IF EXISTS public.event_no_show_summary(uuid);

CREATE OR REPLACE FUNCTION public.event_no_show_summary(p_season_id uuid DEFAULT NULL)
RETURNS TABLE (
    event_id   uuid,
    round      int,
    name       text,
    starts_at  timestamptz,
    entered    int,
    started    int,
    no_shows   int,
    excused    int,
    unexcused  int,
    late       int,
    declared   int
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH ev AS (
        SELECT e.id, e.round, e.name, e.starts_at
        FROM   events e
        WHERE  e.status = 'completed'
          AND  (p_season_id IS NULL OR e.season_id = p_season_id)
    ),
    entered AS (
        SELECT DISTINCT ed.driver_id, en.event_id
        FROM   entry_drivers ed
        JOIN   entries en ON en.id = ed.entry_id
        WHERE  en.event_id IN (SELECT id FROM ev)
    ),
    started AS (
        SELECT DISTINCT rd.driver_id, res.event_id
        FROM   result_drivers rd
        JOIN   results res ON res.id = rd.result_id
        WHERE  res.event_id IN (SELECT id FROM ev)
          AND  COALESCE(rd.status, 'classified') <> 'dns'
    ),
    gaps AS (
        SELECT en.event_id,
               en.driver_id,
               EXISTS (
                   SELECT 1
                   FROM   driver_event_absences a
                   JOIN   ev ON ev.id = a.event_id
                   WHERE  a.event_id = en.event_id
                     AND  a.driver_id = en.driver_id
                     -- In time only: before the grid was published.
                     AND  a.created_at < ev.starts_at - interval '48 hours'
               ) AS declared_in_time,
               -- Flagged, but after the grid was out. Counts as a no-show,
               -- and is shown separately because "told us, just too late"
               -- is material context for whether to omit someone.
               EXISTS (
                   SELECT 1
                   FROM   driver_event_absences a
                   JOIN   ev ON ev.id = a.event_id
                   WHERE  a.event_id = en.event_id
                     AND  a.driver_id = en.driver_id
                     AND  a.created_at >= ev.starts_at - interval '48 hours'
               ) AS declared_late
        FROM   entered en
        WHERE  NOT EXISTS (
                   SELECT 1 FROM started st
                   WHERE  st.event_id = en.event_id AND st.driver_id = en.driver_id
               )
    )
    SELECT
        ev.id,
        ev.round,
        ev.name,
        ev.starts_at,
        (SELECT COUNT(*)::int FROM entered en WHERE en.event_id = ev.id),
        (SELECT COUNT(*)::int FROM started st WHERE st.event_id = ev.id),
        (SELECT COUNT(*)::int FROM gaps g WHERE g.event_id = ev.id),
        (SELECT COUNT(*)::int FROM gaps g WHERE g.event_id = ev.id AND g.declared_in_time),
        (SELECT COUNT(*)::int FROM gaps g WHERE g.event_id = ev.id AND NOT g.declared_in_time),
        (SELECT COUNT(*)::int FROM gaps g WHERE g.event_id = ev.id AND g.declared_late),
        -- Every absence flagged for the round, late ones included. This is
        -- the "told us at some point" figure and is context, not an excuse.
        (SELECT COUNT(*)::int FROM driver_event_absences a WHERE a.event_id = ev.id)
    FROM   ev
    ORDER  BY ev.round;
$$;

GRANT EXECUTE ON FUNCTION public.event_no_show_summary(uuid) TO authenticated;


DROP FUNCTION IF EXISTS driver_no_show_watch(int);

CREATE OR REPLACE FUNCTION driver_no_show_watch(p_lookback int DEFAULT 5)
RETURNS TABLE(
    driver_id      uuid,
    display_name   text,
    psn_id         text,
    team_name      text,
    events_entered int,
    events_raced   int,
    no_shows       int,
    excused        int,
    late           int
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH recent_events AS (
        SELECT id, starts_at
        FROM   events
        WHERE  status = 'completed'
        ORDER  BY starts_at DESC
        LIMIT  p_lookback
    ),
    entered AS (
        SELECT DISTINCT ed.driver_id, en.event_id
        FROM   entry_drivers ed
        JOIN   entries en ON en.id = ed.entry_id
        WHERE  en.event_id IN (SELECT id FROM recent_events)
    ),
    raced AS (
        SELECT DISTINCT rd.driver_id, res.event_id
        FROM   result_drivers rd
        JOIN   results res ON res.id = rd.result_id
        WHERE  res.event_id IN (SELECT id FROM recent_events)
          AND  COALESCE(rd.status, 'classified') <> 'dns'
    ),
    gaps AS (
        SELECT en.driver_id,
               en.event_id,
               EXISTS (
                   SELECT 1
                   FROM   driver_event_absences a
                   JOIN   recent_events re ON re.id = a.event_id
                   WHERE  a.event_id = en.event_id
                     AND  a.driver_id = en.driver_id
                     AND  a.created_at < re.starts_at - interval '48 hours'
               ) AS declared_in_time,
               EXISTS (
                   SELECT 1
                   FROM   driver_event_absences a
                   JOIN   recent_events re ON re.id = a.event_id
                   WHERE  a.event_id = en.event_id
                     AND  a.driver_id = en.driver_id
                     AND  a.created_at >= re.starts_at - interval '48 hours'
               ) AS declared_late
        FROM   entered en
        WHERE  NOT EXISTS (
                   SELECT 1 FROM raced r
                   WHERE  r.event_id = en.event_id AND r.driver_id = en.driver_id
               )
    )
    SELECT
        d.id,
        d.display_name,
        d.psn_id,
        t.name AS team_name,
        (SELECT COUNT(*)::int FROM entered e WHERE e.driver_id = d.id),
        (SELECT COUNT(*)::int FROM raced   r WHERE r.driver_id = d.id),
        (SELECT COUNT(*)::int FROM gaps    g WHERE g.driver_id = d.id AND NOT g.declared_in_time),
        (SELECT COUNT(*)::int FROM gaps    g WHERE g.driver_id = d.id AND g.declared_in_time),
        (SELECT COUNT(*)::int FROM gaps    g WHERE g.driver_id = d.id AND g.declared_late)
    FROM   drivers d
    LEFT   JOIN teams t ON t.id = d.current_team_id
    WHERE  EXISTS (SELECT 1 FROM entered e WHERE e.driver_id = d.id)
      AND  (SELECT COUNT(*) FROM gaps g
             WHERE g.driver_id = d.id AND NOT g.declared_in_time) >= 2
    ORDER  BY 7 DESC, d.display_name;
$$;

GRANT EXECUTE ON FUNCTION driver_no_show_watch(int) TO authenticated;
