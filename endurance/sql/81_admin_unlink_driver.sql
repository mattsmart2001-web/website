-- ============================================================
-- 81 Admin unlink driver
-- Clears a driver's user_id, revokes their driver role, and
-- deletes all claim tokens so the admin can issue a fresh link
-- without touching the driver record or race history.
-- ============================================================

CREATE OR REPLACE FUNCTION admin_unlink_driver(p_driver_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id uuid;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM user_roles
        WHERE user_id = auth.uid() AND role = 'admin'
    ) THEN
        RETURN json_build_object('error', 'Forbidden');
    END IF;

    SELECT user_id INTO v_user_id
    FROM drivers
    WHERE id = p_driver_id;

    IF NOT FOUND THEN
        RETURN json_build_object('error', 'Driver not found');
    END IF;

    -- Revoke driver portal access
    IF v_user_id IS NOT NULL THEN
        DELETE FROM user_roles
        WHERE user_id = v_user_id AND role = 'driver';
    END IF;

    -- Detach auth account from driver record
    UPDATE drivers SET user_id = NULL WHERE id = p_driver_id;

    -- Clear all existing claim tokens so a fresh one can be issued
    DELETE FROM driver_claim_tokens WHERE driver_id = p_driver_id;

    RETURN json_build_object('success', true, 'had_user', v_user_id IS NOT NULL);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_unlink_driver(uuid) TO authenticated;
