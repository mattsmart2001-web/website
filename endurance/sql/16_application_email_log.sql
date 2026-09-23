-- ============================================================
-- 16 Application email log
-- Tracks every acceptance / waitlist / rejection email sent so
-- admins can see what's gone out and re-send if needed.
-- ============================================================

CREATE TABLE IF NOT EXISTS application_emails (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    application_id  uuid NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
    email_type      text NOT NULL CHECK (email_type IN ('accepted','waitlisted','rejected','custom')),
    sent_to         text NOT NULL,
    sent_at         timestamptz NOT NULL DEFAULT now(),
    sent_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    provider_id     text,    -- Resend's message id, for traceability
    ok              boolean NOT NULL DEFAULT true,
    error           text
);

CREATE INDEX IF NOT EXISTS application_emails_app_idx ON application_emails (application_id, sent_at DESC);

ALTER TABLE application_emails ENABLE ROW LEVEL SECURITY;

CREATE POLICY "auth read application_emails" ON application_emails
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "auth insert application_emails" ON application_emails
    FOR INSERT TO authenticated WITH CHECK (true);
