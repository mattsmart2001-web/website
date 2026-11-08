-- Enough of Supabase to let the GTEC migrations apply to a plain Postgres.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
DO $$ BEGIN
  CREATE ROLE anon NOLOGIN;        EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE service_role NOLOGIN;  EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS storage;
CREATE TABLE IF NOT EXISTS auth.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email text);
CREATE TABLE IF NOT EXISTS storage.buckets (
    id text PRIMARY KEY, name text, public boolean DEFAULT false);
CREATE TABLE IF NOT EXISTS storage.objects (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket_id text, name text, owner uuid, metadata jsonb);
-- The current user, which every policy in the schema is written against.
-- Settable from a test so a policy can be exercised as a given person.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS
$$ SELECT COALESCE(NULLIF(current_setting('request.jwt.claim.role', true), ''), 'anon') $$;
CREATE OR REPLACE FUNCTION auth.email() RETURNS text LANGUAGE sql STABLE AS
$$ SELECT NULLIF(current_setting('request.jwt.claim.email', true), '') $$;
ALTER TABLE storage.buckets
    ADD COLUMN IF NOT EXISTS file_size_limit bigint,
    ADD COLUMN IF NOT EXISTS allowed_mime_types text[],
    ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();
DO $$ BEGIN
  CREATE PUBLICATION supabase_realtime;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
