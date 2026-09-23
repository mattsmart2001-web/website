-- ============================================================
-- 86 delete_my_account() RPC
-- Lets a registered driver permanently delete their own account.
-- Their driver record and all race history are preserved so
-- championship standings remain intact.
--
-- What gets removed:
--   * auth.users row (login access gone)
--   * drivers.user_id cleared (driver becomes unclaimed)
--   * user_roles row for this user
--   * driver_claim_tokens for this driver
--   * pending team_join_requests cancelled
--   * removed from their current team (leader auto-promoted if needed)
--
-- No transfer window check — account deletion is always permitted.
-- ============================================================

CREATE OR REPLACE FUNCTION delete_my_account()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_user_id   uuid := auth.uid();
    v_driver_id uuid;
    v_team_id   uuid;
    v_is_leader boolean;
    v_next_lead uuid;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN json_build_object('error', 'Not authenticated.');
    END IF;

    -- Resolve to driver record
    SELECT id, current_team_id
      INTO v_driver_id, v_team_id
      FROM public.drivers
     WHERE user_id = v_user_id;

    -- Remove from team if on one (regardless of transfer window)
    IF v_team_id IS NOT NULL THEN
        SELECT (leader_driver_id = v_driver_id)
          INTO v_is_leader
          FROM public.teams
         WHERE id = v_team_id;

        IF v_is_leader THEN
            SELECT id INTO v_next_lead
              FROM public.drivers
             WHERE current_team_id = v_team_id
               AND id <> v_driver_id
             LIMIT 1;

            UPDATE public.teams
               SET leader_driver_id = v_next_lead
             WHERE id = v_team_id;
        END IF;

        UPDATE public.drivers
           SET current_team_id = NULL
         WHERE id = v_driver_id;
    END IF;

    -- Cancel pending join requests
    DELETE FROM public.team_join_requests
     WHERE driver_id = v_driver_id
       AND status    = 'pending';

    -- Clear user link on driver record (history preserved)
    UPDATE public.drivers
       SET user_id = NULL
     WHERE id = v_driver_id;

    -- Remove claim tokens
    DELETE FROM public.driver_claim_tokens
     WHERE driver_id = v_driver_id;

    -- Remove admin/driver role
    DELETE FROM public.user_roles
     WHERE user_id = v_user_id;

    -- Delete the auth account (invalidates all sessions)
    DELETE FROM auth.users
     WHERE id = v_user_id;

    RETURN json_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_my_account() TO authenticated;
