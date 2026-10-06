-- ============================================================
-- 49 Driver replies to direct admin messages
-- A new is_direct flag distinguishes admin → one-driver messages from
-- broadcasts (which stay reply-less). Direct messages get a reply box
-- in the portal inbox, and the driver's reply bumps the message status
-- back to 'new' so the admin badge counts it.
-- ============================================================

ALTER TABLE driver_contact_messages
    ADD COLUMN IF NOT EXISTS is_direct           boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS driver_reply        text,
    ADD COLUMN IF NOT EXISTS driver_replied_at   timestamptz;

-- New / re-issued: admin-direct sends now flag is_direct AND keep
-- is_broadcast=false (so the portal renders the "From Admin" card with
-- a reply box, not the silent announcement variant).
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
        (driver_id, user_id, subject, message, status,
         is_broadcast, is_direct, broadcast_by)
    VALUES
        (p_driver_id, v_user_id,
         nullif(trim(p_subject), ''),
         p_message,
         'new',
         false,
         true,
         auth.uid());

    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION message_driver(uuid, text, text) TO authenticated;


-- Driver writes back. We allow update only when the row is theirs AND
-- it's an admin-direct message. Submitting flips status to 'new' so the
-- admin Messages badge wakes up.
CREATE OR REPLACE FUNCTION reply_to_admin_message(
    p_message_id uuid,
    p_reply      text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_msg driver_contact_messages%ROWTYPE;
BEGIN
    SELECT * INTO v_msg FROM public.driver_contact_messages WHERE id = p_message_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Message not found.');
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.drivers d
        WHERE  d.id = v_msg.driver_id AND d.user_id = auth.uid()
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    IF NOT v_msg.is_direct THEN
        RETURN jsonb_build_object('ok', false, 'error', 'You can only reply to direct admin messages.');
    END IF;
    IF coalesce(p_reply, '') = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Reply is empty.');
    END IF;

    UPDATE public.driver_contact_messages
       SET driver_reply      = p_reply,
           driver_replied_at = now(),
           status            = 'new'
     WHERE id = p_message_id;

    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION reply_to_admin_message(uuid, text) TO authenticated;
