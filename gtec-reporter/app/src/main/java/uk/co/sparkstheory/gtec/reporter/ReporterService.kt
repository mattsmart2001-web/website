package uk.co.sparkstheory.gtec.reporter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlin.concurrent.thread

/**
 * The whole job: heartbeat the console, read what comes back, post it.
 *
 * A foreground service rather than anything lighter because an endurance
 * round runs six to twelve hours and Android will otherwise suspend the
 * socket. The persistent notification is the price of that, and is also
 * the only status display most drivers will look at.
 */
class ReporterService : Service() {

    companion object {
        const val ACTION_START = "start"
        const val ACTION_STOP = "stop"
        const val EXTRA_TOKEN = "token"

        private const val CHANNEL = "gtec_reporter"
        private const val NOTE_ID = 1

        /** GT7 sends telemetry here. */
        private const val LISTEN_PORT = 33740
        /** And listens for the heartbeat here. */
        private const val CONSOLE_PORT = 33739
        /** GT7 stops streaming 1 to 2 seconds after the last heartbeat. */
        private const val HEARTBEAT_MS = 1_500L

        @Volatile var status: String = "Stopped"
            private set
    }

    private var running = false
    private var worker: Thread? = null
    private var socket: DatagramSocket? = null
    private var lock: WifiManager.MulticastLock? = null

    override fun onBind(p0: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { stopReporting(); stopSelf(); return START_NOT_STICKY }
            ACTION_START -> {
                val token = intent.getStringExtra(EXTRA_TOKEN).orEmpty()
                startForeground(NOTE_ID, note("Starting…"))
                startReporting(token)
            }
        }
        return START_STICKY
    }

    override fun onDestroy() { stopReporting(); super.onDestroy() }

    // ----------------------------------------------------------------
    private fun startReporting(token: String) {
        if (running) return
        running = true

        // Needed on some devices to receive broadcast/multicast traffic
        // while the screen is off.
        lock = (getSystemService(Context.WIFI_SERVICE) as WifiManager)
            .createMulticastLock("gtec-reporter").apply { setReferenceCounted(false); acquire() }

        worker = thread(name = "gtec-reporter") { loop(token) }
    }

    private fun stopReporting() {
        running = false
        socket?.close()
        socket = null
        lock?.let { if (it.isHeld) it.release() }
        lock = null
        worker = null
        status = "Stopped"
    }

    private fun loop(token: String) {
        val prefs = getSharedPreferences("gtec", Context.MODE_PRIVATE)
        val beacon = Beacon(
            prefs.getString("supabase_url", BuildConfigish.SUPABASE_URL)!!,
            prefs.getString("anon_key", BuildConfigish.ANON_KEY)!!,
        )

        // The console answers whoever pinged it, so broadcasting means the
        // driver never has to find or type their PlayStation's IP address.
        val consoleAddr = InetAddress.getByName(
            prefs.getString("console_ip", null) ?: "255.255.255.255"
        )

        val buf = ByteArray(1024)
        var lastHeartbeat = 0L
        var nextBeaconAt = 0L
        var nextWaitMs = 3_000
        var lastSeenLap = -1
        var lapStartedAt = 0L
        var packets = 0L

        try {
            socket = DatagramSocket(null).apply {
                reuseAddress = true
                broadcast = true
                soTimeout = 1_000
                bind(java.net.InetSocketAddress(LISTEN_PORT))
            }
        } catch (e: Exception) {
            status = "Port $LISTEN_PORT busy — close other telemetry apps"
            update(status)
            running = false
            return
        }

        while (running) {
            val now = System.currentTimeMillis()

            if (now - lastHeartbeat >= HEARTBEAT_MS) {
                try {
                    socket?.send(DatagramPacket(byteArrayOf('A'.code.toByte()), 1, consoleAddr, CONSOLE_PORT))
                } catch (_: Exception) { /* a missed heartbeat self-corrects next tick */ }
                lastHeartbeat = now
            }

            val dp = DatagramPacket(buf, buf.size)
            val sample = try {
                socket?.receive(dp)
                Gt7Packet.decode(buf, dp.length)
            } catch (_: java.net.SocketTimeoutException) {
                null
            } catch (_: Exception) {
                null
            }

            if (sample == null) {
                if (now - lastHeartbeat > 6_000 || packets == 0L) {
                    status = "Waiting for GT7 — is the console on the same WiFi?"
                    update(status)
                }
                continue
            }

            packets++

            // GT7 does not send elapsed time on the current lap, so derive it
            // from when the lap counter last changed. Null until a lap ticks
            // over, rather than guessing from the moment the app started.
            if (sample.lap != lastSeenLap) {
                lastSeenLap = sample.lap
                lapStartedAt = now
            }
            val lapMs = if (lapStartedAt == 0L) null else (now - lapStartedAt).toInt()

            if (now >= nextBeaconAt) {
                val reply = beacon.send(token, sample, lapMs)
                nextWaitMs = reply.nextMs
                nextBeaconAt = now + nextWaitMs
                status = when {
                    !reply.ok && reply.error != null -> reply.error
                    reply.reporting -> "Reporting · lap ${sample.lap}" +
                        (if (!sample.onTrack) " · in menus" else "")
                    else -> "Connected to GT7 · no race on"
                }
                update(status)
            }
        }
    }

    // ----------------------------------------------------------------
    private fun note(text: String): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(CHANNEL, "GTEC live timing", NotificationManager.IMPORTANCE_LOW)
                )
            }
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, ReporterService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL)
            .setContentTitle("GTEC live timing")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }

    private fun update(text: String) {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTE_ID, note(text))
    }
}

/**
 * Site details, kept in one place. Both values are public: the anon key is
 * the same one the website ships in `gtec-config.js`, and the beacon is
 * authorised by the driver's pairing token, not by this.
 */
object BuildConfigish {
    const val SUPABASE_URL = "https://wtryzoabpkqtucfpmbnn.supabase.co"
    const val ANON_KEY = "REPLACE_WITH_ANON_KEY_FROM_gtec-config.js"
}
