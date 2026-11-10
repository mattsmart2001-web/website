-- 06 Running 208 again over an earlier version of itself
--
-- This is the failure that actually happened, reproduced so it cannot
-- happen again.
--
-- The first version of 208 checked the code was digits only and spelled
-- the check inline with no name, so Postgres called it
-- practice_lobby_codes_code_check. The second version learned that GT7
-- codes carry letters, named its own check, and dropped only that name
-- before adding it. On a fresh database that is correct. On one that had
-- already run the first version it is not: the old check was still there,
-- so the table carried both rules, and the stricter one refused every
-- real code while nothing in the migration mentioned it.
--
-- The site reported it exactly as the database put it, which is the only
-- reason it took minutes rather than an evening:
--
--   new row for relation "practice_lobby_codes" violates check
--   constraint "practice_lobby_codes_code_check"
--
-- So: put the old constraint back by hand, run the migration over it, and
-- check that a code with letters in it is accepted afterwards.

\set QUIET on
\pset format unaligned
\pset tuples_only on
SET client_min_messages = warning;

\echo ''
\echo '  06_rerunning_208'

-- Wind the table back to what the first version of the file left behind:
-- its own unnamed, digits-only check. Emptied first, because a code with
-- letters in it left over from an earlier test stops the old constraint
-- being added at all, and then the run proves nothing while appearing to
-- pass.
DELETE FROM practice_lobby_codes;
DO $$
DECLARE c record;
BEGIN
    FOR c IN SELECT conname FROM pg_constraint
              WHERE conrelid = 'public.practice_lobby_codes'::regclass
                AND contype = 'c'
    LOOP
        EXECUTE format('ALTER TABLE practice_lobby_codes DROP CONSTRAINT %I',
                       c.conname);
    END LOOP;
END $$;
ALTER TABLE practice_lobby_codes
    ADD CONSTRAINT practice_lobby_codes_code_check CHECK (code ~ '^[0-9]{4,24}$');

INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-0000000000c1')
ON CONFLICT DO NOTHING;
INSERT INTO drivers (id, display_name, slug, user_id) VALUES
    ('00000000-0000-0000-0000-0000000000f1', 'Rerun Test', 'rerun-test',
     '00000000-0000-0000-0000-0000000000c1')
ON CONFLICT (id) DO UPDATE SET user_id = EXCLUDED.user_id;
DO $$ BEGIN PERFORM set_config('request.jwt.claim.sub',
    '00000000-0000-0000-0000-0000000000c1', false); END $$;

-- The attempt is caught, because what matters is which constraint said
-- no, not a page of SQL context in the middle of a test run.
\echo -n '    with the old check:    '
SET client_min_messages = notice;   -- the DO block below reports this way
DO $$
BEGIN
    PERFORM public.post_lobby_code('GT7LM24a');
    RAISE NOTICE 'accepted, so the old check was never there';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'refused by %, which is the bug', '"' ||
        (regexp_match(SQLERRM, 'constraint "([^"]+)"'))[1] || '"';
END $$;
SET client_min_messages = warning;

-- Now the migration, exactly as an admin would paste it in.
\i ../208_lobby_codes_for_practice.sql

\echo -n '    checks on the table:   '
SELECT string_agg(conname, ', ' ORDER BY conname)
  FROM pg_constraint
 WHERE conrelid = 'public.practice_lobby_codes'::regclass AND contype = 'c';

\echo -n '    after running it:      '
SELECT public.post_lobby_code('GT7LM24a')->>'code';

\echo -n '    and a sentence still:  '
SELECT public.post_lobby_code('join my lobby lads')->>'why';
