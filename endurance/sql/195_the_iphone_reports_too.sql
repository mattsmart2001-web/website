-- ============================================================
-- 195 The iPhone reports too
--
-- live_client_slug is the gate on what a reporter may call itself: the
-- value reaches the page and becomes a badge beside a driver's name, so it
-- is matched against a fixed list and anything unrecognised is stored as
-- nothing rather than passed through. That list has android, windows, mac
-- and linux on it, which was everything that existed.
--
-- There is now an iPhone reporter, so there is an ios.
-- ============================================================

CREATE OR REPLACE FUNCTION public.live_client_slug(p_client text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE lower(COALESCE(p_client, ''))
             WHEN 'android' THEN 'android'
             WHEN 'ios'     THEN 'ios'
             WHEN 'iphone'  THEN 'ios'
             WHEN 'ipad'    THEN 'ios'
             WHEN 'windows' THEN 'windows'
             WHEN 'win32'   THEN 'windows'
             WHEN 'mac'     THEN 'mac'
             WHEN 'darwin'  THEN 'mac'
             WHEN 'linux'   THEN 'linux'
             ELSE NULL
           END;
$$;

GRANT EXECUTE ON FUNCTION public.live_client_slug(text) TO anon, authenticated;
