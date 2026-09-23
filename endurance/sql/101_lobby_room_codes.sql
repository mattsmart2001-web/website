-- ============================================================
-- 101 Lobby room codes in the driver portal
--
-- Not every driver uses Discord, so the lobby ID/room code a host
-- creates in GT7 currently only reaches them via the split's Discord
-- channel. This adds an in-portal place for the host to post it,
-- readable by everyone in that split, live via Realtime.
--
-- Only appears/writable once split notifications have gone out
-- (events.splits_notified_at is set) — splits are considered final at
-- that point, so posting a room code before then would risk it going
-- stale if the split changes.
-- ============================================================

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS splits_notified_at timestamptz;

CREATE TABLE IF NOT EXISTS lobby_room_codes (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id     uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    lobby_number int  NOT NULL,
    room_code    text,
    updated_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, lobby_number)
);

ALTER TABLE lobby_room_codes ENABLE ROW LEVEL SECURITY;

-- Any driver with an entry in that event+lobby can read the room code.
CREATE POLICY "drivers in the lobby can read the room code" ON lobby_room_codes
    FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM   entries en
            JOIN   entry_drivers ed ON ed.entry_id = en.id
            JOIN   drivers d        ON d.id = ed.driver_id
            WHERE  en.event_id     = lobby_room_codes.event_id
              AND  en.lobby_number = lobby_room_codes.lobby_number
              AND  d.user_id       = auth.uid()
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );

-- Only that split's assigned host (or an admin) can post/update the room
-- code, and only once split notifications have actually gone out.
CREATE POLICY "the lobby host can set the room code" ON lobby_room_codes
    FOR INSERT TO authenticated
    WITH CHECK (
        (
            EXISTS (
                SELECT 1
                FROM   entries en
                JOIN   drivers d ON d.id = en.host_driver_id
                WHERE  en.event_id     = lobby_room_codes.event_id
                  AND  en.lobby_number = lobby_room_codes.lobby_number
                  AND  d.user_id       = auth.uid()
            )
            AND EXISTS (
                SELECT 1 FROM events ev
                WHERE ev.id = lobby_room_codes.event_id AND ev.splits_notified_at IS NOT NULL
            )
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );

CREATE POLICY "the lobby host can update the room code" ON lobby_room_codes
    FOR UPDATE TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM   entries en
            JOIN   drivers d ON d.id = en.host_driver_id
            WHERE  en.event_id     = lobby_room_codes.event_id
              AND  en.lobby_number = lobby_room_codes.lobby_number
              AND  d.user_id       = auth.uid()
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    )
    WITH CHECK (
        (
            EXISTS (
                SELECT 1
                FROM   entries en
                JOIN   drivers d ON d.id = en.host_driver_id
                WHERE  en.event_id     = lobby_room_codes.event_id
                  AND  en.lobby_number = lobby_room_codes.lobby_number
                  AND  d.user_id       = auth.uid()
            )
            AND EXISTS (
                SELECT 1 FROM events ev
                WHERE ev.id = lobby_room_codes.event_id AND ev.splits_notified_at IS NOT NULL
            )
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );

CREATE POLICY "admins delete room codes" ON lobby_room_codes
    FOR DELETE TO authenticated
    USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

DO $$ BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.lobby_room_codes; EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- ============================================================
-- notify_lobby_assignments now stamps splits_notified_at, marking
-- splits final and unlocking the room-code card in the portal.
-- ============================================================
CREATE OR REPLACE FUNCTION notify_lobby_assignments(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    event_row events%ROWTYPE;
    prior_event_id uuid;
    inserted_count int;
    host_count int;
    event_when text;
    v_settings_text text;
    v_quali_text text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT * INTO event_row FROM public.events WHERE id = p_event_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Event not found.');
    END IF;

    -- Prior round in this season — the event with the largest round
    -- number that is still less than this one.
    SELECT id INTO prior_event_id
    FROM   public.events
    WHERE  season_id  = event_row.season_id
      AND  round      < event_row.round
    ORDER  BY round DESC
    LIMIT  1;

    event_when := COALESCE(
        to_char(event_row.starts_at AT TIME ZONE 'UTC', 'FMDay FMDD FMMonth YYYY "at" HH24:MI "UTC"'),
        'TBC'
    );

    WITH prev_lobby AS (
        SELECT ed.driver_id, en.lobby_number AS prev_lobby_number
        FROM   public.entries en
        JOIN   public.entry_drivers ed ON ed.entry_id = en.id
        WHERE  en.event_id     = prior_event_id
          AND  en.lobby_number IS NOT NULL
    ),
    driver_lobby AS (
        SELECT DISTINCT
            ed.driver_id,
            en.lobby_number,
            en.car_number,
            t.name AS team_name,
            pl.prev_lobby_number
        FROM   public.entries en
        JOIN   public.entry_drivers ed ON ed.entry_id = en.id
        LEFT   JOIN public.teams t     ON t.id = en.team_id
        LEFT   JOIN prev_lobby pl      ON pl.driver_id = ed.driver_id
        WHERE  en.event_id     = p_event_id
          AND  en.lobby_number IS NOT NULL
          AND  en.status       = 'confirmed'
    )
    INSERT INTO public.driver_contact_messages
        (driver_id, user_id, subject, message, status, is_broadcast, broadcast_by, event_id)
    SELECT
        dl.driver_id,
        d.user_id,
        CASE
            WHEN dl.prev_lobby_number IS NULL THEN
                'Split Assignment · ' || event_row.name
            WHEN dl.lobby_number < dl.prev_lobby_number THEN
                'Promoted to Split ' || dl.lobby_number || ' · ' || event_row.name
            WHEN dl.lobby_number > dl.prev_lobby_number THEN
                'Moved to Split ' || dl.lobby_number || ' · ' || event_row.name
            ELSE
                'Staying in Split ' || dl.lobby_number || ' · ' || event_row.name
        END,
        format(
            E'%s%s\n\nRace: %s\nDate: %s%s%sRestart rule: if any driver disconnects within the first lap, a restart may be called.\n\nCheck your portal and Discord ahead of the race.',
            CASE
                WHEN dl.prev_lobby_number IS NULL THEN
                    'You''ve been assigned to Split ' || dl.lobby_number || ' for ' || event_row.name || '.'
                WHEN dl.lobby_number < dl.prev_lobby_number THEN
                    'Promoted. You''ve moved up from Split ' || dl.prev_lobby_number ||
                    ' to Split ' || dl.lobby_number || ' for ' || event_row.name ||
                    ' on the back of last round''s form. Tougher field, but you''ve earned it.'
                WHEN dl.lobby_number > dl.prev_lobby_number THEN
                    'You''ve been moved from Split ' || dl.prev_lobby_number ||
                    ' to Split ' || dl.lobby_number || ' for ' || event_row.name ||
                    '. Fresh shot to rebuild and climb back up the order.'
                ELSE
                    'You''re staying in Split ' || dl.lobby_number || ' for ' || event_row.name ||
                    '. Same field, same fight.'
            END,
            CASE WHEN dl.team_name IS NOT NULL
                 THEN E'\nTeam: ' || dl.team_name
                 ELSE '' END,
            event_row.name,
            event_when,
            CASE WHEN event_row.circuit_name IS NOT NULL
                 THEN E'\nCircuit: ' || event_row.circuit_name
                 ELSE '' END,
            E'\n\n'
        ),
        'in_progress',
        true,
        auth.uid(),
        p_event_id
    FROM   driver_lobby dl
    JOIN   public.drivers d ON d.id = dl.driver_id;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;

    -- Build the race-settings and qualifying blocks once for this event —
    -- same fields the host email already sends, formatted as plain text.
    SELECT COALESCE(string_agg(line, E'\n'), '') INTO v_settings_text
    FROM (
        SELECT 'Weather: ' || event_row.weather AS line WHERE event_row.weather IS NOT NULL
        UNION ALL SELECT 'Time of Day: ' || event_row.time_of_day WHERE event_row.time_of_day IS NOT NULL
        UNION ALL SELECT 'Tyre Wear: ' || event_row.tyre_wear WHERE event_row.tyre_wear IS NOT NULL
        UNION ALL SELECT 'Fuel Consumption: ' || event_row.fuel_consumption WHERE event_row.fuel_consumption IS NOT NULL
        UNION ALL SELECT 'Time Multiplier: ' || event_row.time_multiplier WHERE event_row.time_multiplier IS NOT NULL
        UNION ALL SELECT 'Damage: ' || initcap(event_row.damage_level) WHERE event_row.damage_level IS NOT NULL
        UNION ALL SELECT 'Slipstream: ' || initcap(event_row.slipstream) WHERE event_row.slipstream IS NOT NULL
        UNION ALL SELECT 'Balance of Performance: Enabled' WHERE event_row.bop_enabled IS TRUE
        UNION ALL SELECT 'Equal Conditions Mode: On' WHERE event_row.equal_conditions_mode IS TRUE
        UNION ALL SELECT 'Shortcut Penalty: On - Weak' WHERE event_row.shortcut_penalty IS TRUE
        UNION ALL SELECT 'Wall Collision Penalty: On - Weak' WHERE event_row.wall_collision_penalty IS TRUE
        UNION ALL SELECT 'Car Collision Penalty: On - Weak' WHERE event_row.car_collision_penalty IS TRUE
        UNION ALL SELECT 'Ghosting: On' WHERE event_row.ghosting IS TRUE
        UNION ALL SELECT 'Pit Lane Cutting Penalty: On' WHERE event_row.pit_lane_cutting_penalty IS TRUE
    ) s;

    v_quali_text := CASE
        WHEN event_row.quali_same_as_race IS NOT FALSE THEN
            'Qualifying uses the same lobby settings as the race. No changes needed between sessions.'
        WHEN event_row.quali_notes IS NOT NULL THEN
            event_row.quali_notes
        ELSE
            'Check the race calendar for qualifying-specific settings.'
    END;

    WITH host_entries AS (
        SELECT en.host_driver_id AS driver_id, en.lobby_number, d.user_id
        FROM   public.entries en
        JOIN   public.drivers d ON d.id = en.host_driver_id
        WHERE  en.event_id = p_event_id
          AND  en.host_driver_id IS NOT NULL
    )
    INSERT INTO public.driver_contact_messages
        (driver_id, user_id, subject, message, status, is_broadcast, broadcast_by, event_id)
    SELECT
        he.driver_id,
        he.user_id,
        'Hosting Instructions · Split ' || he.lobby_number || ' · ' || event_row.name,
        format(
            E'You''re hosting Split %s for %s.\n\nRace: %s\nDate: %s%s\n\nWhat you need to do:\n1. Create a Custom Race lobby in GT7 before the race start time.\n2. Set the lobby settings below for qualifying, then update for the race once qualifying is complete.\n3. Share the lobby password with your split''s drivers via the Discord #split-%s channel — and post the Lobby ID in your portal too, since not everyone in the split may use Discord.\n4. Start the lobby on time — aim to have everyone in the room 15 minutes before the scheduled start.\n5. If any driver disconnects within the first lap, a restart is allowed. Call it in the Discord channel and requeue everyone.\n\nRace Settings:\n%s\n\nQualifying Settings:\n%s\n\nIf you have any problems or cannot host, contact an admin as soon as possible so we can arrange a replacement host.',
            he.lobby_number,
            event_row.name,
            event_row.name,
            event_when,
            CASE WHEN event_row.circuit_name IS NOT NULL
                 THEN E'\nCircuit: ' || event_row.circuit_name
                 ELSE '' END,
            he.lobby_number,
            v_settings_text,
            v_quali_text
        ),
        'in_progress',
        true,
        auth.uid(),
        p_event_id
    FROM host_entries he;

    GET DIAGNOSTICS host_count = ROW_COUNT;

    UPDATE public.events SET splits_notified_at = now() WHERE id = p_event_id;

    RETURN jsonb_build_object('ok', true, 'count', inserted_count, 'host_count', host_count);
END;
$$;

GRANT EXECUTE ON FUNCTION notify_lobby_assignments(uuid) TO authenticated;
