# GTEC Endurance - Android app (TWA) build checklist

The GTEC endurance section is already an installable PWA
(`/endurance/assets/manifest.json` + `/endurance/sw.js`, scoped to
`/endurance/`). This turns that PWA into a Google Play app using a **Trusted Web
Activity (TWA)** - a thin Android shell that runs the live PWA full-screen with
no browser bar. There is no second codebase: the app *is* the website.

Everything below runs on your own machine, not the site. The site side is
already prepared (see "Already done").

---

## Already done (in this repo)

- `endurance/assets/manifest.json` - scoped to `/endurance/`, app name em-dash
  removed, and **maskable PNG icons** added (`icon-192-maskable.png`,
  `icon-512-maskable.png`) which Play uses for the adaptive launcher icon.
- `.well-known/assetlinks.json` - placeholder file at the site root. You paste
  the signing fingerprint(s) into it (Step 4) and redeploy. Netlify serves it at
  `https://sparkstheory.co.uk/.well-known/assetlinks.json`.

Suggested package name (used below): **`uk.co.sparkstheory.gtec`**
(reverse of the domain). It must match the one in `assetlinks.json`.

---

## One-time tooling

- **Node 18+** (you already have Node).
- **JDK 17** and the **Android SDK** - Bubblewrap can download and manage these
  for you the first time it runs, so you usually don't need to install them by
  hand. If it asks, let it.

```bash
npm install -g @bubblewrap/cli
```

---

## Step 1 - Initialise the project from the live manifest

Run in an empty folder (NOT inside this repo):

```bash
bubblewrap init --manifest https://sparkstheory.co.uk/endurance/assets/manifest.json
```

Answer the prompts:

- **Application ID / package name:** `uk.co.sparkstheory.gtec`
- **Launcher name:** `GTEC` (keep it short - this is the label under the icon)
- **Start URL:** `/endurance/` (should be pre-filled from the manifest)
- **Display mode:** `standalone`
- **Signing key:** let Bubblewrap create one. **Back this keystore up somewhere
  safe** - losing it means you can never update the app again. Record the
  keystore path and both passwords.

## Step 2 - Build

```bash
bubblewrap build
```

Produces:
- `app-release-bundle.aab` - upload this to Google Play.
- `app-release-signed.apk` - for testing on a device (`adb install`).

## Step 3 - Test on a phone

```bash
adb install app-release-signed.apk
```

Open it. It will show a thin URL bar for now - that disappears once Step 4 is
deployed and verified. Check navigation, sign-in, standings, calendar all work.

## Step 4 - Digital Asset Links (removes the URL bar)

This is the step people get wrong. The `assetlinks.json` must list the SHA-256
of **whatever key ultimately signs the app**:

- **If you use Google Play App Signing** (recommended, and the default for new
  apps): the final signing key lives in Play. After creating the app (Step 5),
  go to **Play Console → your app → Test and release → App integrity → App
  signing** and copy the **SHA-256 certificate fingerprint** shown there.
- Also grab your **upload key** fingerprint from Bubblewrap:
  ```bash
  bubblewrap fingerprint list
  ```

Put **both** fingerprints in `.well-known/assetlinks.json` (the array takes more
than one), replacing the placeholder, keeping `package_name` as
`uk.co.sparkstheory.gtec`. Commit and let Netlify deploy. Verify it is live:

```bash
curl https://sparkstheory.co.uk/.well-known/assetlinks.json
```

Reinstall the app; the URL bar should be gone. (Including both fingerprints
means verification works whether or not Play re-signs, which is why the bar
sometimes stays when only one is listed.)

## Step 5 - Publish to Google Play

1. Create a **Play Console** account - one-time **$25** fee.
2. **Create app** → name `GTEC`, category Sports, free.
3. **Upload** `app-release-bundle.aab` to a release (Internal testing first is
   easiest, then promote to Production).
4. Fill the listing: short + full description, a feature graphic, and
   phone screenshots (you can screenshot the installed app).
5. Complete the required content-rating, data-safety and privacy-policy
   questionnaires, then submit for review (first review is usually a few days).

> Note: Google now often requires new **personal** developer accounts to run a
> closed test with ~12 testers for ~14 days before Production is unlocked.
> Organisation accounts are exempt. Worth checking your account type early.

## Updating later

- **Content/design changes** (the usual case): just deploy the website. The app
  loads the live site, so it updates instantly with no Play resubmission.
- **App shell changes** (icon, name, package, Android settings): re-run
  `bubblewrap build`, bump the version, and upload a new `.aab`. Sign with the
  **same keystore** from Step 1.

## iPhone

TWA is Android-only. iOS users can already "Add to Home Screen" from Safari (the
PWA installs there too, with push on iOS 16.4+). A comparable App Store listing
would need a separate wrapper and is a separate exercise.

## Push notifications (separate task, if wanted)

A TWA can display web push, but *sending* it (race reminders, results,
penalties) needs a backend piece that doesn't exist yet: VAPID keys, storing
subscriptions, and a sender - a Supabase Edge Function is the natural fit. Not
required to ship the app; scope it on its own if notifications are a goal.
