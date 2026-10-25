package uk.co.sparkstheory.gtec.reporter

/**
 * Salsa20, just enough of it to decrypt GT7 telemetry.
 *
 * Hand-written rather than pulled from a library: the whole app is a few
 * hundred lines and this keeps it dependency-free, which matters when the
 * APK is sideloaded rather than installed from a store. Verified against
 * pycryptodome — identical keystream, byte for byte — and the unit test
 * carries a known-good packet so a build can prove it without a console.
 */
object Salsa20 {

    private val SIGMA = "expand 32-byte k".toByteArray(Charsets.US_ASCII)

    private fun le32(b: ByteArray, off: Int): Int =
        (b[off].toInt() and 0xFF) or
            ((b[off + 1].toInt() and 0xFF) shl 8) or
            ((b[off + 2].toInt() and 0xFF) shl 16) or
            ((b[off + 3].toInt() and 0xFF) shl 24)

    private fun rotl(v: Int, n: Int): Int = (v shl n) or (v ushr (32 - n))

    /** One 64-byte keystream block for [counter]. */
    private fun block(key: ByteArray, nonce: ByteArray, counter: Long, out: ByteArray) {
        val s = IntArray(16)
        s[0] = le32(SIGMA, 0); s[5] = le32(SIGMA, 4)
        s[10] = le32(SIGMA, 8); s[15] = le32(SIGMA, 12)
        s[1] = le32(key, 0);  s[2] = le32(key, 4)
        s[3] = le32(key, 8);  s[4] = le32(key, 12)
        s[11] = le32(key, 16); s[12] = le32(key, 20)
        s[13] = le32(key, 24); s[14] = le32(key, 28)
        s[6] = le32(nonce, 0); s[7] = le32(nonce, 4)
        s[8] = (counter and 0xFFFFFFFFL).toInt()
        s[9] = ((counter ushr 32) and 0xFFFFFFFFL).toInt()

        val x = s.copyOf()
        // 20 rounds, as ten column/row double rounds.
        repeat(10) {
            quarter(x, 0, 4, 8, 12);  quarter(x, 5, 9, 13, 1)
            quarter(x, 10, 14, 2, 6); quarter(x, 15, 3, 7, 11)
            quarter(x, 0, 1, 2, 3);   quarter(x, 5, 6, 7, 4)
            quarter(x, 10, 11, 8, 9); quarter(x, 15, 12, 13, 14)
        }
        for (i in 0 until 16) {
            val v = x[i] + s[i]
            out[i * 4]     = (v and 0xFF).toByte()
            out[i * 4 + 1] = ((v ushr 8) and 0xFF).toByte()
            out[i * 4 + 2] = ((v ushr 16) and 0xFF).toByte()
            out[i * 4 + 3] = ((v ushr 24) and 0xFF).toByte()
        }
    }

    private fun quarter(x: IntArray, a: Int, b: Int, c: Int, d: Int) {
        x[b] = x[b] xor rotl(x[a] + x[d], 7)
        x[c] = x[c] xor rotl(x[b] + x[a], 9)
        x[d] = x[d] xor rotl(x[c] + x[b], 13)
        x[a] = x[a] xor rotl(x[d] + x[c], 18)
    }

    /** XORs [data] with the keystream. Salsa20 is symmetric, so this both
     *  encrypts and decrypts. */
    fun xor(key: ByteArray, nonce: ByteArray, data: ByteArray, length: Int): ByteArray {
        require(key.size == 32) { "key must be 32 bytes" }
        require(nonce.size == 8) { "nonce must be 8 bytes" }
        val out = ByteArray(length)
        val ks = ByteArray(64)
        var off = 0
        var counter = 0L
        while (off < length) {
            block(key, nonce, counter, ks)
            val n = minOf(64, length - off)
            for (i in 0 until n) out[off + i] = (data[off + i].toInt() xor ks[i].toInt()).toByte()
            off += 64
            counter++
        }
        return out
    }
}
