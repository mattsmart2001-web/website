-- ============================================================
-- 10 Application links
-- Track which driver/team record (if any) was created from an
-- accepted application, so admins can see at a glance whether
-- the roster has been updated.
-- ============================================================

ALTER TABLE applications
    ADD COLUMN IF NOT EXISTS linked_driver_id uuid REFERENCES drivers(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS linked_team_id   uuid REFERENCES teams(id)   ON DELETE SET NULL;
