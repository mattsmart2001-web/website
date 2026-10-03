-- Replace the over-broad unique constraint on team_join_requests.
--
-- The original constraint UNIQUE (team_id, driver_id, status) blocks any
-- repeated status value for the same (team, driver) pair — so a driver who
-- was previously approved/rejected/cancelled and then reapplies will hit a
-- duplicate key error as soon as the new request reaches the same status.
--
-- The only row that genuinely needs uniqueness is the PENDING one: you
-- should not be able to have two live applications to the same team at
-- the same time. Historical records (approved, rejected, cancelled) can
-- legitimately recur across seasons or after a driver leaves and reapplies.
--
-- Fix: drop the constraint and replace it with a partial unique index
-- covering only pending rows.

ALTER TABLE public.team_join_requests
    DROP CONSTRAINT IF EXISTS team_join_requests_team_id_driver_id_status_key;

CREATE UNIQUE INDEX IF NOT EXISTS uq_team_join_requests_one_pending_per_pair
    ON public.team_join_requests (team_id, driver_id)
    WHERE status = 'pending';
