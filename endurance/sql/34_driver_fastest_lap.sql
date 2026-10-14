-- ============================================================
-- 34 Per-driver fastest lap time
-- Lets admin record each driver's fastest race lap (the one that
-- earned them the FL bonus, or the one that didn't). Stored as ms
-- on result_drivers so it can be displayed per-driver on the
-- public results page and rolled into stats.
-- ============================================================

ALTER TABLE result_drivers
    ADD COLUMN IF NOT EXISTS fastest_lap_ms int
        CHECK (fastest_lap_ms IS NULL OR fastest_lap_ms > 0);
