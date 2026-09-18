-- ============================================================
-- 08 Applications: Driver/team signup interest forms
-- ============================================================

CREATE TABLE IF NOT EXISTS applications (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    type                     text NOT NULL DEFAULT 'driver'
                                 CHECK (type IN ('driver', 'team')),
    name                     text NOT NULL,
    psn_id                   text,
    nationality              text,
    timezone                 text,
    preferred_manufacturer_id uuid REFERENCES manufacturers(id) ON DELETE SET NULL,
    team_name                text,
    experience               text,
    message                  text,
    status                   text NOT NULL DEFAULT 'pending'
                                 CHECK (status IN ('pending', 'accepted', 'waitlisted', 'rejected')),
    reviewer_note            text,
    created_at               timestamptz NOT NULL DEFAULT now(),
    reviewed_at              timestamptz
);

ALTER TABLE applications ENABLE ROW LEVEL SECURITY;

-- Anyone can submit an application
CREATE POLICY "public insert applications" ON applications
    FOR INSERT TO public WITH CHECK (true);

-- Only authenticated admins can read, update, delete
CREATE POLICY "auth read applications" ON applications
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "auth update applications" ON applications
    FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "auth delete applications" ON applications
    FOR DELETE TO authenticated USING (true);
