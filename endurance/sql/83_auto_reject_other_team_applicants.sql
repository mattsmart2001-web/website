-- ============================================================
-- 83 Auto-reject other pending applicants when a team fills up
--
-- When approve_team_join_request fills the last seat on a team,
-- any remaining pending applications to that team are automatically
-- rejected so drivers see "rejected" instead of "pending forever".
--
-- Only fires when the team becomes full — if there are still open
-- seats after an approval, other applicants stay pending (they may
-- still be accepted).
--
-- Unique constraint note: UNIQUE(team_id, driver_id, status) means
-- we can't update a pending row to 'rejected' if the same driver
-- already has a historical 'rejected' row for that team. We delete
-- the stale rejected row first, then update.
-- ============================================================

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

    -- Approve: link driver to team.
    UPDATE public.drivers
       SET current_team_id = req.team_id
     WHERE id = req.driver_id;

    UPDATE public.team_join_requests
       SET status     = 'approved',
           decided_at = now(),
           decided_by = auth.uid()
     WHERE id = p_request_id;

    -- Cancel any other pending requests FROM THIS DRIVER to other teams
    -- (they can only be on one team). Delete rather than update to avoid
    -- the unique constraint on (team_id, driver_id, status).
    DELETE FROM public.team_join_requests
     WHERE driver_id = req.driver_id
       AND status    = 'pending'
       AND id        <> p_request_id;

    -- If the team is now full, auto-reject everyone else who applied.
    -- Remove stale 'rejected' rows first to avoid unique constraint clash,
    -- then update the pending ones to 'rejected'.
    IF (current_cnt + 1) >= team_row.max_drivers THEN
        DELETE FROM public.team_join_requests stale
         WHERE stale.team_id  = req.team_id
           AND stale.status   = 'rejected'
           AND EXISTS (
               SELECT 1 FROM public.team_join_requests pending
                WHERE pending.team_id   = req.team_id
                  AND pending.driver_id = stale.driver_id
                  AND pending.status    = 'pending'
                  AND pending.id        <> p_request_id
           );

        UPDATE public.team_join_requests
           SET status     = 'rejected',
               decided_at = now(),
               decided_by = auth.uid()
         WHERE team_id = req.team_id
           AND status  = 'pending'
           AND id      <> p_request_id;
    END IF;

    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION approve_team_join_request(uuid) TO authenticated;
