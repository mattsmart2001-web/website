-- ============================================================
-- 121 Let the complainant withdraw their own dispute
--
-- Drivers can delete a case they filed straight from their portal — but
-- only while it's still 'open' (stewards haven't touched it). Once it's
-- under_review / resolved / dismissed it locks to admin-only delete, so
-- a case can't be erased out from under a steward mid-review. Mirrors the
-- open-only UPDATE policy from migration 120.
-- ============================================================

CREATE POLICY "complainant withdraws own open dispute" ON disputes
    FOR DELETE TO authenticated
    USING (
        status = 'open'
        AND complainant_driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid())
    );
