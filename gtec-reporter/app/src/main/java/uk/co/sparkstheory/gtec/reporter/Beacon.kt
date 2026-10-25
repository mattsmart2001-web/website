package uk.co.sparkstheory.gtec.reporter

import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

/**
 * Posts one car's state to GTEC.
 *
 * Deliberately stateless and deliberately dumb: a beacon is a snapshot of
 * the last packet, never an aggregate. Everything derived — running order,
 * gaps, distance round the lap — is the website's job, so there is nothing
 * here that can drift out of step with what the server believes.
 */
class Beacon(private val supabaseUrl: String, private val anonKey: String) {

    data class Reply(
        val ok: Boolean,
        /** False when there is no race on, or the driver is not entered. */
        val reporting: Boolean,
        /** How long to wait before the next beacon, as the server sees it. */
        val nextMs: Int,
        val error: String?,
    )

    /** Returned when the request itself failed, as opposed to being refused. */
    private fun unreachable(msg: String) = Reply(false, false, 15_000, msg)

    fun send(token: String, s: Gt7Packet.Sample, lapMs: Int?): Reply {
        val body = JSONObject().apply {
            put("p_token", token)
            put("p_lap", s.lap)
            if (lapMs != null) put("p_lap_ms", lapMs)
            if (s.lastLapMs != null) put("p_last_lap_ms", s.lastLapMs)
            if (s.bestLapMs != null) put("p_best_lap_ms", s.bestLapMs)
            put("p_x", s.x)
            put("p_z", s.z)
            put("p_speed_kph", s.speedKph)
            put("p_on_track", s.onTrack)
        }.toString()

        return try {
            val conn = (URL("$supabaseUrl/rest/v1/rpc/live_beacon").openConnection()
                as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                connectTimeout = 5_000
                readTimeout = 5_000
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("apikey", anonKey)
                setRequestProperty("Authorization", "Bearer $anonKey")
            }
            OutputStreamWriter(conn.outputStream).use { it.write(body) }

            val code = conn.responseCode
            val text = (if (code in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() } ?: ""
            conn.disconnect()

            if (code !in 200..299) return unreachable("Server said $code")

            val j = JSONObject(text)
            Reply(
                ok = j.optBoolean("ok", false),
                reporting = j.optBoolean("reporting", false),
                // Honour the server's pacing: it backs the reporter off to
                // 15s while the car sits in menus, which is where most of
                // the pointless traffic would otherwise come from.
                nextMs = j.optInt("next_ms", 3_000),
                error = if (j.isNull("error")) null else j.optString("error", null),
            )
        } catch (e: Exception) {
            // A dropped beacon is not worth queueing. A stale position shown
            // as live is worse than a gap the page can age out honestly.
            unreachable(e.message ?: "No connection")
        }
    }
}
