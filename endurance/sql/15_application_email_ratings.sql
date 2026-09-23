-- ============================================================
-- 15 Email + GT7 ratings on applications and drivers
-- ============================================================

ALTER TABLE applications
    ADD COLUMN IF NOT EXISTS email          text,
    ADD COLUMN IF NOT EXISTS gt7_dr_rating  text,
    ADD COLUMN IF NOT EXISTS gt7_sr_rating  text;

ALTER TABLE drivers
    ADD COLUMN IF NOT EXISTS gt7_dr_rating  text,
    ADD COLUMN IF NOT EXISTS gt7_sr_rating  text;
