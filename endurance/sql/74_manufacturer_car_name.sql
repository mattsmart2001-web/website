-- ============================================================
-- 74 Add car_name column to manufacturers
--
-- Each manufacturer in GTEC fields exactly one car. Storing
-- the car name on the manufacturer record means it propagates
-- automatically to the apply form, driver profiles, admin
-- tables, and entry grids without any extra joins.
-- ============================================================

ALTER TABLE public.manufacturers
    ADD COLUMN IF NOT EXISTS car_name TEXT;
