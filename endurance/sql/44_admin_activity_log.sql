-- ============================================================
-- 44 Admin activity log
-- Captures every admin-initiated change to the key public tables, so
-- you can see who did what and when. Logging is auto via AFTER triggers
-- — no JS plumbing required, no chance of forgetting to log a path.
--
-- We record:
--   * who: auth.uid() + email if available
--   * what: table_name + operation + entity_id + a short summary
--   * details: JSON of new (or old, on delete) row, trimmed
--
-- Triggers are attached only to high-signal tables — we ignore
-- low-value churn (e.g. user_roles is its own thing already, ratings
-- recompute touches the standings tables constantly).
-- ============================================================

CREATE TABLE IF NOT EXISTS admin_activity_log (
    id           bigserial PRIMARY KEY,
    admin_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    admin_email  text,
    table_name   text NOT NULL,
    operation    text NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    entity_id    text,
    summary      text,
    details      jsonb,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS admin_activity_log_created_idx
    ON admin_activity_log (created_at DESC);

ALTER TABLE admin_activity_log ENABLE ROW LEVEL SECURITY;

-- Only admins see the log. INSERT happens via SECURITY DEFINER trigger,
-- so we don't need a permissive INSERT policy.
CREATE POLICY "admin reads activity log" ON admin_activity_log
    FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

CREATE POLICY "admin deletes activity log" ON admin_activity_log
    FOR DELETE TO authenticated
    USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));


-- Trigger function: writes one row per change. We skip rows where
-- auth.uid() is null (system / SECURITY DEFINER chains with no caller
-- — they'd just be noise).
CREATE OR REPLACE FUNCTION log_admin_change()
RETURNS TRIGGER AS $$
DECLARE
    v_uid     uuid := auth.uid();
    v_email   text;
    v_id      text;
    v_summary text;
    v_data    jsonb;
BEGIN
    IF v_uid IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    SELECT email INTO v_email FROM auth.users WHERE id = v_uid;

    IF TG_OP = 'DELETE' THEN
        v_data := to_jsonb(OLD);
        v_id   := COALESCE(v_data->>'id', v_data->>'slug', '');
    ELSE
        v_data := to_jsonb(NEW);
        v_id   := COALESCE(v_data->>'id', v_data->>'slug', '');
    END IF;

    -- Short human summary, table-dependent. Stick to one or two fields
    -- so the list view stays readable.
    v_summary := CASE TG_TABLE_NAME
        WHEN 'drivers'                 THEN COALESCE(v_data->>'display_name', v_id)
        WHEN 'teams'                   THEN COALESCE(v_data->>'name', v_id)
        WHEN 'manufacturers'           THEN COALESCE(v_data->>'name', v_id)
        WHEN 'events'                  THEN COALESCE(v_data->>'name', v_id)
        WHEN 'seasons'                 THEN COALESCE(v_data->>'year' || '', v_id)
        WHEN 'applications'            THEN COALESCE(v_data->>'name', v_id) || ' (' || COALESCE(v_data->>'status', '?') || ')'
        WHEN 'penalties'               THEN COALESCE(v_data->>'penalty_type', '') || ' ' || COALESCE(v_data->>'reason', '')
        WHEN 'driver_contact_messages' THEN COALESCE(v_data->>'subject', '(no subject)')
        WHEN 'news_articles'           THEN COALESCE(v_data->>'title', v_id)
        WHEN 'media_items'             THEN COALESCE(v_data->>'title', v_id)
        WHEN 'rules_pages'             THEN COALESCE(v_data->>'title', v_id)
        WHEN 'results'                 THEN 'result ' || v_id
        WHEN 'result_drivers'          THEN 'driver result ' || v_id
        WHEN 'entries'                 THEN COALESCE(v_data->>'car_number', v_id)
        WHEN 'user_roles'              THEN COALESCE(v_data->>'role', '') || ' for ' || COALESCE(v_data->>'user_id', '')
        ELSE v_id
    END;

    INSERT INTO admin_activity_log
        (admin_user_id, admin_email, table_name, operation, entity_id, summary, details)
    VALUES
        (v_uid, v_email, TG_TABLE_NAME, TG_OP, v_id, NULLIF(trim(v_summary), ''), v_data);

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- Attach to the high-signal tables. DROP-then-CREATE so re-running the
-- migration is safe.
DO $$
DECLARE
    t text;
BEGIN
    FOR t IN SELECT unnest(ARRAY[
        'drivers', 'teams', 'manufacturers', 'events', 'seasons',
        'applications', 'penalties', 'driver_contact_messages',
        'news_articles', 'media_items', 'rules_pages',
        'entries', 'results', 'result_drivers', 'user_roles'
    ])
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS admin_log_changes ON %I', t);
        EXECUTE format('CREATE TRIGGER admin_log_changes
            AFTER INSERT OR UPDATE OR DELETE ON %I
            FOR EACH ROW EXECUTE FUNCTION log_admin_change()', t);
    END LOOP;
END $$;


-- Clear the log entirely. Bypasses safeupdate's WHERE-required rule
-- because we run as SECURITY DEFINER and TRUNCATE doesn't trip it.
CREATE OR REPLACE FUNCTION clear_admin_activity_log()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    TRUNCATE admin_activity_log RESTART IDENTITY;
    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION clear_admin_activity_log() TO authenticated;
