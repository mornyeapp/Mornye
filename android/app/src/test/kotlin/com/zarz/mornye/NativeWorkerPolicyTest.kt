package com.zarz.mornye

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class NativeWorkerPolicyTest {
    @Test
    fun percentOnlyNotificationTotalsDoNotRenderAsBytes() {
        assertTrue(DownloadService.isPercentOnlyNotificationTotal(10_000L))
        assertTrue(DownloadService.isPercentOnlyNotificationTotal(100L))
        assertFalse(DownloadService.isPercentOnlyNotificationTotal(72L * 1024L * 1024L))
        assertFalse(DownloadService.isPercentOnlyNotificationTotal(0L))
    }

    @Test
    fun rateLimitRetriesExactlyOnce() {
        assertTrue(
            NativeWorkerPolicy.shouldRetryRateLimit(
                errorType = "rate_limit",
                errorMessage = "Too many requests",
                attempts = 0,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldRetryRateLimit(
                errorType = "rate_limit",
                errorMessage = "Too many requests",
                attempts = 1,
            ),
        )
    }

    @Test
    fun rateLimitDetectionFallsBackToMessage() {
        assertTrue(
            NativeWorkerPolicy.shouldRetryRateLimit(
                errorType = "network",
                errorMessage = "HTTP 429: retry later",
                attempts = 0,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldRetryRateLimit(
                errorType = "network",
                errorMessage = "Connection reset",
                attempts = 0,
            ),
        )
    }

    @Test
    fun retryDelayUsesServerHintAndSafeBounds() {
        assertEquals(
            45,
            NativeWorkerPolicy.rateLimitDelaySeconds(
                retryAfterSeconds = 45,
                errorMessage = null,
            ),
        )
        assertEquals(
            12,
            NativeWorkerPolicy.rateLimitDelaySeconds(
                retryAfterSeconds = null,
                errorMessage = "Retry-After seconds: 12",
            ),
        )
        assertEquals(
            5,
            NativeWorkerPolicy.rateLimitDelaySeconds(
                retryAfterSeconds = 1,
                errorMessage = null,
            ),
        )
        assertEquals(
            300,
            NativeWorkerPolicy.rateLimitDelaySeconds(
                retryAfterSeconds = 900,
                errorMessage = null,
            ),
        )
    }

    @Test
    fun wifiOnlyPausesWithoutWifi() {
        assertTrue(
            NativeWorkerPolicy.shouldPauseForNetwork(
                downloadNetworkMode = "wifi_only",
                hasWifi = false,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldPauseForNetwork(
                downloadNetworkMode = "wifi_only",
                hasWifi = true,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldPauseForNetwork(
                downloadNetworkMode = "any",
                hasWifi = false,
            ),
        )
    }

    @Test
    fun verificationDetectionUsesTypeAndMessageFallback() {
        for (errorType in listOf(
            "authentication_error", "provider_auth_failed",
            "request_auth_invalid", "provider_reauth_required",
        )) {
            assertFalse(
                NativeWorkerPolicy.isVerificationRequired(
                    errorType = errorType,
                    errorMessage = "Provider unauthorized; verification required upstream",
                ),
            )
        }
        assertTrue(
            NativeWorkerPolicy.isVerificationRequired(
                errorType = "verification_required",
                errorMessage = null,
            ),
        )
        assertTrue(
            NativeWorkerPolicy.isVerificationRequired(
                errorType = "unknown",
                errorMessage = "Challenge required before download",
            ),
        )
        assertFalse(
            NativeWorkerPolicy.isVerificationRequired(
                errorType = "network",
                errorMessage = "Connection reset",
            ),
        )
    }

    @Test
    fun completionAlertSkipsCancelledOrEmptyRuns() {
        assertTrue(
            NativeWorkerPolicy.shouldNotifyQueueComplete(
                cancelRequested = false,
                completed = 1,
                failed = 0,
            ),
        )
        assertTrue(
            NativeWorkerPolicy.shouldNotifyQueueComplete(
                cancelRequested = false,
                completed = 0,
                failed = 1,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldNotifyQueueComplete(
                cancelRequested = true,
                completed = 1,
                failed = 0,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldNotifyQueueComplete(
                cancelRequested = false,
                completed = 0,
                failed = 0,
            ),
        )
    }

    @Test
    fun stoppedWorkerRequeuesOnlyInFlightItems() {
        listOf("preparing", "downloading", "finalizing").forEach { status ->
            assertEquals("queued", NativeWorkerPolicy.statusAfterWorkerStop(status))
        }
        assertEquals("queued", NativeWorkerPolicy.statusAfterWorkerStop("queued"))
        assertEquals("completed", NativeWorkerPolicy.statusAfterWorkerStop("completed"))
        assertEquals("failed", NativeWorkerPolicy.statusAfterWorkerStop("failed"))
        assertEquals("skipped", NativeWorkerPolicy.statusAfterWorkerStop("skipped"))
    }

    @Test
    fun pausedQueueWithNoBusyWorkerReleasesWakeLock() {
        assertFalse(
            NativeWorkerPolicy.shouldHoldWakeLock(
                nativeRunActive = true,
                paused = true,
                cancelRequested = false,
                busyWorkers = 0,
                pollingForWifi = false,
                preparingQueue = false,
            ),
        )
    }

    @Test
    fun wakeLockStaysWhileWorkCanRun() {
        fun hold(
            nativeRunActive: Boolean = true,
            paused: Boolean = true,
            cancelRequested: Boolean = false,
            busyWorkers: Int = 0,
            pollingForWifi: Boolean = false,
            preparingQueue: Boolean = false,
        ) = NativeWorkerPolicy.shouldHoldWakeLock(
            nativeRunActive = nativeRunActive,
            paused = paused,
            cancelRequested = cancelRequested,
            busyWorkers = busyWorkers,
            pollingForWifi = pollingForWifi,
            preparingQueue = preparingQueue,
        )

        assertTrue(hold(paused = false))
        assertTrue(hold(busyWorkers = 1))
        assertTrue(hold(cancelRequested = true))
        assertTrue(hold(pollingForWifi = true))
        assertTrue(hold(preparingQueue = true))
        assertTrue(hold(nativeRunActive = false))
    }

    @Test
    fun wifiReturnGraceOnlyWhileAnotherPauseAwaitsResume() {
        assertTrue(
            NativeWorkerPolicy.shouldHoldWifiReturnGrace(
                userPaused = true,
                verificationPaused = false,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldHoldWifiReturnGrace(
                userPaused = false,
                verificationPaused = false,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldHoldWifiReturnGrace(
                userPaused = true,
                verificationPaused = true,
            ),
        )
    }

    @Test
    fun workersWaitOnlyWhilePausedInTheirOwnRun() {
        assertTrue(
            NativeWorkerPolicy.shouldWorkerWait(
                paused = true,
                cancelRequested = false,
                currentGeneration = true,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldWorkerWait(
                paused = false,
                cancelRequested = false,
                currentGeneration = true,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldWorkerWait(
                paused = true,
                cancelRequested = true,
                currentGeneration = true,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldWorkerWait(
                paused = true,
                cancelRequested = false,
                currentGeneration = false,
            ),
        )
    }

    @Test
    fun progressPollingStopsOnceAPausedQueueIsIdle() {
        assertFalse(NativeWorkerPolicy.shouldPollProgress(paused = true, busyWorkers = 0))
        assertTrue(NativeWorkerPolicy.shouldPollProgress(paused = true, busyWorkers = 2))
        assertTrue(NativeWorkerPolicy.shouldPollProgress(paused = false, busyWorkers = 0))
    }

    @Test
    fun pausedWaitDoesNotPollUntilSignalled() = runBlocking {
        val signal = NativeWorkerSignal()
        val paused = AtomicBoolean(true)
        val checks = AtomicInteger(0)
        val waiter = launch(Dispatchers.Default) {
            signal.awaitUntil {
                checks.incrementAndGet()
                !paused.get()
            }
        }

        delay(1_600)
        assertTrue(waiter.isActive)
        assertTrue("checked ${checks.get()} times while paused", checks.get() <= 2)

        paused.set(false)
        signal.notifyChanged()
        withTimeout(1_000) { waiter.join() }
    }

    @Test
    fun signalNeverLosesAWakeupRacingTheWaiter() = runBlocking {
        repeat(500) {
            val signal = NativeWorkerSignal()
            val paused = AtomicBoolean(true)
            val waiter = launch(Dispatchers.Default) {
                signal.awaitUntil { !paused.get() }
            }
            launch(Dispatchers.Default) {
                paused.set(false)
                signal.notifyChanged()
            }
            withTimeout(2_000) { waiter.join() }
        }
    }

    @Test
    fun cancelledWaiterStopsWithoutASignal() = runBlocking {
        val signal = NativeWorkerSignal()
        val waiter = launch(Dispatchers.Default) {
            signal.awaitUntil { false }
        }
        delay(50)
        waiter.cancel()
        withTimeout(1_000) { waiter.join() }
        assertTrue(waiter.isCancelled)
    }

    @Test
    fun acknowledgedPayloadsAreReleasedOnlyForTerminalItems() {
        listOf("completed", "failed", "skipped").forEach { status ->
            assertTrue(NativeWorkerPolicy.isTerminalStatus(status))
        }
        listOf("queued", "preparing", "downloading", "finalizing").forEach { status ->
            assertFalse(NativeWorkerPolicy.isTerminalStatus(status))
        }
    }
}
