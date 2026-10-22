-- ============================================================
-- 72 Add first-lap disconnect restart rule to split notifications
--
-- Appends a standard restart rule line to every split-assignment
-- portal message so drivers are aware of the policy at the same
-- time they receive their split information.
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
    RETURN jsonb_build_object('ok', true, 'count', inserted_count);
END;
$$;

GRANT EXECUTE ON FUNCTION notify_lobby_assignments(uuid) TO authenticated;
