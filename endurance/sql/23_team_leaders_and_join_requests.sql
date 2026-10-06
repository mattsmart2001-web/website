-- ============================================================
-- 23 Team leaders + driver→team join requests
-- A team has at most one "leader" driver. The leader is set when
-- admin creates a team from a team-type application. Other drivers
-- can apply to join an under-capacity team from their portal; the
-- team leader (or any admin) approves.
-- ============================================================

-- One leader per team. ON DELETE SET NULL so deleting the leader
-- doesn't cascade-delete the team.
ALTER TABLE teams
    ADD COLUMN IF NOT EXISTS leader_driver_id uuid REFERENCES drivers(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS max_drivers      int  NOT NULL DEFAULT 2 CHECK (max_drivers > 0);

CREATE INDEX IF NOT EXISTS teams_leader_driver_idx ON teams (leader_driver_id);

-- Open-teams view: teams with at least one free seat, joined with the
-- current driver count and the leader's display name. Drivers can hit
-- this to find a team to apply to.
DROP VIEW IF EXISTS team_open_seats;
CREATE VIEW team_open_seats AS
SELECT
    t.id                          AS team_id,
    t.name                        AS team_name,
    t.slug                        AS team_slug,
    t.bio                         AS team_bio,
    t.max_drivers                 AS max_drivers,
    COALESCE(c.driver_count, 0)   AS driver_count,
    t.max_drivers - COALESCE(c.driver_count, 0) AS open_seats,
    t.leader_driver_id            AS leader_driver_id,
    lead.display_name             AS leader_name,
    lead.slug                     AS leader_slug,
    lead.psn_id                   AS leader_psn,
    m.id                          AS manufacturer_id,
    m.name                        AS manufacturer_name,
    m.brand_color                 AS brand_color,
    m.logo_url                    AS manufacturer_logo_url
FROM   teams t
LEFT JOIN (
    SELECT current_team_id, COUNT(*) AS driver_count
    FROM   drivers
    WHERE  current_team_id IS NOT NULL
    GROUP  BY current_team_id
) c ON c.current_team_id = t.id
LEFT JOIN drivers      lead ON lead.id = t.leader_driver_id
LEFT JOIN manufacturers m   ON m.id    = t.manufacturer_id;

GRANT SELECT ON team_open_seats TO anon, authenticated;


-- ----- team_join_requests -----
CREATE TABLE IF NOT EXISTS team_join_requests (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id       uuid NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    driver_id     uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    message       text,
    status        text NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','approved','rejected','cancelled')),
    decided_at    timestamptz,
    decided_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    -- One outstanding request per driver/team at a time. Done as a
    -- partial unique index so historical decided requests don't block
    -- a fresh attempt.
    UNIQUE (team_id, driver_id, status) DEFERRABLE INITIALLY IMMEDIATE
);
CREATE INDEX IF NOT EXISTS team_join_requests_team_idx   ON team_join_requests (team_id, status);
CREATE INDEX IF NOT EXISTS team_join_requests_driver_idx ON team_join_requests (driver_id, status);

ALTER TABLE team_join_requests ENABLE ROW LEVEL SECURITY;

-- Driver inserts a request for themselves.
CREATE POLICY "driver inserts own join request" ON team_join_requests
    FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (SELECT 1 FROM drivers d WHERE d.id = driver_id AND d.user_id = auth.uid())
    );

-- Driver can see their own requests; team leader sees requests for
-- their team; admins see everything.
CREATE POLICY "view own / team-leader / admin join requests" ON team_join_requests
    FOR SELECT TO authenticated
    USING (
        EXISTS (SELECT 1 FROM drivers d WHERE d.id = driver_id AND d.user_id = auth.uid())
        OR EXISTS (
            SELECT 1 FROM teams t JOIN drivers d ON d.id = t.leader_driver_id
            WHERE  t.id = team_id AND d.user_id = auth.uid()
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );

-- Driver can cancel their own pending request.
-- Team leader can approve / reject requests for their team.
-- Admins can do anything.
CREATE POLICY "decide on join requests" ON team_join_requests
    FOR UPDATE TO authenticated
    USING (
        EXISTS (SELECT 1 FROM drivers d WHERE d.id = driver_id AND d.user_id = auth.uid())
        OR EXISTS (
            SELECT 1 FROM teams t JOIN drivers d ON d.id = t.leader_driver_id
            WHERE  t.id = team_id AND d.user_id = auth.uid()
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    )
    WITH CHECK (
        EXISTS (SELECT 1 FROM drivers d WHERE d.id = driver_id AND d.user_id = auth.uid())
        OR EXISTS (
            SELECT 1 FROM teams t JOIN drivers d ON d.id = t.leader_driver_id
            WHERE  t.id = team_id AND d.user_id = auth.uid()
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );

-- Admins can delete.
CREATE POLICY "admin deletes join requests" ON team_join_requests
    FOR DELETE TO authenticated
    USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));


-- ============================================================
-- approve_team_join_request RPC
-- Atomically: marks the request approved, fills decided_*, sets
-- the driver's current_team_id (and manufacturer auto-syncs via the
-- existing trigger from migration 11).
-- ============================================================
CREATE OR REPLACE FUNCTION approve_team_join_request(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    req         team_join_requests%ROWTYPE;
    team_row    teams%ROWTYPE;
    current_cnt int;
BEGIN
    SELECT * INTO req FROM public.team_join_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Request not found.');
    END IF;
    IF req.status <> 'pending' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Request is no longer pending.');
    END IF;

    SELECT * INTO team_row FROM public.teams WHERE id = req.team_id;

    -- Permission: admin OR the team's leader.
    IF NOT (
        EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
        OR EXISTS (
            SELECT 1 FROM public.drivers d
            WHERE  d.id = team_row.leader_driver_id AND d.user_id = auth.uid()
        )
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    -- Capacity check.
    SELECT COUNT(*) INTO current_cnt FROM public.drivers
    WHERE  current_team_id = req.team_id;
    IF current_cnt >= team_row.max_drivers THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Team is already full.');
    END IF;

    UPDATE public.drivers
       SET current_team_id = req.team_id
     WHERE id = req.driver_id;

    UPDATE public.team_join_requests
       SET status     = 'approved',
           decided_at = now(),
           decided_by = auth.uid()
     WHERE id = p_request_id;

    -- Auto-decline any other pending requests for this driver — they
    -- can only be on one team at a time.
    UPDATE public.team_join_requests
       SET status     = 'cancelled',
           decided_at = now(),
           decided_by = auth.uid()
     WHERE driver_id  = req.driver_id
       AND status     = 'pending'
       AND id         <> p_request_id;

    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION approve_team_join_request(uuid) TO authenticated;
