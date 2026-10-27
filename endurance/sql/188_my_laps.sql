-- ============================================================
-- 188 A driver's own race laps
--
-- The lap log goes in the portal, race laps only. Practice is still
-- recorded, because a circuit record and a season's form both want it, but
-- it is not what a driver opens their portal to look at: a practice window
-- that runs every night would bury the one round they raced.
--
-- A function rather than the portal querying live_laps itself, for two
-- reasons. It returns one driver's rounds rather than the whole field, so
-- a portal card costs one small row per round instead of seven thousand
-- laps. And where the driver finished among the cars that were reporting
-- is a comparison across the field, which has to be worked out server side
-- or not at all.
--
-- Signed in only. The standalone page is public and these same times were
-- on the live screen while the race ran, so nothing here is secret; this is
-- scoped to the caller because "my laps" means the caller's, and a function
-- that took a driver id would just be the public page with extra steps.
-- ============================================================

CREATE OR REPLACE FUNCTION public.my_lap_rounds()
RETURNS TABLE (
    event_id     uuid,
    round        int,
    name         text,
    circuit_name text,
    starts_at    timestamptz,
    laps         int,
    clean_laps   int,
    best_ms      int,
    median_ms    int,
    spread_ms    int,
    -- Where that best lap stood among the cars reporting in the same split,
    -- and how many there were. Not a finishing position, and the column it
    -- feeds says so.
    best_rank    int,
    split_cars   int
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH me AS (
        SELECT d.id FROM drivers d WHERE d.user_id = auth.uid()
    ),
    mine AS (
        SELECT l.*, min(l.lap_ms) OVER (PARTITION BY l.event_id) AS own_best
          FROM live_laps l
         WHERE l.driver_id = (SELECT id FROM me)
           AND l.mode = 'race'
    ),
    agg AS (
        SELECT m.event_id,
               count(*)::int                                       AS laps,
               count(*) FILTER (WHERE m.lap_ms <= m.own_best * 1.07)::int AS clean_laps,
               min(m.lap_ms)::int                                   AS best_ms,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY m.lap_ms)
                   FILTER (WHERE m.lap_ms <= m.own_best * 1.07)::int AS median_ms,
               COALESCE(stddev_pop(m.lap_ms) FILTER (
                   WHERE m.lap_ms <= m.own_best * 1.07), 0)::int     AS spread_ms,
               max(m.lobby_number)                                  AS lobby_number
          FROM mine m
         GROUP BY m.event_id
    ),
    -- Everybody's best in the same split, so the rank means something: a
    -- driver in split 7 is not being measured against split 1.
    field AS (
        SELECT l.event_id, l.lobby_number, l.driver_id, min(l.lap_ms) AS best_ms
          FROM live_laps l
         WHERE l.mode = 'race'
         GROUP BY l.event_id, l.lobby_number, l.driver_id
    )
    SELECT a.event_id, e.round, e.name, e.circuit_name, e.starts_at,
           a.laps, a.clean_laps, a.best_ms, a.median_ms, a.spread_ms,
           (SELECT count(*)::int + 1 FROM field f
             WHERE f.event_id = a.event_id
               AND f.lobby_number IS NOT DISTINCT FROM a.lobby_number
               AND f.best_ms < a.best_ms),
           (SELECT count(*)::int FROM field f
             WHERE f.event_id = a.event_id
               AND f.lobby_number IS NOT DISTINCT FROM a.lobby_number)
      FROM agg a
      JOIN events e ON e.id = a.event_id
     ORDER BY e.starts_at DESC;
$$;

-- Signed in only: it reads auth.uid() and returns nothing without one.
GRANT EXECUTE ON FUNCTION public.my_lap_rounds() TO authenticated;
