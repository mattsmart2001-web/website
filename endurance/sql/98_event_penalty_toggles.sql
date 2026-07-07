-- ============================================================
-- 98 Event race-rule toggles
-- Adds five more GT7 Custom Race lobby settings alongside the
-- existing bop_enabled/damage_level/slipstream fields — same
-- nullable-boolean pattern (unset = not specified yet, not "off").
-- ============================================================

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS equal_conditions_mode      boolean,
    ADD COLUMN IF NOT EXISTS shortcut_penalty            boolean,
    ADD COLUMN IF NOT EXISTS wall_collision_penalty      boolean,
    ADD COLUMN IF NOT EXISTS ghosting                    boolean,
    ADD COLUMN IF NOT EXISTS pit_lane_cutting_penalty    boolean;
