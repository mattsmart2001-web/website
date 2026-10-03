-- ============================================================
-- 133 Driver season cards
--
-- Career Trading Cards were "live" - the same button always paints
-- whatever your Elo/points look like right now, so there was nothing
-- to actually collect. This adds a locked snapshot: one card per
-- driver per season, generated once (by an admin, after the season
-- wraps) and frozen forever after - tier, Elo, points, wins, podiums,
-- races, and the team/manufacturer the driver raced for that season.
-- Re-running the generator (e.g. after a late results correction)
-- just overwrites the existing snapshot for that driver+season.
--
-- The card's crest and artwork are still painted on the fly from this
-- row's data by gtec-trading-card.js - nothing here is an image, just
-- the frozen stat line.
-- ============================================================

CREATE TABLE IF NOT EXISTS driver_season_cards (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id           uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    season_id           uuid NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
    season_year         int  NOT NULL,
    tier                text,
    elo                 numeric(10,2),
    points              numeric(10,2) NOT NULL DEFAULT 0,
    wins                int NOT NULL DEFAULT 0,
    podiums             int NOT NULL DEFAULT 0,
    races               int NOT NULL DEFAULT 0,
    poles               int NOT NULL DEFAULT 0,
    career_number       int,
    nationality         text,
    team_name           text,
    team_slug           text,
    manufacturer_name   text,
    manufacturer_color  text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (driver_id, season_id)
);

CREATE INDEX IF NOT EXISTS driver_season_cards_driver_idx ON driver_season_cards (driver_id);

ALTER TABLE driver_season_cards ENABLE ROW LEVEL SECURITY;

-- Public read: a driver's collection is meant to be shown off, same as
-- their career stats.
DROP POLICY IF EXISTS "public read season cards" ON driver_season_cards;
CREATE POLICY "public read season cards" ON driver_season_cards
    FOR SELECT USING (true);

-- Only admins generate/regenerate cards (the admin "Generate Season
-- Cards" action), same pattern as every other admin-managed table.
DROP POLICY IF EXISTS "admin manages season cards" ON driver_season_cards;
CREATE POLICY "admin manages season cards" ON driver_season_cards
    FOR ALL TO authenticated
    USING      (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
    WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

GRANT SELECT ON driver_season_cards TO anon, authenticated;
