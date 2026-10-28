-- ============================================================
-- 190 The log, while it is happening
--
-- The lap log lives on its own page, which is the right home for a round
-- that has finished and the wrong one for a round that is running. During a
-- race the thing people want to see is pace: who is holding it, who is
-- falling away, where the stops went. That belongs next to the map, on the
-- screen already open on the second monitor.
--
-- live_lap_log is no use for that. It returns every lap of the round on
-- every call, and the live page polls every second and a half; across ten
-- splits that is seven thousand rows a poll, for the sake of the one row
-- that changed.
--
-- So: the same rows, from a marker. The page keeps the highest id it has
-- seen and asks for what came after it, which is nothing at all on most
-- polls and one row when a car crosses the line. The id is a bigserial, so
-- "after this one" is exact in a way "since this time" is not: two laps
-- recorded in the same millisecond cannot hide behind each other.
-- ============================================================

CREATE OR REPLACE FUNCTION public.live_lap_feed(p_event_id uuid,
                                                p_mode     text   DEFAULT NULL,
                                                p_after_id bigint DEFAULT NULL)
RETURNS TABLE (
    id           bigint,
    driver_id    uuid,
    display_name text,
    car_number   int,
    lobby_number int,
    lap          int,
    lap_ms       int,
    fuel_pct     real,
    mode         text,
    recorded_at  timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT l.id, l.driver_id, d.display_name, en.car_number, l.lobby_number,
           l.lap, l.lap_ms, l.fuel_pct, l.mode, l.recorded_at
      FROM live_laps l
      JOIN drivers d ON d.id = l.driver_id
      LEFT JOIN entries en ON en.event_id = l.event_id
            AND EXISTS (SELECT 1 FROM entry_drivers ed
                         WHERE ed.entry_id = en.id AND ed.driver_id = l.driver_id)
     WHERE l.event_id = p_event_id
       AND (p_mode     IS NULL OR l.mode = p_mode)
       AND (p_after_id IS NULL OR l.id > p_after_id)
     ORDER BY l.id;
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_feed(uuid, text, bigint) TO anon, authenticated;
