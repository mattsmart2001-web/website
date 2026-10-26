-- ============================================================
-- 171 Order the list by what the session is about
--
-- Reported as "it chops and changes a lot". It does, and the reason is
-- that the order is laps completed, in a practice session, where laps
-- completed is not a ranking of anything. A driver who joined an hour ago
-- has thirty of them and one who joined at the last corner has one, so the
-- list rearranges itself every time anybody crosses a line, and the
-- resulting order tells a viewer nothing.
--
-- I first assumed the cause was the missing tie-break: cars on the same lap
-- had nothing to separate them, so the database could return them in any
-- order it liked. That is true, and it is not what is happening. Asked
-- twenty times with twenty cars tied on the same lap and every row
-- rewritten between each call, Postgres returned the identical order
-- twenty times out of twenty. The tie-break is worth having and is here,
-- but it was not the fault.
--
-- So: a race is ordered by laps completed and then by how far into the
-- current lap, and practice is ordered by best lap, fastest first, which
-- is what a practice screen is for and which holds still between polls.
-- ============================================================

DROP FUNCTION IF EXISTS public.live_field(uuid);

CREATE FUNCTION public.live_field(p_event_id uuid DEFAULT NULL)
RETURNS TABLE (
    event_id      uuid,
    event_name    text,
    round         int,
    is_test       boolean,
    mode          text,
    driver_id     uuid,
    display_name  text,
    car_number    int,
    career_number int,
    team_name     text,
    team_id       uuid,
    brand_color   text,
    lobby_number  int,
    lap           int,
    lap_ms        int,
    last_lap_ms   int,
    best_lap_ms   int,
    x             real,
    y             real,
    z             real,
    speed_kph     int,
    on_track      boolean,
    fuel_pct      real,
    laps_in_race  int,
    client        text,
    age_ms        int
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH active AS (SELECT * FROM live_active_event()),
    target AS (
        SELECT COALESCE(p_event_id, (SELECT a.event_id FROM active a)) AS id,
               COALESCE((SELECT a.is_test FROM active a), false)       AS is_test,
               COALESCE((SELECT a.mode    FROM active a), 'race')      AS mode
    )
    SELECT
        e.id, e.name, e.round, target.is_test, target.mode,
        d.id, d.display_name, en.car_number, d.career_number,
        t.name, t.id, m.brand_color,
        lp.lobby_number, lp.lap, lp.lap_ms, lp.last_lap_ms, lp.best_lap_ms,
        lp.x, lp.y, lp.z, lp.speed_kph, lp.on_track, lp.fuel_pct, lp.laps_in_race,
        lp.client,
        (EXTRACT(EPOCH FROM (now() - lp.updated_at)) * 1000)::int
    FROM   live_positions lp
    JOIN   target        ON target.id = lp.event_id
    JOIN   events  e     ON e.id = lp.event_id
    JOIN   drivers d     ON d.id = lp.driver_id
    LEFT   JOIN entries en ON en.event_id = lp.event_id
            AND EXISTS (SELECT 1 FROM entry_drivers ed
                         WHERE ed.entry_id = en.id AND ed.driver_id = lp.driver_id)
    LEFT   JOIN teams t  ON t.id = d.current_team_id
    -- The manufacturer the driver is actually running, which is the team's
    -- unless they have one of their own set.
    LEFT   JOIN manufacturers m
            ON m.id = COALESCE(d.current_manufacturer_id, t.manufacturer_id)
    -- Ordered by whatever the session is actually about.
    --
    -- In a race that is laps completed, then how far into the current lap,
    -- which is a decent guess at running order when the cars are going at
    -- similar speeds and is honest about being a guess. A real one needs
    -- distance round the lap, which has only just become possible: since
    -- 169 the stored outline starts at the start/finish line, so a car's
    -- nearest point on it IS its progress. Worth doing properly, and best
    -- done by the beacon once per car rather than by every viewer's poll.
    --
    -- In practice it is the best lap, because laps completed in a practice
    -- session is not a ranking of anything. Someone who joined an hour ago
    -- has thirty and someone who joined at the last corner has one, and the
    -- order rearranges itself every time anybody crosses the line. Fastest
    -- first is what a practice screen is for, and it holds still.
    --
    -- Drivers with no lap time yet go to the bottom rather than the top.
    -- driver_id last so that nothing can tie.
    ORDER BY lp.lobby_number,
             CASE WHEN target.mode =  'race' THEN lp.lap         END DESC NULLS LAST,
             CASE WHEN target.mode =  'race' THEN lp.lap_ms      END DESC NULLS LAST,
             CASE WHEN target.mode <> 'race' THEN lp.best_lap_ms END ASC  NULLS LAST,
             lp.driver_id;
$$;

GRANT EXECUTE ON FUNCTION public.live_field(uuid) TO anon, authenticated;
