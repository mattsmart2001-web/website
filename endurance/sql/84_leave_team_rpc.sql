-- ============================================================
-- 84 leave_team() RPC
-- Lets a driver remove themselves from their current team during
-- the open transfer window. If they are the team leader, leadership
-- is automatically transferred to the next driver on the roster
-- (or cleared if they were the sole member).
-- ============================================================

CREATE OR REPLACE FUNCTION leave_team()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_driver_id  uuid;
    v_team_id    uuid;
    v_is_leader  boolean;
    v_next_lead  uuid;
BEGIN
    -- Resolve calling user to their driver record
    SELECT id, current_team_id
      INTO v_driver_id, v_team_id
      FROM drivers
     WHERE user_id = auth.uid();

    IF NOT FOUND OR v_team_id IS NULL THEN
        RETURN json_build_object('error', 'You are not currently on a team.');
    END IF;

    -- Enforce transfer window
    IF NOT public.is_team_window_open() THEN
        RETURN json_build_object('error', 'Team changes are locked during the active season.');
    END IF;

    -- Check leadership
    SELECT (leader_driver_id = v_driver_id)
      INTO v_is_leader
      FROM teams
     WHERE id = v_team_id;

    IF v_is_leader THEN
        -- Find another team member to promote
        SELECT id INTO v_next_lead
          FROM drivers
         WHERE current_team_id = v_team_id
           AND id <> v_driver_id
         LIMIT 1;

        UPDATE teams
           SET leader_driver_id = v_next_lead   -- NULL if no one else
         WHERE id = v_team_id;
    END IF;

    -- Leave the team
    UPDATE drivers
       SET current_team_id = NULL
     WHERE id = v_driver_id;

    -- Cancel any pending outgoing join requests
    DELETE FROM team_join_requests
     WHERE driver_id = v_driver_id
       AND status    = 'pending';

    RETURN json_build_object(
        'success',       true,
        'was_leader',    v_is_leader,
        'new_leader_id', v_next_lead
    );
END;
$$;

GRANT EXECUTE ON FUNCTION leave_team() TO authenticated;
