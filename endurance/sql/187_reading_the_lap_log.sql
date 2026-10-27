-- ============================================================
-- 187 Reading the lap log
--
-- 186 keeps the laps and nothing shows them. Two read functions so a page
-- can: which rounds have laps, and the laps themselves with driver names
-- attached.
--
-- Both are public, like the live screen these times already appeared on
-- while the race was running. Nothing here is secret; a lap time was on a
-- public page the moment it was set, and a league's lap chart is the sort
-- of thing a league wants people to look at.
-- ============================================================

-- ---- which rounds have anything to show ----
CREATE OR REPLACE FUNCTION public.live_lap_rounds()
RETURNS TABLE (
    event_id     uuid,
    round        int,
    name         text,
    circuit_name text,
    starts_at    timestamptz,
    laps         int,
    drivers      int,
    race_laps    int
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT e.id, e.round, e.name, e.circuit_name, e.starts_at,
           count(*)::int,
           count(DISTINCT l.driver_id)::int,
           count(*) FILTER (WHERE l.mode = 'race')::int
      FROM live_laps l
      JOIN events e ON e.id = l.event_id
     GROUP BY e.id, e.round, e.name, e.circuit_name, e.starts_at
     ORDER BY e.starts_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_rounds() TO anon, authenticated;


-- ---- the laps themselves ----
-- Ordered by driver and then by the order they were recorded rather than by
-- lap number, because a red flag restart legitimately produces a second lap
-- 3 and a chart wants them in the order they happened.
CREATE OR REPLACE FUNCTION public.live_lap_log(p_event_id uuid,
                                               p_mode text DEFAULT 'race')
RETURNS TABLE (
    driver_id    uuid,
    display_name text,
    car_number   int,
    lobby_number int,
    lap          int,
    lap_ms       int,
    fuel_pct     real,
    mode         text,
    session_from timestamptz,
    recorded_at  timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT l.driver_id, d.display_name, en.car_number, l.lobby_number,
           l.lap, l.lap_ms, l.fuel_pct, l.mode, l.session_from, l.recorded_at
      FROM live_laps l
      JOIN drivers d ON d.id = l.driver_id
      LEFT JOIN entries en ON en.event_id = l.event_id
            AND EXISTS (SELECT 1 FROM entry_drivers ed
                         WHERE ed.entry_id = en.id AND ed.driver_id = l.driver_id)
     WHERE l.event_id = p_event_id
       AND (p_mode IS NULL OR l.mode = p_mode)
     ORDER BY d.display_name, l.id;
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_log(uuid, text) TO anon, authenticated;
