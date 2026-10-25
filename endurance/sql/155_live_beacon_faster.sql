-- ============================================================
-- 155 A faster beacon while a car is on track
--
-- Three seconds between positions is enough to place a car but not enough
-- to draw a smooth line: on a fast section it leaves a point every 170
-- metres, which reads as a sequence of dots rather than a circuit.
--
-- On track goes to 1.5 seconds, which is the floor the rate limit already
-- enforces, so this is as often as the beacon can report without being
-- throttled. That doubles the resolution of the track map.
--
-- The off-track backoff is unchanged at 15 seconds and no-race at 30, so
-- the extra traffic only exists while cars are actually circulating. At a
-- full grid of 120 that is around 80 writes a second during a race, which
-- is comfortable for Postgres on one small table of 120 rows, and nothing
-- at all between rounds.
--
-- If a race ever shows strain, this is the one number to put back up:
-- nothing else depends on it.
-- ============================================================

CREATE OR REPLACE FUNCTION public.live_beacon_interval_ms(p_on_track boolean)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN COALESCE(p_on_track, true) THEN 1500 ELSE 15000 END;
$$;

GRANT EXECUTE ON FUNCTION public.live_beacon_interval_ms(boolean) TO anon, authenticated;


-- Rebuild live_beacon's reply to use it. Everything else is unchanged from
-- 154; only the next_ms line differs.
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
    p_laps_in_race int     DEFAULT NULL,
    p_y            real    DEFAULT NULL
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

    -- Just under the new cadence, so a reporter asked for 1.5s is not
    -- throttled by its own timing jitter.
    IF v_last IS NOT NULL AND now() - v_last < interval '1.2 seconds' THEN
        RETURN jsonb_build_object('ok', true, 'reporting', true, 'throttled', true);
    END IF;

    INSERT INTO live_positions AS lp (
        event_id, driver_id, lobby_number, lap, lap_ms, last_lap_ms,
        best_lap_ms, x, y, z, speed_kph, on_track, fuel_pct, laps_in_race, updated_at
    ) VALUES (
        v_event_id, v_driver_id, v_lobby, COALESCE(p_lap, 0), p_lap_ms, p_last_lap_ms,
        p_best_lap_ms, p_x, p_y, p_z, p_speed_kph, COALESCE(p_on_track, true),
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
        y            = EXCLUDED.y,
        z            = EXCLUDED.z,
        speed_kph    = EXCLUDED.speed_kph,
        on_track     = EXCLUDED.on_track,
        fuel_pct     = COALESCE(EXCLUDED.fuel_pct, lp.fuel_pct),
        laps_in_race = COALESCE(EXCLUDED.laps_in_race, lp.laps_in_race),
        updated_at   = now();

    UPDATE live_timing_tokens SET last_used_at = now() WHERE token = p_token;

    RETURN jsonb_build_object(
        'ok', true,
        'reporting', true,
        'test', COALESCE(v_is_test, false),
        'no_entry', NOT v_entered,
        'next_ms', public.live_beacon_interval_ms(p_on_track)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_beacon(text, int, int, int, int, real, real, int, boolean, real, int, real)
    TO anon, authenticated;
