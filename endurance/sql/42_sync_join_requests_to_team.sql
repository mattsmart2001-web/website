-- ============================================================
-- 42 Auto-approve pending join requests when a driver lands on a team
-- If admin adds a driver to a team via the Drivers edit form (or any
-- other path that just sets drivers.current_team_id), the driver's
-- pending request to that same team stayed "pending" on their profile.
-- This trigger watches drivers.current_team_id and:
--   • flips any pending request for (driver, new team) to 'approved'
--   • cancels any other pending requests that driver still has open
-- Mirrors what approve_team_join_request already does so the result
-- is consistent regardless of how the driver got assigned.
-- ============================================================

CREATE OR REPLACE FUNCTION sync_join_requests_to_team_membership()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_team_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE'
       AND NEW.current_team_id IS NOT DISTINCT FROM OLD.current_team_id THEN
        RETURN NEW;
    END IF;

    -- Pending request for this exact team → approved.
    UPDATE public.team_join_requests
       SET status     = 'approved',
           decided_at = COALESCE(decided_at, now()),
           decided_by = COALESCE(decided_by, auth.uid())
     WHERE driver_id  = NEW.id
       AND team_id    = NEW.current_team_id
       AND status     = 'pending';

    -- Any other pending requests for this driver → cancelled.
    UPDATE public.team_join_requests
       SET status     = 'cancelled',
           decided_at = now(),
           decided_by = auth.uid()
     WHERE driver_id  = NEW.id
       AND team_id    <> NEW.current_team_id
       AND status     = 'pending';

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS drivers_sync_join_requests ON drivers;
CREATE TRIGGER drivers_sync_join_requests
    AFTER INSERT OR UPDATE OF current_team_id ON drivers
    FOR EACH ROW EXECUTE FUNCTION sync_join_requests_to_team_membership();

-- One-time backfill: any existing pending request whose driver is
-- already on that team gets flipped to approved.
UPDATE public.team_join_requests jr
   SET status     = 'approved',
       decided_at = COALESCE(jr.decided_at, now())
  FROM public.drivers d
 WHERE d.id = jr.driver_id
   AND d.current_team_id = jr.team_id
   AND jr.status = 'pending';
