-- ============================================================
-- 131 Damage level: add "championship"
--
-- GT7 added a new Damage setting called "Championship" that sits
-- alongside the existing Off / Light / Heavy options. Widen the
-- events.damage_level CHECK so the calendar and admin can store it.
--
-- The public calendar and host-instruction messages already render
-- the raw value with initcap(), so "championship" shows as
-- "Championship" with no further changes.
-- ============================================================

ALTER TABLE events DROP CONSTRAINT IF EXISTS events_damage_level_check;

ALTER TABLE events
    ADD CONSTRAINT events_damage_level_check
    CHECK (damage_level IN ('off', 'light', 'heavy', 'championship'));
