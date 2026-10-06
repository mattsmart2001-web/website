-- ============================================================
-- 07 Content: News, Media, Pages
-- ============================================================

-- News articles
CREATE TABLE IF NOT EXISTS news (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title        text NOT NULL,
    slug         text UNIQUE NOT NULL,
    excerpt      text,
    body         text NOT NULL DEFAULT '',
    cover_url    text,
    author       text,
    tags         text[],
    is_published boolean NOT NULL DEFAULT false,
    published_at timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

-- Media items (race photos, etc.)
CREATE TABLE IF NOT EXISTS media_items (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title      text,
    url        text NOT NULL,
    caption    text,
    event_id   uuid REFERENCES events(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Static pages (rules, about, etc.)
CREATE TABLE IF NOT EXISTS pages (
    slug       text PRIMARY KEY,
    title      text NOT NULL,
    body       text NOT NULL DEFAULT '',
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Seed rules page
INSERT INTO pages (slug, title, body)
VALUES ('rules', 'Sporting Regulations', '<p>No regulations have been published yet. Check back soon.</p>')
ON CONFLICT DO NOTHING;

-- RLS
ALTER TABLE news ENABLE ROW LEVEL SECURITY;
ALTER TABLE media_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE pages ENABLE ROW LEVEL SECURITY;

-- Public reads
CREATE POLICY "public read published news" ON news
    FOR SELECT TO public USING (is_published = true);

CREATE POLICY "public read media" ON media_items
    FOR SELECT TO public USING (true);

CREATE POLICY "public read pages" ON pages
    FOR SELECT TO public USING (true);

-- Auth full access
CREATE POLICY "auth full news" ON news
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "auth full media" ON media_items
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "auth full pages" ON pages
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Storage bucket for media photos
INSERT INTO storage.buckets (id, name, public)
VALUES ('gtec-media', 'gtec-media', true)
ON CONFLICT DO NOTHING;

CREATE POLICY "public read gtec-media" ON storage.objects
    FOR SELECT TO public USING (bucket_id = 'gtec-media');

CREATE POLICY "auth upload gtec-media" ON storage.objects
    FOR INSERT TO authenticated WITH CHECK (bucket_id = 'gtec-media');

CREATE POLICY "auth update gtec-media" ON storage.objects
    FOR UPDATE TO authenticated USING (bucket_id = 'gtec-media');

CREATE POLICY "auth delete gtec-media" ON storage.objects
    FOR DELETE TO authenticated USING (bucket_id = 'gtec-media');
