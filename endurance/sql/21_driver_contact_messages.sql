-- ============================================================
-- 21 Driver → Admin contact messages
-- Lets a signed-in driver flag race disputes / issues from their
-- portal, optionally with a link to a replay or screenshot, that
-- admins can triage in the admin panel.
-- ============================================================

CREATE TABLE IF NOT EXISTS driver_contact_messages (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id      uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    user_id        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    subject        text,
    message        text NOT NULL,
    incident_url   text,
    status         text NOT NULL DEFAULT 'new'
                       CHECK (status IN ('new','in_progress','resolved','dismissed')),
    admin_note     text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    resolved_at    timestamptz
);

CREATE INDEX IF NOT EXISTS driver_contact_messages_status_idx
    ON driver_contact_messages (status, created_at DESC);
CREATE INDEX IF NOT EXISTS driver_contact_messages_driver_idx
    ON driver_contact_messages (driver_id, created_at DESC);

ALTER TABLE driver_contact_messages ENABLE ROW LEVEL SECURITY;

-- A driver can read their own messages (matched via the drivers.user_id link).
CREATE POLICY "driver reads own contact messages" ON driver_contact_messages
    FOR SELECT TO authenticated
    USING (
        user_id = auth.uid()
        OR EXISTS (SELECT 1 FROM drivers d WHERE d.id = driver_id AND d.user_id = auth.uid())
    );

-- A driver can submit a message tied to their own driver record.
CREATE POLICY "driver inserts own contact message" ON driver_contact_messages
    FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (SELECT 1 FROM drivers d WHERE d.id = driver_id AND d.user_id = auth.uid())
    );

-- Admins can read, update, delete everything.
CREATE POLICY "admin reads all contact messages" ON driver_contact_messages
    FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

CREATE POLICY "admin updates contact messages" ON driver_contact_messages
    FOR UPDATE TO authenticated
    USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
    WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

CREATE POLICY "admin deletes contact messages" ON driver_contact_messages
    FOR DELETE TO authenticated
    USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- Auto-bump updated_at on UPDATE
CREATE OR REPLACE FUNCTION touch_driver_contact_messages_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    IF NEW.status = 'resolved' AND OLD.status <> 'resolved' THEN
        NEW.resolved_at := now();
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_driver_contact_messages_touch ON driver_contact_messages;
CREATE TRIGGER trg_driver_contact_messages_touch
    BEFORE UPDATE ON driver_contact_messages
    FOR EACH ROW EXECUTE FUNCTION touch_driver_contact_messages_updated_at();
