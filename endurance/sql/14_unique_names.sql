-- ============================================================
-- 14 Case-insensitive uniqueness on driver / team names
-- Matches the admin client-side check exactly (lowercased, no trim).
-- Will fail noisily if duplicates already exist — fix them first.
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS drivers_display_name_ci_unique
    ON drivers (lower(display_name));

CREATE UNIQUE INDEX IF NOT EXISTS teams_name_ci_unique
    ON teams (lower(name));
