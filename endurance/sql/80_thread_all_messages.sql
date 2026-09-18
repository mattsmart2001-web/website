-- ============================================================
-- 80 Extend thread system to driver-initiated messages
--
-- Migration 78 only seeded thread posts for is_direct messages.
-- Driver-submitted contact messages now also use the thread table,
-- so we need to back-fill their original message body as a 'driver'
-- post and any existing admin_reply as an 'admin' post.
--
-- Also removes the is_direct guard in reply_to_admin_message so
-- drivers can follow up on their own contact threads.
-- ============================================================

-- Back-fill driver's original message as first thread post
INSERT INTO public.message_thread_posts (message_id, sender_type, sender_id, content, created_at)
SELECT m.id, 'driver', d.user_id, m.message, m.created_at
FROM   public.driver_contact_messages m
JOIN   public.drivers d ON d.id = m.driver_id
WHERE  m.is_direct    = false
  AND  m.is_broadcast = false
  AND  coalesce(m.message, '') <> ''
  AND  NOT EXISTS (
      SELECT 1 FROM public.message_thread_posts p
      WHERE  p.message_id = m.id
  );

-- Back-fill existing single admin replies
INSERT INTO public.message_thread_posts (message_id, sender_type, sender_id, content, created_at)
SELECT id, 'admin', replied_by, admin_reply,
       coalesce(replied_at, created_at + interval '1 second')
FROM   public.driver_contact_messages
WHERE  is_direct    = false
  AND  is_broadcast = false
  AND  coalesce(admin_reply, '') <> ''
  AND  NOT EXISTS (
      SELECT 1 FROM public.message_thread_posts p
      WHERE  p.message_id = driver_contact_messages.id
        AND  p.sender_type = 'admin'
  );


-- Remove the is_direct restriction so drivers can reply to any thread
-- they own (their contact messages as well as admin-initiated threads).
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
    IF v_msg.is_broadcast THEN
        RETURN jsonb_build_object('ok', false, 'error', 'You cannot reply to broadcast announcements.');
    END IF;
    IF coalesce(p_reply, '') = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Reply is empty.');
    END IF;

    INSERT INTO public.message_thread_posts (message_id, sender_type, sender_id, content)
    VALUES (p_message_id, 'driver', auth.uid(), p_reply);

    UPDATE public.driver_contact_messages
       SET driver_replied_at = now(),
           status            = 'new',
           updated_at        = now()
     WHERE id = p_message_id;

    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION reply_to_admin_message(uuid, text) TO authenticated;
