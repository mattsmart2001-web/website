# Gran Turismo GTEC

(formerly working title: GT Endurance Championship.)

Hidden platform under development. Lives at `/endurance/`.

See **[PLAN.md](./PLAN.md)** for the full architecture, schema, and build
roadmap — it's the source of truth for every decision and the phase-by-phase
deliverable list.

## Status

| Phase | Status | What landed |
|---|---|---|
| 0 — Plan | ✅ done | `PLAN.md` written + all 15 design questions answered |
| 1 — Scaffolding | ✅ done | Folder structure, `robots.txt` disallow, hidden landing page |
| 2 — Supabase setup | ⏳ next | New Supabase project + apply full schema migration |
| 3 → 14 — Build | 📋 queued | See PLAN.md §13 for the phase breakdown |

## Folder structure

```
endurance/
├── PLAN.md            Full build plan + spec (read this first)
├── README.md          This file
├── index.html         Hidden coming-soon landing page (Phase 1)
├── assets/            Future: shared CSS / JS / images
└── sql/               Future: schema migrations + seed data
```

Future phases will populate `admin/`, `profile/`, `seasons/`, `races/`,
`teams/`, `drivers/`, `statistics/`, `hall-of-fame/`, `media/`, `news/`,
and `rules/` per the URL plan in PLAN.md §5.

## Hidden-mode

Until launch:

- Not linked from main site nav or footer
- `noindex, nofollow` meta on every page
- `Disallow: /endurance/` in `/robots.txt`
- Per decision §14.11: no HTTP basic-auth gate — relying on obscurity + noindex

To reach the landing page during dev, visit
`https://sparkstheory.co.uk/endurance/` directly.

## Going live

When ready to launch (see PLAN.md §17 — Definition of LAUNCH-ready):

1. Remove the `Disallow: /endurance/` line from `/robots.txt`
2. Remove `noindex, nofollow` from every `endurance/*.html`
3. Add nav + footer entries on the main site
4. Add the GTEC URLs to `/sitemap.xml`
5. Announce.
