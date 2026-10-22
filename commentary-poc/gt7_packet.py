"""
GT7 telemetry packet: decrypt + parse (single car).

Lifted from the working SparksTheory connector (gt7_connector.py) so the
recorder decodes exactly what the live telemetry page already trusts. GT7's
stream only ever describes ONE car at a time (the car currently on screen /
being followed), so everything here is single-car by design.

Two fields are added on top of the connector's set because the commentary
analyser needs them: the car's race position and the field size. Their
offsets are the widely-documented ones but are worth confirming against a
real capture on your setup (see VERIFY note below).
"""

import struct
from typing import Optional

try:
    from Crypto.Cipher import Salsa20 as _S20
    HAS_SALSA = True
except ImportError:
    HAS_SALSA = False

# GT7 telemetry is Salsa20-encrypted. Key is the ASCII marker (first 32
# bytes). The 8-byte nonce comes from a 32-bit seed at offset 0x40:
# nonce = (seed ^ 0xDEADBEAF) LE, then seed LE. Decrypted packets start
# with the magic 'G7S0' (little-endian int 0x47375330).
_KEY = b'Simulator Interface Packet GT7 ver 0.0'[:32]


def decrypt_packet(data: bytes) -> Optional[bytes]:
    if len(data) < 0x128:
        return None
    seed = int.from_bytes(data[0x40:0x44], 'little')
    nonce = (seed ^ 0xDEADBEAF).to_bytes(4, 'little') + seed.to_bytes(4, 'little')
    if not HAS_SALSA:
        return None
    try:
        dec = _S20.new(key=_KEY, nonce=nonce).decrypt(data)
        if int.from_bytes(dec[0:4], 'little') == 0x47375330:
            return dec
    except Exception:
        pass
    return None


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
        self.packet_id    = self._i(0x70)
        self.speed_kmh    = self._f(0x4C) * 3.6
        self.rpm          = self._f(0x38)
        self.fuel         = self._f(0x44)
        self.fuel_cap     = self._f(0x48)
        self.lap_count    = self._h(0x74)
        self.laps_in_race = self._h(0x76)
        self.best_lap     = self._i(0x78)   # ms, -1 until a lap is set
        self.last_lap     = self._i(0x7C)   # ms, -1 until first lap complete
        # VERIFY: race position + field size. 0x84 / 0x86 are the documented
        # offsets; confirm on a real capture before shipping (the single-car
        # fields above are verbatim from the trusted connector).
        self.pos_in_race  = self._h(0x84)
        self.num_cars     = self._h(0x86)
        flags             = self._H(0x8E)
        self.in_race      = bool(flags & 0x0001)
        self.paused       = bool(flags & 0x0002)
        self.gear         = self._B(0x90) & 0x0F
        self.throttle     = self._B(0x91) / 255.0
        self.brake        = self._B(0x92) / 255.0
        self.vel_x        = self._f(0x10)
        self.vel_z        = self._f(0x18)
        self.angvel_x     = self._f(0x28)
        self.angvel_y     = self._f(0x2C)
        self.angvel_z     = self._f(0x30)
        self.pos_x        = self._f(0x04)
        self.pos_y        = self._f(0x08)
        self.pos_z        = self._f(0x0C)
        # Car orientation. Yaw at 0x20 is verbatim from the trusted connector;
        # pitch (0x1C) and roll (0x24) are the neighbouring rotation floats and
        # are needed so an on-track overlay sits flat on slopes and banking.
        # VERIFY pitch/roll on a real capture (same note as the position field).
        self.rot_pitch    = self._f(0x1C)
        self.rot_yaw      = self._f(0x20)
        self.rot_roll     = self._f(0x24)
        self.vehicle_id   = self._i(0xF4)
        speed = max(self._f(0x4C), 0.1)
        self.lat_g  = self.angvel_y * speed / 9.81
        self.long_g = (self.vel_x * self.angvel_z - self.vel_z * self.angvel_x) / 9.81

    def to_dict(self):
        return {
            "packetId":   self.packet_id,
            "speed":      round(self.speed_kmh, 1),
            "gear":       self.gear,
            "throttle":   round(self.throttle * 100, 1),
            "brake":      round(self.brake * 100, 1),
            "latG":       round(self.lat_g, 3),
            "longG":      round(self.long_g, 3),
            "lapCount":   self.lap_count,
            "lapsInRace": self.laps_in_race,
            "bestLap":    self.best_lap,
            "lastLap":    self.last_lap,
            "posInRace":  self.pos_in_race,
            "numCars":    self.num_cars,
            "inRace":     self.in_race,
            "paused":     self.paused,
            "fuel":       round(self.fuel, 2),
            "fuelCap":    round(self.fuel_cap, 2),
            "vehicleId":  self.vehicle_id,
            "posX":       round(self.pos_x, 2),
            "posY":       round(self.pos_y, 2),
            "posZ":       round(self.pos_z, 2),
            "rotPitch":   round(self.rot_pitch, 4),
            "rotYaw":     round(self.rot_yaw, 4),
            "rotRoll":    round(self.rot_roll, 4),
        }
