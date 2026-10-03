-- ============================================================
-- 136 A driver cannot lift an absence an admin put on them
--
-- Migration 88 gave drivers a self-flag ("can't attend this round").
-- Migration 132 layered admin-set absences onto the SAME row, telling
-- them apart only by reason: non-null means an admin put it there
-- (usually a ban), null means the driver flagged themselves.
--
-- The driver's DELETE policy was never narrowed to match, so it covered
-- every row for their own driver_id including the admin ones. A driver
-- who ticked "can't attend" and then unticked it deleted whatever was
-- on that round, ban included, and the same DELETE works straight
-- against the API without going near the portal. Nothing logged it and
-- the round simply became available again.
--
-- Drivers now only reach rows with no reason on them. Their own
-- self-flags behave exactly as before; admin rows are untouchable from
-- the driver side and only admin's own policy from 132 can clear them.
--
-- There is deliberately still no driver UPDATE policy, so a PostgREST
-- upsert onto an existing admin row is refused rather than quietly
-- rewriting it.
-- ============================================================

DROP POLICY IF EXISTS "delete own absence" ON driver_event_absences;
CREATE POLICY "delete own absence"
    ON driver_event_absences FOR DELETE
    TO authenticated
    USING (
        driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid())
        AND reason IS NULL
    );
