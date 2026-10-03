-- ============================================================
-- 46 Required tyres on events
-- text[] of compound codes (RS, RM, RH, RI, RW). When more than one
-- is set, the race rules typically read "must use two compounds" —
-- the public calendar lists them as pills.
-- ============================================================

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS required_tyres text[];
