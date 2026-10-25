package uk.co.sparkstheory.gtec.reporter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Proves the decode on a known-good packet, so a build can be trusted
 * before anyone goes near a console.
 *
 * The vector is a synthetic GT7 packet encrypted with pycryptodome using
 * the key and nonce construction from the production connector. The field
 * values below are what was packed into it. If Salsa20 or any offset is
 * wrong, this fails rather than producing a car that quietly sits at the
 * wrong end of the circuit.
 */
class Gt7PacketTest {

    private val vector =
        "d732167a5e813d1d1f1eeaafbd61108218ea7403795ab10b46e16357f013a4e0" +
        "fa87a81822addccf1b60daf1e777d31ded16c8cef2da66bbaed7b79378806a87" +
        "78563412e03058379e6a490c534d2df2cae9c2208d458b38f422d95796ad2ba5" +
        "1496b79fb7d56f41a12e4b6b2a8248945f00e6afbda1d4658778cd4bbb5d71e9" +
        "79684bb3267b428ba1b4e150af9c7a3583776f5b3b68c517c4d5c51dfe0e221c" +
        "0ed2d88e290150f14cf7454536c8dd0dc4642a6f3b8ebedb01a70e1dce8eb1e3" +
        "09212490ea6f18c6a0a9eb175fc1bbeca0a0f8db419e910acfb7ec38660eb737" +
        "7cf8766a371b60b9990d5dadf66b4053c409a9be8a31b809507f4c621882aa1c" +
        "5a31f1266a9e838e013e0d5d64fea8cd52d4d49769114345e00266b51d5f3fd4" +
        "22a08894d5cabd67"

    private fun hex(s: String) = ByteArray(s.length / 2) {
        ((Character.digit(s[it * 2], 16) shl 4) or Character.digit(s[it * 2 + 1], 16)).toByte()
    }

    @Test
    fun decodesKnownPacket() {
        val s = Gt7Packet.decode(hex(vector))
        assertNotNull("packet failed magic check — Salsa20 or nonce is wrong", s)
        s!!
        assertEquals(412.75f, s.x, 0.001f)
        assertEquals(18.5f, s.y, 0.001f)
        assertEquals(-1183.25f, s.z, 0.001f)
        assertEquals(213, s.speedKph)          // 59.4 m/s
        assertEquals(37, s.lap)
        assertEquals(111930, s.bestLapMs)
        assertEquals(112480, s.lastLapMs)
        assertEquals(4, s.positionInRace)
        assertEquals(14, s.numCars)
        assertTrue(s.inRace)
        assertTrue(!s.paused)
        assertTrue(s.onTrack)
    }

    @Test
    fun rejectsShortPacket() {
        assertNull(Gt7Packet.decode(ByteArray(64)))
    }

    @Test
    fun rejectsRubbish() {
        // Right length, wrong contents: must fail the magic check rather
        // than being read as a car at coordinates (0, 0).
        assertNull(Gt7Packet.decode(ByteArray(0x128)))
    }

    @Test
    fun salsa20IsSymmetric() {
        val key = ByteArray(32) { it.toByte() }
        val nonce = ByteArray(8) { (it * 7).toByte() }
        val plain = ByteArray(200) { (it * 3).toByte() }
        val enc = Salsa20.xor(key, nonce, plain, plain.size)
        val dec = Salsa20.xor(key, nonce, enc, enc.size)
        assertTrue(plain.contentEquals(dec))
    }
}
