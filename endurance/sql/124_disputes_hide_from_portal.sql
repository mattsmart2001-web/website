-- ============================================================
-- 124 Hide a dispute from the driver's portal (keep it in the log)
--
-- Admins can hide a case from the complainant's portal while keeping the
-- full record in the Stewards log — e.g. tidying away test cases or noise
-- without losing the audit trail. A hidden flag the complainant's SELECT
-- policy now respects; admins still see everything.
-- ============================================================

ALTER TABLE disputes ADD COLUMN IF NOT EXISTS hidden_from_portal boolean NOT NULL DEFAULT false;

-- Rebuild the complainant read policy so hidden cases drop out of their
-- view. Admins keep full visibility via the OR branch.
DROP POLICY IF EXISTS "complainant reads own disputes" ON disputes;
CREATE POLICY "complainant reads own disputes" ON disputes
    FOR SELECT TO authenticated
    USING (
        (
            complainant_driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid())
            AND NOT hidden_from_portal
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );
