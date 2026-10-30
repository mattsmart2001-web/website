import Foundation

/// Decrypt and read a GT7 telemetry packet.
///
/// Key, nonce construction and every field offset are a straight port of
/// `Gt7Packet.kt`, which took them from the GT7 Live Connector that has
/// been in production since the first round. Nothing here was worked out
/// again: three implementations reading the same offsets is a liability,
/// and the one place to change them is the connector.
enum GT7Packet {

    private static let minSize = 0x128
    private static let magic: Int32 = 0x4737_5330      // 'G7S0', little endian
    private static let seedOffset = 0x40

    private static let key: [UInt8] = {
        var k = Array("Simulator Interface Packet GT7 ver 0.0".utf8)
        k.append(contentsOf: [UInt8](repeating: 0, count: max(0, 32 - k.count)))
        return Array(k.prefix(32))
    }()

    struct Sample {
        let x: Float, y: Float, z: Float
        let speedKph: Int
        let lap: Int
        let lapsInRace: Int
        /// Milliseconds, or nil where GT7 reports -1 for a lap not yet set.
        let bestLapMs: Int?
        let lastLapMs: Int?
        let inRace: Bool
        let paused: Bool
        /// Litres in the tank and the tank's size. Capacity varies by car,
        /// so only the percentage of the two compares across a grid.
        let fuel: Float
        let fuelCapacity: Float

        /// On track, as opposed to in the menus, paused or in the lobby.
        /// The server backs the beacon off when this is false.
        var onTrack: Bool { inRace && !paused }

        /// Percentage of the tank, or nil before GT7 has reported a
        /// capacity. Nil rather than a guess: a wrong fuel figure during a
        /// six hour race is worse than no figure at all.
        var fuelPercent: Float? {
            fuelCapacity > 0 ? fuel / fuelCapacity * 100 : nil
        }
    }

    private static func u8(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) }
    private static func u16(_ b: [UInt8], _ o: Int) -> Int { u8(b, o) | (u8(b, o + 1) << 8) }
    private static func i16(_ b: [UInt8], _ o: Int) -> Int {
        let v = u16(b, o)
        return v >= 0x8000 ? v - 0x10000 : v
    }
    private static func i32(_ b: [UInt8], _ o: Int) -> Int32 {
        Int32(truncatingIfNeeded:
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8)
                | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24))
    }
    private static func f32(_ b: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: UInt32(bitPattern: i32(b, o)))
    }

    /// Returns nil where the packet is too short or fails the magic check,
    /// which is also how anything that is not GT7 gets rejected.
    static func decode(_ raw: [UInt8]) -> Sample? {
        guard raw.count >= minSize else { return nil }

        let seed = i32(raw, seedOffset)
        let mixed = seed ^ Int32(bitPattern: 0xDEAD_BEAF)
        let nonce: [UInt8] = [
            UInt8(truncatingIfNeeded: mixed),       UInt8(truncatingIfNeeded: mixed >> 8),
            UInt8(truncatingIfNeeded: mixed >> 16), UInt8(truncatingIfNeeded: mixed >> 24),
            UInt8(truncatingIfNeeded: seed),        UInt8(truncatingIfNeeded: seed >> 8),
            UInt8(truncatingIfNeeded: seed >> 16),  UInt8(truncatingIfNeeded: seed >> 24),
        ]

        let p = Salsa20.xor(key: key, nonce: nonce, data: raw)
        guard i32(p, 0) == magic else { return nil }

        let flags = u16(p, 0x8E)
        let best = i32(p, 0x78)
        let last = i32(p, 0x7C)

        return Sample(
            x: f32(p, 0x04),
            y: f32(p, 0x08),
            z: f32(p, 0x0C),
            speedKph: Int(f32(p, 0x4C) * 3.6),
            lap: i16(p, 0x74),
            lapsInRace: i16(p, 0x76),
            bestLapMs: best <= 0 ? nil : Int(best),
            lastLapMs: last <= 0 ? nil : Int(last),
            inRace: (flags & 0x0001) != 0,
            paused: (flags & 0x0002) != 0,
            fuel: f32(p, 0x44),
            fuelCapacity: f32(p, 0x48)
        )
    }
}
