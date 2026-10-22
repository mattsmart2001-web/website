-- ============================================================
-- 48 Damage level per event (off / light / heavy)
-- ============================================================

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS damage_level text CHECK (damage_level IN ('off','light','heavy'));
