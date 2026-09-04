-- Self-contained fix for approve_team_join_request.
--
-- Migration 75 depended on is_team_window_open() from migration 67,
-- which had not been run. This migration creates both so the RPC works
-- without needing 67 or 75 to have been applied first.

-- 1. Team-window helper (idempotent via CREATE OR REPLACE).
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


-- 2. Fixed approve RPC — DELETEs other pending requests instead of
--    updating them to 'cancelled', which avoids the unique constraint
--    violation on (team_id, driver_id, status).
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

    -- Delete any other pending requests for this driver rather than
    -- updating them to 'cancelled' — the unique constraint on
    -- (team_id, driver_id, status) would fire if a cancelled row
    -- already exists for the same team from a prior application.
    DELETE FROM public.team_join_requests
     WHERE driver_id = req.driver_id
       AND status    = 'pending'
       AND id        <> p_request_id;

    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION approve_team_join_request(uuid) TO authenticated;
