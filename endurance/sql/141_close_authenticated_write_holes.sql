-- ============================================================
-- 141 Close four tables that any logged-in driver could write
--
-- Found while scoping read-only admin access. Four of the tables the
-- site actually uses carry policies granted to `authenticated`, which
-- is EVERY registered driver, not admins:
--
--   applications    UPDATE, DELETE  TO authenticated USING (true)
--                   SELECT          TO authenticated USING (true)
--   news            ALL             TO authenticated USING (true)
--   media_items     ALL             TO authenticated USING (true)
--   pages           ALL             TO authenticated USING (true)
--   application_emails  SELECT, INSERT  TO authenticated
--
-- The comment above the applications block even reads "Only
-- authenticated admins can read, update, delete", so the intent was
-- always admin-only; `TO authenticated` just does not mean that. The
-- admin console never offered these actions, but RLS is the only real
-- boundary and it was open to a direct API call with any driver's own
-- token. So a driver could have deleted every application, or rewritten
-- the news and the rules pages.
--
-- Note the properly gated `news_articles` and `media` tables from
-- 01_schema are the UNUSED duplicates; `news`, `media_items` and
-- `pages` are the live ones.
--
-- Every write to these tables in the site comes from the admin console,
-- and the public pages only read, so admin-only writes break nothing.
-- The apply form's insert stays open to the public, and it does not
-- read its row back, so it needs no select policy.
--
-- Reads here stay admin-only for now. The viewer role in the next
-- migration adds its own SELECT policies, which cannot grant a write.
-- ============================================================

-- ---- applications: anyone may apply, only admin may see or change ----
DROP POLICY IF EXISTS "auth read applications"   ON applications;
DROP POLICY IF EXISTS "auth update applications" ON applications;
DROP POLICY IF EXISTS "auth delete applications" ON applications;

CREATE POLICY "admin reads applications" ON applications
    FOR SELECT TO authenticated USING (has_role('admin'));

CREATE POLICY "admin writes applications" ON applications
    FOR UPDATE TO authenticated USING (has_role('admin')) WITH CHECK (has_role('admin'));

CREATE POLICY "admin deletes applications" ON applications
    FOR DELETE TO authenticated USING (has_role('admin'));

-- "public insert applications" is left exactly as it was: the apply form
-- is open to people who do not have an account yet.


-- ---- application_emails: the send log is admin-only ----
DROP POLICY IF EXISTS "auth read application_emails"   ON application_emails;
DROP POLICY IF EXISTS "auth insert application_emails" ON application_emails;

CREATE POLICY "admin reads application_emails" ON application_emails
    FOR SELECT TO authenticated USING (has_role('admin'));

CREATE POLICY "admin inserts application_emails" ON application_emails
    FOR INSERT TO authenticated WITH CHECK (has_role('admin'));


-- ---- news / media_items / pages: public reads, admin writes ----
-- The existing public SELECT policies are untouched, and policies are
-- permissive and OR together, so the site keeps reading these freely.
DROP POLICY IF EXISTS "auth full news"  ON news;
DROP POLICY IF EXISTS "auth full media" ON media_items;
DROP POLICY IF EXISTS "auth full pages" ON pages;

CREATE POLICY "admin writes news" ON news
    FOR ALL TO authenticated USING (has_role('admin')) WITH CHECK (has_role('admin'));

CREATE POLICY "admin writes media" ON media_items
    FOR ALL TO authenticated USING (has_role('admin')) WITH CHECK (has_role('admin'));

CREATE POLICY "admin writes pages" ON pages
    FOR ALL TO authenticated USING (has_role('admin')) WITH CHECK (has_role('admin'));

-- Admin still needs to read unpublished news in the console; the public
-- policy only exposes published rows, and the ALL policy above covers
-- the rest for admins.
