#!/usr/bin/env python3
"""
GT7 Live Connector
==================
Background system-tray app that bridges Gran Turismo 7 UDP telemetry
to a local WebSocket server at ws://localhost:8765.

Run this, then open the SparksTheory GT7 Telemetry page in your browser.
Right-click the tray icon to quit.
"""

import asyncio
import http.server
import json
import os
import socket
import struct
import sys
import time
import threading
import logging
import urllib.parse
from typing import Optional

# ── Silence logging to not flash a console window ──
logging.disable(logging.CRITICAL)

# ── Crypto ──
# The compiled Salsa20 from pycryptodome is preferred, but it is a native .pyd
# and on a minority of Windows machines it will not load: antivirus quarantines
# it out of the unpacked folder, or Smart App Control refuses an unsigned DLL.
# That raises OSError, not ImportError, at import time, so catching ImportError
# alone killed the whole app before it did anything. Catch everything, and fall
# back to the pure-Python implementation further down, which needs no DLL at
# all. GT7 sends 60 packets a second and the fallback manages about 2000, so
# nobody loses anything but a little headroom.
try:
    from Crypto.Cipher import Salsa20 as _S20
    _S20.new(key=b'\0' * 32, nonce=b'\0' * 8).decrypt(b'\0' * 8)   # prove it really loads
    SALSA_BACKEND = "native"
except Exception:
    _S20 = None
    SALSA_BACKEND = "pure"
HAS_SALSA = True

try:
    import websockets
except ImportError:
    sys.exit(1)

# ── Tray ──
try:
    import pystray
    from PIL import Image, ImageDraw, ImageFont
    HAS_TRAY = True
except ImportError:
    HAS_TRAY = False

# ═══════════════════════════════════════════════════════════════
#  CONFIG
# ═══════════════════════════════════════════════════════════════
VERSION       = "2.9"   # shown in the tray so you can confirm which build is running
GT7_PORT_STD  = 33740   # the port GT7 itself sends telemetry to
GT7_PORT      = GT7_PORT_STD   # what we actually listen on; see _resolve_udp_config
SEND_PORT     = 33739
WS_PORT       = 8765
WS_HOST       = "0.0.0.0"
TRIGGER_PORT  = 8767    # Stream Deck (or anything else) hits this to drop overlay obstacles
HEARTBEAT_INT = 1.5    # GT7 stops streaming ~1-2s after the last heartbeat, so re-ping often
HEARTBEAT_EVERY = 100  # also re-ping every N received packets to keep the stream alive

# Only one program on a PC can hold port 33740, which is where GT7 always sends.
# So a dashboard and this connector cannot both listen directly. Either can be
# second in the chain instead, with the first forwarding a copy on:
#
#   FORWARD_TO    send a copy of every raw datagram somewhere else, so this
#                 connector can be first and still feed a dashboard
#   GT7_PORT      listen somewhere other than 33740, so it can be second and
#                 take a forwarded copy from whatever owns 33740
#
# A connector that is second must not ping the console: the other app is already
# doing that, and the console answers whoever asked, on 33740, which it owns.
FORWARD_TO    = []     # list of (host, port) to copy every raw datagram to
HEARTBEAT_ON  = True   # pinging the console; off by default on a forwarded port
HEARTBEAT_EXPLICIT = False   # True once a user has chosen, so the port stops deciding

# ═══════════════════════════════════════════════════════════════
#  DECRYPTION
# ═══════════════════════════════════════════════════════════════
# GT7 telemetry is Salsa20-encrypted. The key is the ASCII marker string
# (first 32 bytes). The 8-byte nonce is built from a 32-bit seed stored at
# offset 0x40: nonce = (seed ^ 0xDEADBEAF) little-endian, then seed
# little-endian. Decrypted packets begin with the magic b'G7S0'.
_KEY = b'Simulator Interface Packet GT7 ver 0.0'[:32]

# ── Pure-Python Salsa20, used only when the compiled one will not load ──
# Salsa20 is a stream cipher: it makes a keystream from (key, nonce, counter)
# and XORs it with the data, so decrypting is the same operation as encrypting.
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
    if _S20 is not None:
        return _S20.new(key=key, nonce=nonce)
    return _PureSalsa20(key, nonce)

G7S0 = 0x47375330          # b'G7S0' read little-endian, which is how it is stored

def decrypt_packet(data: bytes) -> Optional[bytes]:
    if len(data) < 0x128:
        return None
    # Some tools forward the stream already decoded. If the magic is sitting
    # there in the clear there is nothing to decrypt, and trying would turn a
    # perfectly good packet into noise.
    if int.from_bytes(data[0:4], 'little') == G7S0:
        return data
    seed = int.from_bytes(data[0x40:0x44], 'little')
    nonce = (seed ^ 0xDEADBEAF).to_bytes(4, 'little') + seed.to_bytes(4, 'little')
    if HAS_SALSA:
        try:
            dec = _salsa_new(_KEY, nonce).decrypt(data)
            # Magic 'G7S0' is stored little-endian, so the decoded bytes are
            # 30 53 37 47 -> int 0x47375330. (Comparing to b'G7S0' directly
            # checks the reverse byte order and wrongly rejects valid packets.)
            if int.from_bytes(dec[0:4], 'little') == 0x47375330:
                return dec
        except Exception:
            pass
    return None  # decryption failed, drop packet rather than send garbage

# ═══════════════════════════════════════════════════════════════
#  PACKET PARSER
# ═══════════════════════════════════════════════════════════════
class GT7Packet:
    def __init__(self, raw: bytes):
        self.valid = False
        if len(raw) < 0x128:
            return
        try:
            self._r = raw
            self._parse()
            self.valid = True
        except Exception:
            pass

    def _f(self, o): return struct.unpack_from('<f', self._r, o)[0]
    def _i(self, o): return struct.unpack_from('<i', self._r, o)[0]
    def _h(self, o): return struct.unpack_from('<h', self._r, o)[0]
    def _H(self, o): return struct.unpack_from('<H', self._r, o)[0]
    def _B(self, o): return struct.unpack_from('<B', self._r, o)[0]

    def _parse(self):
        self.packet_id   = self._i(0x70)
        self.speed_ms    = self._f(0x4C)
        self.speed_kmh   = self.speed_ms * 3.6
        self.rpm         = self._f(0x38)
        self.fuel        = self._f(0x44)
        self.fuel_cap    = self._f(0x48)
        self.boost       = self._f(0x50)
        self.oil_press   = self._f(0x54)
        self.water_temp  = self._f(0x58)
        self.oil_temp    = self._f(0x5C)
        self.tfl_temp    = self._f(0x60)
        self.tfr_temp    = self._f(0x64)
        self.trl_temp    = self._f(0x68)
        self.trr_temp    = self._f(0x6C)
        self.lap_count   = self._h(0x74)
        self.laps_in_race= self._h(0x76)
        self.best_lap    = self._i(0x78)
        self.last_lap    = self._i(0x7C)
        flags            = self._H(0x8E)
        self.in_race     = bool(flags & 0x0001)
        self.paused      = bool(flags & 0x0002)
        gear_raw         = self._B(0x90)
        self.gear        = gear_raw & 0x0F
        self.throttle    = self._B(0x91) / 255.0
        self.brake       = self._B(0x92) / 255.0
        self.tfl_rps     = self._f(0xA4)
        self.tfr_rps     = self._f(0xA8)
        self.trl_rps     = self._f(0xAC)
        self.trr_rps     = self._f(0xB0)
        self.tfl_sus     = self._f(0xC4)
        self.tfr_sus     = self._f(0xC8)
        self.trl_sus     = self._f(0xCC)
        self.trr_sus     = self._f(0xD0)
        self.max_alert   = self._h(0x8A)
        self.angvel_y    = self._f(0x2C)
        self.vel_x       = self._f(0x10)
        self.vel_z       = self._f(0x18)
        self.angvel_x    = self._f(0x28)
        self.angvel_z    = self._f(0x30)
        self.rot_yaw     = self._f(0x20)
        # Pitch (0x1C) and roll (0x24) sit either side of yaw; sent so the
        # track-overlay lab can sit graphics flat on slopes and banking.
        # VERIFY these two offsets against a real capture.
        self.rot_pitch   = self._f(0x1C)
        self.rot_roll    = self._f(0x24)
        self.pos_x       = self._f(0x04)
        self.pos_y       = self._f(0x08)
        self.pos_z       = self._f(0x0C)
        self.vehicle_id  = self._i(0xF4)
        speed = max(self.speed_ms, 0.1)
        self.lat_g   = self.angvel_y * speed / 9.81
        self.long_g  = (self.vel_x * self.angvel_z - self.vel_z * self.angvel_x) / 9.81
        steer_raw = self.lat_g / 2.0
        self.steer_est = max(-1.0, min(1.0, steer_raw))

    def to_dict(self):
        return {
            "type":       "telemetry",
            "packetId":   self.packet_id,
            "speed":      round(self.speed_kmh, 1),
            "rpm":        round(self.rpm, 0),
            "rpmMax":     int(self.max_alert) if self.max_alert > 1000 else 9000,
            "gear":       self.gear,
            "throttle":   round(self.throttle * 100, 1),
            "brake":      round(self.brake * 100, 1),
            "steer":      round(self.steer_est * 100, 1),
            "latG":       round(self.lat_g, 3),
            "longG":      round(self.long_g, 3),
            "lapCount":   self.lap_count,
            "lapsInRace": self.laps_in_race,
            "bestLap":    self.best_lap,
            "lastLap":    self.last_lap,
            "inRace":     self.in_race,
            "paused":     self.paused,
            "tyreTempFL": round(self.tfl_temp, 1),
            "tyreTempFR": round(self.tfr_temp, 1),
            "tyreTempRL": round(self.trl_temp, 1),
            "tyreTempRR": round(self.trr_temp, 1),
            "tyreSusFL":  round(self.tfl_sus, 4),
            "tyreSusFR":  round(self.tfr_sus, 4),
            "tyreSusRL":  round(self.trl_sus, 4),
            "tyreSusRR":  round(self.trr_sus, 4),
            "tyreRpsFL":  round(self.tfl_rps, 2),
            "tyreRpsFR":  round(self.tfr_rps, 2),
            "tyreRpsRL":  round(self.trl_rps, 2),
            "tyreRpsRR":  round(self.trr_rps, 2),
            "fuel":       round(self.fuel, 2),
            "fuelCap":    round(self.fuel_cap, 2),
            "boost":      round(self.boost, 3),
            "oilPress":   round(self.oil_press, 2),
            "waterTemp":  round(self.water_temp, 1),
            "oilTemp":    round(self.oil_temp, 1),
            "vehicleId":  self.vehicle_id,
            "posX":       round(self.pos_x, 2),
            "posY":       round(self.pos_y, 2),
            "posZ":       round(self.pos_z, 2),
            "rotYaw":     round(self.rot_yaw, 4),
            "rotPitch":   round(self.rot_pitch, 4),
            "rotRoll":    round(self.rot_roll, 4),
        }


# ═══════════════════════════════════════════════════════════════
#  WEBSOCKET SERVER
# ═══════════════════════════════════════════════════════════════
_clients = {}   # ws -> {"tel": Queue(maxsize=1) latest-frame-only, "evt": Queue small, never coalesced}
# Live status so the web page (and tray tooltip) can tell whether the console
# is actually sending telemetry, not just whether the bridge is up.
# raw and packets are running totals for the tray and the page. The diagnosis
# needs "since we started listening HERE" instead: after a port change, counts
# from the old port would make a silent new one look healthy.
_stats = {"packets": 0, "raw": 0, "ps5": None, "last": 0.0, "debug": None, "bindError": None,
          "boundAt": 0.0, "rawAtBind": 0, "packetsAtBind": 0}

def _capture_debug(raw):
    """One-shot capture of the first datagram so undecodable formats can be
    diagnosed: length, header bytes, and what the standard decrypt yields."""
    info = {"len": len(raw), "head": raw[:min(len(raw), 0x48)].hex()}
    try:
        if HAS_SALSA and len(raw) >= 0x44:
            seed = int.from_bytes(raw[0x40:0x44], 'little')
            nonce = (seed ^ 0xDEADBEAF).to_bytes(4, 'little') + seed.to_bytes(4, 'little')
            info["dec"] = _salsa_new(_KEY, nonce).decrypt(raw)[:8].hex()
        else:
            info["dec"] = "n/a"
    except Exception:
        info["dec"] = "err"
    _stats["debug"] = info

def _status_msg():
    return json.dumps({
        "type": "status",
        # The page compares this with the build it expects, so it can tell the
        # few people on an old connector and nobody else. A status message with
        # no version in it is itself the answer: that connector predates this.
        "version": VERSION,
        "packets": _stats["packets"],   # valid, decoded telemetry packets
        "raw": _stats["raw"],           # raw UDP datagrams received (before decode)
        "ps5": _stats["ps5"],
        "debug": _stats["debug"],
        "listening": True,
        "udpPort": GT7_PORT,
        "forwarded": GT7_PORT != GT7_PORT_STD,   # we are second in the chain
        "heartbeat": HEARTBEAT_ON,
        "forwardTo": [f"{h}:{p}" for h, p in FORWARD_TO],
        "bindError": _stats["bindError"],
        "crypto": SALSA_BACKEND,   # "native", or "pure" if the compiled module would not load
        "gtec": {                  # live timing, so the page can say whether it is working
            "state":  _gtec["state"],
            "detail": _gtec["detail"],
            "sent":   _gtec["sent"],
            "paired": bool(GTEC_CODE),
            "code":   GTEC_CODE,
        },
    })

async def _client_sender(ws, tel_q, evt_q):
    # One task per client, the ONLY place that awaits ws.send. Services both
    # queues concurrently: the telemetry queue (maxsize=1, _broadcast keeps
    # overwriting it, so a slow client just skips stale frames and catches up
    # on the freshest one) and the event queue (small, never coalesced - a
    # Stream Deck trigger must never get silently dropped behind a busy
    # telemetry stream). The receive loop is never blocked by any of this.
    # websockets' own keepalive closes a truly dead connection, which ends
    # this task and cleans the client up.
    tel_task = asyncio.ensure_future(tel_q.get())
    evt_task = asyncio.ensure_future(evt_q.get())
    try:
        while True:
            done, _ = await asyncio.wait({tel_task, evt_task}, return_when=asyncio.FIRST_COMPLETED)
            if evt_task in done:
                await ws.send(evt_task.result())
                evt_task = asyncio.ensure_future(evt_q.get())
            if tel_task in done:
                await ws.send(tel_task.result())
                tel_task = asyncio.ensure_future(tel_q.get())
    except Exception:
        pass
    finally:
        tel_task.cancel(); evt_task.cancel()
        _clients.pop(ws, None)

async def _ws_handler(ws):
    # Handshake messages go out directly and in order, before the frame queue
    # (which coalesces to a single latest frame) is wired up.
    try:
        await ws.send(json.dumps({"type":"connected","message":"GT7 Live Connector ready"}))
        await ws.send(_status_msg())          # tell a fresh page what we're seeing right away
    except Exception:
        return
    tel_q = asyncio.Queue(maxsize=1)
    evt_q = asyncio.Queue(maxsize=20)
    _clients[ws] = {"tel": tel_q, "evt": evt_q}
    sender = asyncio.create_task(_client_sender(ws, tel_q, evt_q))
    try:
        async for _ in ws:
            pass
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        _clients.pop(ws, None)
        sender.cancel()

def _broadcast(msg: str):
    # Non-blocking fan-out: drop any older unsent frame and enqueue the newest
    # for each client. Runs to completion without awaiting, so a slow client can
    # never stall the receive loop with backpressure; it just loses intermediate
    # frames. Kept synchronous on purpose so callers cannot accidentally block.
    for ws, ch in list(_clients.items()):
        try:
            q = ch["tel"]
            if q.full():
                q.get_nowait()      # discard the stale frame the client hasn't sent yet
            q.put_nowait(msg)
        except Exception:
            pass

def _broadcast_event(kind: str):
    # Discrete, non-coalesced events (Stream Deck obstacle triggers). Small
    # queue per client so a burst of button presses still all arrive.
    msg = json.dumps({"type": "event", "event": kind})
    for ws, ch in list(_clients.items()):
        try:
            ch["evt"].put_nowait(msg)
        except Exception:
            pass   # queue full (20 unsent events) - drop rather than block

# ═══════════════════════════════════════════════════════════════
#  SETTINGS PAGE
# ═══════════════════════════════════════════════════════════════
# Served by the connector itself, so there is one interface on every platform
# and nothing extra in the build. It matters most on Linux, where there is no
# tray icon at all and this is the only interface there has ever been.
SETTINGS_HTML = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>GT7 Live Connector</title>
<style>
:root{--bg:#07080d;--pan:#0d0f18;--bor:#1c1f2e;--mut:#8b93a3;--wht:#eef0f8;--blu:#1ab4ff;--grn:#35d07f;--red:#dc524c;--gold:#ffc31a;}
*{box-sizing:border-box;}
body{margin:0;background:var(--bg);color:var(--wht);font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;line-height:1.55;}
.wrap{max-width:760px;margin:0 auto;padding:1.5rem 1rem 4rem;}
header{border-bottom:1px solid var(--bor);padding-bottom:1rem;margin-bottom:1.5rem;}
.eyebrow{font-family:ui-monospace,'JetBrains Mono',Menlo,monospace;font-size:.6rem;letter-spacing:.22em;color:var(--blu);text-transform:uppercase;}
h1{margin:.2rem 0 0;font-size:1.65rem;letter-spacing:-.01em;}
h1 small{color:var(--mut);font-size:.8rem;font-weight:400;letter-spacing:.08em;margin-left:.5rem;}
h2{font-size:.68rem;letter-spacing:.18em;text-transform:uppercase;color:var(--mut);font-family:ui-monospace,'JetBrains Mono',Menlo,monospace;margin:0 0 .9rem;font-weight:600;}
.card{background:var(--pan);border:1px solid var(--bor);border-radius:8px;padding:1.2rem;margin-bottom:1.1rem;}
.live{display:flex;align-items:center;gap:.7rem;flex-wrap:wrap;}
.dot{width:9px;height:9px;border-radius:50%;background:var(--mut);flex:0 0 auto;}
.dot.on{background:var(--grn);box-shadow:0 0 10px rgba(53,208,127,.7);}
.dot.warn{background:var(--gold);}
.dot.err{background:var(--red);}
.state{font-size:1.05rem;font-weight:600;}
.sub{color:var(--mut);font-size:.84rem;}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(118px,1fr));gap:.6rem;margin-top:1rem;}
.stat{background:#090b12;border:1px solid var(--bor);border-radius:6px;padding:.6rem .7rem;}
.stat b{display:block;font-family:ui-monospace,'JetBrains Mono',Menlo,monospace;font-size:.54rem;letter-spacing:.14em;color:var(--mut);text-transform:uppercase;font-weight:600;}
.stat span{font-size:1.15rem;font-variant-numeric:tabular-nums;}
label{display:block;margin-bottom:1rem;}
label .t{font-size:.9rem;font-weight:600;display:block;margin-bottom:.15rem;}
label .h{color:var(--mut);font-size:.8rem;display:block;margin-bottom:.4rem;}
input[type=text],select{width:100%;background:#090b12;border:1px solid var(--bor);border-radius:5px;color:var(--wht);
  padding:.55rem .7rem;font-family:ui-monospace,'JetBrains Mono',Menlo,monospace;font-size:.88rem;}
input[type=text]:focus,select:focus{outline:none;border-color:var(--blu);}
.row{display:flex;gap:.6rem;align-items:center;flex-wrap:wrap;}
button{font-family:ui-monospace,'JetBrains Mono',Menlo,monospace;font-size:.68rem;letter-spacing:.12em;text-transform:uppercase;
  padding:.6rem 1.2rem;border-radius:5px;border:1px solid var(--bor);background:transparent;color:var(--mut);cursor:pointer;}
button:hover{border-color:var(--wht);color:var(--wht);}
button.primary{border-color:var(--blu);background:rgba(26,180,255,.12);color:var(--blu);}
button.primary:hover{background:rgba(26,180,255,.22);}
a{color:var(--blu);}
.note{border-left:3px solid var(--gold);background:rgba(255,195,26,.07);padding:.7rem .9rem;border-radius:0 5px 5px 0;
  font-size:.85rem;margin-top:.9rem;color:#e8dcb0;}
.note.ok{border-color:var(--grn);background:rgba(53,208,127,.07);color:#bfe9d2;}
.note.bad{border-color:var(--red);background:rgba(220,82,76,.08);color:#f0c4c2;}
.hint{color:var(--mut);font-size:.8rem;margin-top:.8rem;}
code{background:#090b12;border:1px solid var(--bor);border-radius:3px;padding:.08rem .35rem;font-size:.84em;}
footer{color:var(--mut);font-size:.76rem;text-align:center;margin-top:1.5rem;}
.hidden{display:none;}
</style></head><body><div class="wrap">

<header>
  <div class="eyebrow">SparksTheory</div>
  <h1>GT7 Live Connector <small id="ver"></small></h1>
</header>

<div class="card">
  <div class="live"><i class="dot" id="dot"></i><span class="state" id="state">Checking…</span></div>
  <div class="sub" id="detail"></div>
  <div class="grid">
    <div class="stat"><b>Listening on</b><span id="sPort">—</span></div>
    <div class="stat"><b>Packets</b><span id="sPkt">0</span></div>
    <div class="stat"><b>Console</b><span id="sIp" style="font-size:.9rem">—</span></div>
    <div class="stat"><b>Pages open</b><span id="sCli">0</span></div>
  </div>
  <div class="note bad hidden" id="bindErr"></div>
</div>

<div class="card">
  <h2>GTEC live timing</h2>
  <p class="sub" style="margin-top:-.4rem">
    Put your car on the GTEC live map during a race. Paste the pairing code from your
    driver portal, under Account. Leave this empty and nothing is sent.
  </p>
  <label>
    <span class="t">GTEC pairing code</span>
    <span class="h">One-off. It works for every round after that.</span>
    <input type="text" id="gtecCode" placeholder="not paired" spellcheck="false">
  </label>
  <div class="note" id="gtecNote">Not paired.</div>
  <div class="row" style="margin-top:.6rem">
    <button class="primary" id="gtecSave">Save pairing code</button>
    <button id="gtecClear">Unpair</button>
  </div>
</div>

<div class="card" id="share">
  <h2>Sharing telemetry with another app</h2>
  <p class="sub" style="margin-top:-.4rem">
    Only one program on this computer can listen on port <b id="stdPort">33740</b>, which is where GT7 sends.
    To run a dashboard at the same time, one of them passes a copy to the other.
  </p>

  <label>
    <span class="t">Listen on this port instead</span>
    <span class="h">Use this when your dashboard goes first and forwards a copy to you. Leave empty for normal use.</span>
    <input type="text" id="udpPort" placeholder="33740" inputmode="numeric">
  </label>

  <label>
    <span class="t">Send a copy to</span>
    <span class="h">Use this when you go first. Your dashboard then listens on that port. Separate several with commas.</span>
    <input type="text" id="forward" placeholder="127.0.0.1:33742">
  </label>

  <label>
    <span class="t">Keep the console awake</span>
    <span class="h">GT7 stops sending unless something keeps asking. Leave this on automatic unless you know you need otherwise.</span>
    <select id="heartbeat">
      <option value="auto">Automatic (on unless another app went first)</option>
      <option value="on">Always on</option>
      <option value="off">Always off</option>
    </select>
  </label>

  <div class="row">
    <button class="primary" id="save">Save</button>
    <button id="reset">Back to normal</button>
  </div>
  <div id="msg"></div>
</div>

<div class="card">
  <h2>Console</h2>
  <label>
    <span class="t">PlayStation address</span>
    <span class="h">Normally found on its own. Only fill this in if your network blocks broadcast, or the console is on another subnet.</span>
    <input type="text" id="consoleIp" placeholder="found automatically">
  </label>
  <div class="row"><button id="saveIp">Save address</button></div>
  <div class="hint">Settings are stored in <code id="dir">…</code></div>
</div>

<footer>
  Telemetry is served to pages on this computer at <code id="ws"></code>.
  <br>Open the <a href="https://sparkstheory.co.uk/gt7-lap-coach.html" target="_blank" rel="noopener">GT7 Lap Coach</a>.
</footer>

</div><script>
const $ = id => document.getElementById(id);
let touched = false;
['udpPort','forward','heartbeat','consoleIp','gtecCode'].forEach(id => {
  $(id).addEventListener('input', () => touched = true);
  $(id).addEventListener('change', () => touched = true);
});

function paint(s){
  $('ver').textContent = 'v' + s.version;
  $('stdPort').textContent = s.standardPort;
  $('ws').textContent = 'ws://localhost:' + s.wsPort;
  $('dir').textContent = s.settingsDir;
  $('sPort').textContent = s.udpPort;
  $('sPkt').textContent = s.packets.toLocaleString();
  $('sIp').textContent = s.consoleIp || (s.udpPort === s.standardPort ? 'searching' : 'via another app');
  $('sCli').textContent = s.clients;

  // Live timing status. Says what is actually happening rather than just
  // whether a code is present, because "paired" and "working" are different
  // things and a driver wants to know the second one.
  if(s.gtec){
    const g = s.gtec, n = $('gtecNote');
    n.classList.remove('bad');
    if(g.state === 'reporting'){ n.textContent = g.detail; n.classList.add('ok'); }
    else {
      n.classList.remove('ok');
      n.textContent = g.detail || 'Not paired.';
      if(g.state === 'error') n.classList.add('bad');
    }
  }

  const dot = $('dot');
  dot.className = 'dot';
  if(s.bindError){
    dot.classList.add('err');
    $('state').textContent = 'Cannot listen on that port';
    $('detail').textContent = 'Something else is probably using it.';
    $('bindErr').textContent = s.bindError;
    $('bindErr').classList.remove('hidden');
  } else {
    $('bindErr').classList.add('hidden');
    if(s.receiving){
      dot.classList.add('on');
      $('state').textContent = 'Receiving telemetry';
      $('detail').textContent = 'Drive a lap and it will show up on the Lap Coach.';
    } else if(s.undecodable){
      dot.classList.add('warn');
      $('state').textContent = 'Data is arriving but cannot be read';
      $('detail').textContent = s.rawHere.toLocaleString() + ' packets have come in and none of them look like GT7 telemetry. If another app is forwarding to this port, check it is sending the raw stream rather than something it has already changed.';
    } else if(s.udpPort !== s.standardPort){
      dot.classList.add('warn');
      $('state').textContent = 'Waiting on the other app';
      $('detail').textContent = 'Listening on ' + s.udpPort + ' for a forwarded copy. If nothing arrives, check that the other program is running and is forwarding to this port.';
    } else if(s.listeningFor > 20 && s.rawHere === 0){
      // The one thing nobody guesses at: something else already owns the port.
      dot.classList.add('warn');
      $('state').textContent = 'Nothing is arriving';
      $('detail').innerHTML = 'If you have a dashboard, motion rig or lap timer open, it has probably already taken port ' + s.standardPort +
        ', and only one program can have it. <a href="#share">Set them to share it</a> and both will work.' +
        '<br>If you are not running anything like that, start Gran Turismo 7 and drive. If it still never connects, your network may be blocking broadcast, so try setting the console address below.';
    } else {
      dot.classList.add('warn');
      $('state').textContent = 'Waiting for the console';
      $('detail').textContent = 'Start Gran Turismo 7 and drive. If it never connects, your network may be blocking broadcast, so try setting the console address below.';
    }
  }
  if(!touched){
    $('udpPort').value  = s.udpPort === s.standardPort ? '' : s.udpPort;
    $('forward').value  = s.forward || '';
    $('heartbeat').value = s.heartbeatExplicit ? (s.heartbeat ? 'on' : 'off') : 'auto';
    $('consoleIp').value = (s.udpPort === s.standardPort ? (s.consoleIp || '') : '');
    $('gtecCode').value  = (s.gtec && s.gtec.code) || '';
  }
}

function say(text, cls){
  $('msg').innerHTML = text ? '<div class="note ' + (cls || '') + '">' + text + '</div>' : '';
}

async function poll(){
  try{ paint(await (await fetch('/api/status')).json()); }catch(e){
    $('dot').className = 'dot err';
    $('state').textContent = 'Connector not running';
    $('detail').textContent = 'This page is served by the connector itself, so if it has quit, start it again.';
  }
}

async function send(body, okText){
  try{
    const r = await fetch('/api/settings', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body) });
    const d = await r.json();
    touched = false;
    say((d.notes && d.notes.length ? d.notes.join(' ') : okText), d.notes && d.notes.length ? '' : 'ok');
    paint(d.status);
  }catch(e){ say('Could not save: ' + e, 'bad'); }
}

$('save').onclick  = () => send({ udpPort: $('udpPort').value, forward: $('forward').value, heartbeat: $('heartbeat').value }, 'Saved, and in use now.');
$('gtecSave').onclick  = () => send({ gtecCode: $('gtecCode').value }, 'Pairing code saved. The status below updates within a few seconds.');
$('gtecClear').onclick = () => { $('gtecCode').value=''; send({ gtecCode: '' }, 'Unpaired. Nothing is sent to GTEC now.'); };
$('reset').onclick = () => { $('udpPort').value=''; $('forward').value=''; $('heartbeat').value='auto';
                             send({ udpPort:'', forward:'', heartbeat:'auto' }, 'Back to normal: listening on the standard port.'); };
$('saveIp').onclick = () => send({ consoleIp: $('consoleIp').value }, 'Address saved.');

poll(); setInterval(poll, 1500);
</script></body></html>
"""

# ═══════════════════════════════════════════════════════════════
#  TRIGGER SERVER (Stream Deck -> overlay obstacles)
# ═══════════════════════════════════════════════════════════════
# A tiny, separate plain-HTTP server on its own thread/port, stdlib only, so
# a Stream Deck "Website" action can fire a GET request without touching the
# telemetry WebSocket server, its dependencies, or its event loop directly.
# _loop is the asyncio loop _run_bridge already creates; call_soon_threadsafe
# hands the trigger back into it safely from this server's own thread.
class _TriggerHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass   # keep the console/tray quiet

    # The settings page writes files, so it answers only to this machine. The
    # trigger stays open to the network, because a Stream Deck is often on a
    # different PC and that behaviour is already out there in people's setups.
    def _is_local(self):
        try:
            return self.client_address[0] in ('127.0.0.1', '::1', '::ffff:127.0.0.1')
        except Exception:
            return False

    def _send(self, code, body, ctype='application/json'):
        if isinstance(body, str):
            body = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path in ('/settings', '/settings/'):
            if not self._is_local():
                return self._send(403, 'Settings can only be opened on the computer running the connector.', 'text/plain')
            return self._send(200, SETTINGS_HTML, 'text/html; charset=utf-8')
        if path == '/api/status':
            if not self._is_local():
                return self._send(403, '{"error":"local only"}')
            return self._send(200, json.dumps(_settings_snapshot()))
        if path == '/favicon.ico':
            return self._send(204, b'', 'image/x-icon')      # a browser asking, not a Stream Deck

        # anything else is a trigger, exactly as before
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        kind = (qs.get('type') or ['wall'])[0]
        if _loop is not None:
            _loop.call_soon_threadsafe(_broadcast_event, kind)
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(b'ok')

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path != '/api/settings' or not self._is_local():
            return self._send(403, '{"error":"local only"}')
        try:
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(min(n, 8192)) or b'{}')
        except Exception:
            return self._send(400, '{"error":"bad request"}')
        try:
            notes = _apply_settings(body if isinstance(body, dict) else {})
        except Exception as e:
            return self._send(500, json.dumps({"error": str(e)[:200]}))
        self._send(200, json.dumps({"notes": notes, "status": _settings_snapshot()}))

def _start_trigger_server():
    try:
        srv = http.server.ThreadingHTTPServer(('0.0.0.0', TRIGGER_PORT), _TriggerHandler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    except Exception:
        pass   # optional feature - never take the telemetry bridge down over this

# ═══════════════════════════════════════════════════════════════
#  UDP RECEIVER + HEARTBEAT
# ═══════════════════════════════════════════════════════════════
def _hb(ip):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        s.sendto(b'A', (ip, SEND_PORT))
        s.close()
    except Exception:
        pass

def _local_subnet_bcast():
    """Best-effort subnet broadcast address (e.g. 192.168.1.255) for the
    interface that reaches the internet. Directed broadcast reaches consoles
    that the limited 255.255.255.255 broadcast misses on many home networks."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))          # no packet sent; just picks the interface
        ip = s.getsockname()[0]
        s.close()
        parts = ip.split('.')
        if len(parts) == 4:
            parts[3] = '255'
            return '.'.join(parts)
    except Exception:
        pass
    return None

async def _heartbeat(ip_ref):
    sub = _local_subnet_bcast()
    def ping():
        tgt = ip_ref[0]
        if tgt:
            _hb(tgt)                         # known/configured console: unicast straight to it
        else:
            _hb('255.255.255.255')           # limited broadcast
            if sub:
                _hb(sub)                     # subnet-directed broadcast (reaches more networks)
    # The flag is read every tick rather than once, so turning the ping on or
    # off in the settings page takes effect without a restart.
    if HEARTBEAT_ON:
        ping()
    while True:
        await asyncio.sleep(HEARTBEAT_INT)
        if HEARTBEAT_ON:
            ping()

async def _status_loop():
    # Push a heartbeat of our own state to any connected page every 2s, so the
    # dashboard can show "listening, no telemetry yet" vs "receiving".
    while True:
        await asyncio.sleep(2)
        if _clients:
            _broadcast(_status_msg())

_fwd_sock = None

def _forward(raw):
    """Pass a copy of the raw datagram on to anything else that wants it, so
    this connector can own port 33740 and still let a dashboard run. Sent
    exactly as it arrived, encrypted and all, because that is what the next
    program along expects from the console."""
    global _fwd_sock
    if not FORWARD_TO:
        return
    try:
        if _fwd_sock is None:
            _fwd_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        for dest in FORWARD_TO:
            try:
                _fwd_sock.sendto(raw, dest)
            except Exception:
                pass                          # one bad destination must not stop the others
    except Exception:
        pass

def _bind_udp(port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('', port))
    sock.setblocking(False)
    return sock

async def _receiver(ps5_ip, ip_ref):
    sock, bound = None, None
    loop = asyncio.get_event_loop()
    last_id = -1
    detected = ps5_ip
    if ps5_ip:
        ip_ref[0] = ps5_ip

    while True:
        await asyncio.sleep(0)
        # Changing the port in the settings page means letting go of one socket
        # and taking another, which happens here rather than on a restart.
        if bound != GT7_PORT:
            if sock is not None:
                try: sock.close()
                except Exception: pass
            try:
                sock = _bind_udp(GT7_PORT)
            except Exception as e:
                _stats["bindError"] = f"Could not listen on UDP {GT7_PORT}: {e}"
                await asyncio.sleep(2)
                continue
            _stats["bindError"] = None
            _stats["boundAt"] = time.time()
            _stats["rawAtBind"] = _stats["raw"]
            _stats["packetsAtBind"] = _stats["packets"]
            bound = GT7_PORT
            last_id = -1
            # on a forwarded port the sender is another app, not the console
            detected = ps5_ip if GT7_PORT == GT7_PORT_STD else None
            _stats["ps5"] = detected
        try:
            raw, addr = await loop.run_in_executor(None, lambda: sock.recvfrom(4096))
        except BlockingIOError:
            await asyncio.sleep(0.001)
            continue
        except Exception:
            await asyncio.sleep(0.01)
            continue

        _stats["raw"] += 1                # a datagram arrived (before any decode)
        _forward(raw)                     # before anything else, so a dashboard never waits on us
        if _stats["raw"] == 1:
            _capture_debug(raw)           # snapshot the first packet for diagnosis

        if detected is None and GT7_PORT == GT7_PORT_STD:
            # On a forwarded port the sender is the app that forwarded it, not
            # the console, so learning an address from it would be wrong.
            detected = addr[0]
            ip_ref[0] = detected
            _stats["ps5"] = detected
            if HEARTBEAT_ON:
                _hb(detected)
            _broadcast(json.dumps({"type":"gt7_detected","ip":detected}))

        dec = decrypt_packet(raw)
        if dec is None:
            continue
        pkt = GT7Packet(dec)
        if not pkt.valid or pkt.packet_id == last_id:
            continue
        last_id = pkt.packet_id
        _stats["packets"] += 1
        _stats["last"] = time.time()
        # Keep the console streaming: GT7 sends ~100 packets per heartbeat, then
        # stops. Re-ping every HEARTBEAT_EVERY packets so the feed never stalls.
        if HEARTBEAT_ON and pkt.packet_id % HEARTBEAT_EVERY == 0:
            _hb(ip_ref[0] or detected or '255.255.255.255')
        global _gtec_last_pkt
        _gtec_last_pkt = pkt              # the beacon reads this, it never decodes
        if _clients:
            _broadcast(json.dumps(pkt.to_dict()))


# ═══════════════════════════════════════════════════════════════
#  GTEC LIVE TIMING
#
#  Posts this car's own position to GTEC so the website can assemble the
#  whole field from every driver reporting. One machine cannot see sixteen
#  cars across eight splits, but it never has to.
#
#  Off unless a pairing code is set, so a driver who does not want to be on
#  the live map simply never enters one and nothing leaves this machine.
#  Nothing is sent outside a race window either: the server decides whether
#  a round is on and tells us how often to come back.
#
#  urllib rather than requests, to keep the frozen build dependency-free.
# ═══════════════════════════════════════════════════════════════
GTEC_URL   = "https://wtryzoabpkqtucfpmbnn.supabase.co"
GTEC_ANON  = ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind0cnl6b2FicGtxdHVjZnBtYm5uIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA0MTg0MjMsImV4cCI6MjA5NTk5NDQyM30.Jpx_23mxUsiS5Ke2MCZKOKBu09bH1XuViY6heAB-jds")
# The public anon key, the same one the website ships in gtec-config.js.
# Public by design: the beacon is authorised by the driver's pairing code,
# not by this.
GTEC_CODE  = ""          # the driver's pairing code; empty means do not report

# What the settings page shows about live timing.
_gtec = {
    "state":  "off",     # off | waiting | reporting | idle | error
    "detail": "",
    "sent":   0,
    "last":   None,
}

_gtec_last_pkt = None    # most recent decoded packet, set by the receiver
# (lap number, when it changed, whether we have seen a real change). The flag
# matters: on the first packet we know the lap number but not when it started,
# so elapsed time is unknown rather than zero.
_gtec_lap_seen = [None, 0.0, False]


def _gtec_post(payload: dict):
    """One beacon. Returns the decoded reply, or None if it did not land."""
    import urllib.request, urllib.error
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        GTEC_URL.rstrip("/") + "/rest/v1/rpc/live_beacon",
        data=body,
        headers={
            "Content-Type": "application/json",
            "apikey": GTEC_ANON,
            "Authorization": "Bearer " + GTEC_ANON,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"Server said {e.code}"}
    except Exception as e:
        # A dropped beacon is not queued. A stale position shown as live is
        # worse than a gap the website can age out honestly.
        return None


async def _gtec_beacon():
    loop = asyncio.get_event_loop()
    wait = 3.0
    while True:
        await asyncio.sleep(wait)

        if not GTEC_CODE or not GTEC_ANON:
            _gtec["state"] = "off"
            _gtec["detail"] = "No pairing code set." if not GTEC_CODE else "This build has no site key."
            wait = 5.0
            continue

        pkt = _gtec_last_pkt
        if pkt is None:
            _gtec["state"] = "waiting"
            _gtec["detail"] = "Waiting for telemetry from GT7."
            wait = 3.0
            continue

        # GT7 does not send elapsed time on the current lap, so derive it from
        # when the lap counter last changed rather than guessing from startup.
        if _gtec_lap_seen[0] != pkt.lap_count:
            if _gtec_lap_seen[0] is not None:
                _gtec_lap_seen[2] = True      # a real crossing, not just the first sight
            _gtec_lap_seen[0] = pkt.lap_count
            _gtec_lap_seen[1] = time.time()
        lap_ms = int((time.time() - _gtec_lap_seen[1]) * 1000) if _gtec_lap_seen[2] else None

        on_track = bool(pkt.in_race and not pkt.paused)
        payload = {
            "p_token":       GTEC_CODE,
            "p_lap":         int(pkt.lap_count or 0),
            "p_lap_ms":      lap_ms,
            # GT7 reports -1 for a lap time that does not exist yet.
            "p_last_lap_ms": int(pkt.last_lap) if (pkt.last_lap or 0) > 0 else None,
            "p_best_lap_ms": int(pkt.best_lap) if (pkt.best_lap or 0) > 0 else None,
            "p_x":           round(float(pkt.pos_x), 2),
            "p_z":           round(float(pkt.pos_z), 2),
            "p_speed_kph":   int(pkt.speed_kmh),
            "p_on_track":    on_track,
        }

        reply = await loop.run_in_executor(None, lambda: _gtec_post(payload))

        if reply is None:
            _gtec["state"] = "error"
            _gtec["detail"] = "Could not reach GTEC. Retrying."
            wait = 10.0
            continue
        if not reply.get("ok"):
            _gtec["state"] = "error"
            _gtec["detail"] = reply.get("error") or "GTEC refused the beacon."
            # A bad code will not fix itself, so stop hammering the server.
            wait = 60.0
            continue
        if not reply.get("reporting"):
            _gtec["state"] = "idle"
            _gtec["detail"] = reply.get("reason") or "No race in progress."
            wait = 30.0
            continue

        _gtec["state"] = "reporting"
        # Say when this is an admin test window rather than a real race, so
        # nobody concludes from the settings page that a round is running.
        where = "On the live timing test" if reply.get("test") else "On the live map"
        _gtec["detail"] = f"{where}, lap {payload['p_lap']}" + ("" if on_track else " (in menus)")
        _gtec["sent"] += 1
        _gtec["last"] = time.time()
        # The server sets the pace, dropping us to 15s while the car sits in
        # menus, which is where most of the idle traffic would come from.
        wait = max(1.5, float(reply.get("next_ms", 3000)) / 1000.0)


# ═══════════════════════════════════════════════════════════════
#  ASYNCIO MAIN (runs in background thread)
# ═══════════════════════════════════════════════════════════════
_loop = None

_ip_ref_global = [None]

async def _async_main(ps5_ip):
    ip_ref = _ip_ref_global
    ip_ref[0] = ps5_ip
    server = await websockets.serve(_ws_handler, WS_HOST, WS_PORT)
    _start_trigger_server()
    if ps5_ip:
        _stats["ps5"] = ps5_ip
    await asyncio.gather(
        server.wait_closed(),
        _receiver(ps5_ip, ip_ref),
        _heartbeat(ip_ref),
        _status_loop(),
        _gtec_beacon(),
    )

def _run_bridge(ps5_ip):
    global _loop
    _loop = asyncio.new_event_loop()
    asyncio.set_event_loop(_loop)
    _loop.run_until_complete(_async_main(ps5_ip))


# ═══════════════════════════════════════════════════════════════
#  TRAY ICON
# ═══════════════════════════════════════════════════════════════
def _make_icon():
    """Draw a small GT7-style icon: dark bg, red circle, 'G7' text."""
    size = 64
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Outer circle (dark)
    draw.ellipse([2, 2, 61, 61], fill=(13, 15, 24, 255), outline=(28, 31, 46, 255))
    # Inner accent circle (red)
    draw.ellipse([14, 14, 49, 49], fill=(255, 45, 59, 220))
    # Inner dark circle to make a ring
    draw.ellipse([22, 22, 41, 41], fill=(13, 15, 24, 255))
    return img

def _quit(icon, _item):
    icon.stop()
    if _loop:
        _loop.call_soon_threadsafe(_loop.stop)
    sys.exit(0)


def _config_dirs():
    """Where a settings file might sit: next to the app, the working directory,
    and the home folder. Home matters on macOS, where the .app bundle hides the
    "next to it" spot."""
    dirs = []
    try:
        dirs.append(os.path.dirname(sys.executable if getattr(sys, "frozen", False) else os.path.abspath(__file__)))
    except Exception:
        pass
    dirs.append(os.getcwd())
    dirs.append(os.path.expanduser("~"))
    return dirs

def _read_setting(filename):
    for base in _config_dirs():
        try:
            cfg = os.path.join(base, filename)
            if os.path.exists(cfg):
                with open(cfg, "r", encoding="utf-8") as fh:
                    for line in fh:
                        line = line.split("#")[0].strip()
                        if line:
                            return line
        except Exception:
            pass
    return None

def _flag(*names):
    """Read --name value or --name=value from the command line."""
    for i, a in enumerate(sys.argv[1:], start=1):
        for n in names:
            if a == n and i + 1 < len(sys.argv):
                return sys.argv[i + 1].strip()
            if a.startswith(n + "="):
                return a.split("=", 1)[1].strip()
    return None

def _parse_dest(text, default_host="127.0.0.1"):
    """'33742' or '127.0.0.1:33742' or '192.168.1.9:33742' -> (host, port)."""
    text = text.strip()
    if not text:
        return None
    if ":" in text:
        host, _, port = text.rpartition(":")
        host = host.strip() or default_host
    else:
        host, port = default_host, text
    try:
        port = int(port)
    except ValueError:
        return None
    if not (1 <= port <= 65535):
        return None
    return (host, port)

def _resolve_udp_config():
    """Sort out which port to listen on, where to forward copies, and whether to
    ping the console. Command line wins, then the environment, then a text file
    next to the app, which is the one most people will actually use.

    Advanced settings: nobody needs them until two programs want the same
    stream, and then nothing else will do."""
    global GT7_PORT, FORWARD_TO, HEARTBEAT_ON

    port_txt = _flag("--port", "-p") or os.environ.get("GT7_UDP_PORT", "").strip() or _read_setting("gt7-udp-port.txt")
    if port_txt:
        try:
            port = int(port_txt)
            if 1 <= port <= 65535:
                GT7_PORT = port
        except ValueError:
            pass

    fwd_txt = _flag("--forward", "-f") or os.environ.get("GT7_FORWARD", "").strip() or _read_setting("gt7-forward.txt")
    if fwd_txt:
        FORWARD_TO = [d for d in (_parse_dest(part) for part in fwd_txt.replace(";", ",").split(",")) if d]

    # A connector on a forwarded port must stay quiet by default: whatever owns
    # 33740 is already pinging, and the console replies to that app, not to us.
    global HEARTBEAT_EXPLICIT
    HEARTBEAT_ON = (GT7_PORT == GT7_PORT_STD)
    hb = _flag("--heartbeat") or os.environ.get("GT7_HEARTBEAT", "").strip() or _read_setting("gt7-heartbeat.txt")
    if hb:
        HEARTBEAT_ON = hb.lower() in ("1", "on", "yes", "true")
        HEARTBEAT_EXPLICIT = True

    # GTEC live timing. Same precedence as the rest: command line, then the
    # environment, then the file the settings page writes.
    global GTEC_CODE
    GTEC_CODE = (_flag("--gtec-code") or os.environ.get("GTEC_CODE", "").strip()
                 or _read_setting("gtec-code.txt") or "").strip()

# ═══════════════════════════════════════════════════════════════
#  SETTINGS: READING, WRITING, APPLYING
# ═══════════════════════════════════════════════════════════════
SETTINGS_FILES = {
    "consoleIp": "gt7-console-ip.txt",
    "udpPort":   "gt7-udp-port.txt",
    "forward":   "gt7-forward.txt",
    "heartbeat": "gt7-heartbeat.txt",
    "gtecCode":  "gtec-code.txt",
}

def _settings_dir():
    """Somewhere we can actually write. Next to the app is the obvious place and
    the one people find, but Program Files and a macOS .app bundle are both
    read-only, so fall back to the home folder rather than failing silently."""
    for base in _config_dirs():
        try:
            probe = os.path.join(base, ".gt7-write-test")
            with open(probe, "w") as fh:
                fh.write("x")
            os.remove(probe)
            return base
        except Exception:
            continue
    return os.path.expanduser("~")

def _write_setting(filename, value):
    """An empty value removes the file, so clearing a box in the page really
    does go back to the default rather than leaving a stale file behind."""
    target = os.path.join(_settings_dir(), filename)
    try:
        if value is None or str(value).strip() == "":
            for base in _config_dirs():                 # clear it wherever it is
                try:
                    old = os.path.join(base, filename)
                    if os.path.exists(old):
                        os.remove(old)
                except Exception:
                    pass
            return True
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(str(value).strip() + "\n")
        return True
    except Exception:
        return False

def _apply_settings(d):
    """Take what the settings page sent, make it true now, and write it down so
    it is still true next time. Returns what was actually applied, which is not
    always what was asked for."""
    global GT7_PORT, FORWARD_TO, HEARTBEAT_ON, HEARTBEAT_EXPLICIT
    notes = []

    if "udpPort" in d:
        txt = str(d.get("udpPort") or "").strip()
        if txt == "":
            GT7_PORT = GT7_PORT_STD
            _write_setting(SETTINGS_FILES["udpPort"], "")
        else:
            try:
                port = int(txt)
                if not (1 <= port <= 65535):
                    raise ValueError
                GT7_PORT = port
                _write_setting(SETTINGS_FILES["udpPort"], port if port != GT7_PORT_STD else "")
            except ValueError:
                notes.append(f"{txt} is not a port number, so that was left alone.")

    if "forward" in d:
        txt = str(d.get("forward") or "").strip()
        dests = [x for x in (_parse_dest(part) for part in txt.replace(";", ",").split(",")) if x]
        if txt and not dests:
            notes.append(f"Could not read \"{txt}\" as an address, so forwarding was left alone.")
        else:
            FORWARD_TO = dests
            _write_setting(SETTINGS_FILES["forward"], ", ".join(f"{h}:{p}" for h, p in dests))

    if "consoleIp" in d:
        ip = str(d.get("consoleIp") or "").strip()
        _write_setting(SETTINGS_FILES["consoleIp"], ip)
        if ip:
            _ip_ref_global[0] = ip
            _stats["ps5"] = ip
        notes.append("The console address is read when the connector starts, so restart it to use a new one.")

    if "gtecCode" in d:
        global GTEC_CODE
        code = str(d.get("gtecCode") or "").strip()
        # Only sanity-check the shape. Whether it is a real code is the
        # server's call, and it says so in the status line within seconds.
        if code and len(code) < 20:
            notes.append("That does not look like a GTEC pairing code, so it was left alone.")
        else:
            GTEC_CODE = code
            _write_setting(SETTINGS_FILES["gtecCode"], code)
            if not code:
                _gtec["state"], _gtec["detail"] = "off", "No pairing code set."

    if "heartbeat" in d:
        v = d.get("heartbeat")
        if v in (None, "", "auto"):
            HEARTBEAT_EXPLICIT = False
            _write_setting(SETTINGS_FILES["heartbeat"], "")
        else:
            HEARTBEAT_EXPLICIT = True
            HEARTBEAT_ON = bool(v) and str(v).lower() not in ("0", "off", "no", "false")
            _write_setting(SETTINGS_FILES["heartbeat"], "on" if HEARTBEAT_ON else "off")

    # With no explicit choice, the ping follows the port: on when we own 33740,
    # off when something else does and is already pinging.
    if not HEARTBEAT_EXPLICIT:
        HEARTBEAT_ON = (GT7_PORT == GT7_PORT_STD)

    return notes

def _settings_snapshot():
    fresh = (time.time() - _stats["last"]) < 3 if _stats["last"] else False
    return {
        "version": VERSION,
        "udpPort": GT7_PORT,
        "standardPort": GT7_PORT_STD,
        "forward": ", ".join(f"{h}:{p}" for h, p in FORWARD_TO),
        "heartbeat": HEARTBEAT_ON,
        "heartbeatExplicit": HEARTBEAT_EXPLICIT,
        "consoleIp": _stats["ps5"] or "",
        "raw": _stats["raw"],
        "packets": _stats["packets"],
        "receiving": fresh,
        "clients": len(_clients),
        "crypto": SALSA_BACKEND,
        "bindError": _stats["bindError"],
        "settingsDir": _settings_dir(),
        "wsPort": WS_PORT,
        # How long we have been listening with nothing to show for it. Silence on
        # the standard port usually means another program already has it, which
        # is the one problem a user will never guess at on their own.
        "listeningFor": round(time.time() - _stats["boundAt"], 1) if _stats["boundAt"] else 0,
        "rawHere": _stats["raw"] - _stats["rawAtBind"],
        # datagrams arriving but none of them decoding is a different fault
        "undecodable": (_stats["raw"] - _stats["rawAtBind"]) > 20
                       and (_stats["packets"] - _stats["packetsAtBind"]) == 0,
    }

def _resolve_ps5_ip():
    """Where to send the heartbeat. Broadcast is tried by default, but on
    networks that block broadcast (or a console on another subnet) you can
    point the connector straight at the console: pass the IP as an argument,
    set the GT7_PS5_IP environment variable, or drop a `gt7-console-ip.txt`
    file (one line, the console's IP) next to the app or in your home folder."""
    # The console IP is still accepted as a bare argument, but the new flags
    # must not be mistaken for it: "--port 33742" is not an IP address.
    skip = False
    for a in sys.argv[1:]:
        if skip:
            skip = False
            continue
        if a.startswith("-"):
            skip = ("=" not in a)          # "--port 33742" eats the next token, "--port=33742" does not
            continue
        if a.strip():
            return a.strip()
    env = os.environ.get("GT7_PS5_IP", "").strip()
    if env:
        return env
    # Look for gt7-console-ip.txt in several sensible places: next to the
    # executable, the current directory, and the user's home folder (the home
    # folder matters on macOS, where the .app bundle hides the "next to it" spot).
    candidates = []
    try:
        candidates.append(os.path.dirname(sys.executable if getattr(sys, "frozen", False) else os.path.abspath(__file__)))
    except Exception:
        pass
    candidates.append(os.getcwd())
    candidates.append(os.path.expanduser("~"))
    for base in candidates:
        try:
            cfg = os.path.join(base, "gt7-console-ip.txt")
            if os.path.exists(cfg):
                with open(cfg, "r", encoding="utf-8") as fh:
                    ip = fh.readline().strip()
                    if ip:
                        return ip
        except Exception:
            pass
    return None

def _tray_status(icon):
    while True:
        time.sleep(2)
        ip = _stats["ps5"] or "searching…"
        p = _stats["packets"]
        raw = _stats["raw"]
        if p > 0:
            state = "receiving"
        elif raw > 0:
            d = _stats.get("debug") or {}
            state = f"undecoded len={d.get('len')} dec={d.get('dec')}"
        else:
            state = "nothing from console, is GT7 on track?"
        try:
            # On a forwarded port "searching for console" is the wrong story:
            # we are waiting on another program, not on the PS5.
            where = f"Console: {ip}" if GT7_PORT == GT7_PORT_STD else f"Listening on UDP {GT7_PORT} (forwarded)"
            fwd = f"\nCopying to {', '.join(f'{h}:{q}' for h, q in FORWARD_TO)}" if FORWARD_TO else ""
            icon.title = f"GT7 Live Connector v{VERSION}\n{where}{fwd}\nRaw: {raw}  Decoded: {p}\n{state}"
        except Exception:
            pass

SETTINGS_URL = f"http://127.0.0.1:{TRIGGER_PORT}/settings"

def _open_settings(icon=None, item=None):
    try:
        import webbrowser
        webbrowser.open(SETTINGS_URL)
    except Exception:
        pass

def main():
    _resolve_udp_config()
    ps5_ip = _resolve_ps5_ip()

    # Start bridge in background thread
    t = threading.Thread(target=_run_bridge, args=(ps5_ip,), daemon=True)
    t.start()

    if HAS_TRAY:
        icon = pystray.Icon(
            name="GT7 Live Connector",
            icon=_make_icon(),
            title="GT7 Live Connector: Running\nws://localhost:8765",
            menu=pystray.Menu(
                pystray.MenuItem("GT7 Live Connector: Running", None, enabled=False),
                pystray.MenuItem("Port: 8765", None, enabled=False),
                pystray.MenuItem(f"Stream Deck trigger: {TRIGGER_PORT}", None, enabled=False),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem("Settings…", _open_settings, default=True),
                pystray.MenuItem("Quit", _quit),
            )
        )
        threading.Thread(target=_tray_status, args=(icon,), daemon=True).start()
        icon.run()
    else:
        # Fallback: no tray, just keep main thread alive
        print("GT7 Live Connector running on ws://localhost:8765")
        print(f"Settings: {SETTINGS_URL}")
        if GT7_PORT != GT7_PORT_STD:
            print(f"Listening for telemetry on UDP {GT7_PORT} (forwarded from another app).")
            print("Console heartbeat is " + ("on." if HEARTBEAT_ON else "off, as the other app is sending it."))
        if FORWARD_TO:
            print("Copying every packet on to " + ", ".join(f"{h}:{q}" for h, q in FORWARD_TO) + ".")
        print("Press Ctrl+C to stop.")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
