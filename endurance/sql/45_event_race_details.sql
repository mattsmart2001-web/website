-- ============================================================
-- 45 Event race-detail fields
-- Per-event briefing values surfaced on the public calendar via the
-- "Race Details" button. Free-text so admins can format however they
-- want — tyre wear "5x", weather "Variable / 60% chance of rain", etc.
-- ============================================================

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS tyre_wear          text,
    ADD COLUMN IF NOT EXISTS fuel_consumption   text,
    ADD COLUMN IF NOT EXISTS weather            text,
    ADD COLUMN IF NOT EXISTS time_of_day        text,
    ADD COLUMN IF NOT EXISTS starting_procedure text,
    ADD COLUMN IF NOT EXISTS mandatory_pit_stops int,
    ADD COLUMN IF NOT EXISTS race_details       text;
