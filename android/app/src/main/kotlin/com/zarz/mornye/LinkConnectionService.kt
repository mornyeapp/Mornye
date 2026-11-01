package com.zarz.mornye

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/** Keeps the live Link socket available for playback handoffs while the phone is idle. */
class LinkConnectionService : Service() {
    companion object {
        private const val CHANNEL_ID = "link_connection"
        private const val NOTIFICATION_ID = 0x4D4C0001
        private const val TAG = "LinkConnectionService"

        @Volatile private var requestedName: String? = null
        @Volatile private var instance: LinkConnectionService? = null

        fun start(context: Context, name: String): Boolean {
            requestedName = name
            val active = instance
            if (active != null && active.inForeground && !active.stopRequested) {
                active.showComputer(name)
                return true
            }
            return try {
                val intent = Intent(context, LinkConnectionService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (error: Exception) {
                requestedName = null
                android.util.Log.w(TAG, "Could not start Link connection service", error)
                false
            }
        }

        fun stop(context: Context) {
            requestedName = null
            instance?.stopRequested = true
            context.stopService(Intent(context, LinkConnectionService::class.java))
        }
    }

    private var inForeground = false
    private var stopRequested = false
    private var shownName: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Mornye Link", NotificationManager.IMPORTANCE_LOW)
                    .apply { setShowBadge(false) },
            )
        }
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Promote even if a queued start was cancelled before delivery.
        val name = requestedName
        stopRequested = name == null
        try {
            if (!inForeground) {
                val notification = notification(name ?: "Mornye")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                inForeground = true
                shownName = name
            } else if (name != null) {
                showComputer(name)
            }
        } catch (error: Exception) {
            android.util.Log.w(TAG, "Could not promote Link connection service", error)
            stopSelf(startId)
        }
        if (name == null) stopSelf(startId)
        // A killed process must not restart a socket whose Dart owner is gone.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        if (inForeground) stopForeground(STOP_FOREGROUND_REMOVE)
        inForeground = false
        super.onDestroy()
    }

    private fun showComputer(name: String) {
        if (shownName == name) return
        try {
            getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, notification(name))
            shownName = name
        } catch (error: Exception) {
            android.util.Log.w(TAG, "Could not update Link connection notification", error)
        }
    }

    private fun notification(name: String): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Mornye Link")
            .setContentText(name)
            .setSmallIcon(R.drawable.ic_notification_airplay)
            .setContentIntent(mainActivityContentIntent())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
}
