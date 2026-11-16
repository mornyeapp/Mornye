package com.zarz.mornye

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update

internal object NativeWorkerPolicy {
    const val MAX_RATE_LIMIT_RETRIES = 1
    private const val DEFAULT_RATE_LIMIT_DELAY_SECONDS = 30
    private const val MIN_RATE_LIMIT_DELAY_SECONDS = 5
    private const val MAX_RATE_LIMIT_DELAY_SECONDS = 300

    private val retryAfterPattern = Regex(
        """retry[- ]?after(?: seconds)?[:= ]+(\d+)""",
        RegexOption.IGNORE_CASE,
    )

    fun shouldRetryRateLimit(
        errorType: String?,
        errorMessage: String?,
        attempts: Int,
    ): Boolean {
        if (attempts >= MAX_RATE_LIMIT_RETRIES) return false
        if (errorType.equals("rate_limit", ignoreCase = true)) return true

        val message = errorMessage.orEmpty()
        return message.contains("429") ||
            message.contains("rate limit", ignoreCase = true) ||
            message.contains("too many requests", ignoreCase = true)
    }

    fun rateLimitDelaySeconds(
        retryAfterSeconds: Int?,
        errorMessage: String?,
    ): Int {
        val parsedFromMessage = retryAfterPattern
            .find(errorMessage.orEmpty())
            ?.groupValues
            ?.getOrNull(1)
            ?.toIntOrNull()
        return (retryAfterSeconds?.takeIf { it > 0 }
            ?: parsedFromMessage
            ?: DEFAULT_RATE_LIMIT_DELAY_SECONDS)
            .coerceIn(
                MIN_RATE_LIMIT_DELAY_SECONDS,
                MAX_RATE_LIMIT_DELAY_SECONDS,
            )
    }

    fun isVerificationRequired(
        errorType: String?,
        errorMessage: String?,
    ): Boolean {
        if (errorType.equals("verification_required", ignoreCase = true)) {
            return true
        }
        when (errorType?.trim()?.lowercase()) {
            "authentication_error", "provider_auth_failed",
            "request_auth_invalid", "provider_reauth_required" -> return false
        }
        val message = errorMessage.orEmpty()
        return message.contains("verification required", ignoreCase = true) ||
            message.contains("challenge required", ignoreCase = true)
    }

    fun requiresWifi(downloadNetworkMode: String?): Boolean =
        downloadNetworkMode.equals("wifi_only", ignoreCase = true)

    fun shouldPauseForNetwork(
        downloadNetworkMode: String?,
        hasWifi: Boolean,
    ): Boolean = requiresWifi(downloadNetworkMode) && !hasWifi

    fun shouldNotifyQueueComplete(
        cancelRequested: Boolean,
        completed: Int,
        failed: Int,
    ): Boolean = !cancelRequested && completed + failed > 0

    fun isTerminalStatus(status: String): Boolean =
        status == "completed" || status == "failed" || status == "skipped"

    fun statusAfterWorkerStop(status: String): String = when (status) {
        "preparing", "downloading", "finalizing" -> "queued"
        else -> status
    }

    /**
     * A paused or waiting native queue releases the wake lock once no worker
     * is still running an item or finishing the run. Polling for Wi-Fi (no
     * network callback), a queue still being prepared by Flutter and the
     * legacy progress-only mode keep it, as all need the CPU to advance.
     */
    fun shouldHoldWakeLock(
        nativeRunActive: Boolean,
        paused: Boolean,
        cancelRequested: Boolean,
        busyWorkers: Int,
        pollingForWifi: Boolean,
        preparingQueue: Boolean,
    ): Boolean = !nativeRunActive ||
        !paused ||
        cancelRequested ||
        busyWorkers > 0 ||
        pollingForWifi ||
        preparingQueue

    /**
     * Wi-Fi came back while the queue stays paused by another flag. In Wi-Fi
     * only mode Flutter pauses the queue itself when Wi-Fi drops, so its
     * resume has to travel through Flutter and startService first.
     * Verification still blocks the queue after that resume, so no grace.
     */
    fun shouldHoldWifiReturnGrace(
        userPaused: Boolean,
        verificationPaused: Boolean,
    ): Boolean = userPaused && !verificationPaused

    fun shouldWorkerWait(
        paused: Boolean,
        cancelRequested: Boolean,
        currentGeneration: Boolean,
    ): Boolean = paused && !cancelRequested && currentGeneration

    fun shouldPollProgress(
        paused: Boolean,
        busyWorkers: Int,
    ): Boolean = !paused || busyWorkers > 0
}

/**
 * Wakes coroutines suspended on native queue state. Every write that can end
 * a wait (pause, resume, cancel, generation, network, busy workers) must call
 * [notifyChanged] after it, so waiters need no timer.
 */
internal class NativeWorkerSignal {
    private val version = MutableStateFlow(0L)

    fun notifyChanged() {
        version.update { it + 1 }
    }

    suspend fun awaitUntil(condition: () -> Boolean) {
        if (condition()) return
        version.first { condition() }
    }
}
