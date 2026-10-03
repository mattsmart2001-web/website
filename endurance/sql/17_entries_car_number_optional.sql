-- ============================================================
-- 17 Make entries.car_number optional
-- The car number is now derived from the first driver added to the
-- entry (using their career_number), so admins don't have to enter
-- it when registering a team for an event.
-- ============================================================

ALTER TABLE entries
    ALTER COLUMN car_number DROP NOT NULL;

-- The existing CHECK (car_number > 0) is fine — NULL bypasses CHECK.
-- The existing UNIQUE (event_id, car_number) is fine — Postgres allows
-- multiple NULLs in a UNIQUE constraint.
