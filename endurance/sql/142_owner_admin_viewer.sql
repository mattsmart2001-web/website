-- ============================================================
-- 142 Owner / admin / viewer
--
-- Three tiers for console access:
--
--   owner   Matt. Everything an admin can do, plus managing roles.
--   admin   Full operational access. May add and remove viewers, but
--           cannot promote anyone to admin or owner.
--   viewer  Sees the console, changes nothing, no access to driver
--           messages.
--
-- The owner also holds an `admin` row. That is deliberate: every one of
-- the 87 hand-rolled gates in the existing RPCs tests for `admin`
-- exactly, so carrying both rows means none of them need touching and
-- none can be missed. `owner` is purely an extra marker that unlocks
-- role management, never a replacement for `admin`.
--
-- Read-only needs no enforcement work. Every write gate, in the RPCs
-- and in RLS, requires `admin` exactly, so a viewer is already refused
-- everywhere. This migration therefore only ADDS read policies, never
-- widens a write one: a FOR SELECT policy cannot grant a write, so
-- there is no way for this to hand out more than intended. Anything
-- overlooked stays invisible to a viewer rather than editable.
--
-- Messages are deliberately excluded (driver_contact_messages,
-- message_thread_posts), as are driver_claim_tokens, which are
-- effectively credentials for claiming a driver profile.
-- ============================================================

ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'owner';
ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'viewer';


-- ============================================================
-- Helpers. Comparisons are on text so the new labels are usable in the
-- same transaction that adds them.
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_owner()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (SELECT 1 FROM user_roles
                    WHERE user_id = auth.uid() AND role::text = 'owner');
$$;

-- Anyone allowed to open the console at all.
CREATE OR REPLACE FUNCTION public.is_console_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (SELECT 1 FROM user_roles
                    WHERE user_id = auth.uid()
                      AND role::text IN ('owner', 'admin', 'viewer'));
$$;

CREATE OR REPLACE FUNCTION public.is_viewer()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (SELECT 1 FROM user_roles
                    WHERE user_id = auth.uid() AND role::text = 'viewer');
$$;

GRANT EXECUTE ON FUNCTION public.is_owner(), public.is_console_user(),
                          public.is_viewer() TO authenticated;


-- ============================================================
-- Viewer reads. Added as separate SELECT policies so they sit beside
-- the admin ones and cannot affect writes.
-- ============================================================
DROP POLICY IF EXISTS "viewer reads activity log" ON admin_activity_log;
CREATE POLICY "viewer reads activity log" ON admin_activity_log
    FOR SELECT TO authenticated USING (is_viewer());

DROP POLICY IF EXISTS "viewer reads disputes" ON disputes;
CREATE POLICY "viewer reads disputes" ON disputes
    FOR SELECT TO authenticated USING (is_viewer());

DROP POLICY IF EXISTS "viewer reads screenshots" ON lobby_result_screenshots;
CREATE POLICY "viewer reads screenshots" ON lobby_result_screenshots
    FOR SELECT TO authenticated USING (is_viewer());

DROP POLICY IF EXISTS "viewer reads room codes" ON lobby_room_codes;
CREATE POLICY "viewer reads room codes" ON lobby_room_codes
    FOR SELECT TO authenticated USING (is_viewer());

DROP POLICY IF EXISTS "viewer reads join requests" ON team_join_requests;
CREATE POLICY "viewer reads join requests" ON team_join_requests
    FOR SELECT TO authenticated USING (is_viewer());

-- Drafts as well as published, so the news panel is not half empty.
DROP POLICY IF EXISTS "viewer reads news" ON news;
CREATE POLICY "viewer reads news" ON news
    FOR SELECT TO authenticated USING (is_viewer());

DROP POLICY IF EXISTS "viewer reads applications" ON applications;
CREATE POLICY "viewer reads applications" ON applications
    FOR SELECT TO authenticated USING (is_viewer());

DROP POLICY IF EXISTS "viewer reads application_emails" ON application_emails;
CREATE POLICY "viewer reads application_emails" ON application_emails
    FOR SELECT TO authenticated USING (is_viewer());

-- Everything else the console reads already carries a "public read"
-- policy from 01_schema: entries, results, result_drivers, qualifying
-- results, penalties, steward decisions, driver ratings, drivers,
-- teams, events, seasons and the rest.


-- ============================================================
-- Role management. Owner may grant anything; admin may grant only
-- viewer. The guards below stop the console locking itself out.
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_list_roles()
RETURNS TABLE (user_id uuid, email text, roles text[], driver_name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT ur.user_id,
           u.email::text,
           array_agg(ur.role::text ORDER BY ur.role::text),
           MAX(d.display_name)
    FROM   user_roles ur
    JOIN   auth.users u ON u.id = ur.user_id
    LEFT   JOIN drivers d ON d.user_id = ur.user_id
    WHERE  public.is_console_user()
      AND  ur.role::text IN ('owner', 'admin', 'viewer')
    GROUP  BY ur.user_id, u.email
    ORDER  BY u.email;
$$;

CREATE OR REPLACE FUNCTION public.admin_grant_role(p_email text, p_role text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid uuid;
BEGIN
    IF p_role NOT IN ('owner', 'admin', 'viewer') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Unknown role.');
    END IF;

    -- Only the owner hands out console power above viewer.
    IF p_role <> 'viewer' AND NOT public.is_owner() THEN
        RETURN jsonb_build_object('ok', false,
            'error', 'Only the owner can grant admin or owner.');
    END IF;
    IF NOT (public.is_owner() OR has_role('admin')) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
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
    IF p_role <> 'viewer' AND NOT public.is_owner() THEN
        RETURN jsonb_build_object('ok', false,
            'error', 'Only the owner can revoke admin or owner.');
    END IF;
    IF NOT (public.is_owner() OR has_role('admin')) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Not permitted.');
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

GRANT EXECUTE ON FUNCTION public.admin_list_roles() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_grant_role(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_revoke_role(uuid, text) TO authenticated;


-- ============================================================
-- The audit trail is what makes delegating safe, so an admin should not
-- be able to erase it. Migration 44 let any admin delete from it, which
-- meant an admin could act and then remove the record of having acted.
-- Clearing it is now the owner's call alone. Reads are unchanged.
-- ============================================================
DROP POLICY IF EXISTS "admin deletes activity log" ON admin_activity_log;
CREATE POLICY "owner deletes activity log" ON admin_activity_log
    FOR DELETE TO authenticated USING (public.is_owner());

