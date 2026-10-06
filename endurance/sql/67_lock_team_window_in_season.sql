-- ============================================================
-- 67 Lock team changes once the season has started racing
--
-- "Mid-season team changes" cause headaches: which team gets the
-- driver's championship points this round, do we re-allocate splits
-- mid-event, what does the constructors' table look like? Easiest
-- rule: no team moves once a race has been run.
--
-- Definition of "mid-season":
--   * an active season exists, AND
--   * at least one result has been recorded for an event in it.
-- Pre-season (active season but no races yet) — still fine, so
-- admin can finalise rosters during setup. Offseason (no active
-- season) — also fine.
--
-- Two enforcement points:
--   1. team_join_requests INSERT policy refuses new applications.
--   2. approve_team_join_request RPC refuses to approve pending
--      ones (the application can still sit pending; it just can't
--      be actioned).
-- In both cases admin still bypasses, so they can intervene for
-- a driver who quits the league entirely.
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_team_window_open()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT NOT EXISTS (
        SELECT 1
        FROM   public.results res
        JOIN   public.events  ev ON ev.id = res.event_id
        JOIN   public.seasons s  ON s.id  = ev.season_id
        WHERE  s.is_active
    );
$$;

GRANT EXECUTE ON FUNCTION public.is_team_window_open() TO anon, authenticated;


-- Replace the INSERT policy so the window check applies to fresh
-- applications. Admin still gets through.
DROP POLICY IF EXISTS "driver inserts own join request" ON team_join_requests;
CREATE POLICY "driver inserts own join request" ON team_join_requests
    FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (SELECT 1 FROM drivers d WHERE d.id = driver_id AND d.user_id = auth.uid())
        AND (
            public.is_team_window_open()
            OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
        )
    );


-- Replace approve_team_join_request so it refuses to approve pending
-- requests once racing has started. Admin still bypasses.
CREATE OR REPLACE FUNCTION approve_team_join_request(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    req         team_join_requests%ROWTYPE;
    team_row    teams%ROWTYPE;
    current_cnt int;
    is_admin    bool;
BEGIN
    SELECT * INTO req FROM public.team_join_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Request not found.');
    END IF;
    IF req.status <> 'pending' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Request is no longer pending.');
    END IF;

    SELECT * INTO team_row FROM public.teams WHERE id = req.team_id;

    is_admin := EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin');

    -- Permission: admin OR the team's leader.
    IF NOT (
        is_admin
        OR EXISTS (
            SELECT 1 FROM public.drivers d
            WHERE  d.id = team_row.leader_driver_id AND d.user_id = auth.uid()
        )
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    -- Season window check: once the active season has any results, no
    -- more team changes via this flow. Admin overrides.
    IF NOT is_admin AND NOT public.is_team_window_open() THEN
        RETURN jsonb_build_object('ok', false,
            'error', 'Team changes are locked until the end of the current season.');
    END IF;

    -- Capacity check.
    SELECT COUNT(*) INTO current_cnt FROM public.drivers
    WHERE  current_team_id = req.team_id;
    IF current_cnt >= team_row.max_drivers THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Team is already full.');
    END IF;

    UPDATE public.drivers
       SET current_team_id = req.team_id
     WHERE id = req.driver_id;

    UPDATE public.team_join_requests
       SET status     = 'approved',
           decided_at = now(),
           decided_by = auth.uid()
     WHERE id = p_request_id;

    -- Auto-decline any other pending requests for this driver — they
    -- can only be on one team at a time.
    UPDATE public.team_join_requests
       SET status     = 'cancelled',
           decided_at = now(),
           decided_by = auth.uid()
     WHERE driver_id  = req.driver_id
       AND status     = 'pending'
       AND id         <> p_request_id;

    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION approve_team_join_request(uuid) TO authenticated;
