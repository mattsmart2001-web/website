-- ============================================================
-- 148 The absence deadline is when the splits actually went out
--
-- 147 used a fixed 48 hours before the start, taken from regulation
-- 3.7's promise that lobby allocations go out no later than that. The
-- hour count was never the thing that mattered, though. What matters is
-- whether the grid had been published when the driver flagged: before
-- it, they can still be taken off the entry list and nobody is affected;
-- after it, the split is set and the hole is real.
--
-- So the cutoff is now the moment this round's split-assignment
-- notifications were sent, read from the messages those notifications
-- created. That is recorded per event and exists for every round already
-- raced, so it applies to the season's history as well as to future
-- rounds, and it tracks reality rather than an assumption about when
-- admin got round to it.
--
-- Where no notification is recorded (a round notified outside the
-- system, or one whose messages were since cleared), it falls back to
-- the published rule: 72 hours before the start, per 6.4. The hour count
-- lives in absence_notice_hours() because it mirrors a regulation and
-- has already moved once.
-- ============================================================

CREATE OR REPLACE FUNCTION public.absence_notice_hours()
RETURNS int LANGUAGE sql IMMUTABLE AS $$
    -- Mirrors regulation 6.4, and is only the fallback: the real cutoff
    -- is when the splits went out. Used for rounds with no recorded
    -- notification.
    SELECT 72;
$$;


-- When this round's split assignments were sent to the drivers. Matched
-- on the subjects notify_lobby_assignments writes; a driver moved
-- between splits gets a differently worded one, and the earliest of them
-- is when the grid became public.
CREATE OR REPLACE FUNCTION public.split_published_at(p_event_id uuid)
RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT MIN(m.created_at)
    FROM   driver_contact_messages m
    WHERE  m.event_id = p_event_id
      AND  (m.subject LIKE 'Split Assignment%'
         OR m.subject LIKE 'Promoted to Split%'
         OR m.subject LIKE 'Moved to Split%');
$$;


-- An absence flagged before this instant excuses the driver; one flagged
-- after it does not.
CREATE OR REPLACE FUNCTION public.absence_deadline(p_event_id uuid)
RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT COALESCE(
        public.split_published_at(p_event_id),
        (SELECT e.starts_at - (public.absence_notice_hours() * interval '1 hour')
           FROM events e WHERE e.id = p_event_id)
    );
$$;

GRANT EXECUTE ON FUNCTION public.absence_notice_hours() TO authenticated;
GRANT EXECUTE ON FUNCTION public.split_published_at(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.absence_deadline(uuid) TO authenticated;


-- Return types match 147, so a replace would do. Both are dropped first
-- anyway so this applies cleanly whatever state the database is in,
-- including straight over 145 or 146. Nothing depends on either function
-- but the console's own RPC calls, and the grants are reissued below.
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
                   SELECT 1 FROM driver_event_absences a
                   WHERE  a.event_id  = en.event_id
                     AND  a.driver_id = en.driver_id
                     AND  a.created_at < public.absence_deadline(en.event_id)
               ) AS declared_in_time,
               -- Flagged, but after the grid went out. Counts as a no-show,
               -- and is shown separately because "told us, just too late"
               -- is material context for whether to omit someone.
               EXISTS (
                   SELECT 1 FROM driver_event_absences a
                   WHERE  a.event_id  = en.event_id
                     AND  a.driver_id = en.driver_id
                     AND  a.created_at >= public.absence_deadline(en.event_id)
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
                   SELECT 1 FROM driver_event_absences a
                   WHERE  a.event_id  = en.event_id
                     AND  a.driver_id = en.driver_id
                     AND  a.created_at < public.absence_deadline(en.event_id)
               ) AS declared_in_time,
               EXISTS (
                   SELECT 1 FROM driver_event_absences a
                   WHERE  a.event_id  = en.event_id
                     AND  a.driver_id = en.driver_id
                     AND  a.created_at >= public.absence_deadline(en.event_id)
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
