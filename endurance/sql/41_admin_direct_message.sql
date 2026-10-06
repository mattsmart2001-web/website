-- ============================================================
-- 41 Admin → individual driver messages
-- Same storage as broadcasts (is_broadcast=true so the portal renders
-- it as an admin-sent announcement card with no reply box), but lets
-- admins pick a single driver instead of blasting everyone.
-- ============================================================

CREATE OR REPLACE FUNCTION message_driver(
    p_driver_id uuid,
    p_subject   text,
    p_message   text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id uuid;
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

    SELECT user_id INTO v_user_id FROM public.drivers WHERE id = p_driver_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Driver not found.');
    END IF;

    INSERT INTO public.driver_contact_messages
        (driver_id, user_id, subject, message, status, is_broadcast, broadcast_by)
    VALUES
        (p_driver_id, v_user_id,
         nullif(trim(p_subject), ''),
         p_message,
         'in_progress',
         true,
         auth.uid());

    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION message_driver(uuid, text, text) TO authenticated;
