package uk.co.sparkstheory.gtec.reporter

/**
 * Decrypt and read a GT7 telemetry packet.
 *
 * Key, nonce construction and every field offset are taken verbatim from
 * the GT7 Live Connector (`gt7_connector.py` and `commentary-poc/
 * gt7_packet.py`), which is already in production, rather than worked out
 * again here.
 */
object Gt7Packet {

    private const val MIN_SIZE = 0x128
    private const val MAGIC = 0x47375330          // 'G7S0' read as a little-endian int
    private const val SEED_OFFSET = 0x40

    private val KEY: ByteArray =
        "Simulator Interface Packet GT7 ver 0.0".toByteArray(Charsets.US_ASCII).copyOf(32)

    data class Sample(
        val x: Float,
        val y: Float,
        val z: Float,
        val speedKph: Int,
        val lap: Int,
        val lapsInRace: Int,
        /** Milliseconds, or null when GT7 reports -1 (no lap set yet). */
        val bestLapMs: Int?,
        val lastLapMs: Int?,
        /** Unverified against a real capture — see KNOWN_UNVERIFIED below. */
        val positionInRace: Int,
        val numCars: Int,
        val inRace: Boolean,
        val paused: Boolean,
        /** Litres in the tank, and the tank's size. Capacity varies by car,
         *  so only the percentage of the two is comparable across a grid. */
        val fuel: Float,
        val fuelCapacity: Float,
    ) {
        /** True when the car is actually on track, as opposed to sitting in
         *  menus, paused, or in the pre-race lobby. Drives the beacon backoff. */
        val onTrack: Boolean get() = inRace && !paused

        /** Percentage of the tank, or null before GT7 has reported a capacity.
         *  Null rather than a guess: a wrong fuel figure during a six hour
         *  race is worse than no figure at all. */
        val fuelPercent: Float? get() =
            if (fuelCapacity > 0f) fuel / fuelCapacity * 100f else null
    }

    /**
     * `positionInRace` and `numCars` come from offsets the connector's own
     * source marks as needing confirmation on a real capture. The app sends
     * them anyway, and the server treats them as optional, so a wrong offset
     * degrades the running order rather than breaking the map.
     */
    const val KNOWN_UNVERIFIED = "positionInRace(0x84), numCars(0x86)"

    private fun u8(b: ByteArray, o: Int) = b[o].toInt() and 0xFF
    private fun i16(b: ByteArray, o: Int): Int {
        val v = u8(b, o) or (u8(b, o + 1) shl 8)
        return if (v >= 0x8000) v - 0x10000 else v
    }
    private fun u16(b: ByteArray, o: Int) = u8(b, o) or (u8(b, o + 1) shl 8)
    private fun i32(b: ByteArray, o: Int) =
        u8(b, o) or (u8(b, o + 1) shl 8) or (u8(b, o + 2) shl 16) or (u8(b, o + 3) shl 24)
    private fun f32(b: ByteArray, o: Int) = Float.fromBits(i32(b, o))

    /** Returns null when the packet is too short or fails the magic check,
     *  which is also how a packet from something other than GT7 is rejected. */
    fun decode(raw: ByteArray, length: Int = raw.size): Sample? {
        if (length < MIN_SIZE) return null

        val seed = i32(raw, SEED_OFFSET)
        val mixed = seed xor 0xDEADBEAF.toInt()
        val nonce = byteArrayOf(
            (mixed and 0xFF).toByte(), ((mixed ushr 8) and 0xFF).toByte(),
            ((mixed ushr 16) and 0xFF).toByte(), ((mixed ushr 24) and 0xFF).toByte(),
            (seed and 0xFF).toByte(), ((seed ushr 8) and 0xFF).toByte(),
            ((seed ushr 16) and 0xFF).toByte(), ((seed ushr 24) and 0xFF).toByte(),
        )

        val p = Salsa20.xor(KEY, nonce, raw, length)
        if (i32(p, 0) != MAGIC) return null

        val flags = u16(p, 0x8E)
        // GT7 reports -1 for a lap time that does not exist yet.
        val best = i32(p, 0x78).let { if (it <= 0) null else it }
        val last = i32(p, 0x7C).let { if (it <= 0) null else it }

        return Sample(
            x = f32(p, 0x04),
            y = f32(p, 0x08),
            z = f32(p, 0x0C),
            speedKph = (f32(p, 0x4C) * 3.6f).toInt(),
            lap = i16(p, 0x74),
            lapsInRace = i16(p, 0x76),
            bestLapMs = best,
            lastLapMs = last,
            positionInRace = i16(p, 0x84),
            numCars = i16(p, 0x86),
            inRace = (flags and 0x0001) != 0,
            paused = (flags and 0x0002) != 0,
            // Same offsets the connector reads, which are in production.
            fuel = f32(p, 0x44),
            fuelCapacity = f32(p, 0x48),
        )
    }
}
