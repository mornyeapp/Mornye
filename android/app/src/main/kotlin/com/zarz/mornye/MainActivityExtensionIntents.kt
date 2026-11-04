package com.zarz.mornye

import android.content.Intent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal fun MainActivity.handleVerificationNotificationIntent(intent: Intent?) {
    if (intent?.action != VerificationNotificationIntent.ACTION) return
    val payload = intent.getStringExtra(VerificationNotificationIntent.PAYLOAD)
        ?.takeIf { it.isNotBlank() } ?: return
    pendingVerificationNotification = payload
    intent.removeExtra(VerificationNotificationIntent.PAYLOAD)
    // Keep the payload until Dart is initialized and explicitly consumes it.
    backendChannel?.invokeMethod("extensionVerificationNotificationTapped", null)
}

/**
 * Queues an extension OAuth callback for completion after Dart initializes.
 * The backend resolves the one-time state nonce to the owning extension.
 */
internal fun MainActivity.handleExtensionOAuthIntent(intent: Intent?) {
    val uri = intent?.data ?: return
    if (!MainActivity.extensionAuthCallbacks.offer(uri)) return
    // Keep the Intent intact until the result is handled. A cold start has
    // no extension owner yet; Dart drains this inbox after initialization.
    backendChannel?.invokeMethod("extensionAuthCallbackReceived", null)
}

internal suspend fun MainActivity.processPendingExtensionCallbacks() {
    MainActivity.extensionAuthCallbacks.drain { callback ->
        var callbackExtensionId = ""
        try {
            withContext(Dispatchers.IO) {
                coreBackend.completeAuthCallback(callback.state, callback.code, callback.sessionGrant) {
                    callbackExtensionId = it
                }
            }
            android.util.Log.i("Mornye", "Extension callback completed")
            if (callback.sessionGrant) {
                notifySessionGrantCompleted(callbackExtensionId, true)
            }
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            android.util.Log.w("Mornye", "Extension callback failed (${e.javaClass.simpleName})")
            if (callback.sessionGrant && callbackExtensionId.isNotEmpty()) {
                notifySessionGrantCompleted(callbackExtensionId, false)
            }
        }
        val current = intent?.data
        if (current?.getQueryParameter("state") == callback.state) intent.data = null
    }
}

private fun MainActivity.notifySessionGrantCompleted(extensionId: String, success: Boolean) {
    val payload = mapOf(
        "extension_id" to extensionId,
        "success" to success,
    )
    val channel = backendChannel
    if (channel == null) {
        pendingSessionGrantEvents.add(payload)
        return
    }
    channel.invokeMethod("extensionSessionGrantCompleted", payload)
}
