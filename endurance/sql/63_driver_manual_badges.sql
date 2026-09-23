-- ============================================================
-- 63 Manual badges on drivers
-- text[] of badge keys an admin has awarded by hand. The badge
-- helper short-circuits to "earned" when a badge key shows up here,
-- letting admins compensate for missed results / data-entry errors
-- without breaking the automatic detection paths.
-- ============================================================

ALTER TABLE drivers
    ADD COLUMN IF NOT EXISTS manual_badges text[] NOT NULL DEFAULT '{}';
