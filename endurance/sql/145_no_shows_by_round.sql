-- ============================================================
-- 145 No-shows by round, and aligning the watch list with 6.4
--
-- Two things.
--
-- 1. event_no_show_summary() gives per-round no-show volume, which
--    nothing reported before. The per-driver watch list answered "who
--    keeps missing races"; this answers "how bad is it, and is it
--    getting worse", which is what the grid needs to be shown.
--
-- 2. driver_no_show_watch() is fixed to ignore excused absences.
--    Regulation 6.4 puts a driver on the watch list after two no-shows
--    but says "This does not apply to drivers who tick that they are not
--    available to race a round." The function counted entered-minus-
--    raced with no reference to driver_event_absences, so a driver who
--    told us in advance and was left on the entry list anyway could be
--    shown on the watch list. Since omission decisions are now made off
--    this panel, a driver could have been dropped from a round for
--    absences they had properly declared.
--
-- A no-show is counted as: entered for the event, and no result row with
-- a status other than 'dns'. A missing result row counts too, since a
-- driver who was on the grid and has nothing recorded did not race.
-- ============================================================

-- ---- per-round volume ----
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
    -- Entered but never started: the holes in the grid.
    gaps AS (
        SELECT en.event_id,
               en.driver_id,
               EXISTS (
                   SELECT 1 FROM driver_event_absences a
                   WHERE  a.event_id = en.event_id AND a.driver_id = en.driver_id
               ) AS was_declared
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
        (SELECT COUNT(*)::int FROM gaps g WHERE g.event_id = ev.id AND g.was_declared),
        (SELECT COUNT(*)::int FROM gaps g WHERE g.event_id = ev.id AND NOT g.was_declared),
        -- Everyone who flagged an absence for the round, whether or not
        -- they were left on the entry list. This is the "told us in
        -- advance" figure, which is the behaviour we want to encourage.
        (SELECT COUNT(*)::int FROM driver_event_absences a WHERE a.event_id = ev.id)
    FROM   ev
    ORDER  BY ev.round;
$$;

GRANT EXECUTE ON FUNCTION public.event_no_show_summary(uuid) TO authenticated;


-- ---- watch list now honours a declared absence, per 6.4 ----
CREATE OR REPLACE FUNCTION driver_no_show_watch(p_lookback int DEFAULT 5)
RETURNS TABLE(
    driver_id      uuid,
    display_name   text,
    psn_id         text,
    team_name      text,
    events_entered int,
    events_raced   int,
    no_shows       int,
    excused        int
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
    -- Split each missed race into declared and undeclared. Only the
    -- undeclared ones count toward the watch list under 6.4.
    gaps AS (
        SELECT en.driver_id,
               en.event_id,
               EXISTS (
                   SELECT 1 FROM driver_event_absences a
                   WHERE  a.event_id = en.event_id AND a.driver_id = en.driver_id
               ) AS was_declared
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
        (SELECT COUNT(*)::int FROM gaps    g WHERE g.driver_id = d.id AND NOT g.was_declared),
        (SELECT COUNT(*)::int FROM gaps    g WHERE g.driver_id = d.id AND g.was_declared)
    FROM   drivers d
    LEFT   JOIN teams t ON t.id = d.current_team_id
    WHERE  EXISTS (SELECT 1 FROM entered e WHERE e.driver_id = d.id)
      AND  (SELECT COUNT(*) FROM gaps g WHERE g.driver_id = d.id AND NOT g.was_declared) >= 2
    ORDER  BY 7 DESC, d.display_name;
$$;

GRANT EXECUTE ON FUNCTION driver_no_show_watch(int) TO authenticated;
