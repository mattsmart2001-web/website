-- ============================================================
-- 25 Broadcast messages from admin to every driver
-- Reuses driver_contact_messages but flagged as a broadcast so the
-- portal renders it as an announcement card (no "your message" header,
-- no reply box) and admin can spot them in the list.
-- ============================================================

ALTER TABLE driver_contact_messages
    ADD COLUMN IF NOT EXISTS is_broadcast boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS broadcast_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS driver_contact_messages_broadcast_idx
    ON driver_contact_messages (is_broadcast, created_at DESC);


CREATE OR REPLACE FUNCTION broadcast_message_to_drivers(p_subject text, p_message text)
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
    FROM    public.drivers d;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'count', inserted_count);
END;
$$;

GRANT EXECUTE ON FUNCTION broadcast_message_to_drivers(text, text) TO authenticated;
