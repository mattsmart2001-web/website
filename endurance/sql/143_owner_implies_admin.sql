-- ============================================================
-- 143 An owner always carries admin
--
-- 142 relied on the owner also holding an admin row, because all 87
-- hand-rolled gates in the existing RPCs test for `admin` exactly. That
-- was documented and nothing enforced it, so the obvious action in the
-- Supabase table editor — change your own row from admin to owner —
-- silently removed every write permission and left the console treating
-- the owner as read-only.
--
-- The invariant is now the database's job rather than something to
-- remember:
--
--   * granting owner grants admin alongside it
--   * removing admin from someone who is still an owner puts it back
--
-- To step down properly, remove the owner row first, then the admin row.
--
-- Also backfills any existing owner who is missing admin, which repairs
-- exactly the state above.
-- ============================================================

-- ---- repair first, so a live console comes back immediately ----
INSERT INTO user_roles (user_id, role)
SELECT o.user_id, 'admin'::user_role
FROM   user_roles o
WHERE  o.role::text = 'owner'
  AND  NOT EXISTS (
        SELECT 1 FROM user_roles a
        WHERE a.user_id = o.user_id AND a.role::text = 'admin')
ON CONFLICT (user_id, role) DO NOTHING;


-- ---- keep it true from here on ----
CREATE OR REPLACE FUNCTION public.owner_implies_admin()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Someone was made owner: make sure admin rides along.
    IF TG_OP = 'INSERT' AND NEW.role::text = 'owner' THEN
        INSERT INTO user_roles (user_id, role)
        VALUES (NEW.user_id, 'admin'::user_role)
        ON CONFLICT (user_id, role) DO NOTHING;
        RETURN NEW;
    END IF;

    -- Someone's admin row was removed while they are still an owner:
    -- put it back rather than leaving an owner who cannot write.
    IF TG_OP = 'DELETE' AND OLD.role::text = 'admin' THEN
        IF EXISTS (SELECT 1 FROM user_roles
                    WHERE user_id = OLD.user_id AND role::text = 'owner') THEN
            INSERT INTO user_roles (user_id, role)
            VALUES (OLD.user_id, 'admin'::user_role)
            ON CONFLICT (user_id, role) DO NOTHING;
        END IF;
        RETURN OLD;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS user_roles_owner_implies_admin ON user_roles;
CREATE TRIGGER user_roles_owner_implies_admin
    AFTER INSERT OR DELETE ON user_roles
    FOR EACH ROW EXECUTE FUNCTION public.owner_implies_admin();


-- ---- and a guard against the specific edit that caused this ----
-- Changing a row's role in place (admin -> owner) is an UPDATE, which
-- neither branch above sees. Catch it by treating the update as a
-- removal of the old role and an addition of the new one.
CREATE OR REPLACE FUNCTION public.owner_implies_admin_on_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.role::text = 'owner' OR OLD.role::text = 'admin' THEN
        INSERT INTO user_roles (user_id, role)
        VALUES (NEW.user_id, 'admin'::user_role)
        ON CONFLICT (user_id, role) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_roles_owner_implies_admin_upd ON user_roles;
CREATE TRIGGER user_roles_owner_implies_admin_upd
    AFTER UPDATE OF role ON user_roles
    FOR EACH ROW
    WHEN (NEW.role::text = 'owner' OR OLD.role::text = 'admin')
    EXECUTE FUNCTION public.owner_implies_admin_on_update();
