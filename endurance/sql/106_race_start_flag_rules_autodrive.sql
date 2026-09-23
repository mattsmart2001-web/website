-- ============================================================
-- 106 Race Start, Flag Rules, AutoDrive settings
--
-- Three more GT7 Custom Race lobby settings, same nullable pattern
-- as migrations 98/105: unset means not specified yet.
--   race_start  — 'grid_start_fsc' | 'grid_start' | 'rolling_start'
--   flag_rules  — boolean
--   autodrive   — 'prohibited' | 'allowed'
-- ============================================================

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS race_start text,
    ADD COLUMN IF NOT EXISTS flag_rules  boolean,
    ADD COLUMN IF NOT EXISTS autodrive   text;

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
        UNION ALL SELECT 'Grip Reduction Off Track: ' || initcap(event_row.grip_reduction_off_track) WHERE event_row.grip_reduction_off_track IS NOT NULL
        UNION ALL SELECT 'Nitrous: ' || initcap(event_row.nitrous) WHERE event_row.nitrous IS NOT NULL
        UNION ALL SELECT 'Engine Swap: ' || initcap(event_row.engine_swap) WHERE event_row.engine_swap IS NOT NULL
        UNION ALL SELECT 'Race Start: ' || CASE event_row.race_start
                              WHEN 'grid_start_fsc' THEN 'Grid Start with False Start Check'
                              WHEN 'grid_start'     THEN 'Grid Start'
                              WHEN 'rolling_start'  THEN 'Rolling Start'
                              ELSE initcap(event_row.race_start)
                          END WHERE event_row.race_start IS NOT NULL
        UNION ALL SELECT 'AutoDrive: ' || initcap(event_row.autodrive) WHERE event_row.autodrive IS NOT NULL
        UNION ALL SELECT 'Balance of Performance: Enabled' WHERE event_row.bop_enabled IS TRUE
        UNION ALL SELECT 'Equal Conditions Mode: On' WHERE event_row.equal_conditions_mode IS TRUE
        UNION ALL SELECT 'Shortcut Penalty: On - Weak' WHERE event_row.shortcut_penalty IS TRUE
        UNION ALL SELECT 'Wall Collision Penalty: On - Weak' WHERE event_row.wall_collision_penalty IS TRUE
        UNION ALL SELECT 'Car Collision Penalty: On' WHERE event_row.car_collision_penalty IS TRUE
        UNION ALL SELECT 'Correct Vehicle Course: On' WHERE event_row.correct_vehicle_course IS TRUE
        UNION ALL SELECT 'Flag Rules: On' WHERE event_row.flag_rules IS TRUE
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
            E'You''re hosting Split %s for %s.\n\nRace: %s\nDate: %s%s\n\nWhat you need to do:\n1. Create a Custom Race lobby in GT7 before the race start time.\n2. Set the lobby settings below for qualifying, then update for the race once qualifying is complete.\n3. Share the lobby password with your split''s drivers via the Discord #split-%s channel.\n4. Start the lobby on time — aim to have everyone in the room 15 minutes before the scheduled start.\n5. If any driver disconnects within the first lap, a restart is allowed. Call it in the Discord channel and requeue everyone.\n\nRace Settings:\n%s\n\nQualifying Settings:\n%s\n\nIf you have any problems or cannot host, contact an admin as soon as possible so we can arrange a replacement host.',
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

    RETURN jsonb_build_object('ok', true, 'count', inserted_count, 'host_count', host_count);
END;
$$;

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
        UNION ALL SELECT 'Grip Reduction Off Track: ' || initcap(event_row.grip_reduction_off_track) WHERE event_row.grip_reduction_off_track IS NOT NULL
        UNION ALL SELECT 'Nitrous: ' || initcap(event_row.nitrous) WHERE event_row.nitrous IS NOT NULL
        UNION ALL SELECT 'Engine Swap: ' || initcap(event_row.engine_swap) WHERE event_row.engine_swap IS NOT NULL
        UNION ALL SELECT 'Race Start: ' || CASE event_row.race_start
                              WHEN 'grid_start_fsc' THEN 'Grid Start with False Start Check'
                              WHEN 'grid_start'     THEN 'Grid Start'
                              WHEN 'rolling_start'  THEN 'Rolling Start'
                              ELSE initcap(event_row.race_start)
                          END WHERE event_row.race_start IS NOT NULL
        UNION ALL SELECT 'AutoDrive: ' || initcap(event_row.autodrive) WHERE event_row.autodrive IS NOT NULL
        UNION ALL SELECT 'Balance of Performance: Enabled' WHERE event_row.bop_enabled IS TRUE
        UNION ALL SELECT 'Equal Conditions Mode: On' WHERE event_row.equal_conditions_mode IS TRUE
        UNION ALL SELECT 'Shortcut Penalty: On - Weak' WHERE event_row.shortcut_penalty IS TRUE
        UNION ALL SELECT 'Wall Collision Penalty: On - Weak' WHERE event_row.wall_collision_penalty IS TRUE
        UNION ALL SELECT 'Car Collision Penalty: On' WHERE event_row.car_collision_penalty IS TRUE
        UNION ALL SELECT 'Correct Vehicle Course: On' WHERE event_row.correct_vehicle_course IS TRUE
        UNION ALL SELECT 'Flag Rules: On' WHERE event_row.flag_rules IS TRUE
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
