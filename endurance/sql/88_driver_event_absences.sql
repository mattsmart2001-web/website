-- ============================================================
-- 88 Driver event absences
--   Drivers can flag themselves as unable to attend a scheduled
--   event from their profile page. The auto-register function
--   skips absent drivers when linking them to entries, and the
--   admin Health Check shows who has flagged each upcoming event.
-- ============================================================

CREATE TABLE IF NOT EXISTS driver_event_absences (
    driver_id  uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    event_id   uuid NOT NULL REFERENCES events(id)  ON DELETE CASCADE,
    created_at timestamptz DEFAULT now(),
    PRIMARY KEY (driver_id, event_id)
);

ALTER TABLE driver_event_absences ENABLE ROW LEVEL SECURITY;

-- Authenticated users (admins + drivers) can read all absences.
CREATE POLICY "read absences"
    ON driver_event_absences FOR SELECT
    TO authenticated
    USING (true);

-- Drivers may only insert absences for their own driver record.
CREATE POLICY "insert own absence"
    ON driver_event_absences FOR INSERT
    TO authenticated
    WITH CHECK (
        driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid())
    );

-- Drivers may only delete their own absence records.
CREATE POLICY "delete own absence"
    ON driver_event_absences FOR DELETE
    TO authenticated
    USING (
        driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid())
    );
