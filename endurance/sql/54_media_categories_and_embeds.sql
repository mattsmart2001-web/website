-- ============================================================
-- 54 Media: category tag + embed-video support
-- Two new columns on media_items:
--   * category text — small fixed taxonomy for filter buttons on the
--     public gallery (Race Highlights, Liveries, Onboards, Podiums,
--     Behind the Scenes, Stewarding).
--   * embed_provider text — when set ('youtube' | 'twitch' | 'vimeo'),
--     the public gallery renders an iframe player instead of an <img>.
--     For uploaded images both columns stay null and the existing
--     <img>+url path keeps working unchanged.
--
-- A simple CHECK keeps category values consistent; admin UI uses a
-- dropdown so users won't hit it directly.
-- ============================================================

ALTER TABLE media_items
    ADD COLUMN IF NOT EXISTS category        text,
    ADD COLUMN IF NOT EXISTS embed_provider  text;

DO $$
BEGIN
    -- Drop any prior version of the check so re-running is safe.
    BEGIN
        ALTER TABLE media_items DROP CONSTRAINT IF EXISTS media_items_category_chk;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        ALTER TABLE media_items DROP CONSTRAINT IF EXISTS media_items_embed_provider_chk;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END $$;

ALTER TABLE media_items
    ADD CONSTRAINT media_items_category_chk CHECK (
        category IS NULL OR category IN (
            'race_highlights',
            'podiums',
            'liveries',
            'onboards',
            'behind_the_scenes',
            'stewarding'
        )
    ),
    ADD CONSTRAINT media_items_embed_provider_chk CHECK (
        embed_provider IS NULL OR embed_provider IN ('youtube', 'twitch', 'vimeo')
    );

CREATE INDEX IF NOT EXISTS media_items_category_idx ON media_items (category);
