-- ============================================================
-- 90 Admin -> all willing lobby hosts
-- Same storage/shape as broadcast_message_to_drivers, but scoped to
-- drivers who ticked "willing to host" on their application
-- (drivers.willing_host = true), regardless of whether they're
-- assigned as host for a specific event.
-- ============================================================

CREATE OR REPLACE FUNCTION message_lobby_hosts(p_subject text, p_message text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    inserted_count int;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    IF coalesce(p_message, '') = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Message body is required.');
    END IF;

    INSERT INTO public.driver_contact_messages
        (driver_id, user_id, subject, message, status, is_broadcast, broadcast_by)
    SELECT  d.id,
            d.user_id,
            nullif(trim(p_subject), ''),
            p_message,
            'in_progress',
            true,
            auth.uid()
    FROM    public.drivers d
    WHERE   d.willing_host = true;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'count', inserted_count);
END;
$$;

GRANT EXECUTE ON FUNCTION message_lobby_hosts(text, text) TO authenticated;
