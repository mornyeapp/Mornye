package com.zarz.mornye

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock

/**
 * Partial wake lock held by a dataSync foreground service while it works.
 *
 * The lock is not reference-counted and every acquire uses a 30-minute
 * timeout, so a lock that is never released expires on its own. Callers keep
 * it alive by renewing it at least every 15 minutes. The class is not
 * thread-safe; callers synchronize as their service requires.
 */
internal class ForegroundWorkLock(
    private val context: Context,
    private val tag: String,
    private val logTag: String,
) {
    companion object {
        const val TIMEOUT_MS = 30 * 60 * 1000L
        const val RENEW_INTERVAL_MS = 15 * 60 * 1000L
    }

    private var wakeLock: PowerManager.WakeLock? = null
    @Volatile private var lastRenewedAt = 0L

    /**
     * Acquires a fresh lock unless one is held. When one is held it is renewed
     * once [RENEW_INTERVAL_MS] has passed since the last acquire.
     */
    fun ensure() {
        val existingWakeLock = wakeLock
        if (existingWakeLock?.isHeld == true) {
            val now = SystemClock.elapsedRealtime()
            if (now - lastRenewedAt >= RENEW_INTERVAL_MS) {
                existingWakeLock.acquire(TIMEOUT_MS)
                lastRenewedAt = now
            }
            return
        }
        if (existingWakeLock != null) {
            wakeLock = null
        }
        acquireNew()
    }

    /** Acquires a fresh lock unless one is held; returns false when one was held. */
    fun acquireIfNotHeld(): Boolean {
        if (wakeLock?.isHeld == true) return false
        acquireNew()
        return true
    }

    /** Re-acquires the current lock, if any, for another [TIMEOUT_MS]. */
    fun reacquire() {
        wakeLock?.acquire(TIMEOUT_MS)
    }

    fun release() {
        val existingWakeLock = wakeLock
        wakeLock = null
        lastRenewedAt = 0L
        if (existingWakeLock?.isHeld == true) {
            try {
                existingWakeLock.release()
            } catch (e: RuntimeException) {
                android.util.Log.w(logTag, "WakeLock release failed: ${e.message}")
            }
        }
    }

    private fun acquireNew() {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            tag
        ).apply {
            setReferenceCounted(false)
            acquire(TIMEOUT_MS)
        }
        lastRenewedAt = SystemClock.elapsedRealtime()
    }
}

/** Promotes the service to the foreground with the dataSync type where supported. */
internal fun Service.startDataSyncForeground(notificationId: Int, notification: Notification) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        startForeground(
            notificationId,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
    } else {
        startForeground(notificationId, notification)
    }
}

internal fun Context.mainActivityContentIntent(): PendingIntent =
    PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )
