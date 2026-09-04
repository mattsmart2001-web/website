-- ============================================================
-- 103 Team banner image
--
-- Lets a team's leader upload a wide banner image (3:1, object-fit:
-- cover on display — no strict dimension validation, same approach as
-- the driver avatar upload), shown on the public teams grid and the
-- team's own profile page hero.
-- ============================================================

ALTER TABLE teams
    ADD COLUMN IF NOT EXISTS banner_url text;

-- Storage bucket for banner uploads. 5MB cap; object name convention is
-- "{team_id}.{ext}" so RLS can tie an upload back to the team without a
-- separate lookup table.
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('gtec-team-banners', 'gtec-team-banners', true, 5242880)
ON CONFLICT (id) DO UPDATE SET file_size_limit = EXCLUDED.file_size_limit;

CREATE POLICY "public read gtec-team-banners" ON storage.objects
    FOR SELECT TO public USING (bucket_id = 'gtec-team-banners');

CREATE POLICY "team leader uploads own banner" ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'gtec-team-banners'
        AND EXISTS (
            SELECT 1 FROM teams t
            JOIN drivers d ON d.id = t.leader_driver_id
            WHERE d.user_id = auth.uid()
              AND split_part(name, '.', 1) = t.id::text
        )
    );

CREATE POLICY "team leader updates own banner" ON storage.objects
    FOR UPDATE TO authenticated
    USING (
        bucket_id = 'gtec-team-banners'
        AND EXISTS (
            SELECT 1 FROM teams t
            JOIN drivers d ON d.id = t.leader_driver_id
            WHERE d.user_id = auth.uid()
              AND split_part(name, '.', 1) = t.id::text
        )
    )
    WITH CHECK (
        bucket_id = 'gtec-team-banners'
        AND EXISTS (
            SELECT 1 FROM teams t
            JOIN drivers d ON d.id = t.leader_driver_id
            WHERE d.user_id = auth.uid()
              AND split_part(name, '.', 1) = t.id::text
        )
    );

CREATE POLICY "team leader deletes own banner" ON storage.objects
    FOR DELETE TO authenticated
    USING (
        bucket_id = 'gtec-team-banners'
        AND EXISTS (
            SELECT 1 FROM teams t
            JOIN drivers d ON d.id = t.leader_driver_id
            WHERE d.user_id = auth.uid()
              AND split_part(name, '.', 1) = t.id::text
        )
    );
