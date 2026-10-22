-- ============================================================
-- 82 Team join request dismiss
-- Adds dismissed_at so drivers can soft-hide resolved (non-pending)
-- requests from their portal without destroying the record.
-- The existing "decide on join requests" UPDATE policy already
-- covers drivers updating their own rows, so no new RLS needed.
-- ============================================================

ALTER TABLE team_join_requests
    ADD COLUMN IF NOT EXISTS dismissed_at timestamptz;
