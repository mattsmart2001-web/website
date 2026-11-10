-- 04 Lobby codes for practice nights (migration 208)
--
-- The panel this feeds sits on a public page that is also a broadcast
-- overlay, so the interesting cases are the refusals, not the happy path.
-- Everything here goes through the functions, because that is the only
-- way in: the table has RLS on and no policies at all.

\set QUIET on
\pset format unaligned
\pset tuples_only on
SET client_min_messages = warning;

-- Two drivers, each with a user of their own.
INSERT INTO auth.users (id) VALUES
    ('00000000-0000-0000-0000-0000000000a1'),
    ('00000000-0000-0000-0000-0000000000a2')
ON CONFLICT DO NOTHING;

INSERT INTO drivers (id, display_name, slug, user_id) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'Lobby Host One', 'lobby-host-one',
     '00000000-0000-0000-0000-0000000000a1'),
    ('00000000-0000-0000-0000-0000000000d2', 'Lobby Host Two', 'lobby-host-two',
     '00000000-0000-0000-0000-0000000000a2')
ON CONFLICT (id) DO UPDATE SET user_id = EXCLUDED.user_id;

\echo ''
\echo '  04_lobby_codes'

-- ── Signed out ──────────────────────────────────────────────
DO $$ BEGIN PERFORM set_config('request.jwt.claim.sub', '', false); END $$;
\echo -n '    signed out, posting:   '
SELECT public.post_lobby_code('12345678')->>'why';

-- ── A driver posts ──────────────────────────────────────────
DO $$ BEGIN PERFORM set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', false); END $$;

-- Letters are fine: GT7 codes carry them. Spaces and punctuation are not,
-- which is what keeps the box from being used for prose on a stream.
\echo -n '    a code with letters:   '
SELECT public.post_lobby_code('GT7LM24a')->>'code';

\echo -n '    a sentence refused:    '
SELECT public.post_lobby_code('join my lobby lads')->>'why';

\echo -n '    punctuation refused:   '
SELECT public.post_lobby_code('see bit.ly/x')->>'why';

\echo -n '    too short refused:     '
SELECT public.post_lobby_code('12')->>'why';

\echo -n '    too long refused:      '
SELECT public.post_lobby_code(repeat('A', 25))->>'why';

-- Trailing whitespace off a copy and paste is forgiven; a space in the
-- middle is not, because that is how a sentence gets in.
\echo -n '    ends trimmed:          '
SELECT public.post_lobby_code('  123456789012  ')->>'code';

\echo -n '    inner space refused:   '
SELECT public.post_lobby_code('1234 5678')->>'why';

\echo -n '    on the list as:        '
SELECT (public.live_lobby_codes()->0->>'host') || ' · '
    || (public.live_lobby_codes()->0->>'code');

-- ── Posting again replaces, it does not stack ───────────────
DO $$ BEGIN PERFORM public.post_lobby_code('999888777'); END $$;
\echo -n '    posting again:         '
SELECT jsonb_array_length(public.live_lobby_codes()) || ' code, now '
    || (public.live_lobby_codes()->0->>'code');

-- ── A second host appears ───────────────────────────────────
DO $$ BEGIN PERFORM set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', false); END $$;
DO $$ BEGIN PERFORM public.post_lobby_code('5551234'); END $$;
\echo -n '    two hosts:             '
SELECT jsonb_array_length(public.live_lobby_codes()) || ' codes';

-- ── One driver may not take down another's ──────────────────
\echo -n '    clearing another''s:    '
SELECT public.clear_lobby_code('00000000-0000-0000-0000-0000000000d1')->>'why';

-- ── But may take down their own ─────────────────────────────
DO $$ BEGIN PERFORM public.clear_lobby_code(); END $$;
\echo -n '    clearing my own:       '
SELECT jsonb_array_length(public.live_lobby_codes()) || ' code left';

-- ── Expiry ──────────────────────────────────────────────────
-- Aged by hand rather than waited for. A code nobody took down must drop
-- off the list on its own, because the lobby it names is long gone.
UPDATE practice_lobby_codes SET expires_at = now() - interval '1 minute';
\echo -n '    once expired:          '
SELECT jsonb_array_length(public.live_lobby_codes()) || ' codes';

-- ── Anonymous reading ───────────────────────────────────────
-- The live page is public, so somebody who has not signed in has to be
-- able to see that a lobby is running.
DO $$ BEGIN PERFORM set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', false); END $$;
DO $$ BEGIN PERFORM public.post_lobby_code('4242424242'); END $$;
DO $$ BEGIN PERFORM set_config('request.jwt.claim.sub', '', false); END $$;
\echo -n '    signed out, reading:   '
SELECT (public.live_lobby_codes()->0->>'code')
    || ' by ' || (public.live_lobby_codes()->0->>'host')
    || ', mine=' || (public.live_lobby_codes()->0->>'mine');

-- ── Nothing reaches the table directly ──────────────────────
-- RLS is on and there are no policies, so even with a grant nobody would
-- see a row; there is no grant either. Asked of the catalogue rather than
-- by trying the read, because the refusal is the pass and a test whose
-- successful outcome is an ERROR in the log is a test nobody trusts.
\echo -n '    table grants to anon:  '
SELECT COALESCE(string_agg(privilege_type, ', '), 'none, as it should be')
  FROM information_schema.role_table_grants
 WHERE table_name = 'practice_lobby_codes' AND grantee = 'anon';

\echo -n '    and to a signed-in:    '
SELECT COALESCE(string_agg(privilege_type, ', '), 'none, as it should be')
  FROM information_schema.role_table_grants
 WHERE table_name = 'practice_lobby_codes' AND grantee = 'authenticated';

\echo -n '    policies on the table: '
SELECT count(*) || ', so the functions are the only door'
  FROM pg_policies WHERE tablename = 'practice_lobby_codes';
