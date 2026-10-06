-- ============================================================
-- 73 Add time_multiplier column to events
--
-- Stores the in-game time-of-day speed setting for a race,
-- e.g. "10x" (1 real minute = 10 in-game minutes). Kept as
-- text to match the tyre_wear / fuel_consumption convention.
-- ============================================================

ALTER TABLE public.events
    ADD COLUMN IF NOT EXISTS time_multiplier TEXT;
