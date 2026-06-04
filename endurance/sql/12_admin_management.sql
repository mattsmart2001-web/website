-- ============================================================
-- 12 Admin management RPCs
-- SECURITY DEFINER helpers so admins can list, grant, and revoke
-- admin access from the admin UI without needing service-role key.
-- ============================================================

-- List all current admins (joined with their email)
CREATE OR REPLACE FUNCTION list_admins()
RETURNS TABLE(user_id uuid, email text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin') THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    RETURN QUERY
    SELECT u.id, u.email::text, ur.created_at
    FROM   user_roles ur
    JOIN   auth.users u ON u.id = ur.user_id
    WHERE  ur.role = 'admin'
    ORDER  BY ur.created_at;
END;
$$;


-- Grant admin role to an existing auth user (looked up by email)
CREATE OR REPLACE FUNCTION grant_admin(p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    target_id uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin') THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT id INTO target_id FROM auth.users WHERE lower(email) = lower(p_email);
    IF target_id IS NULL THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error', 'No auth user with that email. Have them sign up at /endurance/admin/login first.'
        );
    END IF;

    INSERT INTO user_roles (user_id, role)
    VALUES (target_id, 'admin')
    ON CONFLICT (user_id, role) DO NOTHING;

    RETURN jsonb_build_object('ok', true, 'user_id', target_id);
END;
$$;


-- Revoke admin role
CREATE OR REPLACE FUNCTION revoke_admin(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin') THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    IF p_user_id = auth.uid() THEN
        RETURN jsonb_build_object('ok', false, 'error', 'You cannot revoke your own admin access.');
    END IF;

    DELETE FROM user_roles WHERE user_id = p_user_id AND role = 'admin';
    RETURN jsonb_build_object('ok', true);
END;
$$;


GRANT EXECUTE ON FUNCTION list_admins()         TO authenticated;
GRANT EXECUTE ON FUNCTION grant_admin(text)     TO authenticated;
GRANT EXECUTE ON FUNCTION revoke_admin(uuid)    TO authenticated;
