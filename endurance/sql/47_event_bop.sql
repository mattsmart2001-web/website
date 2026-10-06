-- ============================================================
-- 47 BoP (Balance of Performance) on / off per event
-- ============================================================

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS bop_enabled boolean;
