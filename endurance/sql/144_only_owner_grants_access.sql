-- ============================================================
-- 144 Only the owner grants console access
--
-- 142 let an admin grant and revoke the viewer role, on the reasoning
-- that a viewer cannot change anything so it was a low-risk delegation.
-- That misses what a viewer can READ: every driver's date of birth, PSN
-- and Discord handle, the applications, and the internal reasons behind
-- availability bans. Handing someone that is a decision about drivers'
-- personal data, not an operational one, so it sits with the owner
-- rather than with whoever is running race night.
--
-- Both functions now require owner for every role. The guards against
-- locking the console out are unchanged.
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_grant_role(p_email text, p_role text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid uuid;
BEGIN
    IF p_role NOT IN ('owner', 'admin', 'viewer') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Unknown role.');
    END IF;

    -- Console access is the owner's to give, viewer included: a viewer
    -- reads personal data even though they cannot change anything.
    IF NOT public.is_owner() THEN
        RETURN jsonb_build_object('ok', false,
            'error', 'Only the owner can grant console access.');
    END IF;

    SELECT id INTO v_uid FROM auth.users WHERE lower(email) = lower(btrim(p_email));
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'error', 'No GTEC account with that email. They need to sign up and log in once first.');
    END IF;

    INSERT INTO user_roles (user_id, role)
    VALUES (v_uid, p_role::user_role)
    ON CONFLICT (user_id, role) DO NOTHING;

    RETURN jsonb_build_object('ok', true, 'user_id', v_uid, 'role', p_role);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_revoke_role(p_user_id uuid, p_role text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RETURN jsonb_build_object('ok', false,
            'error', 'Only the owner can remove console access.');
    END IF;

    -- Never strip the last owner, and never your own owner row: either
    -- would leave nobody able to manage roles.
    IF p_role = 'owner' THEN
        IF p_user_id = auth.uid() THEN
            RETURN jsonb_build_object('ok', false,
                'error', 'You cannot remove your own owner role.');
        END IF;
        IF (SELECT COUNT(*) FROM user_roles WHERE role::text = 'owner') <= 1 THEN
            RETURN jsonb_build_object('ok', false,
                'error', 'That is the last owner.');
        END IF;
    END IF;

    DELETE FROM user_roles WHERE user_id = p_user_id AND role::text = p_role;
    RETURN jsonb_build_object('ok', true);
END;
$$;

-- The list stays readable by any console user, so an admin can still see
-- who holds what without being able to change it.
