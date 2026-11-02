package com.zarz.mornye

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DownloadServiceStartupTest {
    @Test
    fun inlineQueueEntersForegroundBeforeReplayGainRecovery() {
        verifyStartup(fromFile = false)
    }

    @Test
    fun fileQueueEntersForegroundBeforeReplayGainRecovery() {
        verifyStartup(fromFile = true)
    }

    private fun verifyStartup(fromFile: Boolean) {
        // This test writes worker snapshots. Run only on a disposable install.
        assumeTrue(
            InstrumentationRegistry.getArguments()
                .getString("download_service_startup") == "true",
        )
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val intent = Intent(context, DownloadService::class.java)
        val payload = File.createTempFile("invalid-download-", ".json", context.cacheDir)
        payload.writeText("invalid queue JSON")
        instrumentation.uiAutomation.adoptShellPermissionIdentity(
            "android.permission.START_FOREGROUND_SERVICES_FROM_BACKGROUND",
        )
        try {
            assertFalse("No existing download may be interrupted", isPresent(activityManager))
            // Simulate a slow journal recovery without relying on large files
            // or a device-specific timing threshold. The service must already
            // be foreground while waiting for this lock, even for bad input.
            synchronized(DownloadService.NATIVE_REPLAYGAIN_JOURNAL_FILE_LOCK) {
                if (fromFile) {
                    DownloadService.startNativeQueueFromFiles(context, payload.path)
                } else {
                    DownloadService.startNativeQueue(context, "invalid queue JSON")
                }
                awaitState("Download service did not enter foreground before recovery") {
                    isForeground(activityManager)
                }
            }
            awaitState("Invalid queue left the foreground service running") {
                !isPresent(activityManager)
            }
            assertFalse(DownloadService.isServiceRunning())
            // A fresh start after the rejected queue must still work.
            DownloadService.start(context, "Startup test")
            awaitState("Service could not restart after rejecting the queue") {
                isForeground(activityManager)
            }
            DownloadService.stop(context)
            awaitState("Stop left the service running") { !isPresent(activityManager) }
        } finally {
            context.stopService(intent)
            payload.delete()
            instrumentation.uiAutomation.dropShellPermissionIdentity()
        }
    }

    @Suppress("DEPRECATION")
    private fun isPresent(manager: ActivityManager): Boolean =
        manager.getRunningServices(Int.MAX_VALUE).any {
            it.service.className == DownloadService::class.java.name
        }

    @Suppress("DEPRECATION")
    private fun isForeground(manager: ActivityManager): Boolean =
        manager.getRunningServices(Int.MAX_VALUE).any {
            it.service.className == DownloadService::class.java.name && it.foreground
        }

    private fun awaitState(message: String, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 3_000
        while (!condition() && SystemClock.elapsedRealtime() < deadline) {
            SystemClock.sleep(20)
        }
        assertTrue(message, condition())
    }
}
