-- ============================================================
-- 203 The marque, for the lap log's filter
--
-- 202 put the car on the board and in the lap log. Filtering the lap log
-- by manufacturer needs the marque as well, because the car name cannot
-- stand in for it: "911 GT3 R (992) '22" does not contain the word
-- Porsche, and a dropdown listing model names is a dropdown nobody can
-- scan.
--
-- One column, on the one function the lap log reads for this. Appended at
-- the end like 202's, so every existing column keeps its position and the
-- page works whether or not this has been run.
-- ============================================================

DROP FUNCTION IF EXISTS public.live_lap_summary(uuid, text);

CREATE FUNCTION public.live_lap_summary(p_event_id uuid,
                                        p_mode text DEFAULT 'race')
RETURNS TABLE (
    driver_id    uuid,
    display_name text,
    lobby_number int,
    laps         int,
    clean_laps   int,
    best_ms      int,
    median_ms    int,
    mean_ms      int,
    spread_ms    int,
    car_name     text,
    manufacturer_name text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH mine AS (
        SELECT l.*, min(l.lap_ms) OVER (PARTITION BY l.driver_id) AS own_best
          FROM live_laps l
         WHERE l.event_id = p_event_id
           AND (p_mode IS NULL OR l.mode = p_mode)
           AND live_lap_kept(l.event_id, l.driver_id, l.mode, l.recorded_at)
    )
    SELECT m.driver_id, d.display_name, max(m.lobby_number),
           count(*)::int,
           count(*) FILTER (WHERE m.lap_ms <= m.own_best * 1.07)::int,
           min(m.lap_ms)::int,
           percentile_cont(0.5) WITHIN GROUP (
               ORDER BY m.lap_ms) FILTER (WHERE m.lap_ms <= m.own_best * 1.07)::int,
           avg(m.lap_ms) FILTER (WHERE m.lap_ms <= m.own_best * 1.07)::int,
           COALESCE(stddev_pop(m.lap_ms) FILTER (
               WHERE m.lap_ms <= m.own_best * 1.07), 0)::int,
           -- Same source as the live board: the driver's own manufacturer
           -- if they have one, otherwise their team's.
           COALESCE(mf.car_name, mf.name),
           -- The marque on its own, for the filter. car_name cannot stand
           -- in for it: "911 GT3 R (992) '22" does not contain the word
           -- Porsche, and a dropdown of model names is a dropdown nobody
           -- can scan.
           mf.name
      FROM mine m
      JOIN drivers d ON d.id = m.driver_id
      LEFT JOIN teams t ON t.id = d.current_team_id
      LEFT JOIN manufacturers mf
             ON mf.id = COALESCE(d.current_manufacturer_id, t.manufacturer_id)
     GROUP BY m.driver_id, d.display_name, mf.car_name, mf.name
     ORDER BY min(m.lap_ms);
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_summary(uuid, text) TO anon, authenticated;
