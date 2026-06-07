# Gran Turismo GTEC — Supabase Setup Guide

Apply this once to a fresh Supabase project to get the GTEC database ready.

---

## 1. Create a new Supabase project

1. Go to [supabase.com](https://supabase.com) → **New project**
2. Name it something like `gtec` or `sparkstheory-gtec`
3. Choose a strong database password (save it — you'll need it)
4. Pick a region close to your users (e.g. **EU West** for a UK audience)
5. Wait for the project to initialise (~1 min)

---

## 2. Apply the schema

1. In your Supabase project, go to **SQL Editor** (left sidebar)
2. Click **New query**
3. Open `01_schema.sql` from this folder, paste the entire contents, click **Run**
4. You should see: `Success. No rows returned.`

---

## 3. Apply the seed data

1. Still in SQL Editor → **New query**
2. Open `02_seed_defaults.sql`, paste the entire contents, click **Run**
3. This inserts:
   - The default **F1 points system** (25-18-15-12-10-8-6-4-2-1 + pole + fastest lap)
   - Five starter **rules pages** (Sporting, Technical, Penalties, Conduct, Stewarding)

---

## 4. Bootstrap your first admin

After you've signed up at `/endurance/admin/login` (Phase 4a — not built yet), or created a user directly in the Supabase Auth dashboard:

1. In Supabase → **Authentication** → **Users** → find your user → copy the UUID
2. In SQL Editor → **New query**, run:

```sql
INSERT INTO user_roles (user_id, role)
VALUES ('<YOUR_AUTH_UUID_HERE>'::uuid, 'admin')
ON CONFLICT (user_id, role) DO NOTHING;
```

You're now admin. The instructions are also in `02_seed_defaults.sql` as comments.

---

## 5. Save your project credentials

You'll need these later when wiring up the frontend (Phase 4+):

| Variable | Where to find it |
|---|---|
| `SUPABASE_URL` | Project Settings → API → Project URL |
| `SUPABASE_ANON_KEY` | Project Settings → API → `anon` `public` key |
| `SUPABASE_SERVICE_ROLE_KEY` | Project Settings → API → `service_role` key (keep secret) |

Store the service role key in Netlify environment variables — never expose it client-side.

---

## What's in the schema

`01_schema.sql` creates:

- **Enums**: `user_role`, `entry_status`, `session_type`, `session_status`, `incident_verdict`
- **Tables** (18): `user_roles`, `points_systems`, `seasons`, `teams`, `drivers`, `entries`, `sessions`, `laps`, `results`, `race_incidents`, `steward_decisions`, `fastest_laps`, `team_standings`, `driver_standings`, `driver_stats`, `rules_pages`, `news_articles`, `media_items`
- **Triggers**: `touch_updated_at` (auto-timestamp), `check_entry_manufacturer_lock` (one manufacturer per team per season)
- **Helper**: `has_role(uuid, user_role)` function for RLS policies
- **RLS**: Enabled on every table with read-public / write-admin policies

---

## File order matters

Always apply in this order:

1. `01_schema.sql` — creates all tables, triggers, functions, RLS
2. `02_seed_defaults.sql` — inserts default data (idempotent, safe to re-run)
3. `03_driver_claim_tokens.sql` — driver self-service claim tokens
4. `04_standings.sql` — driver / team standings views
5. `05_elo.sql` — pairwise Elo rating tables + views
6. `06_stats.sql` — Hall of Fame / career stats
7. `07_content.sql` — news, media, pages tables + `gtec-media` bucket
8. `08_applications.sql` — driver / team applications table
9. `09_manufacturer_logos.sql` — `gtec-manufacturers` bucket + view refresh to expose logos
10. `10_application_links.sql` — tracks which driver/team record was created from each application
11. `11_driver_team_manufacturer_lock.sql` — driver's manufacturer auto-syncs to their team's manufacturer
12. `12_admin_management.sql` — RPCs so admins can grant / revoke admin access from the admin UI
13. `13_application_discord_unique_numbers.sql` — Discord handle on applications + unique driver career numbers
14. `14_unique_names.sql` — case-insensitive uniqueness on driver display names and team names
15. `15_application_email_ratings.sql` — email + GT7 DR/SR ratings on applications and drivers
16. `16_application_email_log.sql` — log of acceptance / waitlist / rejection emails sent
17. `17_entries_car_number_optional.sql` — entries.car_number derived from first driver, no longer required
18. `18_penalty_points_deduction.sql` — adds `points_deduction` to the penalty_type enum
19. `19_entry_lobbies.sql` — adds `entries.lobby_number` for skill-based lobby allocation
20. `20_reset_statistics.sql` — admin RPCs to wipe race data per event or globally
21. `21_driver_contact_messages.sql` — driver→admin contact form storage (race disputes, issues)
22. `22_message_replies.sql` — admin reply field + driver-read tracking for the inbox
23. `23_team_leaders_and_join_requests.sql` — team leaders, join requests, approve RPC
24. `24_team_leader_update.sql` — RLS policy so team leaders can edit their team from the portal
25. `25_broadcast_messages.sql` — admin "Message All Drivers" broadcast RPC + is_broadcast flag
26. `26_lobby_notifications.sql` — per-event lobby-assignment broadcast + delete RPCs
27. `27_per_driver_qualifying.sql` — per-driver qualifying + per-driver finish columns on result_drivers
28. `28_per_driver_scoring.sql` — per-driver points + pole auto-derived from quali + solo entries
29. `29_per_driver_elo.sql` — fix Elo to rank by per-driver finish_position instead of entry-level
30. `30_points_deduction_standings.sql` — penalties.points_amount + driver/team standings subtract deductions

---

## Sending applicant emails (Resend)

The admin **Application → View** modal has Acceptance / Waitlist / Rejection
buttons. Each one calls the `send-application-email` Netlify Function, which
delivers via Resend and writes a row to `application_emails`.

To enable it:

1. Sign up at [resend.com](https://resend.com) (free tier: 3,000 emails / month).
2. Add a Netlify env var **`RESEND_API_KEY`** with the key from Resend's API Keys page.
3. Add **`GTEC_SUPABASE_URL`** and **`GTEC_SUPABASE_ANON_KEY`** to Netlify env vars,
   set to the values from `endurance/assets/gtec-config.js`. (The function falls
   back to `SUPABASE_URL` / `SUPABASE_ANON_KEY` if those are unset, but use the
   GTEC-prefixed names if you already have those in use for another project.)
4. (Optional, recommended) Verify your sending domain in Resend's dashboard, then
   set **`GTEC_FROM_EMAIL`** to something like
   `"Gran Turismo GTEC <noreply@yourdomain.com>"`. If you skip this, mails go from
   `onboarding@resend.dev`, which works for testing but isn't a great look in production.
