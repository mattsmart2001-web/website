-- ============================================================
-- 120 Disputes / Stewards
--
-- A driver can file an on-track incident from their portal against
-- another driver. The complainant submits everything (description +
-- up to 4 clip LINKS — no video is hosted, just YouTube/Streamable/
-- Medal URLs). Stewards review it in the admin panel, set a verdict,
-- and optionally drop a note into the complainant's portal inbox.
--
-- Visibility is stewards-private: the complainant sees only the cases
-- they filed; the accused driver sees nothing; admins see everything.
-- That keeps RLS simple — no accused-side read policy at all.
--
-- Each case gets a human-readable, per-season incident reference
-- (INC-2026-014) assigned by a BEFORE INSERT trigger via a small
-- per-season counter table, so everyone has one shared handle to quote.
-- ============================================================

CREATE TABLE IF NOT EXISTS disputes (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    incident_ref          text UNIQUE,                                   -- 'INC-2026-014', set by trigger
    season_id             uuid REFERENCES seasons(id) ON DELETE SET NULL,-- derived from event by trigger
    event_id              uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    lobby_number          int,                                           -- complainant's split, for context
    complainant_driver_id uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    accused_driver_id     uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    description           text NOT NULL,
    clip_1_url            text NOT NULL,                                 -- your POV 1 (required)
    clip_2_url            text,                                          -- further links, all optional
    clip_3_url            text,
    clip_4_url            text,
    status                text NOT NULL DEFAULT 'open'
                          CHECK (status IN ('open', 'under_review', 'resolved', 'dismissed')),
    outcome               text,                                          -- stewards' verdict / notes
    penalty_id            uuid REFERENCES penalties(id) ON DELETE SET NULL,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    resolved_at           timestamptz,
    CHECK (accused_driver_id <> complainant_driver_id)
);

CREATE INDEX IF NOT EXISTS disputes_complainant_idx ON disputes(complainant_driver_id);
CREATE INDEX IF NOT EXISTS disputes_status_idx      ON disputes(status);


-- ----- per-season incident counter -------------------------------
-- Kept in its own table so numbering is atomic under concurrent
-- filings (ON CONFLICT ... RETURNING). Locked down: no grants, RLS on
-- with no policies — only the SECURITY DEFINER trigger below touches it.
CREATE TABLE IF NOT EXISTS dispute_seq (
    season_id uuid PRIMARY KEY,
    last_num  int NOT NULL DEFAULT 0
);
ALTER TABLE dispute_seq ENABLE ROW LEVEL SECURITY;


CREATE OR REPLACE FUNCTION disputes_assign_ref()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_year int;
    v_num  int;
BEGIN
    -- Derive the season from the event so the client never has to.
    IF NEW.season_id IS NULL AND NEW.event_id IS NOT NULL THEN
        SELECT ev.season_id INTO NEW.season_id FROM events ev WHERE ev.id = NEW.event_id;
    END IF;

    IF NEW.incident_ref IS NULL THEN
        SELECT s.year INTO v_year FROM seasons s WHERE s.id = NEW.season_id;

        INSERT INTO dispute_seq (season_id, last_num)
        VALUES (NEW.season_id, 1)
        ON CONFLICT (season_id) DO UPDATE SET last_num = dispute_seq.last_num + 1
        RETURNING last_num INTO v_num;

        NEW.incident_ref := 'INC-'
            || COALESCE(v_year::text, EXTRACT(YEAR FROM now())::text)
            || '-' || lpad(v_num::text, 3, '0');
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS disputes_assign_ref_trg ON disputes;
CREATE TRIGGER disputes_assign_ref_trg
    BEFORE INSERT ON disputes
    FOR EACH ROW EXECUTE FUNCTION disputes_assign_ref();


-- ----- RLS -------------------------------------------------------
ALTER TABLE disputes ENABLE ROW LEVEL SECURITY;

-- The complainant may file a case for themselves, in the 'open' state.
CREATE POLICY "complainant files own dispute" ON disputes
    FOR INSERT TO authenticated
    WITH CHECK (
        status = 'open'
        AND complainant_driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid())
    );

-- The complainant may see only the cases they filed.
CREATE POLICY "complainant reads own disputes" ON disputes
    FOR SELECT TO authenticated
    USING (
        complainant_driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );

-- The complainant may still edit their own case while it's untouched
-- ('open'); once stewards move it on, it locks. Status must stay 'open'.
CREATE POLICY "complainant edits own open dispute" ON disputes
    FOR UPDATE TO authenticated
    USING (
        status = 'open'
        AND complainant_driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid())
    )
    WITH CHECK (
        status = 'open'
        AND complainant_driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid())
    );

-- Admins: full control (review, verdict, delete).
CREATE POLICY "admins manage all disputes" ON disputes
    FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
    WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

GRANT SELECT, INSERT, UPDATE, DELETE ON disputes TO authenticated;


-- ----- read view (names + event joined) --------------------------
-- security_invoker so the base-table RLS above still governs who sees
-- what: complainant gets only their own rows, admin gets all. Without
-- it a plain view would run as owner and leak every case.
CREATE OR REPLACE VIEW dispute_overview
WITH (security_invoker = true) AS
SELECT
    dp.*,
    cd.display_name AS complainant_name,
    cd.psn_id       AS complainant_psn,
    ad.display_name AS accused_name,
    ad.psn_id       AS accused_psn,
    ev.name         AS event_name,
    ev.round        AS event_round,
    ev.slug         AS event_slug,
    ev.starts_at    AS event_starts_at,
    s.year          AS season_year
FROM   disputes dp
JOIN   drivers cd ON cd.id = dp.complainant_driver_id
JOIN   drivers ad ON ad.id = dp.accused_driver_id
JOIN   events  ev ON ev.id = dp.event_id
LEFT   JOIN seasons s ON s.id = dp.season_id;

GRANT SELECT ON dispute_overview TO authenticated;


-- ----- verdict RPC ----------------------------------------------
-- Admin-only. Sets status/outcome/penalty in one shot, stamps
-- resolved_at for terminal states, and (optionally) drops a note into
-- the complainant's portal inbox — reusing driver_contact_messages the
-- same way message_driver (migration 41) does, so it renders as an
-- admin announcement card with no reply box.
CREATE OR REPLACE FUNCTION update_dispute(
    p_dispute_id uuid,
    p_status     text,
    p_outcome    text DEFAULT NULL,
    p_penalty_id uuid DEFAULT NULL,
    p_notify     text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_ref          text;
    v_complainant  uuid;
    v_user_id      uuid;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    IF p_status NOT IN ('open', 'under_review', 'resolved', 'dismissed') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Invalid status.');
    END IF;

    UPDATE public.disputes
    SET    status      = p_status,
           outcome     = p_outcome,
           penalty_id  = p_penalty_id,
           resolved_at = CASE WHEN p_status IN ('resolved', 'dismissed') THEN now() ELSE NULL END,
           updated_at  = now()
    WHERE  id = p_dispute_id
    RETURNING incident_ref, complainant_driver_id INTO v_ref, v_complainant;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Dispute not found.');
    END IF;

    IF COALESCE(trim(p_notify), '') <> '' THEN
        SELECT user_id INTO v_user_id FROM public.drivers WHERE id = v_complainant;
        INSERT INTO public.driver_contact_messages
            (driver_id, user_id, subject, message, status, is_broadcast, broadcast_by)
        VALUES
            (v_complainant, v_user_id,
             'Incident ' || COALESCE(v_ref, ''),
             p_notify,
             'in_progress',
             true,
             auth.uid());
    END IF;

    RETURN jsonb_build_object('ok', true, 'incident_ref', v_ref);
END;
$$;

GRANT EXECUTE ON FUNCTION update_dispute(uuid, text, text, uuid, text) TO authenticated;


-- ----- realtime --------------------------------------------------
-- So the complainant's portal picks up a verdict live (mirrors the
-- driver_contact_messages / drivers subscriptions from migration 79).
DO $$ BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.disputes; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
