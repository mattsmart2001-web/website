-- ============================================================
-- 18 Add points_deduction to penalty_type enum
-- ============================================================

ALTER TYPE penalty_type ADD VALUE IF NOT EXISTS 'points_deduction';
