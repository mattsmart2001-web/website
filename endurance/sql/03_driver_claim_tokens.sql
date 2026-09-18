-- =============================================================
-- Gran Turismo GTEC — driver claim tokens (Phase 4b)
-- =============================================================
-- Apply after 01_schema.sql + 02_seed_defaults.sql.
-- Adds the claim-token table and two SECURITY DEFINER RPCs used
-- by the driver self-serve profile portal.
-- =============================================================


-- ============================================================
-- 1. driver_claim_tokens
-- ============================================================
CREATE TABLE IF NOT EXISTS driver_claim_tokens (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id   uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    token       uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    expires_at  timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),
    used_at     timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS claim_tokens_driver_idx ON driver_claim_tokens (driver_id);

ALTER TABLE driver_claim_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin write" ON driver_claim_tokens;
CREATE POLICY "admin write" ON driver_claim_tokens
    FOR ALL USING (has_role('admin'))
    WITH CHECK (has_role('admin'));


-- ============================================================
-- 2. get_claim_info(token)
-- ============================================================
-- Public function: given a token UUID, returns the driver's
-- display_name if the token is valid + unused. Safe to call
-- unauthenticated — reveals nothing sensitive.
-- ============================================================
CREATE OR REPLACE FUNCTION get_claim_info(p_token uuid)
RETURNS json AS $$
DECLARE
    v_name text;
BEGIN
    SELECT d.display_name INTO v_name
    FROM   driver_claim_tokens t
    JOIN   drivers              d ON d.id = t.driver_id
    WHERE  t.token       = p_token
      AND  t.expires_at  > now()
      AND  t.used_at    IS NULL;

    IF NOT FOUND THEN
        RETURN json_build_object('valid', false);
    END IF;

    RETURN json_build_object('valid', true, 'driver_name', v_name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;


-- ============================================================
-- 3. claim_driver_profile(token)
-- ============================================================
-- Authenticated function: atomically links the calling user to
-- a driver record, grants the 'driver' role, and marks the
-- token as used. Must be called with a valid Supabase JWT.
-- ============================================================
CREATE OR REPLACE FUNCTION claim_driver_profile(p_token uuid)
RETURNS json AS $$
DECLARE
    v_token  driver_claim_tokens%ROWTYPE;
    v_rows   int;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN json_build_object('error', 'Not authenticated.');
    END IF;

    SELECT * INTO v_token
    FROM   driver_claim_tokens
    WHERE  token       = p_token
      AND  expires_at  > now()
      AND  used_at    IS NULL;

    IF NOT FOUND THEN
        RETURN json_build_object('error', 'This link is invalid or has expired.');
    END IF;

    -- Link user → driver (only if not already claimed)
    UPDATE drivers
    SET    user_id = auth.uid()
    WHERE  id      = v_token.driver_id
      AND  user_id IS NULL;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
        RETURN json_build_object('error', 'This driver profile has already been claimed.');
    END IF;

    -- Grant driver role
    INSERT INTO user_roles (user_id, role)
    VALUES (auth.uid(), 'driver')
    ON CONFLICT (user_id, role) DO NOTHING;

    -- Mark token used
    UPDATE driver_claim_tokens
    SET    used_at = now()
    WHERE  id      = v_token.id;

    RETURN json_build_object('success', true, 'driver_id', v_token.driver_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
