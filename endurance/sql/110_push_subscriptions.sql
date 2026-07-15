-- ============================================================
-- 110 Web push subscriptions
--
-- Lets a driver opt in to browser push notifications (via the
-- service worker already registered at /endurance/sw.js) as a
-- fourth notification channel alongside Discord, the portal inbox,
-- and email — free, and reaches them even if they're not checking
-- either of those.
--
-- One row per subscribed device/browser (a driver can have several).
-- endpoint is globally unique per the Push API spec, so it doubles as
-- the natural upsert key when the same device re-subscribes.
-- ============================================================

CREATE TABLE IF NOT EXISTS push_subscriptions (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id   uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    endpoint    text NOT NULL UNIQUE,
    p256dh      text NOT NULL,
    auth        text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS push_subscriptions_driver_idx ON push_subscriptions (driver_id);

ALTER TABLE push_subscriptions ENABLE ROW LEVEL SECURITY;

-- A driver manages their own subscriptions; admin can read/delete any
-- (read to actually send pushes, delete to clean up stale endpoints
-- reported by the push service as 404/410).
CREATE POLICY "drivers manage their own push subscriptions" ON push_subscriptions
    FOR ALL TO authenticated
    USING (
        EXISTS (SELECT 1 FROM drivers d WHERE d.id = push_subscriptions.driver_id AND d.user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    )
    WITH CHECK (
        EXISTS (SELECT 1 FROM drivers d WHERE d.id = push_subscriptions.driver_id AND d.user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );
