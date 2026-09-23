-- ============================================================
-- 22 Admin replies + driver inbox tracking
-- Adds a single admin reply per message + driver-side read tracking
-- so the thread lives in the driver portal instead of an email.
-- ============================================================

ALTER TABLE driver_contact_messages
    ADD COLUMN IF NOT EXISTS admin_reply           text,
    ADD COLUMN IF NOT EXISTS replied_at            timestamptz,
    ADD COLUMN IF NOT EXISTS replied_by            uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS driver_read_reply_at  timestamptz;

-- Let the driver mark their own reply as read.
DROP POLICY IF EXISTS "driver marks own reply read" ON driver_contact_messages;
CREATE POLICY "driver marks own reply read" ON driver_contact_messages
    FOR UPDATE TO authenticated
    USING (
        EXISTS (SELECT 1 FROM drivers d WHERE d.id = driver_id AND d.user_id = auth.uid())
    )
    WITH CHECK (
        EXISTS (SELECT 1 FROM drivers d WHERE d.id = driver_id AND d.user_id = auth.uid())
    );
