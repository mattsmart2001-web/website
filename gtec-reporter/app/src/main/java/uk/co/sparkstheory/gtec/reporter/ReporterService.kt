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

        /** GT7 sends telemetry here, and only one app per device can hold it. */
        private const val STD_PORT = 33740
        /** And listens for the heartbeat here. */
        private const val CONSOLE_PORT = 33739
        /** GT7 stops streaming 1 to 2 seconds after the last heartbeat. */
        private const val HEARTBEAT_MS = 1_500L
        /** Where a forwarded copy goes: another app on this same phone. */
        private val LOOPBACK: InetAddress = InetAddress.getByName("127.0.0.1")

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

        // Sharing the console with another telemetry app on this same phone.
        // Only one app can hold 33740, and GT7 always sends there, so the two
        // of them have to agree who owns it. Same two settings as the desktop
        // connector, for the same reason:
        //
        //   listen_port  listen somewhere other than 33740, so this can be
        //                second in the chain and take a forwarded copy from
        //                whatever owns it
        //   forward_to   when this one owns 33740, send a copy of every raw
        //                datagram on to local ports, so the other app can be
        //                second instead
        //
        // The heartbeat follows the port. A connector that is second must not
        // ping the console: the app that owns 33740 is already doing that, and
        // the console answers whoever asked, on the port it owns.
        val listenPort = prefs.getInt("listen_port", STD_PORT)
        val weOwnThePort = listenPort == STD_PORT
        val forwardTo = (prefs.getString("forward_to", "") ?: "")
            .split(',', ';')
            .mapNotNull { it.trim().toIntOrNull() }
            .filter { it in 1..65535 }

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
                bind(java.net.InetSocketAddress(listenPort))
            }
        } catch (e: Exception) {
            // A dashboard on another device is never the cause: the console
            // answers each device separately. This only happens when another
            // telemetry app on this phone already holds the port.
            status = if (weOwnThePort) {
                "Another app on this phone is using port $STD_PORT · close it, " +
                    "or set a listen port under Sharing"
            } else {
                "Port $listenPort is in use · pick another under Sharing"
            }
            update(status)
            running = false
            return
        }

        while (running) {
            val now = System.currentTimeMillis()

            if (weOwnThePort && now - lastHeartbeat >= HEARTBEAT_MS) {
                try {
                    socket?.send(DatagramPacket(byteArrayOf('A'.code.toByte()), 1, consoleAddr, CONSOLE_PORT))
                } catch (_: Exception) { /* a missed heartbeat self-corrects next tick */ }
                lastHeartbeat = now
            }

            val dp = DatagramPacket(buf, buf.size)
            val sample = try {
                socket?.receive(dp)
                // Pass the datagram on untouched, before anything is read from
                // it, so the other app sees exactly what the console sent.
                for (port in forwardTo) {
                    try {
                        socket?.send(DatagramPacket(buf, dp.length, LOOPBACK, port))
                    } catch (_: Exception) { /* its problem, not ours */ }
                }
                Gt7Packet.decode(buf, dp.length)
            } catch (_: java.net.SocketTimeoutException) {
                null
            } catch (_: Exception) {
                null
            }

            if (sample == null) {
                if (now - lastHeartbeat > 6_000 || packets == 0L) {
                    status = if (weOwnThePort) {
                        "Waiting for GT7 · is the console on the same WiFi?"
                    } else {
                        "Waiting on port $listenPort · is the other app forwarding to it?"
                    }
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
        // Channels arrived in Oreo, and so did the Builder that takes one.
        // Below that the plain constructor is the only one there is: calling
        // the channel one on Android 6 throws NoSuchMethodError and takes the
        // service down the instant it starts, which is why the app used to
        // declare Android 7 as its floor.
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(CHANNEL, "GTEC live timing", NotificationManager.IMPORTANCE_LOW)
                )
            }
            Notification.Builder(this, CHANNEL)
        } else {
            Notification.Builder(this)
        }
        // FLAG_IMMUTABLE is itself API 23, and neither of these intents needs
        // to be filled in by whoever receives it, so it is asked for where it
        // exists and left off where it does not.
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), flags,
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, ReporterService::class.java).setAction(ACTION_STOP), flags,
        )
        @Suppress("DEPRECATION")
        return builder
            .setContentTitle("GTEC live timing")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setContentIntent(open)
            // The icon-based Action.Builder is API 23, so the old integer
            // overload instead. Deprecated, present everywhere, and the
            // action looks identical.
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stop)
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
    const val ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind0cnl6b2FicGtxdHVjZnBtYm5uIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA0MTg0MjMsImV4cCI6MjA5NTk5NDQyM30.Jpx_23mxUsiS5Ke2MCZKOKBu09bH1XuViY6heAB-jds"
}
