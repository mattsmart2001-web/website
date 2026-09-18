-- ============================================================
-- 65 Split notifications now know about promotion / relegation
--
-- The notify_lobby_assignments RPC sent the same generic "you've
-- been assigned to Split N" message every round, which made the
-- promotion / relegation story invisible to drivers. With splits
-- naturally moving each round as Elo updates, drivers should see
-- whether they've gone UP, DOWN or STAYED PUT.
--
-- This rewrite looks at the driver's previous-round split (the
-- chronologically prior event in the same season) and branches:
--   * no prior round   → "Assigned to Split N" (first time)
--   * smaller number   → "Promoted from Split X to Split N"
--   * larger number    → "Moved from Split X to Split N"
--   * same number      → "Staying in Split N"
-- The subject line carries the same headline so it's readable in
-- a list view too.
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

    -- Most recent event in this season that came before the one we're
    -- notifying about. Used to compute promotion / relegation deltas.
    SELECT id INTO prior_event_id
    FROM   public.events
    WHERE  season_id  = event_row.season_id
      AND  starts_at IS NOT NULL
      AND  event_row.starts_at IS NOT NULL
      AND  starts_at  < event_row.starts_at
    ORDER  BY starts_at DESC
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
            E'%s%s\n\nRace: %s\nDate: %s%s%sCheck your portal and Discord ahead of the race.',
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
