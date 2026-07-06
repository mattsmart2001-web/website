-- ============================================================
-- 51 Broadcast messages from admin to willing lobby hosts only
-- Same shape as broadcast_message_to_drivers (25) but scoped to
-- drivers with willing_host = true.
-- ============================================================

CREATE OR REPLACE FUNCTION broadcast_message_to_lobby_hosts(p_subject text, p_message text)
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

GRANT EXECUTE ON FUNCTION broadcast_message_to_lobby_hosts(text, text) TO authenticated;
