-- Enable Supabase Realtime for tables used by live-update subscriptions.
-- Wrapped in DO blocks so the migration is safe to run even if a table
-- is already in the publication (avoids "already member" errors).

DO $$ BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.driver_contact_messages; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.message_thread_posts;     EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.team_join_requests;       EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.drivers;                  EXCEPTION WHEN duplicate_object THEN NULL; END $$;
