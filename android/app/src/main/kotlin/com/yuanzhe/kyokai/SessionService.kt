package com.yuanzhe.kyokai

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the process alive while sessions are open: the core's connections
 * live in this process, and Android stops a background app's network within
 * minutes. A foreground service with an ongoing notification that names the
 * sessions, and a partial wake lock while it runs.
 */
class SessionService : Service() {
    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val notification = notification(this, text)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ID, notification)
        }
        if (wake == null) {
            wake = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "kyokai:sessions")
                .apply { setReferenceCounted(false); acquire() }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wake?.release()
        wake = null
        super.onDestroy()
    }

    companion object {
        private const val ID = 1
        private const val CHANNEL = "sessions"
        private const val EXTRA_TEXT = "text"

        private fun notification(context: Context, text: String): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL, "Open sessions", NotificationManager.IMPORTANCE_LOW)
                )
            }
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE,
            )
            return Notification.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                .setContentTitle("Kyokai")
                .setContentText(text)
                .setContentIntent(open)
                .setOngoing(true)
                .build()
        }

        /** Starts or updates the service; [text] names the open sessions. */
        fun update(context: Context, text: String?) {
            val intent = Intent(context, SessionService::class.java)
            if (text == null) {
                context.stopService(intent)
            } else {
                intent.putExtra(EXTRA_TEXT, text)
                context.startForegroundService(intent)
            }
        }
    }
}
