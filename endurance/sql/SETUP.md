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
31. `31_dsq_zero_points.sql` — DSQ status zeroes points + DSQ penalty auto-flips result status
32. `32_team_deductions_cascade.sql` — whole-team points-deductions cascade to each driver on the entry
33. `33_dsq_penalty_zeroes_points.sql` — DSQ penalty trigger now zeroes points_awarded immediately
34. `34_driver_fastest_lap.sql` — per-driver fastest_lap_ms column on result_drivers
35. `35_fix_solo_entry_sync.sql` — fix `invalid reference to FROM-clause entry` on driver-team change
36. `36_auto_register_team_season.sql` — auto-register team to season when a driver joins (avoids team_seasons error)
37. `37_team_standings_sum_drivers.sql` — team points = sum of driver points; per-event wins/podiums counted once
38. `38_classified_only_counters.sql` — wins/podiums/poles/FLs only count when status='classified' (DNFs ignored)
39. `39_team_capacity_trigger.sql` — DB-level trigger enforcing teams.max_drivers (default 2)
40. `40_refresh_hof_no_race_hours.sql` — drop the race_hours reference from refresh_hall_of_fame
41. `41_admin_direct_message.sql` — admin can send a message to a single driver (reuses broadcast storage)
42. `42_sync_join_requests_to_team.sql` — auto-approve pending join requests when a driver gets added to that team by any path
43. `43_unique_psn.sql` — case-insensitive unique PSN on drivers + auto-delete safe duplicates
44. `44_admin_activity_log.sql` — auto-logged admin action history via triggers, viewable / deletable from admin UI
45. `45_event_race_details.sql` — per-event briefing fields (tyre wear, fuel, weather, starting procedure, etc.)
46. `46_event_required_tyres.sql` — per-event required tyre compounds (text[])
47. `47_event_bop.sql` — per-event BoP on/off flag
48. `48_event_damage.sql` — per-event damage level (off / light / heavy)
49. `49_driver_replies_to_direct.sql` — drivers can reply to direct admin messages (not broadcasts); reply re-opens the thread for admin
50. `50_driver_delete_cascade.sql` — driver deletes cascade through entry_drivers / result_drivers (and SET NULL on penalties)
51. `51_lock_driver_message_inserts.sql` — driver INSERT on driver_contact_messages can't spoof is_broadcast / is_direct / admin_reply anymore
52. `52_elo_idempotent_recompute.sql` — compute_elo wipes the event's existing ratings before recomputing so re-runs don't compound the deltas
53. `53_circuit_records_include_race_fl.sql` — circuit_records picks the lower of qualifying and race fastest lap per circuit
54. `54_media_categories_and_embeds.sql` — adds category + embed_provider columns to media_items for filtered gallery + YouTube/Twitch/Vimeo embeds
55. `55_application_preferred_number.sql` — applicants can nominate a preferred career number on the apply form
56. `56_drivers_discord_username.sql` — promote discord_username onto drivers (backfilled from linked applications) so drivers can self-edit it from the portal and admin can edit on the driver row
57. `57_elo_per_lobby.sql` — Elo pairwise comparisons now restricted to drivers who shared a lobby (was pooling everyone in the event, inflating P1 deltas in multi-lobby events)
58. `58_team_standings_per_driver_counters.sql` — team wins/podiums/poles/FLs counted per driver again (multi-lobby reality means a 1-2 split or P3-in-each-lobby is two separate top-3 finishes)
59. `59_event_refuel_and_slipstream.sql` — two more per-event briefing fields: refuel rate (1–10 L/s) and slipstream (off / weak / real / strong)
60. `60_rename_lobby_to_split_in_notifications.sql` — notification subject + body now say "Split N" instead of "Lobby N" to match the rebranded UI vocabulary
61. `61_secret_badges.sql` — server-side detector for hidden achievements (Giant Killer / David vs Goliath / Giant Slayer) returned as a single jsonb RPC
62. `62_more_secret_badges.sql` — adds Unfinished Business / Phoenix / Comeback King / Last to First / Mr Consistent to the same RPC
63. `63_driver_manual_badges.sql` — text[] column on drivers so admin can override the auto-detection and grant a badge by hand
64. `64_david_vs_goliath_strict_min.sql` — David vs Goliath now requires a strict rating gap in the lobby, so it stops firing for everyone in round 1 when the field is flat at the seed Elo
65. `65_split_movement_notifications.sql` — split-assignment notifications now compare against the previous round's split and tell each driver whether they've been promoted, relegated or are staying put
66. `66_notification_prior_event_by_round.sql` — the prior-round lookup now sorts by `round` (NOT NULL) instead of `starts_at` (nullable), so the promotion / relegation copy works even when an event's date is still TBC

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
