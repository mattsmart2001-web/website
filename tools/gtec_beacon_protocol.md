# Writing your own GTEC live timing reporter

Everything a new reporter needs to put a car on the live map, written down
because somebody is building one on a Pico and the only description of
this until now was `gt7_connector.py` itself.

Nothing here is secret and nothing needs switching on at the GTEC end. If
you have a pairing code from your portal, you can write a client this
afternoon and it will appear on the map.

## The shape of it

    PlayStation  --UDP 33740-->  your device  --HTTPS-->  GTEC

Three jobs, in order:

1. Keep the console talking, and receive its telemetry.
2. Decrypt and decode it, on your device.
3. Send a handful of numbers to GTEC every second or two.

**GTEC never sees a GT7 packet.** There is no port of ours to open and
nothing is sent to sparkstheory.co.uk. You decode locally and post JSON.

## 1. Getting telemetry out of the console

Bind UDP **33740** and listen. The console only sends while something is
asking, and stops one to two seconds after the last ask, so send a single
`A` byte to the console's IP on UDP **33739** about every 1.5 seconds. The
reply comes back to whichever socket asked, so send the heartbeat from the
socket bound to 33740 rather than a fresh one.

Only one program on a device can hold 33740. If a dashboard already has
it, you are second in the chain and need that program to forward a copy
to another port; if you have it, you can forward copies yourself. Either
way the one that is second must not send the heartbeat, because the
console answers whoever asked and that is the other program.

## 2. Decrypting

Salsa20.

- **Key**: the first 32 bytes of the ASCII string
  `Simulator Interface Packet GT7 ver 0.0`
- **Nonce**: 8 bytes. Read the little-endian `uint32` at offset `0x40` of
  the encrypted packet, call it `seed`. The nonce is
  `(seed ^ 0xDEADBEAF)` little-endian, followed by `seed` little-endian.
- **Check**: a correct decrypt begins with the magic `G7S0`. Stored
  little-endian, so comparing the first four bytes against `b'G7S0'`
  fails on a perfectly good packet — compare the first four bytes read as
  a little-endian `uint32` against `0x47375330`.

Drop anything that does not decrypt rather than sending a guess.

Some tools forward the stream already decoded, so if the magic is sitting
there in the clear, skip the decryption rather than turning a good packet
into noise.

## 3. Reading the fields

All little-endian, offsets into the decrypted packet. These are the ones
the beacon needs; there are plenty more.

| Offset | Type    | What it is                                  |
|--------|---------|---------------------------------------------|
| `0x04` | float32 | position X                                  |
| `0x08` | float32 | position Y, the vertical axis               |
| `0x0C` | float32 | position Z                                  |
| `0x44` | float32 | fuel in the tank                            |
| `0x48` | float32 | tank capacity                               |
| `0x4C` | float32 | speed in metres per second                  |
| `0x70` | int32   | packet id, increments, good for de-duping   |
| `0x74` | int16   | lap count                                   |
| `0x76` | int16   | laps in the race                            |
| `0x78` | int32   | best lap, ms, `-1` when there is not one    |
| `0x7C` | int32   | last lap, ms, `-1` when there is not one    |
| `0x8E` | uint16  | flags: bit 0 is in-race, bit 1 is paused    |

Fuel as a percentage, not litres: capacity varies by car, so litres
cannot be compared across a grid of different machinery.

## 4. Sending it to GTEC

One HTTPS POST, no socket, no websocket, nothing to keep open.

    POST https://wtryzoabpkqtucfpmbnn.supabase.co/rest/v1/rpc/live_beacon
    Content-Type: application/json
    apikey: <the anon key>
    Authorization: Bearer <the anon key>

The anon key is public by design and sits at the top of the GTEC section
of `gt7_connector.py`. It is not a secret and is not what identifies you.

**Your pairing code is.** It goes in the body as `p_token`, never in a
header, and it is yours: do not paste it into Discord.

### The body

Exactly these keys. `null` is the right answer for anything GT7 has not
told you yet; a zero or a guess is not.

| Key               | Type    | Notes                                         |
|-------------------|---------|-----------------------------------------------|
| `p_token`         | string  | your pairing code                             |
| `p_lap`           | int     | lap count, `0` if unknown                     |
| `p_lap_ms`        | int     | ms into the current lap, or `null`            |
| `p_last_lap_ms`   | int     | `null` unless greater than zero               |
| `p_best_lap_ms`   | int     | `null` unless greater than zero               |
| `p_x`             | float   | two decimals is plenty                        |
| `p_y`             | float   | elevation; a position without it cannot be rebuilt |
| `p_z`             | float   |                                               |
| `p_speed_kph`     | int     | m/s × 3.6                                     |
| `p_on_track`      | bool    | in-race flag set AND not paused               |
| `p_fuel_pct`      | float   | `fuel / capacity * 100`, `null` if no capacity yet |
| `p_laps_in_race`  | int     | `null` unless greater than zero               |
| `p_client`        | string  | what you are running on; unknown values are fine |

GT7 does not report elapsed time on the current lap. Derive `p_lap_ms`
from when you last saw the lap counter change, and send `null` until you
have actually seen a crossing rather than timing from when your program
started.

### The one that will catch you out

Send a key the function does not declare and PostgREST rejects the whole
call with a 404. Your car does not report a slightly wrong position: it
vanishes from the board, with nothing on screen explaining why. Stick to
the list above exactly.

### The reply, and letting it set the pace

```json
{ "ok": true, "reporting": true, "next_ms": 3000 }
```

- `ok` false means the token is wrong. That will not fix itself, so back
  right off rather than retrying every second.
- `reporting` false means there is nothing to report into — no race, no
  practice window. `reason` says which.
- `next_ms` is when to come back. Honour it instead of picking your own
  interval: the server drops a car sat in the menus to fifteen seconds,
  which is where most idle traffic would otherwise come from.

A dropped beacon is not worth queueing. A stale position shown as live is
worse than a gap the website can age out honestly.

## Notes for a microcontroller

You do not need to keep up with 60 Hz. Drain the socket and decrypt only
the newest packet when a beacon is due: lap count, best and last lap are
all counters, so sampling every second or two loses nothing. That turns
Salsa20 from sixty decryptions a second into one.

TLS will be the hard part rather than any of the above. Check you have
the heap for it before you write the rest.

## The reference implementation

`gt7_connector.py`, in this repository. The decryption is at the top, the
packet fields are in `GT7Packet._parse`, and the beacon is `_gtec_post`
and `_gtec_beacon`. When this document and that file disagree, the file
is right and this document is out of date.
