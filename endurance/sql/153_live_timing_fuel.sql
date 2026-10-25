-- ============================================================
-- 153 Fuel on the live timing field
--
-- The single most useful number on an endurance timing screen, and the
-- one nobody else showing GT7 has. "Car 23, four laps of fuel left" says
-- more about how a six hour race is going than any lap time does.
--
-- Stored as a percentage rather than litres. GT7 reports a level and a
-- capacity, and capacity varies by car, so a percentage is the only thing
-- comparable across a grid of different machinery. The page can turn it
-- into laps remaining from the driver's own consumption, which is a
-- better estimate than anything computed here.
--
-- Also carries laps_in_race, so a round with a lap target can show
-- progress rather than just a lap count climbing.
--
-- Both are nullable and both are additions, so an older connector that
-- does not send them keeps working and simply shows nothing.
-- ============================================================

ALTER TABLE live_positions ADD COLUMN IF NOT EXISTS fuel_pct     real;
ALTER TABLE live_positions ADD COLUMN IF NOT EXISTS laps_in_race int;


-- Replace rather than overload. Two signatures that can both accept the
-- same nine named parameters make the call ambiguous, and PostgREST sends
-- named parameters, so an older connector would fail outright instead of
-- degrading. One function with defaults for the new fields means a 3.0
-- connector keeps working untouched.
DROP FUNCTION IF EXISTS public.live_beacon(text, int, int, int, int, real, real, int, boolean);

CREATE OR REPLACE FUNCTION public.live_beacon(
    p_token        text,
    p_lap          int     DEFAULT NULL,
    p_lap_ms       int     DEFAULT NULL,
    p_last_lap_ms  int     DEFAULT NULL,
    p_best_lap_ms  int     DEFAULT NULL,
    p_x            real    DEFAULT NULL,
    p_z            real    DEFAULT NULL,
    p_speed_kph    int     DEFAULT NULL,
    p_on_track     boolean DEFAULT true,
    p_fuel_pct     real    DEFAULT NULL,
    p_laps_in_race int     DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_driver_id uuid;
    v_event_id  uuid;
    v_is_test   boolean;
    v_lobby     int;
    v_entered   boolean;
    v_last      timestamptz;
BEGIN
    SELECT driver_id INTO v_driver_id
      FROM live_timing_tokens
     WHERE token = p_token AND revoked_at IS NULL;

    IF v_driver_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not paired.');
    END IF;

    SELECT event_id, is_test INTO v_event_id, v_is_test FROM live_active_event();

    IF v_event_id IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'reporting', false, 'reason', 'No race in progress.');
    END IF;

    SELECT en.lobby_number INTO v_lobby
      FROM entries en
      JOIN entry_drivers ed ON ed.entry_id = en.id
     WHERE en.event_id = v_event_id AND ed.driver_id = v_driver_id
     LIMIT 1;
    v_entered := FOUND;

    IF NOT v_entered AND NOT COALESCE(v_is_test, false) THEN
        RETURN jsonb_build_object('ok', true, 'reporting', false, 'reason', 'Not entered for this round.');
    END IF;

    SELECT updated_at INTO v_last
      FROM live_positions
     WHERE event_id = v_event_id AND driver_id = v_driver_id;

    IF v_last IS NOT NULL AND now() - v_last < interval '1.5 seconds' THEN
        RETURN jsonb_build_object('ok', true, 'reporting', true, 'throttled', true);
    END IF;

    INSERT INTO live_positions AS lp (
        event_id, driver_id, lobby_number, lap, lap_ms, last_lap_ms,
        best_lap_ms, x, z, speed_kph, on_track, fuel_pct, laps_in_race, updated_at
    ) VALUES (
        v_event_id, v_driver_id, v_lobby, COALESCE(p_lap, 0), p_lap_ms, p_last_lap_ms,
        p_best_lap_ms, p_x, p_z, p_speed_kph, COALESCE(p_on_track, true),
        p_fuel_pct, p_laps_in_race, now()
    )
    ON CONFLICT (event_id, driver_id) DO UPDATE SET
        lobby_number = COALESCE(EXCLUDED.lobby_number, lp.lobby_number),
        lap          = GREATEST(lp.lap, COALESCE(EXCLUDED.lap, 0)),
        lap_ms       = EXCLUDED.lap_ms,
        last_lap_ms  = COALESCE(EXCLUDED.last_lap_ms, lp.last_lap_ms),
        best_lap_ms  = LEAST(COALESCE(EXCLUDED.best_lap_ms, lp.best_lap_ms),
                             COALESCE(lp.best_lap_ms, EXCLUDED.best_lap_ms)),
        x            = EXCLUDED.x,
        z            = EXCLUDED.z,
        speed_kph    = EXCLUDED.speed_kph,
        on_track     = EXCLUDED.on_track,
        -- Keep the last known figure when a beacon omits it, so an older
        -- connector mixed into the field does not blank a car's fuel.
        fuel_pct     = COALESCE(EXCLUDED.fuel_pct, lp.fuel_pct),
        laps_in_race = COALESCE(EXCLUDED.laps_in_race, lp.laps_in_race),
        updated_at   = now();

    UPDATE live_timing_tokens SET last_used_at = now() WHERE token = p_token;

    RETURN jsonb_build_object(
        'ok', true,
        'reporting', true,
        'test', COALESCE(v_is_test, false),
        'no_entry', NOT v_entered,
        'next_ms', CASE WHEN COALESCE(p_on_track, true) THEN 3000 ELSE 15000 END
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_beacon(text, int, int, int, int, real, real, int, boolean, real, int)
    TO anon, authenticated;


DROP FUNCTION IF EXISTS public.live_field(uuid);

CREATE OR REPLACE FUNCTION public.live_field(p_event_id uuid DEFAULT NULL)
RETURNS TABLE (
    event_id     uuid,
    event_name   text,
    round        int,
    is_test      boolean,
    driver_id    uuid,
    display_name text,
    car_number   int,
    team_name    text,
    lobby_number int,
    lap          int,
    lap_ms       int,
    last_lap_ms  int,
    best_lap_ms  int,
    x            real,
    z            real,
    speed_kph    int,
    on_track     boolean,
    fuel_pct     real,
    laps_in_race int,
    age_ms       int
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH active AS (SELECT * FROM live_active_event()),
    target AS (
        SELECT COALESCE(p_event_id, (SELECT a.event_id FROM active a)) AS id,
               COALESCE((SELECT a.is_test FROM active a), false)       AS is_test
    )
    SELECT
        e.id, e.name, e.round, target.is_test,
        d.id, d.display_name, en.car_number, t.name,
        lp.lobby_number, lp.lap, lp.lap_ms, lp.last_lap_ms, lp.best_lap_ms,
        lp.x, lp.z, lp.speed_kph, lp.on_track, lp.fuel_pct, lp.laps_in_race,
        (EXTRACT(EPOCH FROM (now() - lp.updated_at)) * 1000)::int
    FROM   live_positions lp
    JOIN   target        ON target.id = lp.event_id
    JOIN   events  e     ON e.id = lp.event_id
    JOIN   drivers d     ON d.id = lp.driver_id
    LEFT   JOIN entries en ON en.event_id = lp.event_id
            AND EXISTS (SELECT 1 FROM entry_drivers ed
                         WHERE ed.entry_id = en.id AND ed.driver_id = lp.driver_id)
    LEFT   JOIN teams t  ON t.id = d.current_team_id
    ORDER BY lp.lobby_number, lp.lap DESC;
$$;

GRANT EXECUTE ON FUNCTION public.live_field(uuid) TO anon, authenticated;
