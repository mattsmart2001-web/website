-- ============================================================
-- 132 Admin-managed absences (bans)
--   On top of the driver self-flag (migration 88), let admins mark
--   any driver unavailable for specific rounds, e.g. a ban. A nullable
--   reason column records why; it stays null for driver self-flags, so a
--   non-null reason marks an admin-added absence. These absences flow
--   through the same paths self-flags do: the auto-register skips them,
--   and the Health Check "Unable to Attend" panel lists them.
-- ============================================================

ALTER TABLE driver_event_absences ADD COLUMN IF NOT EXISTS reason text;

-- Admins may insert an absence for any driver (drivers keep their own
-- self-insert policy from migration 88; RLS policies are OR'd).
DROP POLICY IF EXISTS "admin inserts any absence" ON driver_event_absences;
CREATE POLICY "admin inserts any absence"
    ON driver_event_absences FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );

-- Admins may update an absence (e.g. edit the reason).
DROP POLICY IF EXISTS "admin updates any absence" ON driver_event_absences;
CREATE POLICY "admin updates any absence"
    ON driver_event_absences FOR UPDATE
    TO authenticated
    USING (
        EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );

-- Admins may delete an absence for any driver.
DROP POLICY IF EXISTS "admin deletes any absence" ON driver_event_absences;
CREATE POLICY "admin deletes any absence"
    ON driver_event_absences FOR DELETE
    TO authenticated
    USING (
        EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );
