# GTEC Live Timing, iPhone

The iPhone version of the reporter. Same job as the Android app and the
desktop connector: listen to the console's telemetry on your own WiFi,
and post the handful of figures the timing board needs.

## What is different from Android, and why

**It runs in the foreground.** Android keeps a socket alive behind a
notification for twelve hours. iOS suspends an app that leaves the screen,
and the background modes that would avoid that are for audio, navigation
and the like: using one for this would be rejected, and rightly. So the
app holds the screen awake while it reports and says so. A driver props
the phone on a charger, which is what every other GT7 telemetry app for
iPhone asks for.

**It has to be told where the console is.** The Android reporter finds it
by broadcasting to the whole network, which on iOS needs the multicast
entitlement, granted by Apple on written application. So the address is
typed in once, or found with **Find it**, which asks all 254 addresses on
the local network in turn and waits for one to answer. That is ordinary
unicast, needs nobody's permission, and takes a couple of seconds.

**It asks for permission to talk to your network.** iOS prompts the first
time. The prompt is raised by starting a Bonjour browse that does nothing
else, because a raw socket can otherwise have its traffic dropped with no
prompt and no error, which looks exactly like a console that is switched
off.

## Alongside other telemetry apps

**On another device, no problem.** The console answers whichever address
asked it, on that device's own port, so a dashboard on a PC, a tablet or
a second phone runs at the same time as this and neither knows about the
other. That is how the Windows connector and the Android app already
coexist.

**On this phone, the two apps have to agree who owns the port.** Only one
can hold UDP 33740, and the console always sends there. `SO_REUSEPORT`
looks like the answer and is not: it would let both bind, but a unicast
datagram is delivered to one socket rather than copied to both, so each
app would get a share of the packets and both would be wrong. A clear
"port busy" beats two apps quietly half-working, so the socket does not
ask for it.

Forwarding is the answer, and the **Sharing** section is where it lives,
with the same two settings as the desktop connector:

- **Listen on port** · this app goes second in the chain, takes a copy
  from whatever owns 33740, and stops pinging the console, because the
  owner is already doing that and the console answers whoever asked.
- **Copy to ports** · this app goes first, and passes every raw datagram
  on to another app on this phone, untouched and before it reads anything
  from it.

Either way it takes two: the other app has to be able to forward, or to
be told to listen somewhere other than 33740. Plenty cannot. In practice
it rarely comes up on iOS, since the phone suspends whatever is not in
front of you and this has to be in front of you.

The status line says which case you are in rather than just failing.

## Layout

| File | What it does |
| --- | --- |
| `Salsa20.swift` | Decryption. A port of the Android one, itself checked against pycryptodome |
| `GT7Packet.swift` | Field offsets, ported from the connector rather than worked out again |
| `UDP.swift` | Sockets: bind, send, receive, and this device's own address |
| `Reporter.swift` | The loop: heartbeat, decode, post. And the console search |
| `Beacon.swift` | One HTTPS call to `live_beacon`, same contract as every other client |
| `ContentView.swift` | Code, console, button, status |

No packages, no dependencies. Everything a review has to read is in
`Sources`, and it is about six hundred lines.

## Building

The project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) rather than keeping a
`.pbxproj` in the repo, since that file is unreviewable in a diff and
conflicts whenever two people touch it.

```sh
brew install xcodegen
cd gtec-reporter-ios
xcodegen generate
open GTECReporter.xcodeproj
```

CI builds it on every push, on a macOS runner, for the simulator with
signing off. That needs no Apple account and answers the only question
that can be answered without one: does it compile.

## Getting it onto a phone

Three things, none of them code:

1. **Apple Developer Program**, ninety-nine pounds a year. Nothing can be
   signed without it.
2. **A certificate and provisioning profile**, stored here as repository
   secrets so the runner can sign.
3. **An upload step to TestFlight.** TestFlight allows ten thousand
   external testers, so a league of two hundred installs from a link and
   later builds arrive without a fresh review each time. The first build
   is reviewed, more lightly than an App Store submission.

Until then the app compiles and can run in the simulator, which exercises
everything but the console itself.
