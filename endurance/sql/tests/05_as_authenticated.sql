-- 05 The lobby functions, called as the roles the website calls them as
--
-- 04 ran as the owner of the schema, which proves the logic and hides
-- everything about permission: an owner has every grant there is and
-- bypasses the policies on their own tables. The site arrives as `anon`
-- or as `authenticated`, so that is who asks here.
--
-- Written after the panel went out and posting failed on the real site
-- with the database saying nothing useful. It was not this, but "it was
-- not the database" is worth being able to establish in one command
-- rather than by reasoning about it.
INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-0000000000b1')
ON CONFLICT DO NOTHING;
INSERT INTO drivers (id, display_name, slug, user_id) VALUES
    ('00000000-0000-0000-0000-0000000000e1', 'Auth Role Test', 'auth-role-test',
     '00000000-0000-0000-0000-0000000000b1')
ON CONFLICT (id) DO UPDATE SET user_id = EXCLUDED.user_id;

DO $$ BEGIN PERFORM set_config('request.jwt.claim.sub',
    '00000000-0000-0000-0000-0000000000b1', false); END $$;

SET ROLE authenticated;
\echo -n '  as authenticated, post:  '
SELECT public.post_lobby_code('TESTCODE1')::text;
\echo -n '  as authenticated, read:  '
SELECT public.live_lobby_codes()::text;
\echo -n '  as authenticated, clear: '
SELECT public.clear_lobby_code()::text;
RESET ROLE;

SET ROLE anon;
\echo -n '  as anon, read:           '
SELECT public.live_lobby_codes()::text;
\echo -n '  as anon, post:           '
DO $$ BEGIN PERFORM public.post_lobby_code('NOPE1234');
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'refused, as it should be'; END $$;
RESET ROLE;
