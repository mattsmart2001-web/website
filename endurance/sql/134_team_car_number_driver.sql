-- ============================================================
-- 134 Team car number driver
--
-- A team's car carries one number for the whole crew (same convention
-- as Le Mans/WEC/IMSA), sourced from one of its drivers' own career
-- numbers. Auto-assignment already defaults to the team leader
-- (see the admin JS), but an admin may want the OTHER driver's number
-- instead - this column is that explicit override, picked from the
-- Teams admin listing.
--
-- NULL (the default) means "no override" - auto-assignment falls
-- back to the leader, then to any numbered driver on the entry, same
-- as before this column existed.
-- ============================================================

ALTER TABLE teams
    ADD COLUMN IF NOT EXISTS car_number_driver_id uuid REFERENCES drivers(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS teams_car_number_driver_idx ON teams (car_number_driver_id);
