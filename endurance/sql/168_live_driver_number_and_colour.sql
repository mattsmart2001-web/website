-- ============================================================
-- 168 A driver's own number, and their colours, on the live map
--
-- The map labels each car with the ENTRY's number, which 134 deliberately
-- makes one number per team, Le Mans style, taken from one driver's career
-- number with the team leader as the default. That is right during a race,
-- where a team fields one car and only one of its drivers is on track at a
-- time, and wrong during practice, where both teammates can be circulating
-- at once and both show the leader's number.
--
-- So the field now carries the driver's own career number as well, and the
-- page picks: the car's number during a race, because that is what is on the
-- car and on every other timing screen, and the driver's own number
-- otherwise, because in practice there is no shared car to speak of.
--
-- Also carries the team and its manufacturer's colour, so cars can be drawn
-- in their team's colours rather than by split.
--
-- One honest limit: a team has no colour of its own. Only manufacturers do,
-- and several teams can run the same manufacturer, so those teams share a
-- colour. Giving teams their own colour would be a column, an admin control
-- and sixty drivers' worth of choices, which is a bigger change than this
-- and worth doing only if the sharing actually bothers anyone.
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
    ORDER BY lp.lobby_number, lp.lap DESC;
$$;

GRANT EXECUTE ON FUNCTION public.live_field(uuid) TO anon, authenticated;
