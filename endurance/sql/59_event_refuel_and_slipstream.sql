-- ============================================================
-- 59 Event briefing: refueling rate + slipstream
-- Two more per-event briefing fields that slot in alongside tyre wear,
-- BoP, damage etc. surfaced on the public Race Details modal.
--   * refuel_rate_lps  — litres per second, GT7 range 1..10
--   * slipstream       — off | weak | real | strong
-- ============================================================

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS refuel_rate_lps int
        CHECK (refuel_rate_lps IS NULL OR refuel_rate_lps BETWEEN 1 AND 10),
    ADD COLUMN IF NOT EXISTS slipstream text
        CHECK (slipstream IS NULL OR slipstream IN ('off', 'weak', 'real', 'strong'));
