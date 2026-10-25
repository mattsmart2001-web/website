-- ============================================================
-- 156 The track outline survives a refresh
--
-- The map was built from positions the page had seen itself, so a refresh
-- wiped it and a viewer arriving an hour into a race got an empty box
-- until cars had been round again. Not much use to a spectator, which is
-- who the page is for.
--
-- The outline is now captured server side, as one ordered path per round.
--
-- Ordered, not a point cloud, and that is the whole design. A cloud of
-- everyone's positions cannot be drawn as a line, because neighbouring
-- points in a mixed cloud are not neighbouring in time. So one car at a
-- time is the shape source and only its positions are appended, which
-- gives a path that joins up.
--
-- If that car stops reporting, the next beacon takes over the job. The
-- handover leaves a jump in the path, which the page already breaks rather
-- than drawing a line across the infield.
--
-- Costs one extra insert per 1.5 seconds for the whole event, not per car,
-- and stops once a few laps are captured.
-- ============================================================

ALTER TABLE events ADD COLUMN IF NOT EXISTS shape_driver_id uuid REFERENCES drivers(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS live_track_path (
    event_id uuid   NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    seq      bigint NOT NULL,
    x        real,
    y        real,
    z        real,
    PRIMARY KEY (event_id, seq)
);

ALTER TABLE live_track_path ENABLE ROW LEVEL SECURITY;

-- Public read, no public write. Written only by live_beacon, which is
-- SECURITY DEFINER, exactly as live_positions is.
DROP POLICY IF EXISTS "public read track path" ON live_track_path;
CREATE POLICY "public read track path" ON live_track_path
    FOR SELECT TO anon, authenticated USING (true);


-- How many points are enough. At 1.5s a car covers a Nordschleife lap in
-- roughly 320, so this is several laps of any circuit and bounded whatever
-- happens.
CREATE OR REPLACE FUNCTION public.live_track_path_max()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 2000; $$;


CREATE OR REPLACE FUNCTION public.live_track(p_event_id uuid DEFAULT NULL)
RETURNS TABLE (seq bigint, x real, y real, z real)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT p.seq, p.x, p.y, p.z
    FROM   live_track_path p
    WHERE  p.event_id = COALESCE(p_event_id, (SELECT event_id FROM live_active_event()))
    ORDER  BY p.seq;
$$;

GRANT EXECUTE ON FUNCTION public.live_track(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.live_track_path_max() TO anon, authenticated;


-- Clearing a test window should clear the shape it captured too, or the
-- next test on that round starts with yesterday's outline.
CREATE OR REPLACE FUNCTION public.live_test_close(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cleared int;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
    END IF;

    UPDATE events SET live_test_until = NULL, shape_driver_id = NULL WHERE id = p_event_id;
    DELETE FROM live_positions  WHERE event_id = p_event_id;
    GET DIAGNOSTICS v_cleared = ROW_COUNT;
    DELETE FROM live_track_path WHERE event_id = p_event_id;

    RETURN jsonb_build_object('ok', true, 'cleared', v_cleared);
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_test_close(uuid) TO authenticated;


-- ============================================================
-- The beacon appends to the path when this car is the shape source.
-- ============================================================
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
    v_shape     uuid;
    v_shape_ok  boolean;
    v_points    int;
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

    -- ---- the track outline ----
    IF COALESCE(p_on_track, true) AND p_x IS NOT NULL AND p_z IS NOT NULL THEN
        SELECT shape_driver_id INTO v_shape FROM events WHERE id = v_event_id;

        -- Take the job if nobody holds it, or if whoever does has gone
        -- quiet. Two minutes, because a pit stop should not cost the path
        -- its continuity.
        IF v_shape IS NULL OR NOT EXISTS (
               SELECT 1 FROM live_positions
                WHERE event_id = v_event_id AND driver_id = v_shape
                  AND updated_at > now() - interval '2 minutes'
           ) THEN
            UPDATE events SET shape_driver_id = v_driver_id WHERE id = v_event_id;
            v_shape := v_driver_id;
        END IF;

        v_shape_ok := (v_shape = v_driver_id);

        IF v_shape_ok THEN
            SELECT COUNT(*) INTO v_points FROM live_track_path WHERE event_id = v_event_id;
            IF v_points < public.live_track_path_max() THEN
                INSERT INTO live_track_path (event_id, seq, x, y, z)
                SELECT v_event_id,
                       COALESCE((SELECT MAX(seq) FROM live_track_path WHERE event_id = v_event_id), 0) + 1,
                       p_x, p_y, p_z;
            END IF;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'reporting', true,
        'test', COALESCE(v_is_test, false),
        'no_entry', NOT v_entered,
        -- Tells a driver their car is the one drawing the track, which is
        -- worth knowing and costs nothing to say.
        'shaping', COALESCE(v_shape_ok, false),
        'next_ms', public.live_beacon_interval_ms(p_on_track)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_beacon(text, int, int, int, int, real, real, int, boolean, real, int, real)
    TO anon, authenticated;
