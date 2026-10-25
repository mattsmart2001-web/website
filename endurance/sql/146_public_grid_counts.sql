-- ============================================================
-- 146 Public grid counts per round
--
-- Feeds "118 entered · 99 started" onto the public results index, so a
-- thin split is explained by the page rather than left as a mystery.
--
-- Aggregates only. No driver is named and nothing here says who missed a
-- race, which is the point: the round page states a fact about the race,
-- and who was absent stays between the driver and admin.
--
-- Granted to anon because the results index is a public page. The
-- underlying entries / results tables already carry public read policies
-- from 01_schema, so this exposes nothing new; it exists so the page can
-- ask for six numbers instead of fetching every entry and result row and
-- counting them in the browser, where PostgREST's row cap would quietly
-- truncate the answer as the season grows.
-- ============================================================

CREATE OR REPLACE FUNCTION public.event_grid_counts(p_season_id uuid DEFAULT NULL)
RETURNS TABLE (
    event_id uuid,
    entered  int,
    started  int
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH ev AS (
        SELECT e.id
        FROM   events e
        WHERE  e.status <> 'cancelled'
          AND  (p_season_id IS NULL OR e.season_id = p_season_id)
    )
    SELECT
        ev.id,
        (SELECT COUNT(DISTINCT ed.driver_id)::int
           FROM entries en
           JOIN entry_drivers ed ON ed.entry_id = en.id
          WHERE en.event_id = ev.id),
        -- Anything other than a DNS means they took the start, including a
        -- DNF: retiring from a race you started is not a no-show.
        (SELECT COUNT(DISTINCT rd.driver_id)::int
           FROM results r
           JOIN result_drivers rd ON rd.result_id = r.id
          WHERE r.event_id = ev.id
            AND COALESCE(rd.status, 'classified') <> 'dns')
    FROM ev;
$$;

GRANT EXECUTE ON FUNCTION public.event_grid_counts(uuid) TO anon, authenticated;
