package com.zarz.mornye

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.util.LinkedHashMap
import java.util.UUID

/**
 * Short-lived descriptor leases for zero-copy SAF playback. The returned proc
 * path identifies the lease. The Android audio plugin must duplicate this
 * descriptor, never reopen it (AppFuse rejects reopening). A small hard cap
 * protects against abandoned method calls.
 *
 * The leases belong to the process, not an Activity: playback a media browser
 * starts without one opens them through the engine channel, the Activity
 * channel that replaces it closes them, and playback outlives the Activity.
 */
internal object SafPlaybackLeases {
    private val lock = Any()
    private val leases = LinkedHashMap<String, ParcelFileDescriptor>()

    fun open(context: Context, uriStr: String): Map<String, String>? {
        if (!uriStr.startsWith("content://")) return null
        val descriptor = try {
            context.contentResolver.openFileDescriptor(Uri.parse(uriStr), "r")
        } catch (e: Exception) {
            android.util.Log.w("Mornye", "Failed to open SAF playback descriptor: ${e.message}")
            null
        } ?: return null

        if (!isSeekableSafDescriptor(descriptor)) {
            descriptor.close()
            return null
        }
        val token = UUID.randomUUID().toString()
        synchronized(lock) {
            while (leases.size >= 4) {
                val oldest = leases.entries.firstOrNull() ?: break
                leases.remove(oldest.key)
                try {
                    oldest.value.close()
                } catch (_: Exception) {}
            }
            leases[token] = descriptor
        }
        return mapOf(
            "token" to token,
            "path" to "/proc/self/fd/${descriptor.fd}",
            "display_name" to context.buildUriDisplayName(Uri.parse(uriStr)),
        )
    }

    fun close(token: String) {
        if (token.isBlank()) return
        val descriptor = synchronized(lock) {
            leases.remove(token)
        } ?: return
        try {
            descriptor.close()
        } catch (_: Exception) {}
    }
}
