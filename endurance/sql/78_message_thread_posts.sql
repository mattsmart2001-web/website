-- ============================================================
-- 78 Message thread posts — unlimited admin ↔ driver replies
--
-- Replaces the single admin_reply / driver_reply columns with a
-- proper thread table. Each row is one message in the conversation.
-- The parent driver_contact_messages row is still the thread header
-- (subject, status, is_direct flag, unread tracking).
-- ============================================================

CREATE TABLE IF NOT EXISTS public.message_thread_posts (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id  uuid NOT NULL REFERENCES public.driver_contact_messages(id) ON DELETE CASCADE,
    sender_type text NOT NULL CHECK (sender_type IN ('admin', 'driver')),
    sender_id   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    content     text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mtp_message_id_created_idx
    ON public.message_thread_posts (message_id, created_at);

ALTER TABLE public.message_thread_posts ENABLE ROW LEVEL SECURITY;

-- Admin: full access
CREATE POLICY "admin all on mtp" ON public.message_thread_posts
    FOR ALL
    USING (EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ))
    WITH CHECK (EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ));

-- Driver: read posts on their own threads
CREATE POLICY "driver read own mtp" ON public.message_thread_posts
    FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.driver_contact_messages m
            JOIN   public.drivers d ON d.id = m.driver_id
            WHERE  m.id = message_thread_posts.message_id
              AND  d.user_id = auth.uid()
        )
    );

-- Driver: insert only driver-typed posts on their own threads
CREATE POLICY "driver insert own mtp" ON public.message_thread_posts
    FOR INSERT TO authenticated
    WITH CHECK (
        sender_type = 'driver'
        AND EXISTS (
            SELECT 1 FROM public.driver_contact_messages m
            JOIN   public.drivers d ON d.id = m.driver_id
            WHERE  m.id = message_thread_posts.message_id
              AND  d.user_id = auth.uid()
        )
    );


-- ============================================================
-- Migrate existing data into thread posts
-- ============================================================

-- Initial admin message for every is_direct thread
INSERT INTO public.message_thread_posts (message_id, sender_type, sender_id, content, created_at)
SELECT id, 'admin', broadcast_by, message, created_at
FROM   public.driver_contact_messages
WHERE  is_direct = true
  AND  coalesce(message, '') <> '';

-- Existing single admin replies
INSERT INTO public.message_thread_posts (message_id, sender_type, sender_id, content, created_at)
SELECT id, 'admin', replied_by, admin_reply,
       coalesce(replied_at, created_at + interval '1 second')
FROM   public.driver_contact_messages
WHERE  is_direct = true
  AND  coalesce(admin_reply, '') <> '';

-- Existing single driver replies
INSERT INTO public.message_thread_posts (message_id, sender_type, sender_id, content, created_at)
SELECT m.id, 'driver', d.user_id, m.driver_reply,
       coalesce(m.driver_replied_at, m.created_at + interval '2 seconds')
FROM   public.driver_contact_messages m
JOIN   public.drivers d ON d.id = m.driver_id
WHERE  m.is_direct = true
  AND  coalesce(m.driver_reply, '') <> '';


-- ============================================================
-- Update message_driver: seeds the first thread post
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
    v_msg_id  uuid;
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
         auth.uid())
    RETURNING id INTO v_msg_id;

    INSERT INTO public.message_thread_posts (message_id, sender_type, sender_id, content)
    VALUES (v_msg_id, 'admin', auth.uid(), p_message);

    RETURN jsonb_build_object('ok', true, 'message_id', v_msg_id);
END;
$$;

GRANT EXECUTE ON FUNCTION message_driver(uuid, text, text) TO authenticated;


-- ============================================================
-- New: admin_reply_to_thread — appends an admin post to a thread
-- ============================================================
CREATE OR REPLACE FUNCTION admin_reply_to_thread(
    p_message_id uuid,
    p_content    text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    IF coalesce(p_content, '') = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Reply cannot be empty.');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.driver_contact_messages WHERE id = p_message_id) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Thread not found.');
    END IF;

    INSERT INTO public.message_thread_posts (message_id, sender_type, sender_id, content)
    VALUES (p_message_id, 'admin', auth.uid(), p_content);

    -- Reset driver read state so unread badge appears; bump to in_progress
    UPDATE public.driver_contact_messages
       SET updated_at           = now(),
           status               = 'in_progress',
           driver_read_reply_at = NULL
     WHERE id = p_message_id;

    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_reply_to_thread(uuid, text) TO authenticated;


-- ============================================================
-- Update reply_to_admin_message: appends a driver post
-- ============================================================
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

    INSERT INTO public.message_thread_posts (message_id, sender_type, sender_id, content)
    VALUES (p_message_id, 'driver', auth.uid(), p_reply);

    -- Bump status to 'new' so the admin Messages badge wakes up
    UPDATE public.driver_contact_messages
       SET driver_replied_at = now(),
           status            = 'new',
           updated_at        = now()
     WHERE id = p_message_id;

    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION reply_to_admin_message(uuid, text) TO authenticated;
