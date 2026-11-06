#!/usr/bin/env python3
"""
Look inside GT7's bigger telemetry packets.

WHY THIS EXISTS
---------------
The connector asks the console for the 'A' packet by sending a single byte
'A' as its heartbeat. That packet is 296 bytes and every field in it is
publicly documented. Later game updates added bigger ones, selected by
sending a different letter instead:

    A   296 bytes   what the connector uses, fully mapped
    B   316 bytes
    ~   344 bytes   reported to add a per-tyre surface type
    C   368 bytes   appeared around update 1.68, NOT publicly mapped

Nobody has published what is in C's extra 72 bytes. Tyre compound and tyre
wear are both absent from everything that has been mapped, and both would
be worth having. This records the unmapped bytes while you drive so they
can be diffed afterwards: a byte that changes only when you change
compound is the compound, and one that creeps steadily through a stint and
resets when you pit is wear.

It is a diagnostic, not part of the league site. It talks to the console
and writes a CSV, and does nothing else.

USING IT
--------
GT7 streams to one listener only, so close the connector first.

    python3 tools/gt7_probe.py 192.168.1.50 --letter C --seconds 60 --out c-hard.csv

Then change compound in the garage and run it again to a different file.
Two files, one difference between them, and the answer falls out.

    python3 tools/gt7_probe.py 192.168.1.50 --letter A --seconds 20 --out a-control.csv

is worth doing once as a control: if A works and C does not, your game
build has no C packet and that is the answer.
"""

import argparse
import csv
import socket
import struct
import sys
import time

# Bumped whenever this file changes in a way that matters to someone
# running it. Printed on every run and available as --version, because
# "re-download it" and "I did" have now disagreed twice, and a number on
# screen settles that in one line instead of a wasted capture.
VERSION   = 5

SEND_PORT = 33739          # the console listens for the heartbeat here
RECV_PORT = 33740          # and streams to here
A_SIZE    = 0x128          # 296: everything below this is already mapped
# What each letter is reported to return. 'A' is the one the connector uses
# and the only one that is fully mapped; the rest are community findings.
EXPECTED = {'A': 296, 'B': 316, '~': 344, 'C': 368}

# Self-contained on purpose, cipher and all.
#
# Importing the connector would have kept the decryption in one place, and
# that was the first attempt. It cannot work: the connector exits at import
# if websockets is missing, silently and with no message. This is a tool a
# driver might be asked to run on a bare Python to answer one question, so
# it carries its own copy rather than inheriting a dependency list. The
# cipher below is lifted from the connector's pure-Python fallback.
#
# Salsa20 is a stream cipher: keystream from (key, nonce, counter), XORed
# with the data, so decrypting and encrypting are the same operation.
_KEY   = b'Simulator Interface Packet GT7 ver 0.0'[:32]
G7S0   = 0x47375330      # b'G7S0' stored little-endian
_MASK  = 0xFFFFFFFF
_SIGMA = b'expand 32-byte k'

def _rotl(v, n):
    return ((v << n) | (v >> (32 - n))) & _MASK

def _salsa_core(state):
    x = list(state)
    for _ in range(10):                       # 20 rounds, two per pass
        x[4]  ^= _rotl((x[0]  + x[12]) & _MASK, 7)
        x[8]  ^= _rotl((x[4]  + x[0])  & _MASK, 9)
        x[12] ^= _rotl((x[8]  + x[4])  & _MASK, 13)
        x[0]  ^= _rotl((x[12] + x[8])  & _MASK, 18)
        x[9]  ^= _rotl((x[5]  + x[1])  & _MASK, 7)
        x[13] ^= _rotl((x[9]  + x[5])  & _MASK, 9)
        x[1]  ^= _rotl((x[13] + x[9])  & _MASK, 13)
        x[5]  ^= _rotl((x[1]  + x[13]) & _MASK, 18)
        x[14] ^= _rotl((x[10] + x[6])  & _MASK, 7)
        x[2]  ^= _rotl((x[14] + x[10]) & _MASK, 9)
        x[6]  ^= _rotl((x[2]  + x[14]) & _MASK, 13)
        x[10] ^= _rotl((x[6]  + x[2])  & _MASK, 18)
        x[3]  ^= _rotl((x[15] + x[11]) & _MASK, 7)
        x[7]  ^= _rotl((x[3]  + x[15]) & _MASK, 9)
        x[11] ^= _rotl((x[7]  + x[3])  & _MASK, 13)
        x[15] ^= _rotl((x[11] + x[7])  & _MASK, 18)
        x[1]  ^= _rotl((x[0]  + x[3])  & _MASK, 7)
        x[2]  ^= _rotl((x[1]  + x[0])  & _MASK, 9)
        x[3]  ^= _rotl((x[2]  + x[1])  & _MASK, 13)
        x[0]  ^= _rotl((x[3]  + x[2])  & _MASK, 18)
        x[6]  ^= _rotl((x[5]  + x[4])  & _MASK, 7)
        x[7]  ^= _rotl((x[6]  + x[5])  & _MASK, 9)
        x[4]  ^= _rotl((x[7]  + x[6])  & _MASK, 13)
        x[5]  ^= _rotl((x[4]  + x[7])  & _MASK, 18)
        x[11] ^= _rotl((x[10] + x[9])  & _MASK, 7)
        x[8]  ^= _rotl((x[11] + x[10]) & _MASK, 9)
        x[9]  ^= _rotl((x[8]  + x[11]) & _MASK, 13)
        x[10] ^= _rotl((x[9]  + x[8])  & _MASK, 18)
        x[12] ^= _rotl((x[15] + x[14]) & _MASK, 7)
        x[13] ^= _rotl((x[12] + x[15]) & _MASK, 9)
        x[14] ^= _rotl((x[13] + x[12]) & _MASK, 13)
        x[15] ^= _rotl((x[14] + x[13]) & _MASK, 18)
    return struct.pack('<16I', *[(x[i] + state[i]) & _MASK for i in range(16)])

class _PureSalsa20:
    """Same shape as Crypto.Cipher.Salsa20's object, so the call sites below
    do not need to know which one they are holding."""
    def __init__(self, key, nonce):
        if len(key) == 16:
            key = key + key
        k = struct.unpack('<8I', key)
        n = struct.unpack('<2I', nonce)
        c = struct.unpack('<4I', _SIGMA)
        self._state = [c[0], k[0], k[1], k[2], k[3], c[1], n[0], n[1],
                       0, 0, c[2], k[4], k[5], k[6], k[7], c[3]]

    def decrypt(self, data):
        out, counter = bytearray(), 0
        while len(out) < len(data):
            st = list(self._state)
            st[8]  = counter & _MASK
            st[9]  = (counter >> 32) & _MASK
            out   += _salsa_core(st)
            counter += 1
        return bytes(a ^ b for a, b in zip(data, out))

    encrypt = decrypt

def _salsa_new(key, nonce):
    return _PureSalsa20(key, nonce)


# 'G7S0' is stored little-endian, so the decoded bytes read '0S7G'. The
# trailing character is a version, and a bigger packet is likely to carry a
# different one: insisting on '0' would throw away a perfectly good decode
# of a packet type we have never seen. So the family is what is checked,
# and the variant is reported back.
_FAMILY = b'S7G'

# The nonce is built from a seed in the packet XORed with a mask, and the
# mask is NOT the same for every packet type. 0xDEADBEAF is the one the
# connector uses and is right for 'A'; the bigger packets are reported to
# use others. Rather than pick one, try each and say which answered, which
# also means this keeps working if a later update adds another.
_MASKS = [
    ('0xDEADBEAF', 0xDEADBEAF),     # the 'A' packet, what the connector uses
    ('0x55FABB4F', 0x55FABB4F),     # cited for a later packet type
    ('0xDEADBEEF', 0xDEADBEEF),     # cited, and one bit from the first
]


def decrypt_packet(data):
    """Decode one packet.

    Returns (plaintext, magic) where magic is the four characters as they
    read in the packet, e.g. 'G7S0'. Returns (None, None) if this is not a
    GT7 packet at all, and (None, hex) if it decoded to something whose
    magic is not of the family, which is worth seeing rather than hiding.
    """
    if len(data) < A_SIZE:
        return None, None
    # Already decoded by whatever forwarded it.
    if data[1:4] == _FAMILY:
        return data, data[0:4][::-1].decode('latin-1') + ' (already decoded)'
    seed = int.from_bytes(data[0x40:0x44], 'little')
    first = None
    for name, mask in _MASKS:
        nonce = (seed ^ mask).to_bytes(4, 'little') + seed.to_bytes(4, 'little')
        try:
            dec = _salsa_new(_KEY, nonce).decrypt(data)
        except Exception:
            continue
        if first is None:
            first = dec[0:8].hex()
        if dec[1:4] == _FAMILY:
            return dec, f"{dec[0:4][::-1].decode('latin-1')} via {name}"
    return None, first


def subnet_bcast():
    """Best-effort subnet broadcast address, e.g. 192.168.1.255.

    Lifted from the connector, which learned it the hard way: many home
    networks drop the limited 255.255.255.255 broadcast but pass a directed
    one, so sending both finds consoles that either alone misses.
    """
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))      # no packet sent; this only picks the interface
        ip = s.getsockname()[0]
        s.close()
        parts = ip.split('.')
        if len(parts) == 4:
            parts[3] = '255'
            return '.'.join(parts)
    except Exception:
        pass
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('ip', nargs='?', default=None,
                    help="the console's address. Leave it out and the probe"
                         " broadcasts and lets the console answer, which is"
                         " what the connector does.")
    ap.add_argument('--letter', default='C',
                    help="which packet to ask for: A, B, ~ or C (default C)")
    ap.add_argument('--seconds', type=float, default=60.0,
                    help='how long to record for (default 60)')
    ap.add_argument('--hz', type=float, default=2.0,
                    help='samples written per second (default 2)')
    ap.add_argument('--out', default=None,
                    help='CSV to write (default probe-<letter>.csv)')
    ap.add_argument('--save-raw', metavar='FILE', default=None,
                    help='also write the packets exactly as they arrived, '
                         'undecoded, so they can be picked apart offline')
    ap.add_argument('--port', type=int, default=RECV_PORT,
                    help=f'port to listen on (default {RECV_PORT})')
    ap.add_argument('--version', action='version',
                    version=f'gt7_probe v{VERSION}')
    args = ap.parse_args()

    letter = args.letter.encode()[:1]
    out_path = args.out or f'probe-{args.letter}.csv'.replace('~', 'tilde')

    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        rx.bind(('0.0.0.0', args.port))
    except OSError as e:
        print(f"Could not listen on {args.port}: {e}")
        print("GT7 streams to one program at a time. Close the connector "
              "(and any dashboard) and try again.")
        return 2
    rx.settimeout(1.0)

    # No address given: shout, and let the console answer. The connector
    # works this way and finds the console on its own, so asking a person to
    # go and look one up is a step that need not exist.
    targets = [args.ip] if args.ip else \
        [t for t in ('255.255.255.255', subnet_bcast()) if t]
    where = args.ip if args.ip else "the whole network (" + ", ".join(targets) + ")"
    print(f"gt7_probe v{VERSION}")
    print(f"Asking {where} for the '{args.letter}' packet, listening on "
          f"{args.port}, for {args.seconds:g}s.")
    print("Get in a car and drive: GT7 sends nothing from the menus.")
    print("Press Ctrl-C to stop early.\n")

    raw_fh = open(args.save_raw, 'wb') if args.save_raw else None
    rows, sizes = [], {}
    magics, bad_sample = [], None
    console = None
    first_seen = None
    t0 = time.time()
    next_sample = 0.0
    last_beat = 0.0
    n_pkts = 0

    try:
        while time.time() - t0 < args.seconds:
            now = time.time()
            # GT7 stops streaming a second or two after the last heartbeat.
            if now - last_beat > 1.0:
                for t in targets:
                    try:
                        rx.sendto(letter, (t, SEND_PORT))
                    except OSError:
                        pass
                last_beat = now
            try:
                data, src = rx.recvfrom(4096)
            except socket.timeout:
                continue
            if console is None:
                console = src[0]
                print(f"  console at {console}")
            n_pkts += 1
            sizes[len(data)] = sizes.get(len(data), 0) + 1
            if raw_fh is not None and n_pkts <= 400:
                # Length-prefixed, so the file can be read back packet by
                # packet. 400 is plenty to find a pattern and keeps the
                # file small enough to send.
                raw_fh.write(len(data).to_bytes(2, 'little') + data)
            dec, magic = decrypt_packet(data)
            if dec is None:
                # Keep the first thing that failed, so the summary can show
                # what it actually decoded to instead of guessing.
                if bad_sample is None and magic:
                    bad_sample = magic
                continue
            if magic and magic not in magics:
                magics.append(magic)
                if not magic.startswith('G7S0 via 0xDEADBEAF'):
                    print(f"  magic '{magic}' -- a packet type nobody has "
                          f"published under this letter")
            if first_seen is None:
                first_seen = len(dec)
                note = ""
                if first_seen <= A_SIZE and args.letter.upper() != 'A':
                    note = "  <-- the ordinary 'A' packet, not what was asked for"
                elif first_seen > A_SIZE:
                    note = f"  <-- {first_seen - A_SIZE} bytes beyond the mapped region"
                print(f"  decoding {first_seen}-byte packets{note}\n")
            t = now - t0
            if t < next_sample:
                continue
            next_sample = t + 1.0 / max(args.hz, 0.1)
            row = {
                't_s':       round(t, 2),
                'size':      len(dec),
                'lap':       struct.unpack_from('<h', dec, 0x74)[0],
                'speed_kph': round(struct.unpack_from('<f', dec, 0x4C)[0] * 3.6, 1),
                'fuel':      round(struct.unpack_from('<f', dec, 0x44)[0], 2),
            }
            # Only the bytes nobody has mapped. The rest is already known and
            # would bury the thing being looked for.
            for off in range(A_SIZE, len(dec)):
                row[f'b{off:03X}'] = dec[off]
            rows.append(row)
    except KeyboardInterrupt:
        print("\nstopped.")
    finally:
        rx.close()
        if raw_fh is not None:
            raw_fh.close()
            print(f"raw packets -> {args.save_raw}")

    if not n_pkts:
        print("Nothing arrived.\n")
        if args.ip:
            print(f"  You gave the address {args.ip}. Try leaving it off "
                  f"entirely:\n"
                  f"    python gt7_probe.py --letter {args.letter}\n"
                  f"  and the probe will shout on the network and let the "
                  f"console answer.")
        else:
            print("  Things to check, in the order they usually go wrong:\n"
                  "   - GT7 is running AND you are out on track. It sends\n"
                  "     nothing from the menus or the garage.\n"
                  "   - The connector and any dashboard are closed.\n"
                  "   - Windows did not block this when it asked. Allow it\n"
                  "     on private networks.\n"
                  "   - Some networks drop broadcast. If the connector finds\n"
                  "     your console, its settings page shows the address:\n"
                  "     pass that as the first argument.")
        return 1
    print(f"{n_pkts} packets, sizes seen: "
          + ", ".join(f"{k} bytes x{v}" for k, v in sorted(sizes.items())))
    if not rows:
        print("None of them decrypted.")
        if bad_sample:
            print(f"  First eight bytes after decoding: {bad_sample}")
            print(f"  Tried {len(_MASKS)} known nonce masks; none gave a "
                  f"'G7S' magic.")
            print("  Send me that hex and the letter you used, with "
                  "--save-raw so the")
            print("  packets themselves can be searched offline.")
        return 1
    if first_seen is not None and first_seen <= A_SIZE:
        if args.letter.upper() == 'A':
            # The control run, and it passed. 'A' is SUPPOSED to be 296
            # bytes; saying "nothing more to find" here would read as a
            # failure when it is the opposite.
            print(f"\nControl run fine: the console is at {console}, the "
                  f"packets decode, and 'A' is 296 bytes as it should be.\n"
                  f"Now ask for the one nobody has mapped:\n"
                  f"    python gt7_probe.py --letter C --seconds 60 "
                  f"--out c-hard.csv")
            return 0
        print(f"\nThe game answered '{args.letter}' with an ordinary "
              f"{first_seen}-byte packet, so this build has no bigger one "
              f"under that letter.")
        others = [k for k in EXPECTED if k != args.letter.upper() and k != 'A']
        print("  Worth trying the others before giving up: "
              + ", ".join(f"--letter {k}" for k in others))
        return 0

    with open(out_path, 'w', newline='') as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"\n{len(rows)} samples -> {out_path}")

    # The headline: which of the unmapped bytes moved at all. A byte that
    # never changes across a whole stint is not wear and is not compound.
    moved = []
    for off in range(A_SIZE, first_seen):
        key = f'b{off:03X}'
        vals = {r[key] for r in rows}
        if len(vals) > 1:
            moved.append((off, min(vals), max(vals), len(vals)))
    # Everything that held still, as one line of hex. Wear changes as you
    # drive and shows up above; a compound does not change at all within a
    # run, so the only way to find it is to compare this line between two
    # runs on different tyres. Printed rather than buried in the CSV so
    # that comparison is a glance.
    still = [off for off in range(A_SIZE, first_seen)
             if len({r[f'b{off:03X}'] for r in rows}) == 1]
    if still:
        print(f"\nheld still ({len(still)} bytes) — compare this line between "
              f"two runs on different tyres:")
        line, last = [], None
        for off in still:
            if last is not None and off != last + 1:
                line.append(' |')
            line.append(f" {rows[0][f'b{off:03X}']:02X}")
            last = off
        print(f"  0x{still[0]:03X}:" + "".join(line))

    if not moved:
        print("\nNone of the unmapped bytes changed while you drove.")
        return 0
    print(f"\n{len(moved)} of the {first_seen - A_SIZE} unmapped bytes changed:")
    for off, lo, hi, n in moved:
        print(f"  0x{off:03X}  {lo:3d}..{hi:3d} ({n} distinct)")
    # Where several neighbours moved together, read them as one number: a
    # wear value is far more likely to be a float than four busy bytes.
    starts = sorted({off - (off - A_SIZE) % 4 for off, *_ in moved})
    print("\nread as numbers, first and last sample:")
    for off in starts:
        print(f"  0x{off:03X}  first {describe(rows[0], off)}"
              f"   last {describe(rows[-1], off)}")
    return 0


def describe(row, off):
    """Rebuild the four bytes from the CSV row and read them every way."""
    try:
        buf = bytes(row[f'b{off + i:03X}'] for i in range(4))
    except KeyError:
        return '-'
    f = struct.unpack('<f', buf)[0]
    parts = [f"u8={buf[0]}", f"u16={struct.unpack('<H', buf[:2])[0]}"]
    if -1e9 < f < 1e9:
        parts.append(f"f32={f:.4g}")
    return " ".join(parts)


if __name__ == '__main__':
    sys.exit(main())
