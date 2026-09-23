-- ============================================================
-- 50 Cascade on driver deletion
-- Trying to delete a driver who had been entered into an event blew
-- up with "violates foreign key constraint on entry_drivers" because
-- entry_drivers.driver_id, result_drivers.driver_id and
-- penalties.driver_id had no ON DELETE clause (default = RESTRICT).
--
-- Switch them to CASCADE for the per-driver detail tables, and to
-- SET NULL for penalties (the penalty itself should survive — it
-- belonged to the entry / event, not just the driver).
-- ============================================================

ALTER TABLE entry_drivers
    DROP CONSTRAINT IF EXISTS entry_drivers_driver_id_fkey,
    ADD  CONSTRAINT entry_drivers_driver_id_fkey
        FOREIGN KEY (driver_id) REFERENCES drivers(id) ON DELETE CASCADE;

ALTER TABLE result_drivers
    DROP CONSTRAINT IF EXISTS result_drivers_driver_id_fkey,
    ADD  CONSTRAINT result_drivers_driver_id_fkey
        FOREIGN KEY (driver_id) REFERENCES drivers(id) ON DELETE CASCADE;

ALTER TABLE penalties
    DROP CONSTRAINT IF EXISTS penalties_driver_id_fkey,
    ADD  CONSTRAINT penalties_driver_id_fkey
        FOREIGN KEY (driver_id) REFERENCES drivers(id) ON DELETE SET NULL;
