-- ============================================================
-- 51 Lock driver-side message inserts down to "thread starter" rows
-- The original INSERT policy on driver_contact_messages only checked
-- that the driver was inserting against their own driver_id — it didn't
-- restrict admin-only columns. That meant a signed-in driver could
-- manually post a row with is_broadcast=true, is_direct=true,
-- admin_reply pre-filled, or broadcast_by spoofed via the Supabase JS
-- client and the row would render in everyone else's inbox as a
-- broadcast "From Admin".
--
-- Tighten the policy so drivers can only insert plain thread-starter
-- rows: status='new', no broadcast flag, no admin reply, no
-- impersonation columns set. Broadcasts / direct sends already go
-- through SECURITY DEFINER RPCs which bypass RLS, so admin paths still
-- work fine.
-- ============================================================

DROP POLICY IF EXISTS "driver inserts own contact message" ON driver_contact_messages;

CREATE POLICY "driver inserts own contact message" ON driver_contact_messages
    FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (SELECT 1 FROM drivers d WHERE d.id = driver_id AND d.user_id = auth.uid())
        AND coalesce(is_broadcast, false) = false
        AND coalesce(is_direct,    false) = false
        AND admin_reply       IS NULL
        AND replied_at        IS NULL
        AND broadcast_by      IS NULL
        AND driver_reply      IS NULL
        AND driver_replied_at IS NULL
        AND status            = 'new'
    );

-- Same defensive shape on UPDATE. Drivers shouldn't be able to set the
-- admin flags / fields on an existing row of theirs either. Only the
-- reply_to_admin_message RPC (SECURITY DEFINER) writes driver_reply.
DROP POLICY IF EXISTS "driver updates own contact message" ON driver_contact_messages;
-- (No matching policy previously existed; admins update via their own
-- policy, drivers shouldn't be able to UPDATE this table at all from
-- the client — replies go through the RPC.)
