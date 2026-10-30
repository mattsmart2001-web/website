import Foundation

/// Salsa20, just enough of it to decrypt GT7 telemetry.
///
/// A direct port of `Salsa20.kt` in the Android reporter, which was itself
/// verified against pycryptodome byte for byte. Hand-written rather than
/// pulled from a package so the app has no dependencies at all: everything
/// an App Store review has to look at is in this folder.
enum Salsa20 {

    private static let sigma = Array("expand 32-byte k".utf8)

    private static func le32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | (UInt32(b[off + 1]) << 8)
            | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }

    private static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 {
        (v << n) | (v >> (32 - n))
    }

    private static func quarter(_ x: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        x[b] ^= rotl(x[a] &+ x[d], 7)
        x[c] ^= rotl(x[b] &+ x[a], 9)
        x[d] ^= rotl(x[c] &+ x[b], 13)
        x[a] ^= rotl(x[d] &+ x[c], 18)
    }

    /// One 64 byte keystream block for `counter`.
    private static func block(_ key: [UInt8], _ nonce: [UInt8],
                              _ counter: UInt64, _ out: inout [UInt8]) {
        var s = [UInt32](repeating: 0, count: 16)
        s[0] = le32(sigma, 0);  s[5] = le32(sigma, 4)
        s[10] = le32(sigma, 8); s[15] = le32(sigma, 12)
        s[1] = le32(key, 0);    s[2] = le32(key, 4)
        s[3] = le32(key, 8);    s[4] = le32(key, 12)
        s[11] = le32(key, 16);  s[12] = le32(key, 20)
        s[13] = le32(key, 24);  s[14] = le32(key, 28)
        s[6] = le32(nonce, 0);  s[7] = le32(nonce, 4)
        s[8] = UInt32(truncatingIfNeeded: counter)
        s[9] = UInt32(truncatingIfNeeded: counter >> 32)

        var x = s
        // 20 rounds, as ten column and row double rounds.
        for _ in 0..<10 {
            quarter(&x, 0, 4, 8, 12);  quarter(&x, 5, 9, 13, 1)
            quarter(&x, 10, 14, 2, 6); quarter(&x, 15, 3, 7, 11)
            quarter(&x, 0, 1, 2, 3);   quarter(&x, 5, 6, 7, 4)
            quarter(&x, 10, 11, 8, 9); quarter(&x, 15, 12, 13, 14)
        }
        for i in 0..<16 {
            let v = x[i] &+ s[i]
            out[i * 4]     = UInt8(truncatingIfNeeded: v)
            out[i * 4 + 1] = UInt8(truncatingIfNeeded: v >> 8)
            out[i * 4 + 2] = UInt8(truncatingIfNeeded: v >> 16)
            out[i * 4 + 3] = UInt8(truncatingIfNeeded: v >> 24)
        }
    }

    /// XORs `data` with the keystream. Salsa20 is symmetric, so this both
    /// encrypts and decrypts.
    static func xor(key: [UInt8], nonce: [UInt8], data: [UInt8]) -> [UInt8] {
        precondition(key.count == 32, "key must be 32 bytes")
        precondition(nonce.count == 8, "nonce must be 8 bytes")
        var out = [UInt8](repeating: 0, count: data.count)
        var ks = [UInt8](repeating: 0, count: 64)
        var off = 0
        var counter: UInt64 = 0
        while off < data.count {
            block(key, nonce, counter, &ks)
            let n = min(64, data.count - off)
            for i in 0..<n { out[off + i] = data[off + i] ^ ks[i] }
            off += 64
            counter += 1
        }
        return out
    }
}
