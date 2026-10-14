-- ============================================================
-- 126 Lock team applications for the whole active season
--
-- Rule change. Previously is_team_window_open() only closed once the
-- active season had a race result recorded, so drivers could still apply
-- to teams during pre-season. The league rule is no team changes during a
-- season at all — admin has full control of rosters while a season runs —
-- so the window is now open ONLY when there is no active season (between
-- seasons / off-season).
--
-- This single helper drives all three enforcement points, so nothing else
-- needs to change:
--   1. team_join_requests INSERT policy (blocks new applications),
--   2. approve_team_join_request RPC (blocks approvals),
--   3. the portal UI (shows "Team window closed" and hides Apply).
-- Admin still bypasses 1 and 2, and manages rosters directly on the
-- driver record regardless.
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_team_window_open()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT NOT EXISTS (SELECT 1 FROM public.seasons s WHERE s.is_active);
$$;

GRANT EXECUTE ON FUNCTION public.is_team_window_open() TO anon, authenticated;
