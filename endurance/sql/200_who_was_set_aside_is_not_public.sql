-- ============================================================
-- 200 Who was set aside is not public
--
-- 197 made the list of set-aside drivers readable by anyone, on the
-- reasoning that a name which was on the chart yesterday and is gone today
-- needs explaining. That reasoning covers the fact that something was set
-- aside. It does not cover the name, and it certainly does not cover the
-- reason, which is a note an admin types for whoever undoes it later and
-- which went straight onto a public page beside a real person's name.
-- "Wrong car" next to a driver, on a page anybody can link to, is a
-- published accusation. The league has a stewarding process for that and
-- this is not it.
--
-- So the list goes behind the admin check and the public gets a count.
-- Two cars' times are not being counted this session; which two is between
-- the admin and the driver.
--
-- What stays public, and why:
--
--   live_field.times_void, on a car that is out on track. Its name is on
--   the board already because it is lapping, and its Best and Last are
--   blank. Something has to account for the blank or the next hour is
--   spent telling people the timing is broken. The page shows viewers a
--   flat "Not timed" there and keeps "Set aside" for admins.
--
--   The count. It is the smallest thing that explains an absence.
--
-- A driver on the far side of a cut is not in the count, because their
-- times ARE being counted. To a viewer they are simply a driver again,
-- which is the right end of the whole exercise.
-- ============================================================

-- ---- the list: admins only ----
--
-- Checked inside the function as well as in the grant. The grant stops
-- anon; the check stops the other two hundred drivers, who are all
-- 'authenticated' and could otherwise call it straight from a console.
DROP FUNCTION IF EXISTS public.live_lap_void_list(uuid, text);

CREATE FUNCTION public.live_lap_void_list(p_event_id uuid,
                                          p_mode     text DEFAULT NULL)
RETURNS TABLE (
    driver_id    uuid,
    display_name text,
    mode         text,
    reason       text,
    laps         int,
    kept         int,
    through      timestamptz,
    created_at   timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM user_roles ur
                    WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
        RAISE EXCEPTION 'Admins only';
    END IF;

    RETURN QUERY
    SELECT v.driver_id, d.display_name, v.mode, v.reason,
           (SELECT count(*)::int FROM live_laps l
             WHERE l.event_id = v.event_id AND l.driver_id = v.driver_id
               AND l.mode = v.mode
               AND (v.through IS NULL OR l.recorded_at <= v.through)),
           (SELECT count(*)::int FROM live_laps l
             WHERE l.event_id = v.event_id AND l.driver_id = v.driver_id
               AND l.mode = v.mode
               AND v.through IS NOT NULL AND l.recorded_at > v.through),
           v.through, v.created_at
      FROM live_lap_voids v
      JOIN drivers d ON d.id = v.driver_id
     WHERE v.event_id = p_event_id
       AND (p_mode IS NULL OR v.mode = p_mode)
     ORDER BY d.display_name;
END $$;

REVOKE ALL ON FUNCTION public.live_lap_void_list(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.live_lap_void_list(uuid, text) TO authenticated;


-- ---- the count: everybody ----
--
-- Drivers, not rows: with the session picker on Everything the same person
-- can be set aside in practice and in a test, and that is one car not
-- being counted rather than two.
--
-- Only the full voids. Somebody being counted from a cut is being counted.
CREATE OR REPLACE FUNCTION public.live_lap_void_count(p_event_id uuid,
                                                      p_mode     text DEFAULT NULL)
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT count(DISTINCT v.driver_id)::int
      FROM live_lap_voids v
     WHERE v.event_id = p_event_id
       AND (p_mode IS NULL OR v.mode = p_mode)
       AND v.through IS NULL;
$$;

GRANT EXECUTE ON FUNCTION public.live_lap_void_count(uuid, text)
    TO anon, authenticated;


-- ---- the table itself ----
--
-- 197 gave live_lap_voids a public read policy, which hands out every name
-- and every reason to anyone who asks for the table directly, whatever the
-- functions above do. Dropped. Nothing reads the table except the
-- SECURITY DEFINER functions in this file and the ones before it, which
-- are not subject to RLS.
DROP POLICY IF EXISTS "public read lap voids" ON live_lap_voids;

-- Admins keep a direct read, so the admin pages can query it without a
-- function for every question.
DROP POLICY IF EXISTS "admins read lap voids" ON live_lap_voids;
CREATE POLICY "admins read lap voids" ON live_lap_voids
    FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM user_roles ur
                    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));
