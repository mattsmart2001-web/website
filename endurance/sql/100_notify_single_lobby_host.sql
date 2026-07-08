-- ============================================================
-- 100 Notify a single manually-assigned lobby host
--
-- Auto-allocate can leave a split with no host (no willing/eligible
-- driver present). This backs a manual "Set Host" action in the admin
-- splits view — sends just the one host their Hosting Instructions
-- portal message, without re-notifying the whole field the way
-- notify_lobby_assignments does. Same message body/content as the
-- host branch of that function.
-- ============================================================

CREATE OR REPLACE FUNCTION notify_single_lobby_host(p_entry_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    entry_row entries%ROWTYPE;
    event_row events%ROWTYPE;
    v_driver_user_id uuid;
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

    SELECT * INTO entry_row FROM public.entries WHERE id = p_entry_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Entry not found.');
    END IF;
    IF entry_row.host_driver_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Entry has no host assigned.');
    END IF;

    SELECT * INTO event_row FROM public.events WHERE id = entry_row.event_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Event not found.');
    END IF;

    SELECT user_id INTO v_driver_user_id FROM public.drivers WHERE id = entry_row.host_driver_id;

    event_when := COALESCE(
        to_char(event_row.starts_at AT TIME ZONE 'UTC', 'FMDay FMDD FMMonth YYYY "at" HH24:MI "UTC"'),
        'TBC'
    );

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

    INSERT INTO public.driver_contact_messages
        (driver_id, user_id, subject, message, status, is_broadcast, broadcast_by, event_id)
    VALUES (
        entry_row.host_driver_id,
        v_driver_user_id,
        'Hosting Instructions · Split ' || entry_row.lobby_number || ' · ' || event_row.name,
        format(
            E'You''re hosting Split %s for %s.\n\nRace: %s\nDate: %s%s\n\nWhat you need to do:\n1. Create a Custom Race lobby in GT7 before the race start time.\n2. Set the lobby settings below for qualifying, then update for the race once qualifying is complete.\n3. Share the lobby password with your split''s drivers via the Discord #split-%s channel.\n4. Start the lobby on time — aim to have everyone in the room 15 minutes before the scheduled start.\n5. If any driver disconnects within the first lap, a restart is allowed. Call it in the Discord channel and requeue everyone.\n\nRace Settings:\n%s\n\nQualifying Settings:\n%s\n\nIf you have any problems or cannot host, contact an admin as soon as possible so we can arrange a replacement host.',
            entry_row.lobby_number,
            event_row.name,
            event_row.name,
            event_when,
            CASE WHEN event_row.circuit_name IS NOT NULL
                 THEN E'\nCircuit: ' || event_row.circuit_name
                 ELSE '' END,
            entry_row.lobby_number,
            v_settings_text,
            v_quali_text
        ),
        'in_progress',
        true,
        auth.uid(),
        entry_row.event_id
    );

    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION notify_single_lobby_host(uuid) TO authenticated;
