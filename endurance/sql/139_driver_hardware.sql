-- ============================================================
-- 139 Driver hardware
--
-- Drivers can record the console they race on and whether they use a
-- wheel or a controller, with a free-text line for the wheel itself.
-- It shows on their public profile, and it gives the league a real
-- answer to "how much of the grid is on a wheel" rather than a guess.
--
-- Three plain columns rather than a JSON blob: the two fixed choices
-- stay constrained so the public profile can never render a typo, and
-- they can be counted directly in a query.
--
-- No RLS change is needed. "driver update own profile" (01_schema) is
-- row-level, so a driver can already write any column on their own
-- row, and the public profile selects * so the new fields appear on
-- their own.
-- ============================================================

ALTER TABLE drivers
    ADD COLUMN IF NOT EXISTS hardware_console text,
    ADD COLUMN IF NOT EXISTS hardware_input   text,
    ADD COLUMN IF NOT EXISTS hardware_wheel   text;

-- Fixed lists, so a value can only be one the portal offers. NULL means
-- the driver has not said.
ALTER TABLE drivers DROP CONSTRAINT IF EXISTS drivers_hardware_console_check;
ALTER TABLE drivers ADD CONSTRAINT drivers_hardware_console_check
    CHECK (hardware_console IS NULL
           OR hardware_console IN ('PS4', 'PS4 Pro', 'PS5', 'PS5 Pro'));

ALTER TABLE drivers DROP CONSTRAINT IF EXISTS drivers_hardware_input_check;
ALTER TABLE drivers ADD CONSTRAINT drivers_hardware_input_check
    CHECK (hardware_input IS NULL
           OR hardware_input IN ('wheel', 'controller'));

-- The wheel is free text, so cap it. It renders on a public page and
-- nobody needs 500 characters to name a wheel.
ALTER TABLE drivers DROP CONSTRAINT IF EXISTS drivers_hardware_wheel_check;
ALTER TABLE drivers ADD CONSTRAINT drivers_hardware_wheel_check
    CHECK (hardware_wheel IS NULL OR char_length(hardware_wheel) <= 120);

COMMENT ON COLUMN drivers.hardware_console IS 'PS4 / PS4 Pro / PS5 / PS5 Pro, or NULL if not stated';
COMMENT ON COLUMN drivers.hardware_input   IS 'wheel / controller, or NULL if not stated';
COMMENT ON COLUMN drivers.hardware_wheel   IS 'Free text, only meaningful when hardware_input = wheel';
