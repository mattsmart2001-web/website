-- ============================================================
-- 127 Clear leftover pending team applications during a season
--
-- Migration 126 locks team applications for the whole active season, but
-- requests created before that lock are left sitting as 'pending' — dead
-- ends that a leader can't approve and that still clutter the driver's
-- portal, the leader's "Drivers Applying to Your Team" list, and the
-- health check's "Applied to X" badges.
--
-- Since the rule is off-season applications only (drivers contact admin
-- otherwise), those stragglers are just deleted. Guarded to only fire
-- while a season is active, so running this off-season is a no-op and
-- won't wipe legitimate open-window requests.
-- ============================================================

DELETE FROM team_join_requests
WHERE  status = 'pending'
  AND  EXISTS (SELECT 1 FROM seasons WHERE is_active);
