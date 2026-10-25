-- ============================================================
-- 149 Live timing
--
-- Each driver's device reports only its own car; the server assembles
-- the field. One machine cannot see sixteen cars across eight splits,
-- but it never has to, and this is identical whether eight hosts report
-- or the whole grid does.
--
-- Three objects:
--
--   live_positions       one row per car per event, upserted, no history
--   live_timing_tokens   what a reporter authenticates with
--   live_beacon()        the only way a row is written
--
-- Deliberately NOT stored: anything derived. Gaps, running order and
-- distance along the lap are all computed by the page from x/z and the
-- track centreline, so the thing shipped to a hundred phones stays a
-- dumb relay with no state and nothing to get out of sync.
-- ============================================================

-- ---- the live field ----
CREATE TABLE IF NOT EXISTS live_positions (
    event_id     uuid NOT NULL REFERENCES events(id)  ON DELETE CASCADE,
    driver_id    uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    lobby_number int,
    lap          int     NOT NULL DEFAULT 0,
    lap_ms       int,
    last_lap_ms  int,
    best_lap_ms  int,
    x            real,
    z            real,
    speed_kph    int,
    on_track     boolean NOT NULL DEFAULT true,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, driver_id)
);

-- The page always asks for one event's field at a time.
CREATE INDEX IF NOT EXISTS live_positions_event_idx ON live_positions (event_id);

ALTER TABLE live_positions ENABLE ROW LEVEL SECURITY;

-- Public read: live timing is a spectator feature. Writes are closed to
-- everyone, including authenticated drivers, because the only legitimate
-- writer is live_beacon() below, which is SECURITY DEFINER. That means a
-- driver cannot move another driver's car, or their own, by calling the
-- API directly with their own token.
DROP POLICY IF EXISTS "public read live positions" ON live_positions;
CREATE POLICY "public read live positions" ON live_positions
    FOR SELECT TO anon, authenticated USING (true);


-- ---- reporter credentials ----
-- Per driver rather than per event. A QR code before every race is fine
-- for eight hosts and miserable for a grid, so the token is long-lived
-- and the beacon resolves which event is live at the time it arrives.
CREATE TABLE IF NOT EXISTS live_timing_tokens (
    token       text PRIMARY KEY,
    driver_id   uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    created_at  timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz,
    revoked_at  timestamptz
);

CREATE INDEX IF NOT EXISTS live_timing_tokens_driver_idx
    ON live_timing_tokens (driver_id) WHERE revoked_at IS NULL;

ALTER TABLE live_timing_tokens ENABLE ROW LEVEL SECURITY;
-- No policies at all: nobody reads or writes this table through the API.
-- It is touched only by the SECURITY DEFINER functions below, so a token
-- cannot be listed, guessed at scale, or stolen through PostgREST.


-- ============================================================
-- Issuing a token. Called from the driver's own portal.
-- ============================================================
CREATE OR REPLACE FUNCTION public.live_timing_token_issue()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_driver_id uuid;
    v_token     text;
BEGIN
    SELECT id INTO v_driver_id FROM drivers WHERE user_id = auth.uid();
    IF v_driver_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'No driver profile for this account.');
    END IF;

    -- One active token per driver. Re-pairing replaces the old one, so a
    -- phone that was lost or reinstalled stops reporting the moment the
    -- driver pairs again.
    UPDATE live_timing_tokens
       SET revoked_at = now()
     WHERE driver_id = v_driver_id AND revoked_at IS NULL;

    -- Two UUIDs rather than gen_random_bytes: that is pgcrypto, which
    -- Supabase installs into the `extensions` schema, and this function
    -- pins search_path to public so it would not resolve. gen_random_uuid
    -- is built in. Two of them give 64 hex characters and well over 200
    -- bits of randomness, which is ample for a bearer token.
    v_token := replace(gen_random_uuid()::text, '-', '')
            || replace(gen_random_uuid()::text, '-', '');
    INSERT INTO live_timing_tokens (token, driver_id) VALUES (v_token, v_driver_id);

    RETURN jsonb_build_object('ok', true, 'token', v_token);
END;
$$;


CREATE OR REPLACE FUNCTION public.live_timing_token_revoke()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_driver_id uuid;
BEGIN
    SELECT id INTO v_driver_id FROM drivers WHERE user_id = auth.uid();
    IF v_driver_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'No driver profile for this account.');
    END IF;

    UPDATE live_timing_tokens
       SET revoked_at = now()
     WHERE driver_id = v_driver_id AND revoked_at IS NULL;

    DELETE FROM live_positions
     WHERE driver_id = v_driver_id
       AND event_id IN (SELECT id FROM events WHERE status <> 'completed');

    RETURN jsonb_build_object('ok', true);
END;
$$;


-- ============================================================
-- The beacon. The only writer of live_positions.
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
    v_lobby     int;
    v_last      timestamptz;
BEGIN
    SELECT driver_id INTO v_driver_id
      FROM live_timing_tokens
     WHERE token = p_token AND revoked_at IS NULL;

    IF v_driver_id IS NULL THEN
        -- Deliberately vague: a reporter has no business knowing whether
        -- a token is wrong or merely revoked.
        RETURN jsonb_build_object('ok', false, 'error', 'Not paired.');
    END IF;

    -- Which race is on. A reporter left running on a Tuesday writes
    -- nothing rather than inventing a session.
    SELECT e.id INTO v_event_id
      FROM events e
     WHERE e.status <> 'completed'
       AND e.status <> 'cancelled'
       AND now() BETWEEN e.starts_at - interval '2 hours'
                     AND e.starts_at + (e.duration_hours * interval '1 hour') + interval '2 hours'
     ORDER BY e.starts_at
     LIMIT 1;

    IF v_event_id IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'reporting', false, 'reason', 'No race in progress.');
    END IF;

    -- Only drivers actually entered for the round appear on the map.
    SELECT en.lobby_number INTO v_lobby
      FROM entries en
      JOIN entry_drivers ed ON ed.entry_id = en.id
     WHERE en.event_id = v_event_id AND ed.driver_id = v_driver_id
     LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', true, 'reporting', false, 'reason', 'Not entered for this round.');
    END IF;

    -- Rate limit. A client sending faster than this is buggy or hostile;
    -- either way the extra beacons are dropped rather than served.
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
        -- A host who rejoins the lobby can have their in-game lap counter
        -- reset. Going backwards is always wrong, so take the highest lap
        -- seen rather than whatever the last packet claimed.
        lap          = GREATEST(lp.lap, COALESCE(EXCLUDED.lap, 0)),
        lap_ms       = EXCLUDED.lap_ms,
        last_lap_ms  = COALESCE(EXCLUDED.last_lap_ms, lp.last_lap_ms),
        -- Best lap only ever improves, whatever a fresh session reports.
        best_lap_ms  = LEAST(COALESCE(EXCLUDED.best_lap_ms, lp.best_lap_ms),
                             COALESCE(lp.best_lap_ms, EXCLUDED.best_lap_ms)),
        x            = EXCLUDED.x,
        z            = EXCLUDED.z,
        speed_kph    = EXCLUDED.speed_kph,
        on_track     = EXCLUDED.on_track,
        updated_at   = now();

    UPDATE live_timing_tokens SET last_used_at = now() WHERE token = p_token;

    -- Tells the reporter how often to come back: slow right down when the
    -- car is sitting in menus or the pre-race lobby, which is where most
    -- of the idle traffic would otherwise come from.
    RETURN jsonb_build_object(
        'ok', true,
        'reporting', true,
        'next_ms', CASE WHEN COALESCE(p_on_track, true) THEN 3000 ELSE 15000 END
    );
END;
$$;


-- anon as well as authenticated: the reporter is a device holding a
-- token, not a logged-in session, and the token is the credential.
GRANT EXECUTE ON FUNCTION public.live_beacon(text, int, int, int, int, real, real, int, boolean)
    TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.live_timing_token_issue()   TO authenticated;
GRANT EXECUTE ON FUNCTION public.live_timing_token_revoke()  TO authenticated;


-- ============================================================
-- What the live page reads. One call, one event, no joins client side.
-- ============================================================
CREATE OR REPLACE FUNCTION public.live_field(p_event_id uuid DEFAULT NULL)
RETURNS TABLE (
    event_id     uuid,
    event_name   text,
    round        int,
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
    age_ms       int
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH target AS (
        SELECT COALESCE(
            p_event_id,
            (SELECT e.id FROM events e
              WHERE e.status <> 'completed' AND e.status <> 'cancelled'
                AND now() BETWEEN e.starts_at - interval '2 hours'
                              AND e.starts_at + (e.duration_hours * interval '1 hour') + interval '2 hours'
              ORDER BY e.starts_at LIMIT 1)
        ) AS id
    )
    SELECT
        e.id, e.name, e.round,
        d.id, d.display_name, en.car_number, t.name,
        lp.lobby_number, lp.lap, lp.lap_ms, lp.last_lap_ms, lp.best_lap_ms,
        lp.x, lp.z, lp.speed_kph, lp.on_track,
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


-- ============================================================
-- Clear a round's live field once it is done. Safe to call repeatedly.
-- ============================================================
CREATE OR REPLACE FUNCTION public.live_positions_clear(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n int;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
    END IF;
    DELETE FROM live_positions WHERE event_id = p_event_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'cleared', v_n);
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_positions_clear(uuid) TO authenticated;
