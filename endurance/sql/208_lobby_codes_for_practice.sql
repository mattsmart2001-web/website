-- ============================================================
-- 208 Lobby codes for practice nights
--
-- Asked for by a driver, and the reason is the right one: people practise
-- alone because they do not know anyone else is out there. 158 gave the
-- league a standing nightly practice window that any paired driver can
-- report into, entered or not. This is the other half of it, a place to
-- say "I am hosting, here is the room".
--
-- 101 already holds room codes and does not cover this. That table is
-- race-day machinery: tied to an event and a lobby number, writable only
-- once splits have been notified, readable only by drivers entered in
-- that lobby. A practice night has no splits, no entries and no host, so
-- none of it applies.
--
-- Three decisions worth writing down.
--
-- ONE WORD, NO SPACES, enforced here rather than in the page. The live
-- timing page is public and is used as a broadcast overlay, so a free
-- text box on it is a sentence of someone else's choosing on your stream.
-- Letters and digits and nothing else, between 4 and 24 of them, which
-- rules out a sentence, a URL and anything with punctuation in it.
--
-- This started out as digits only, which would have been a much stronger
-- guarantee and is wrong: GT7 lobby codes carry letters as well. So the
-- format is no longer the whole defence, and it was never meant to be the
-- only one. A code can only be posted by a signed-in driver, it is shown
-- with that driver's name beside it, and an admin can take any of them
-- down. Attribution is what actually governs this; the pattern just stops
-- the box being used for prose.
--
-- The check is on the column because the page can be bypassed by anyone
-- who can open a browser console.
--
-- ONE CODE PER DRIVER, which is why driver_id is the primary key. Posting
-- again replaces your own rather than adding to the list, so a changed
-- room is an update and nobody can fill the panel on their own.
--
-- IT EXPIRES. A code from Tuesday is worse than no code at all: somebody
-- joins a dead lobby and decides the feature is broken. Four hours, or
-- when tonight's practice window shuts, whichever comes first.
-- ============================================================

CREATE TABLE IF NOT EXISTS practice_lobby_codes (
    driver_id  uuid PRIMARY KEY REFERENCES drivers(id) ON DELETE CASCADE,
    code       text        NOT NULL
               CONSTRAINT practice_lobby_codes_code_ok
               CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9-]{3,23}$'),
    posted_at  timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL
);

-- Re-asserted by name, so that running this file again over a version of
-- itself that was applied earlier replaces the pattern instead of leaving
-- the old one in place: CREATE TABLE IF NOT EXISTS does nothing to a table
-- that is already there, constraints included.
ALTER TABLE practice_lobby_codes
    DROP CONSTRAINT IF EXISTS practice_lobby_codes_code_ok;
ALTER TABLE practice_lobby_codes
    ADD  CONSTRAINT practice_lobby_codes_code_ok
         CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9-]{3,23}$');

COMMENT ON TABLE practice_lobby_codes IS
    'Lobby IDs drivers are hosting on practice nights. One live code per '
    'driver, letters and digits only, expiring. Read through '
    'live_lobby_codes(), '
    'written through post_lobby_code(); nothing reads this table directly.';

-- No policies, on purpose. Every way in is a function below, which is
-- what lets the live page read the list without the anon key being given
-- the table, and what stops a signed-in driver writing a row for somebody
-- else. RLS with no policy denies everyone; SECURITY DEFINER is the only
-- door.
ALTER TABLE practice_lobby_codes ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS practice_lobby_codes_expires_idx
    ON practice_lobby_codes (expires_at);

-- ── Reading ─────────────────────────────────────────────────
-- Anon as well as signed in, because the live page is public and the
-- whole point is that somebody who has not signed in can still see that a
-- lobby is running and go and join it.
--
-- Returns the host's name, not their id: a display name is already public
-- on the drivers page, and nothing else about them needs to travel.
CREATE OR REPLACE FUNCTION public.live_lobby_codes()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'posted_at' DESC), '[]'::jsonb)
      FROM (
        SELECT jsonb_build_object(
                   'code',      c.code,
                   'host',      d.display_name,
                   'slug',      d.slug,
                   'posted_at', c.posted_at,
                   'mine',      d.user_id IS NOT DISTINCT FROM auth.uid()
               ) AS x
          FROM practice_lobby_codes c
          JOIN drivers d ON d.id = c.driver_id
         WHERE c.expires_at > now()
      ) s;
$$;

GRANT EXECUTE ON FUNCTION public.live_lobby_codes() TO anon, authenticated;

-- ── Posting ─────────────────────────────────────────────────
-- Only the ends are trimmed. Stripping spaces from the middle was tried
-- and is how prose gets in: "join my lobby lads" becomes
-- "joinmylobbylads", which is fifteen letters with no spaces and passes
-- every check here. A space in the middle means it is not a code, and
-- saying so is both true and a two second fix for anyone who pasted one
-- with a space in. Hyphens stay, since a code may have one.
CREATE OR REPLACE FUNCTION public.post_lobby_code(p_code text)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_driver  uuid;
    v_clean   text;
    v_window  jsonb;
    v_expires timestamptz;
BEGIN
    SELECT id INTO v_driver FROM drivers WHERE user_id = auth.uid();
    IF v_driver IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'why', 'Only a signed-in driver can post a lobby code.');
    END IF;

    v_clean := btrim(COALESCE(p_code, ''));
    IF v_clean !~ '^[A-Za-z0-9][A-Za-z0-9-]{3,23}$' THEN
        RETURN jsonb_build_object('ok', false,
            'why', 'A lobby code is 4 to 24 letters and numbers, with no spaces.');
    END IF;

    -- Gone by the time practice shuts, so nobody arrives at an empty
    -- lobby tomorrow morning. Four hours otherwise, which covers an
    -- evening without covering a week.
    v_expires := now() + interval '4 hours';
    v_window  := public.live_practice_window();
    IF COALESCE((v_window->>'open')::boolean, false)
       AND (v_window->>'at')::timestamptz < v_expires THEN
        v_expires := (v_window->>'at')::timestamptz;
    END IF;

    DELETE FROM practice_lobby_codes WHERE expires_at <= now();

    INSERT INTO practice_lobby_codes (driver_id, code, posted_at, expires_at)
         VALUES (v_driver, v_clean, now(), v_expires)
    ON CONFLICT (driver_id) DO UPDATE
            SET code = EXCLUDED.code,
                posted_at = EXCLUDED.posted_at,
                expires_at = EXCLUDED.expires_at;

    RETURN jsonb_build_object('ok', true, 'code', v_clean,
                              'expires_at', v_expires);
END;
$$;

GRANT EXECUTE ON FUNCTION public.post_lobby_code(text) TO authenticated;

-- ── Taking it down ──────────────────────────────────────────
-- Your own without an argument, which is the case that matters: the lobby
-- filled up, or you have stopped hosting. An admin can clear somebody
-- else's, because somebody has to be able to.
CREATE OR REPLACE FUNCTION public.clear_lobby_code(p_driver_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_target uuid;
    v_admin  boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM user_roles ur
                    WHERE ur.user_id = auth.uid()
                      AND ur.role::text IN ('owner', 'admin')) INTO v_admin;

    IF p_driver_id IS NULL THEN
        SELECT id INTO v_target FROM drivers WHERE user_id = auth.uid();
    ELSIF v_admin THEN
        v_target := p_driver_id;
    ELSE
        RETURN jsonb_build_object('ok', false,
            'why', 'You can only take down your own lobby code.');
    END IF;

    IF v_target IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'why', 'No driver to clear.');
    END IF;

    DELETE FROM practice_lobby_codes WHERE driver_id = v_target;
    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.clear_lobby_code(uuid) TO authenticated;
