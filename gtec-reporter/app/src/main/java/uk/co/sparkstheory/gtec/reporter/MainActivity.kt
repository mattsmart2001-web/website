package uk.co.sparkstheory.gtec.reporter

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.EditText
import android.widget.TextView

/**
 * One screen: paste the pairing code from your GTEC portal, press start.
 *
 * Everything else the driver needs to know is in the notification, because
 * during a race the phone is face-down next to them and this screen is not
 * what they are looking at.
 */
class MainActivity : Activity() {

    private lateinit var tokenField: EditText
    private lateinit var statusLine: TextView
    private lateinit var startBtn: Button
    private lateinit var stopBtn: Button

    private val ui = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            statusLine.text = ReporterService.status
            ui.postDelayed(this, 1_000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        tokenField = findViewById(R.id.token)
        statusLine = findViewById(R.id.status)
        startBtn = findViewById(R.id.start)
        stopBtn = findViewById(R.id.stop)

        val prefs = getSharedPreferences("gtec", Context.MODE_PRIVATE)
        tokenField.setText(prefs.getString("token", ""))

        startBtn.setOnClickListener {
            val token = tokenField.text.toString().trim()
            if (token.length < 20) {
                statusLine.text = getString(R.string.need_token)
                return@setOnClickListener
            }
            prefs.edit().putString("token", token).apply()
            askForNotifications()
            startService(
                Intent(this, ReporterService::class.java)
                    .setAction(ReporterService.ACTION_START)
                    .putExtra(ReporterService.EXTRA_TOKEN, token)
            )
        }

        stopBtn.setOnClickListener {
            startService(
                Intent(this, ReporterService::class.java).setAction(ReporterService.ACTION_STOP)
            )
        }
    }

    /** Android 13+ hides the foreground notification without this, which
     *  would leave the driver with no way to see whether it is working. */
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun onResume() { super.onResume(); ui.post(tick) }
    override fun onPause() { super.onPause(); ui.removeCallbacks(tick) }
}
