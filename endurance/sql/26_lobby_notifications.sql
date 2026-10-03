-- ============================================================
-- 26 Lobby assignment notifications
-- Tags driver_contact_messages with the event they relate to so
-- admins can send a "you're in Lobby N" message to every assigned
-- driver from the lobbies panel and later wipe those notifications
-- if the allocation changes.
-- ============================================================

ALTER TABLE driver_contact_messages
    ADD COLUMN IF NOT EXISTS event_id uuid REFERENCES events(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS driver_contact_messages_event_idx
    ON driver_contact_messages (event_id);


-- ============================================================
-- notify_lobby_assignments(event_id)
-- Inserts one broadcast-flagged message per driver who is on a
-- confirmed entry that has a lobby_number assigned for the event.
-- ============================================================
CREATE OR REPLACE FUNCTION notify_lobby_assignments(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    event_row events%ROWTYPE;
    inserted_count int;
    event_when text;
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

    event_when := COALESCE(
        to_char(event_row.starts_at AT TIME ZONE 'UTC', 'FMDay FMDD FMMonth YYYY "at" HH24:MI "UTC"'),
        'TBC'
    );

    WITH driver_lobby AS (
        SELECT DISTINCT
            ed.driver_id,
            en.lobby_number,
            en.car_number,
            t.name AS team_name
        FROM   entries en
        JOIN   entry_drivers ed ON ed.entry_id = en.id
        LEFT   JOIN teams t     ON t.id = en.team_id
        WHERE  en.event_id      = p_event_id
          AND  en.lobby_number  IS NOT NULL
          AND  en.status        = 'confirmed'
    )
    INSERT INTO public.driver_contact_messages
        (driver_id, user_id, subject, message, status, is_broadcast, broadcast_by, event_id)
    SELECT
        dl.driver_id,
        d.user_id,
        'Lobby Assignment · ' || event_row.name,
        format(
            E'You\'ve been assigned to Lobby %s for %s.%s\n\nRace: %s\nDate: %s%s%sCheck your portal and Discord ahead of the race.',
            dl.lobby_number,
            event_row.name,
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
    JOIN   drivers d ON d.id = dl.driver_id;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'count', inserted_count);
END;
$$;


-- ============================================================
-- delete_lobby_notifications(event_id)
-- Wipes every lobby-notification message previously sent for
-- this event. Useful when re-allocating after a first batch
-- of notifications has already gone out.
-- ============================================================
CREATE OR REPLACE FUNCTION delete_lobby_notifications(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    deleted_count int;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    DELETE FROM public.driver_contact_messages
    WHERE  event_id = p_event_id
      AND  is_broadcast = true;
    GET DIAGNOSTICS deleted_count = ROW_COUNT;

    RETURN jsonb_build_object('ok', true, 'count', deleted_count);
END;
$$;


GRANT EXECUTE ON FUNCTION notify_lobby_assignments(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION delete_lobby_notifications(uuid) TO authenticated;
