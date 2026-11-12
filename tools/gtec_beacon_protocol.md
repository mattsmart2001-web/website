# Build your own GTEC live timing reporter

So you fancy writing your own thing to put your car on the live map. Good
on you. Here is everything you need.

Nothing here is secret and there is nothing I need to switch on at my
end. If you have a pairing code from your portal, you can write this
today and your car will show up.

## How it works

    PlayStation  --UDP 33740-->  your gadget  --HTTPS-->  GTEC

Three jobs:

1. Get the telemetry out of the console and keep it coming.
2. Decrypt it and read the bits you need, on your own gadget.
3. Send me a few numbers every second or two.

**I never see a GT7 packet.** There is no port of mine to open and
nothing goes to sparkstheory.co.uk. You do the decoding, then post me
some JSON.

## 1. Getting the telemetry

Listen on UDP **33740**.

The console only sends while something keeps asking, and it shuts up
about a second or two after you stop. So send a single `A` byte to the
console's IP on UDP **33739** every 1.5 seconds or so. Send that from the
same socket you are listening on, because the console replies to whoever
asked.

Only one program on a machine can have 33740. If you have a dashboard
running it already has it, and you will need that app to pass a copy on
to another port. Whoever is second in the chain must not send the
heartbeat, because the console answers the one that asked and that is the
other app.

## 2. Decrypting it

It is Salsa20.

- **Key**: first 32 bytes of the text `Simulator Interface Packet GT7 ver 0.0`
- **Nonce**: 8 bytes. Grab the little endian `uint32` at offset `0x40`,
  call that the seed. Nonce is `(seed XOR 0xDEADBEAF)` little endian,
  then the seed itself little endian.
- **Did it work?** A good one starts with `G7S0`. It is stored back to
  front, so do not compare the bytes against `G7S0`: read the first four
  bytes as a little endian `uint32` and check it against `0x47375330`.
  Catches people out, that one.

If it does not decrypt, bin it. Do not send me a guess.

Some apps pass the stream on already decoded. If the magic is sitting
there in plain sight, skip the decrypting or you will scramble a
perfectly good packet.

## 3. What to read out of it

All little endian. Offsets into the decrypted packet. There is loads more
in there, these are just the ones I want.

| Offset | Type    | What it is                                |
|--------|---------|-------------------------------------------|
| `0x04` | float32 | X position                                |
| `0x08` | float32 | Y position, that is height                |
| `0x0C` | float32 | Z position                                |
| `0x44` | float32 | fuel in the tank                          |
| `0x48` | float32 | size of the tank                          |
| `0x4C` | float32 | speed in metres per second                |
| `0x70` | int32   | packet id, goes up, handy for spotting repeats |
| `0x74` | int16   | lap number                                |
| `0x76` | int16   | laps in the race                          |
| `0x78` | int32   | best lap in ms, `-1` if there isn't one   |
| `0x7C` | int32   | last lap in ms, `-1` if there isn't one   |
| `0x8E` | uint16  | flags. bit 0 = in a race, bit 1 = paused  |

Send fuel as a percentage, not litres. Tanks are different sizes car to
car, so litres tell me nothing I can compare across a grid.

## 4. Sending it to me

One HTTPS POST. No socket to keep open, no websocket, nothing clever.

    POST https://wtryzoabpkqtucfpmbnn.supabase.co/rest/v1/rpc/live_beacon
    Content-Type: application/json
    apikey: <the anon key>
    Authorization: Bearer <the anon key>

The anon key is meant to be public. It is sat at the top of the GTEC bit
of `gt7_connector.py`. It is not a secret and it is not what says who you
are.

**Your pairing code is.** That goes in the body as `p_token`, never in a
header. And keep it to yourself, do not paste it in Discord.

### What goes in the body

These exact keys, nothing else. If GT7 has not told you something yet,
send `null`. Do not send a zero or a guess.

| Key               | Type   | Notes                                    |
|-------------------|--------|------------------------------------------|
| `p_token`         | string | your pairing code                        |
| `p_lap`           | int    | lap number, `0` if you don't know yet    |
| `p_lap_ms`        | int    | ms into the lap you are on, or `null`    |
| `p_last_lap_ms`   | int    | `null` unless it is above zero           |
| `p_best_lap_ms`   | int    | `null` unless it is above zero           |
| `p_x`             | float  | 2 decimal places is plenty               |
| `p_y`             | float  | height. without it I can't rebuild the map properly |
| `p_z`             | float  |                                          |
| `p_speed_kph`     | int    | m/s times 3.6                            |
| `p_on_track`      | bool   | in a race AND not paused                 |
| `p_fuel_pct`      | float  | `fuel / tank size * 100`, `null` if no tank size yet |
| `p_laps_in_race`  | int    | `null` unless it is above zero           |
| `p_client`        | string | what you are running it on. anything is fine |

GT7 does not tell you how far into the current lap you are. Work it out
from when you last saw the lap number change, and send `null` until you
have actually seen one tick over. Timing from when your program started
is not the same thing.

### The one that will get you

Send a key I am not expecting and the whole thing gets knocked back with
a 404. Your car does not report slightly wrong, it just vanishes off the
board and nothing tells you why. Stick to the list.

### Let me set the pace

You get a reply like this:

```json
{ "ok": true, "reporting": true, "next_ms": 3000 }
```

- `ok` false means your code is wrong. That is not going to fix itself,
  so back right off instead of hammering me.
- `reporting` false means there is nothing on at the minute, no race and
  no practice window. `reason` tells you which.
- `next_ms` is when to come back. Use it instead of picking your own
  gap. I slow cars sat in the menus down to 15 seconds, which is where
  most of the pointless traffic would come from otherwise.

If a beacon does not get through, forget it, do not queue it up. An old
position shown as live is worse than a gap, because the site can handle a
gap honestly.

## If you are doing this on a Pico or similar

You do not need to keep up with 60 a second. Empty the socket and only
decrypt the newest one when a beacon is due. Lap number, best and last
lap are all counters, so checking every second or two loses you nothing.
That takes you from sixty decrypts a second down to one.

TLS will give you more grief than anything above. Make sure you have the
memory for it before you build the rest.

## When in doubt

`gt7_connector.py` in this repo is the real thing. Decrypting is at the
top, the packet fields are in `GT7Packet._parse`, and the sending bit is
`_gtec_post` and `_gtec_beacon`. If this page and that file disagree, the
file is right and this page needs updating.
