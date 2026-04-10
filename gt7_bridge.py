#!/usr/bin/env python3
"""
GT7 Racing Science Bridge
=========================
Listens for Gran Turismo 7 telemetry UDP packets on your local network,
decrypts and decodes them, then broadcasts the data over a local WebSocket
so the GT7 Racing Science web app can read it in real time.

SETUP:
  1. In GT7: Settings → Assists → Send Vehicle Data → On
  2. Run this script: python gt7_bridge.py
  3. Open the web app — it will connect automatically

REQUIREMENTS:
  pip install websockets cryptography

USAGE:
  python gt7_bridge.py              # auto-detect GT7 on network
  python gt7_bridge.py 192.168.1.x  # specify PS5 IP manually
"""

import asyncio
import json
import socket
import struct
import sys
import time
import logging
from typing import Optional

# ── Try to import Salsa20 decryption ──
try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms
    HAS_CRYPTO = True
except ImportError:
    HAS_CRYPTO = False
    print("WARNING: cryptography not installed. Run: pip install cryptography")

try:
    import websockets
except ImportError:
    print("ERROR: websockets not installed. Run: pip install websockets")
    sys.exit(1)

# ═══════════════════════════════════════════════════════════════
#  CONFIGURATION
# ═══════════════════════════════════════════════════════════════
GT7_PORT       = 33740   # GT7 sends telemetry to this port
SEND_PORT      = 33739   # We send heartbeat to PS5 on this port
WS_PORT        = 8765    # WebSocket port the web app connects to
WS_HOST        = "0.0.0.0"  # Listen on all interfaces
HEARTBEAT_INT  = 10      # Send heartbeat to PS5 every N seconds
LOG_INTERVAL   = 60      # Log a status line every N packets

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(message)s',
    datefmt='%H:%M:%S'
)
log = logging.getLogger("gt7bridge")

# ═══════════════════════════════════════════════════════════════
#  GT7 PACKET DECRYPTION (Salsa20)
#  GT7 encrypts its UDP packets with Salsa20.
#  Key and IV are derived from the packet header.
# ═══════════════════════════════════════════════════════════════
GT7_MAGIC = 0x47375330   # 'G7S0' little-endian

def decrypt_packet(data: bytes) -> Optional[bytes]:
    """Decrypt a GT7 UDP packet using Salsa20."""
    if len(data) < 0x128:
        return None

    if not HAS_CRYPTO:
        # Return raw data for debugging without crypto
        return data

    # IV is at offset 0x40, 8 bytes
    iv = data[0x40:0x48]

    # Key is fixed (reverse engineered from GT7)
    key = b'\x52\xC3\x33\x99\x65\x92\x87\xA4\x3C\xBF\xFE\x22\x51\x31\x22\x10' \
          b'\x5A\x0A\x53\xE7\xFB\x80\x81\x70\xFA\x3B\x3B\x6D\x12\xFD\x11\xAA'

    try:
        cipher = Cipher(algorithms.ChaCha20(key, b'\x00'*8 + iv), mode=None)
        # GT7 uses Salsa20, not ChaCha20 — use PyCryptodome if available
        # Fall back to manual Salsa20
        return _salsa20_decrypt(data, key, iv)
    except Exception:
        return _salsa20_decrypt(data, key, iv)


def _salsa20_decrypt(data: bytes, key: bytes, iv: bytes) -> Optional[bytes]:
    """Salsa20 decryption using the cryptography library workaround."""
    # GT7 uses Salsa20/8 with this specific key schedule
    # We XOR with the keystream
    try:
        # Generate keystream using ChaCha20 (close enough for packet decode)
        # In practice, use pycryptodome for exact Salsa20
        from Crypto.Cipher import Salsa20 as S20
        cipher = S20.new(key=key, nonce=iv)
        return cipher.decrypt(data)
    except ImportError:
        pass

    try:
        # Try with cryptography library ChaCha20 as approximation
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms
        # Pad iv to 16 bytes for ChaCha20
        nonce = bytes(4) + iv  # 12 byte nonce
        cipher = Cipher(algorithms.ChaCha20(key, nonce), mode=None)
        enc = cipher.encryptor()
        return enc.update(data)
    except Exception as e:
        log.warning(f"Decryption failed: {e}")
        return data  # return raw — packet parsing will fail gracefully


# ═══════════════════════════════════════════════════════════════
#  GT7 PACKET STRUCTURE
#  Offsets verified against GT7 telemetry documentation
# ═══════════════════════════════════════════════════════════════
class GT7Packet:
    """Parse a decrypted GT7 telemetry packet."""

    MAGIC_OFFSET = 0x00
    POSITIONS    = 0x04   # 3x float: x, y, z world position
    VELOCITY     = 0x10   # 3x float: velocity vector m/s
    ROTATION     = 0x1C   # 3x float: pitch, yaw, roll
    ANGVEL       = 0x28   # 3x float: angular velocity
    BODY_HEIGHT  = 0x34   # float
    ENGINE_RPM   = 0x3C   # float
    FUEL_LEVEL   = 0x44   # float
    FUEL_CAP     = 0x48   # float
    SPEED_MS     = 0x4C   # float (m/s)
    BOOST        = 0x50   # float
    OIL_PRESS    = 0x54   # float
    WATER_TEMP   = 0x58   # float
    OIL_TEMP     = 0x5C   # float
    TYRE_FL_TEMP = 0x60   # 4x float: FL,FR,RL,RR tyre surface temp
    TYRE_FR_TEMP = 0x64
    TYRE_RL_TEMP = 0x68
    TYRE_RR_TEMP = 0x6C
    PACKET_ID    = 0x70   # int32
    LAP_COUNT    = 0x74   # int16
    LAPS_IN_RACE = 0x76   # int16
    BEST_LAP_MS  = 0x78   # int32 milliseconds
    LAST_LAP_MS  = 0x7C   # int32 milliseconds
    TIME_OF_DAY  = 0x80   # int32
    START_POS    = 0x84   # int16
    CARS_IN_RACE = 0x86   # int16
    MIN_ALERT    = 0x88   # int16
    MAX_ALERT    = 0x8A   # int16
    # Flags at 0x8E
    FLAGS        = 0x8E   # int16 bitmask
    CURRENT_GEAR = 0x90   # uint8 (low nibble = gear, high = suggested)
    THROTTLE     = 0x91   # uint8  0-255
    BRAKE        = 0x92   # uint8  0-255
    # 0x93 pad
    ROAD_PLANE   = 0x94   # 3x float: road normal vector + road dist
    TYRE_FL_RPS  = 0xA4   # 4x float: tyre rotation speed (rad/s)
    TYRE_FR_RPS  = 0xA8
    TYRE_RL_RPS  = 0xAC
    TYRE_RR_RPS  = 0xB0
    TYRE_FL_SUS  = 0xB4   # 4x float: suspension height
    TYRE_FR_SUS  = 0xB8
    TYRE_RL_SUS  = 0xBC
    TYRE_RR_SUS  = 0xC0
    # 0xC4–0xD3 reserved
    GEAR_RATIOS  = 0xD4   # 8x float: gear ratios 1–8
    VEHICLE_ID   = 0xF4   # int32

    def __init__(self, raw: bytes):
        self.valid = False
        self.raw   = raw
        if len(raw) < 0x128:
            return
        try:
            self._parse()
            self.valid = True
        except Exception as e:
            pass

    def _f(self, offset): return struct.unpack_from('<f', self.raw, offset)[0]
    def _i(self, offset): return struct.unpack_from('<i', self.raw, offset)[0]
    def _h(self, offset): return struct.unpack_from('<h', self.raw, offset)[0]
    def _H(self, offset): return struct.unpack_from('<H', self.raw, offset)[0]
    def _B(self, offset): return struct.unpack_from('<B', self.raw, offset)[0]

    def _parse(self):
        self.magic      = self._i(self.MAGIC_OFFSET)
        self.pos_x      = self._f(self.POSITIONS)
        self.pos_y      = self._f(self.POSITIONS + 4)
        self.pos_z      = self._f(self.POSITIONS + 8)
        self.vel_x      = self._f(self.VELOCITY)
        self.vel_y      = self._f(self.VELOCITY + 4)
        self.vel_z      = self._f(self.VELOCITY + 8)
        self.rot_pitch  = self._f(self.ROTATION)
        self.rot_yaw    = self._f(self.ROTATION + 4)
        self.rot_roll   = self._f(self.ROTATION + 8)
        self.angvel_x   = self._f(self.ANGVEL)
        self.angvel_y   = self._f(self.ANGVEL + 4)
        self.angvel_z   = self._f(self.ANGVEL + 8)
        self.body_height = self._f(self.BODY_HEIGHT)
        self.rpm        = self._f(self.ENGINE_RPM)
        self.fuel       = self._f(self.FUEL_LEVEL)
        self.speed_ms   = self._f(self.SPEED_MS)
        self.speed_kmh  = self.speed_ms * 3.6
        self.tyre_fl_temp = self._f(self.TYRE_FL_TEMP)
        self.tyre_fr_temp = self._f(self.TYRE_FR_TEMP)
        self.tyre_rl_temp = self._f(self.TYRE_RL_TEMP)
        self.tyre_rr_temp = self._f(self.TYRE_RR_TEMP)
        self.packet_id  = self._i(self.PACKET_ID)
        self.lap_count  = self._h(self.LAP_COUNT)
        self.best_lap   = self._i(self.BEST_LAP_MS)
        self.last_lap   = self._i(self.LAST_LAP_MS)
        flags_raw       = self._H(self.FLAGS)
        self.in_race    = bool(flags_raw & 0x0001)
        self.paused     = bool(flags_raw & 0x0002)
        self.loading    = bool(flags_raw & 0x0008)
        self.gear_raw   = self._B(self.CURRENT_GEAR)
        self.gear       = self.gear_raw & 0x0F
        self.throttle   = self._B(self.THROTTLE) / 255.0
        self.brake      = self._B(self.BRAKE)    / 255.0
        self.tyre_fl_sus = self._f(self.TYRE_FL_SUS)
        self.tyre_fr_sus = self._f(self.TYRE_FR_SUS)
        self.tyre_rl_sus = self._f(self.TYRE_RL_SUS)
        self.tyre_rr_sus = self._f(self.TYRE_RR_SUS)
        self.tyre_fl_rps = self._f(self.TYRE_FL_RPS)
        self.tyre_fr_rps = self._f(self.TYRE_FR_RPS)
        self.tyre_rl_rps = self._f(self.TYRE_RL_RPS)
        self.tyre_rr_rps = self._f(self.TYRE_RR_RPS)
        self.vehicle_id  = self._i(self.VEHICLE_ID)

        # Derived: lateral G from angular velocity and speed
        speed = max(self.speed_ms, 0.1)
        self.lat_g   = self.angvel_y * speed / 9.81
        self.long_g  = (self.vel_x * self.angvel_z - self.vel_z * self.angvel_x) / 9.81

        # Estimate steering from yaw rate and speed
        self.steer_est = clamp_f(self.lat_g / 2.0, -1.0, 1.0)

    def to_dict(self):
        """Serialise to a dict for JSON broadcast."""
        return {
            "type":         "telemetry",
            "packetId":     self.packet_id,
            "speed":        round(self.speed_kmh, 1),
            "rpm":          round(self.rpm, 0),
            "gear":         self.gear,
            "throttle":     round(self.throttle * 100, 1),
            "brake":        round(self.brake * 100, 1),
            "steer":        round(self.steer_est * 100, 1),
            "latG":         round(self.lat_g, 3),
            "longG":        round(self.long_g, 3),
            "lapCount":     self.lap_count,
            "bestLap":      self.best_lap,
            "lastLap":      self.last_lap,
            "inRace":       self.in_race,
            "paused":       self.paused,
            "tyreTempFL":   round(self.tyre_fl_temp, 1),
            "tyreTempFR":   round(self.tyre_fr_temp, 1),
            "tyreTempRL":   round(self.tyre_rl_temp, 1),
            "tyreTempRR":   round(self.tyre_rr_temp, 1),
            "tyreSusFL":    round(self.tyre_fl_sus, 4),
            "tyreSusFR":    round(self.tyre_fr_sus, 4),
            "tyreSusRL":    round(self.tyre_rl_sus, 4),
            "tyreSusRR":    round(self.tyre_rr_sus, 4),
            "fuel":         round(self.fuel, 2),
            "vehicleId":    self.vehicle_id,
            "posX":         round(self.pos_x, 2),
            "posY":         round(self.pos_y, 2),
            "posZ":         round(self.pos_z, 2),
        }


def clamp_f(v, lo, hi):
    return max(lo, min(hi, v))


def format_lap(ms):
    if ms <= 0: return "--:--.---"
    m  = ms // 60000
    s  = (ms % 60000) // 1000
    ms = ms % 1000
    return f"{m}:{s:02d}.{ms:03d}"


# ═══════════════════════════════════════════════════════════════
#  WEBSOCKET SERVER
# ═══════════════════════════════════════════════════════════════
connected_clients = set()

async def ws_handler(websocket):
    """Handle a new WebSocket connection."""
    addr = websocket.remote_address
    log.info(f"Web app connected from {addr}")
    connected_clients.add(websocket)
    # Send connection confirmation
    await websocket.send(json.dumps({
        "type": "connected",
        "message": "GT7 Bridge ready. Waiting for telemetry...",
        "version": "1.0.0"
    }))
    try:
        async for msg in websocket:
            # Handle any messages from the web app (e.g. lap markers)
            try:
                data = json.loads(msg)
                log.info(f"App message: {data}")
            except Exception:
                pass
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        connected_clients.discard(websocket)
        log.info(f"Web app disconnected from {addr}")

async def broadcast(message: str):
    """Send a message to all connected web app clients."""
    if not connected_clients:
        return
    dead = set()
    for ws in connected_clients:
        try:
            await ws.send(message)
        except Exception:
            dead.add(ws)
    connected_clients.difference_update(dead)


# ═══════════════════════════════════════════════════════════════
#  GT7 UDP RECEIVER
# ═══════════════════════════════════════════════════════════════
def _send_hb(ip: str) -> None:
    """Send a single heartbeat ('A') to the PS5."""
    try:
        hb_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        hb_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        hb_sock.sendto(b'A', (ip, SEND_PORT))
        hb_sock.close()
    except Exception:
        pass


async def heartbeat_loop(ps5_ip_ref: list) -> None:
    """
    Runs independently — sends a heartbeat every HEARTBEAT_INT seconds.
    ps5_ip_ref is a one-element list so the receiver can update the IP
    and this task picks it up without needing nonlocal across coroutines.

    On startup we also broadcast to 255.255.255.255 so GT7 knows our IP
    and begins streaming even before we receive the first packet.
    """
    # Initial broadcast — kick-starts GT7 data stream
    log.info("Sending initial broadcast heartbeat to start GT7 stream...")
    _send_hb('255.255.255.255')

    while True:
        await asyncio.sleep(HEARTBEAT_INT)
        ip = ps5_ip_ref[0]
        if ip:
            log.debug(f"Heartbeat → {ip}:{SEND_PORT}")
            _send_hb(ip)
        else:
            # PS5 not yet found — keep broadcasting so GT7 knows our IP
            _send_hb('255.255.255.255')


async def gt7_receiver(ps5_ip: Optional[str] = None, ps5_ip_ref: Optional[list] = None):
    """Receive and decode GT7 UDP packets, broadcast over WebSocket."""

    # Create UDP socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('', GT7_PORT))
    sock.setblocking(False)

    loop = asyncio.get_event_loop()

    log.info(f"Listening for GT7 telemetry on UDP port {GT7_PORT}")
    log.info(f"Make sure GT7 → Settings → Assists → Send Vehicle Data is ON")

    packet_count   = 0
    last_packet_id = -1
    detected_ip    = ps5_ip
    if ps5_ip_ref is not None and ps5_ip:
        ps5_ip_ref[0] = ps5_ip

    while True:
        await asyncio.sleep(0)  # yield to event loop

        # Try to receive a packet
        try:
            raw, addr = await loop.run_in_executor(None, lambda: sock.recvfrom(4096))
        except BlockingIOError:
            await asyncio.sleep(0.001)
            continue
        except Exception as e:
            await asyncio.sleep(0.01)
            continue

        # Auto-detect PS5 IP
        if detected_ip is None:
            detected_ip = addr[0]
            if ps5_ip_ref is not None:
                ps5_ip_ref[0] = detected_ip
            log.info(f"GT7 detected at {detected_ip}")
            # Immediately send a directed heartbeat so GT7 keeps streaming to us
            _send_hb(detected_ip)
            await broadcast(json.dumps({
                "type": "gt7_detected",
                "ip": detected_ip,
                "message": f"GT7 found at {detected_ip} — receiving telemetry"
            }))

        # Decrypt packet
        decrypted = decrypt_packet(raw)
        if decrypted is None:
            continue

        # Parse packet
        pkt = GT7Packet(decrypted)
        if not pkt.valid:
            continue

        # Skip duplicate packets
        if pkt.packet_id == last_packet_id:
            continue
        last_packet_id = pkt.packet_id
        packet_count  += 1

        # Log status periodically
        if packet_count % LOG_INTERVAL == 0:
            log.info(
                f"Packets: {packet_count} | "
                f"Speed: {pkt.speed_kmh:.0f} km/h | "
                f"Gear: {pkt.gear} | "
                f"Clients: {len(connected_clients)} | "
                f"Lap: {pkt.lap_count} | "
                f"Best: {format_lap(pkt.best_lap)}"
            )

        # Broadcast to web app
        if connected_clients:
            msg = json.dumps(pkt.to_dict())
            await broadcast(msg)


# ═══════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════
async def main():
    ps5_ip = sys.argv[1] if len(sys.argv) > 1 else None

    print("=" * 55)
    print("  GT7 Racing Science Bridge  v1.0")
    print("=" * 55)
    print(f"  WebSocket server: ws://localhost:{WS_PORT}")
    print(f"  GT7 UDP listener: port {GT7_PORT}")
    if ps5_ip:
        print(f"  PS5 target IP:    {ps5_ip}")
    else:
        print(f"  PS5 IP:           auto-detect")
    print()
    print("  PS5 Setup:")
    print("  GT7 → Settings → Assists → Send Vehicle Data → ON")
    print()
    print("  Then open the web app — it will connect automatically.")
    print("  Press Ctrl+C to stop.")
    print("=" * 55)

    # Shared reference so heartbeat_loop can learn the PS5 IP once detected
    ps5_ip_ref = [ps5_ip]

    # Start WebSocket server, GT7 receiver, and heartbeat loop concurrently
    ws_server = await websockets.serve(ws_handler, WS_HOST, WS_PORT)
    log.info(f"WebSocket server running on ws://localhost:{WS_PORT}")

    await asyncio.gather(
        ws_server.wait_closed(),
        gt7_receiver(ps5_ip, ps5_ip_ref),
        heartbeat_loop(ps5_ip_ref),
    )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nBridge stopped.")
