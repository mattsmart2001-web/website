-- =============================================================
-- Gran Turismo GTEC — schema v1
-- =============================================================
-- This file creates every table, enum, index, RLS policy, and
-- trigger for the GTEC platform per endurance/PLAN.md §3-4.
--
-- Apply in order:
--   1. This file (01_schema.sql)
--   2. 02_seed_defaults.sql
--
-- Safe to re-run: enum creation, table creation, and policy
-- creation are all wrapped in idempotent guards. A clean wipe
-- block is provided at the top but commented out by default —
-- uncomment if you need to start from zero during development.
-- =============================================================


-- ============================================================
-- 0. Extensions
-- ============================================================
CREATE EXTENSION IF NOT EXISTS "pgcrypto";          -- gen_random_uuid()


-- ============================================================
-- (Optional) Dev wipe — uncomment to start from a clean slate.
-- WARNING: destroys ALL data. NEVER uncomment on production.
-- ============================================================
-- DROP TABLE IF EXISTS hall_of_fame_records   CASCADE;
-- DROP TABLE IF EXISTS rules_pages            CASCADE;
-- DROP TABLE IF EXISTS media                  CASCADE;
-- DROP TABLE IF EXISTS news_articles          CASCADE;
-- DROP TABLE IF EXISTS driver_ratings         CASCADE;
-- DROP TABLE IF EXISTS steward_decisions      CASCADE;
-- DROP TABLE IF EXISTS penalties              CASCADE;
-- DROP TABLE IF EXISTS result_drivers         CASCADE;
-- DROP TABLE IF EXISTS results                CASCADE;
-- DROP TABLE IF EXISTS qualifying_results     CASCADE;
-- DROP TABLE IF EXISTS entry_drivers          CASCADE;
-- DROP TABLE IF EXISTS entries                CASCADE;
-- DROP TABLE IF EXISTS events                 CASCADE;
-- DROP TABLE IF EXISTS team_drivers           CASCADE;
-- DROP TABLE IF EXISTS team_seasons           CASCADE;
-- DROP TABLE IF EXISTS seasons                CASCADE;
-- DROP TABLE IF EXISTS points_systems         CASCADE;
-- DROP TABLE IF EXISTS drivers                CASCADE;
-- DROP TABLE IF EXISTS teams                  CASCADE;
-- DROP TABLE IF EXISTS manufacturers          CASCADE;
-- DROP TABLE IF EXISTS user_roles             CASCADE;
-- DROP TYPE  IF EXISTS user_role              CASCADE;
-- DROP TYPE  IF EXISTS team_driver_role       CASCADE;
-- DROP TYPE  IF EXISTS entry_status           CASCADE;
-- DROP TYPE  IF EXISTS stint_role             CASCADE;
-- DROP TYPE  IF EXISTS result_status          CASCADE;
-- DROP TYPE  IF EXISTS penalty_type           CASCADE;
-- DROP TYPE  IF EXISTS steward_ruling         CASCADE;
-- DROP TYPE  IF EXISTS event_status           CASCADE;
-- DROP TYPE  IF EXISTS media_type             CASCADE;
-- DROP TYPE  IF EXISTS hof_category           CASCADE;


-- ============================================================
-- 1. Enum types
-- ============================================================
DO $$ BEGIN
    CREATE TYPE user_role AS ENUM ('admin', 'steward', 'editor', 'team_manager', 'driver');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE team_driver_role AS ENUM ('lead', 'co', 'reserve');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE entry_status AS ENUM ('confirmed', 'withdrawn', 'dnq');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE stint_role AS ENUM ('starting', 'reserve');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE result_status AS ENUM ('classified', 'dnf', 'dsq', 'dns', 'withdrawn');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE penalty_type AS ENUM (
        'drive_through', 'stop_go', 'time_add', 'grid_drop',
        'dsq', 'warning', 'reprimand'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE steward_ruling AS ENUM ('no_action', 'reprimand', 'penalty', 'dsq');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE event_status AS ENUM ('scheduled', 'in_progress', 'completed', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE media_type AS ENUM ('image', 'video_embed', 'youtube');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE hof_category AS ENUM (
        'most_wins', 'most_championships', 'highest_rating',
        'most_race_hours', 'longest_win_streak',
        'most_consecutive_finishes', 'fastest_lap'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- ============================================================
-- 2. Tables (no FK dependencies first, then layer up)
-- ============================================================

-- ----- user_roles -----
-- References Supabase's built-in auth.users.
CREATE TABLE IF NOT EXISTS user_roles (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role          user_role NOT NULL,
    team_id       uuid,  -- team_id added later when teams table exists
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, role)
);
CREATE INDEX IF NOT EXISTS user_roles_user_id_idx ON user_roles (user_id);


-- ----- manufacturers -----
CREATE TABLE IF NOT EXISTS manufacturers (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name          text NOT NULL UNIQUE,
    slug          text NOT NULL UNIQUE,
    logo_url      text,
    brand_color   text,
    country       text,
    created_at    timestamptz NOT NULL DEFAULT now()
);


-- ----- points_systems -----
CREATE TABLE IF NOT EXISTS points_systems (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name                     text NOT NULL,
    points                   jsonb NOT NULL,  -- [{ "position": 1, "points": 25 }, …]
    pole_points              int NOT NULL DEFAULT 0,
    fastest_lap_points       int NOT NULL DEFAULT 0,
    finish_required_for_fl   boolean NOT NULL DEFAULT true,
    created_at               timestamptz NOT NULL DEFAULT now()
);


-- ----- seasons -----
CREATE TABLE IF NOT EXISTS seasons (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    year               int NOT NULL UNIQUE,
    name               text NOT NULL,
    slug               text NOT NULL UNIQUE,
    starts_on          date NOT NULL,
    ends_on            date NOT NULL,
    points_system_id   uuid NOT NULL REFERENCES points_systems(id),
    is_active          boolean NOT NULL DEFAULT false,
    hero_image_url     text,
    description        text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (ends_on >= starts_on)
);


-- ----- teams -----
CREATE TABLE IF NOT EXISTS teams (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name               text NOT NULL,
    slug               text NOT NULL UNIQUE,
    logo_url           text,
    founded_on         date,
    manager_user_id    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    manufacturer_id    uuid REFERENCES manufacturers(id),  -- default / latest
    home_country       text,
    bio                text,
    created_at         timestamptz NOT NULL DEFAULT now()
);

-- Now we can add the FK on user_roles.team_id (deferred because teams
-- didn't exist yet).
ALTER TABLE user_roles
    DROP CONSTRAINT IF EXISTS user_roles_team_id_fkey,
    ADD  CONSTRAINT user_roles_team_id_fkey
         FOREIGN KEY (team_id) REFERENCES teams(id) ON DELETE SET NULL;


-- ----- drivers -----
CREATE TABLE IF NOT EXISTS drivers (
    id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                    uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
    display_name               text NOT NULL,
    slug                       text NOT NULL UNIQUE,
    psn_id                     text,
    nationality                text,
    date_of_birth              date,
    bio                        text,
    photo_url                  text,
    joined_at                  date,
    current_team_id            uuid REFERENCES teams(id) ON DELETE SET NULL,
    current_manufacturer_id    uuid REFERENCES manufacturers(id) ON DELETE SET NULL,
    career_number              int,
    created_at                 timestamptz NOT NULL DEFAULT now(),
    updated_at                 timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS drivers_current_team_idx ON drivers (current_team_id);


-- ----- team_seasons (strict manufacturer-lock registration) -----
CREATE TABLE IF NOT EXISTS team_seasons (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id                     uuid NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    season_id                   uuid NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
    manufacturer_id             uuid NOT NULL REFERENCES manufacturers(id),
    registered_at               timestamptz NOT NULL DEFAULT now(),
    admin_override_at           timestamptz,
    admin_override_reason       text,
    UNIQUE (team_id, season_id)
);
CREATE INDEX IF NOT EXISTS team_seasons_season_idx ON team_seasons (season_id);


-- ----- team_drivers -----
CREATE TABLE IF NOT EXISTS team_drivers (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id            uuid NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    driver_id          uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    season_id          uuid NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
    role               team_driver_role NOT NULL DEFAULT 'co',
    joined_event_id    uuid,  -- FK to events added below
    left_event_id      uuid,
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (team_id, driver_id, season_id)
);


-- ----- events -----
CREATE TABLE IF NOT EXISTS events (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    season_id           uuid NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
    round               int NOT NULL,
    name                text NOT NULL,
    slug                text NOT NULL,
    circuit_name        text NOT NULL,
    circuit_country     text,
    circuit_length_km   numeric(5,3),
    duration_hours      numeric(4,1) NOT NULL,
    starts_at           timestamptz NOT NULL,
    ends_at             timestamptz NOT NULL,
    weather_summary     text,
    hero_image_url      text,
    status              event_status NOT NULL DEFAULT 'scheduled',
    replay_url          text,
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (season_id, round),
    UNIQUE (season_id, slug),
    CHECK (ends_at >= starts_at),
    CHECK (duration_hours > 0)
);
CREATE INDEX IF NOT EXISTS events_starts_at_idx ON events (starts_at);
CREATE INDEX IF NOT EXISTS events_status_idx     ON events (status);

-- Now backfill the deferred FKs on team_drivers.
ALTER TABLE team_drivers
    DROP CONSTRAINT IF EXISTS team_drivers_joined_event_fk,
    ADD  CONSTRAINT team_drivers_joined_event_fk
         FOREIGN KEY (joined_event_id) REFERENCES events(id) ON DELETE SET NULL,
    DROP CONSTRAINT IF EXISTS team_drivers_left_event_fk,
    ADD  CONSTRAINT team_drivers_left_event_fk
         FOREIGN KEY (left_event_id)   REFERENCES events(id) ON DELETE SET NULL;


-- ----- entries -----
CREATE TABLE IF NOT EXISTS entries (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id           uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    team_id            uuid NOT NULL REFERENCES teams(id),
    car_number         int NOT NULL,
    manufacturer_id    uuid NOT NULL REFERENCES manufacturers(id),
    car_model          text NOT NULL,
    livery_image_url   text,
    status             entry_status NOT NULL DEFAULT 'confirmed',
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, car_number),
    CHECK (car_number > 0)
);
CREATE INDEX IF NOT EXISTS entries_event_idx ON entries (event_id);
CREATE INDEX IF NOT EXISTS entries_team_idx  ON entries (team_id);


-- ----- entry_drivers -----
CREATE TABLE IF NOT EXISTS entry_drivers (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_id      uuid NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    driver_id     uuid NOT NULL REFERENCES drivers(id),
    stint_role    stint_role NOT NULL DEFAULT 'starting',
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (entry_id, driver_id)
);


-- ----- qualifying_results -----
CREATE TABLE IF NOT EXISTS qualifying_results (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id      uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    entry_id      uuid NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    position      int NOT NULL,
    best_lap_ms   int,
    gap_ms        int,
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, entry_id),
    UNIQUE (event_id, position),
    CHECK (position > 0)
);


-- ----- results -----
CREATE TABLE IF NOT EXISTS results (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id            uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    entry_id            uuid NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    finish_position     int,
    classified          boolean NOT NULL DEFAULT true,
    laps_completed      int NOT NULL DEFAULT 0,
    total_time_ms       int,
    gap_to_winner_ms    int,
    status              result_status NOT NULL DEFAULT 'classified',
    dnf_reason          text,
    fastest_lap_ms      int,
    fastest_lap_lap     int,
    points_awarded      int NOT NULL DEFAULT 0,
    fastest_lap_point   boolean NOT NULL DEFAULT false,
    pole_point          boolean NOT NULL DEFAULT false,
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, entry_id),
    CHECK (finish_position IS NULL OR finish_position > 0),
    CHECK (laps_completed >= 0),
    CHECK (points_awarded >= 0)
);
CREATE INDEX IF NOT EXISTS results_event_idx ON results (event_id);


-- ----- result_drivers -----
CREATE TABLE IF NOT EXISTS result_drivers (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    result_id       uuid NOT NULL REFERENCES results(id) ON DELETE CASCADE,
    driver_id       uuid NOT NULL REFERENCES drivers(id),
    stint_seconds   int,
    laps_driven     int,
    points_share    numeric(5,4) NOT NULL DEFAULT 1.0,  -- 0.0 to 1.0
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (result_id, driver_id),
    CHECK (points_share >= 0 AND points_share <= 1)
);


-- ----- penalties -----
CREATE TABLE IF NOT EXISTS penalties (
    id                              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id                        uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    entry_id                        uuid NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    driver_id                       uuid REFERENCES drivers(id),
    penalty_type                    penalty_type NOT NULL,
    penalty_value                   text,
    reason                          text NOT NULL,
    laps_remaining_when_applied     int,
    issued_by                       uuid REFERENCES auth.users(id),
    created_at                      timestamptz NOT NULL DEFAULT now()
);


-- ----- steward_decisions -----
CREATE TABLE IF NOT EXISTS steward_decisions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id        uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    entry_id        uuid REFERENCES entries(id) ON DELETE SET NULL,
    driver_id       uuid REFERENCES drivers(id) ON DELETE SET NULL,
    decision_no     text,
    title           text NOT NULL,
    content         text NOT NULL,
    ruling          steward_ruling NOT NULL DEFAULT 'no_action',
    issued_at       timestamptz NOT NULL DEFAULT now(),
    issued_by       uuid NOT NULL REFERENCES auth.users(id)
);


-- ----- driver_ratings -----
CREATE TABLE IF NOT EXISTS driver_ratings (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id        uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    event_id         uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    rating_before    int NOT NULL,
    rating_after     int NOT NULL,
    delta            int NOT NULL,
    reason           text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (driver_id, event_id),
    CHECK (rating_after BETWEEN 800 AND 3000)
);


-- ----- news_articles -----
CREATE TABLE IF NOT EXISTS news_articles (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title           text NOT NULL,
    slug            text NOT NULL UNIQUE,
    author_user_id  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    content_md      text NOT NULL,
    featured_image  text,
    published_at    timestamptz,
    tags            text[],
    season_id       uuid REFERENCES seasons(id) ON DELETE SET NULL,
    event_id        uuid REFERENCES events(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS news_published_at_idx ON news_articles (published_at);


-- ----- media -----
CREATE TABLE IF NOT EXISTS media (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    url           text NOT NULL,
    type          media_type NOT NULL,
    caption       text,
    season_id     uuid REFERENCES seasons(id) ON DELETE SET NULL,
    event_id      uuid REFERENCES events(id) ON DELETE SET NULL,
    driver_id     uuid REFERENCES drivers(id) ON DELETE SET NULL,
    team_id       uuid REFERENCES teams(id) ON DELETE SET NULL,
    sort_order    int NOT NULL DEFAULT 0,
    created_at    timestamptz NOT NULL DEFAULT now()
);


-- ----- rules_pages -----
CREATE TABLE IF NOT EXISTS rules_pages (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                  text NOT NULL UNIQUE,
    title                 text NOT NULL,
    content_md            text NOT NULL,
    sort_order            int NOT NULL DEFAULT 0,
    updated_at            timestamptz NOT NULL DEFAULT now(),
    updated_by_user_id    uuid REFERENCES auth.users(id) ON DELETE SET NULL
);


-- ----- hall_of_fame_records -----
CREATE TABLE IF NOT EXISTS hall_of_fame_records (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    category         hof_category NOT NULL,
    driver_id        uuid REFERENCES drivers(id) ON DELETE SET NULL,
    team_id          uuid REFERENCES teams(id) ON DELETE SET NULL,
    value            text NOT NULL,
    context          text,
    event_id         uuid REFERENCES events(id) ON DELETE SET NULL,
    sort_order       int NOT NULL DEFAULT 0,
    auto_generated   boolean NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now()
);


-- ============================================================
-- 3. updated_at touch trigger (applies to a few tables)
-- ============================================================
CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS drivers_touch       ON drivers;
CREATE TRIGGER drivers_touch        BEFORE UPDATE ON drivers       FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
DROP TRIGGER IF EXISTS news_touch          ON news_articles;
CREATE TRIGGER news_touch           BEFORE UPDATE ON news_articles FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
DROP TRIGGER IF EXISTS rules_pages_touch   ON rules_pages;
CREATE TRIGGER rules_pages_touch    BEFORE UPDATE ON rules_pages   FOR EACH ROW EXECUTE FUNCTION touch_updated_at();


-- ============================================================
-- 4. Manufacturer-lock trigger on entries
-- ============================================================
-- Enforces decision §14.4 — strict manufacturer lock. Every entry's
-- manufacturer must match the team's locked manufacturer for that
-- season (from team_seasons). Throws on mismatch.
CREATE OR REPLACE FUNCTION check_entry_manufacturer_lock()
RETURNS TRIGGER AS $$
DECLARE
    season_id_v uuid;
    locked_mfr  uuid;
BEGIN
    SELECT season_id INTO season_id_v FROM events WHERE id = NEW.event_id;
    IF season_id_v IS NULL THEN
        RAISE EXCEPTION 'Entry references event that does not exist (%)', NEW.event_id;
    END IF;

    SELECT manufacturer_id INTO locked_mfr
    FROM team_seasons
    WHERE team_id = NEW.team_id AND season_id = season_id_v;

    IF locked_mfr IS NULL THEN
        RAISE EXCEPTION
            'Team % is not registered for season % — create a team_seasons row first.',
            NEW.team_id, season_id_v;
    END IF;

    IF NEW.manufacturer_id <> locked_mfr THEN
        RAISE EXCEPTION
            'Entry manufacturer (%) does not match the team-season lock (%).',
            NEW.manufacturer_id, locked_mfr;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS entries_mfr_lock ON entries;
CREATE TRIGGER entries_mfr_lock
    BEFORE INSERT OR UPDATE OF manufacturer_id, team_id, event_id ON entries
    FOR EACH ROW EXECUTE FUNCTION check_entry_manufacturer_lock();


-- ============================================================
-- 5. has_role() helper for RLS
-- ============================================================
CREATE OR REPLACE FUNCTION has_role(check_role user_role)
RETURNS boolean AS $$
    SELECT EXISTS (
        SELECT 1 FROM user_roles
        WHERE user_id = auth.uid()
          AND role    = check_role
    );
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ============================================================
-- 6. Row-Level Security
-- ============================================================
-- Public read for competition data, admin write everywhere, with
-- specific carve-outs for team_manager / driver / editor / steward.

-- Pattern macros aren't a thing in SQL so we repeat the policy
-- blocks explicitly. Each table:
--   1. ENABLE RLS
--   2. DROP IF EXISTS each policy then CREATE
-- Makes the file idempotent.

DO $$
DECLARE t text;
BEGIN
    FOR t IN
        SELECT unnest(ARRAY[
            'manufacturers','points_systems','seasons','teams','drivers',
            'team_seasons','team_drivers','events','entries','entry_drivers',
            'qualifying_results','results','result_drivers','penalties',
            'steward_decisions','driver_ratings','news_articles','media',
            'rules_pages','hall_of_fame_records','user_roles'
        ])
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    END LOOP;
END $$;

-- Public read on competition + content tables
DO $$
DECLARE t text;
BEGIN
    FOR t IN
        SELECT unnest(ARRAY[
            'manufacturers','points_systems','seasons','teams','drivers',
            'team_seasons','team_drivers','events','entries','entry_drivers',
            'qualifying_results','results','result_drivers','penalties',
            'steward_decisions','driver_ratings','media','rules_pages',
            'hall_of_fame_records'
        ])
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS "public read" ON %I', t);
        EXECUTE format('CREATE POLICY "public read" ON %I FOR SELECT USING (true)', t);
    END LOOP;
END $$;

-- News: public read only when published
DROP POLICY IF EXISTS "public read published" ON news_articles;
CREATE POLICY "public read published" ON news_articles
    FOR SELECT USING (published_at IS NOT NULL AND published_at <= now());

-- user_roles: a user can read only their own roles, admins can read all
DROP POLICY IF EXISTS "self read" ON user_roles;
CREATE POLICY "self read" ON user_roles
    FOR SELECT USING (user_id = auth.uid() OR has_role('admin'));

-- Admin write on all data tables
DO $$
DECLARE t text;
BEGIN
    FOR t IN
        SELECT unnest(ARRAY[
            'manufacturers','points_systems','seasons','teams','drivers',
            'team_seasons','team_drivers','events','entries','entry_drivers',
            'qualifying_results','results','result_drivers','penalties',
            'driver_ratings','media','rules_pages','hall_of_fame_records',
            'user_roles'
        ])
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS "admin write" ON %I', t);
        EXECUTE format(
            'CREATE POLICY "admin write" ON %I FOR ALL USING (has_role(''admin''))
             WITH CHECK (has_role(''admin''))', t);
    END LOOP;
END $$;

-- Stewards can author steward_decisions + penalties
DROP POLICY IF EXISTS "steward write decisions" ON steward_decisions;
CREATE POLICY "steward write decisions" ON steward_decisions
    FOR ALL USING (has_role('steward') OR has_role('admin'))
    WITH CHECK (has_role('steward') OR has_role('admin'));

DROP POLICY IF EXISTS "steward write penalties" ON penalties;
CREATE POLICY "steward write penalties" ON penalties
    FOR ALL USING (has_role('steward') OR has_role('admin'))
    WITH CHECK (has_role('steward') OR has_role('admin'));

-- Editors can manage news + media
DROP POLICY IF EXISTS "editor write news" ON news_articles;
CREATE POLICY "editor write news" ON news_articles
    FOR ALL USING (has_role('editor') OR has_role('admin'))
    WITH CHECK (has_role('editor') OR has_role('admin'));

DROP POLICY IF EXISTS "editor write media" ON media;
CREATE POLICY "editor write media" ON media
    FOR ALL USING (has_role('editor') OR has_role('admin'))
    WITH CHECK (has_role('editor') OR has_role('admin'));

-- Team managers can update their own team row + team_drivers + team_seasons
DROP POLICY IF EXISTS "team manager update own team" ON teams;
CREATE POLICY "team manager update own team" ON teams
    FOR UPDATE USING (manager_user_id = auth.uid() OR has_role('admin'))
    WITH CHECK (manager_user_id = auth.uid() OR has_role('admin'));

-- Drivers can update their own profile row (bio, photo etc. only — admin
-- still required to change current_team_id, current_manufacturer_id, etc.)
-- We enforce the column-level restriction at the application layer; the
-- DB allows the row update but the admin UI is the canonical channel for
-- the protected fields.
DROP POLICY IF EXISTS "driver update own profile" ON drivers;
CREATE POLICY "driver update own profile" ON drivers
    FOR UPDATE USING (user_id = auth.uid() OR has_role('admin'))
    WITH CHECK (user_id = auth.uid() OR has_role('admin'));

-- Storage bucket policies are managed in the Supabase dashboard separately
-- (see SETUP.md for the gtec-* bucket configuration).

-- ============================================================
-- 7. Done.
-- ============================================================
-- Next: run 02_seed_defaults.sql to insert the F1 points system and
-- any other starter data; then follow SETUP.md to bootstrap the first
-- admin user.
