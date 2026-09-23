-- ============================================================
-- 13 Add Discord username to applications + unique driver numbers
-- ============================================================

-- Discord handle on applications
ALTER TABLE applications
    ADD COLUMN IF NOT EXISTS discord_username text;

-- Career numbers must be unique across the championship.
-- Multiple NULLs are still allowed (Postgres default for UNIQUE).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'drivers_career_number_unique'
    ) THEN
        ALTER TABLE drivers
            ADD CONSTRAINT drivers_career_number_unique UNIQUE (career_number);
    END IF;
END $$;
