-- ============================================================
-- 55 Preferred career number on applications
-- Lets applicants nominate their preferred GTEC career number on
-- the apply form so admin sees their pick when reviewing. The driver
-- record's career_number column already has its own uniqueness
-- constraint (mig 13), so the actual reservation happens when admin
-- creates the driver record.
-- ============================================================

ALTER TABLE applications
    ADD COLUMN IF NOT EXISTS preferred_career_number int
        CHECK (preferred_career_number IS NULL OR preferred_career_number BETWEEN 1 AND 999);
