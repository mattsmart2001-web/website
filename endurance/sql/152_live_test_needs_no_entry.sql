-- ============================================================
-- 152 Testing live timing should not require an entry
--
-- The beacon looks up the driver's entry to find which split they are in,
-- and refuses with "Not entered for this round." when there isn't one.
-- Correct during a race: a driver not on the grid has no business on the
-- live map.
--
-- During an admin test window it is just friction. The person testing is
-- usually the owner, checking the plumbing on a round they are not racing,
-- and adding themselves to an entry list to do it risks leaving a stray
-- entry behind on a real event.
--
-- So in a test window a driver with no entry still reports, with no split.
-- The live page already groups a null lobby under "Unassigned", so this
-- needs nothing on the front end.
--
-- Unchanged for a real race: no entry, no reporting.
-- ============================================================

CREATE OR REPLACE FUNCTION public.live_beacon(
    p_token       text,
    p_lap         int     DEFAULT NULL,
    p_lap_ms      int     DEFAULT NULL,
    p_last_lap_ms int     DEFAULT NULL,
    p_best_lap_ms int     DEFAULT NULL,
    p_x           real    DEFAULT NULL,
    p_z           real    DEFAULT NULL,
    p_speed_kph   int     DEFAULT NULL,
    p_on_track    boolean DEFAULT true
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

    -- A real race needs an entry; a test does not, so the owner can check
    -- the plumbing without putting themselves on a grid they are not racing.
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
        best_lap_ms, x, z, speed_kph, on_track, updated_at
    ) VALUES (
        v_event_id, v_driver_id, v_lobby, COALESCE(p_lap, 0), p_lap_ms, p_last_lap_ms,
        p_best_lap_ms, p_x, p_z, p_speed_kph, COALESCE(p_on_track, true), now()
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
        updated_at   = now();

    UPDATE live_timing_tokens SET last_used_at = now() WHERE token = p_token;

    RETURN jsonb_build_object(
        'ok', true,
        'reporting', true,
        'test', COALESCE(v_is_test, false),
        -- Says so when reporting without an entry, which only a test allows.
        'no_entry', NOT v_entered,
        'next_ms', CASE WHEN COALESCE(p_on_track, true) THEN 3000 ELSE 15000 END
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_beacon(text, int, int, int, int, real, real, int, boolean)
    TO anon, authenticated;
