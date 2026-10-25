# GTEC Live Timing — Android reporter

A driver's phone reads GT7's telemetry off the local network and posts
their own car's position to GTEC. The server assembles the field from
however many drivers are reporting, so this works at any level of
adoption: one car or a hundred.

Sideloaded as an APK from sparkstheory.co.uk. No Play Store, no review,
no developer account, no annual fee.

## Why an app at all

A browser cannot open a raw UDP socket. There is no API, no permission
prompt and no flag — WebRTC needs a negotiated peer and WebTransport
talks QUIC to a server, so neither can receive unsolicited packets from a
PlayStation. Anyone on a PC or Mac can use the existing GT7 Live
Connector instead and needs none of this.

## What it does

1. Broadcasts a one-byte `A` heartbeat to port 33739 every 1.5 seconds.
   GT7 stops streaming one to two seconds after the last heartbeat, and
   broadcasting means **the driver never has to find their console's IP**.
2. Listens on port 33740, decrypts each packet (Salsa20) and reads seven
   fields.
3. Posts them to `live_beacon`, which replies with how long to wait —
   3 seconds on track, 15 while the car sits in menus.

No third-party code ships in the APK. `org.json` is part of Android and
Salsa20 is hand-written, which keeps a sideloaded binary something a
driver can reasonably be asked to trust.

## Before building

Put the real anon key into `BuildConfigish` at the bottom of
`ReporterService.kt`. It is the same public key the website already ships
in `endurance/assets/gtec-config.js`; the beacon is authorised by the
driver's pairing token, not by the key.

## Build

```bash
cd gtec-reporter
./gradlew test                      # verifies the decode, see below
./gradlew assembleRelease
```

Signing for a sideloaded APK, once:

```bash
keytool -genkey -v -keystore gtec-release.jks -keyalg RSA \
        -keysize 2048 -validity 10000 -alias gtec
```

Then add a `signingConfigs` block to `app/build.gradle.kts` pointing at
it, or sign the unsigned output with `apksigner`. **Keep the keystore
safe:** Android will refuse to update an APK signed with a different key,
so losing it means every driver uninstalling and reinstalling.

## The decode is tested

`Gt7PacketTest` carries a known-good encrypted packet with known field
values, so `./gradlew test` proves Salsa20 and every offset before anyone
goes near a console. If the crypto or an offset is wrong it fails, rather
than putting a car quietly at the wrong end of the circuit.

The same source has been compiled and run on the JVM against that vector:
all fifteen checks pass, including the two rejection cases and Salsa20
round-tripping.

Key, nonce construction and offsets are taken verbatim from the
production connector (`gt7_connector.py`, `commentary-poc/gt7_packet.py`)
rather than worked out again.

## Known unverified

`positionInRace` (0x84) and `numCars` (0x86) come from offsets the
connector's own source marks as needing confirmation against a real
capture. They matter: if they hold, a reporting car knows its **actual
race position**, so even partial coverage gives a true running order
rather than only dots on a map. The app sends them and the server treats
them as optional, so a wrong offset degrades the order rather than
breaking anything.

Worth confirming first, with the connector and a real race.

## What the driver does

1. Open the GTEC portal, tap **Start live timing**, copy the pairing code.
2. Paste it into the app, press Start.
3. Leave the phone on the same WiFi as the console, on charge.

The notification is the status display, since during a race the phone is
face-down next to them. It shows the current lap, or why nothing is being
reported.

## Limits

- **Port 33740 can only be held by one app per device.** A driver running
  another telemetry app on the same phone will see "port busy". On a
  separate device it is fine, which is the usual case: connector on a PC,
  this on a phone.
- **Whether a PS5 streams to two devices at once is unconfirmed.** It
  should, since each sends its own heartbeat from its own IP, but it has
  not been tested. Matters for a driver running a dashboard as well.
- **No iOS.** UDP is fine on iOS, but sideloading needs re-signing every
  seven days, so it would mean the App Store, a paid account and a Mac.
- **A twelve-hour race is a twelve-hour foreground service.** Phone on
  charge, and expect Android vendors with aggressive battery management
  (Xiaomi, Huawei, OnePlus) to need the app excluded by hand.
