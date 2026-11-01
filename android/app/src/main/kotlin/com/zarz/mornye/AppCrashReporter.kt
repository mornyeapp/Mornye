package com.zarz.mornye

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Process
import android.util.AtomicFile
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.PrintWriter
import java.io.Writer
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean

/** Persists diagnostics outside Dart, including process deaths during native work. */
internal object AppCrashReporter {
    private const val MAX_TEXT = 128 * 1024
    private const val MAX_TRACE_BYTES = 2 * 1024 * 1024
    private const val MAX_NOTICE_AGE_MS = 7L * 24 * 60 * 60 * 1000
    private lateinit var context: Context
    private var sessionStartedAt = 0L
    private var recovery: Future<*>? = null
    private val storageLock = Any()
    private val handlingCrash = AtomicBoolean(false)

    fun isUnexpectedExit(reason: Int, status: Int = 0): Boolean = when (reason) {
        ApplicationExitInfo.REASON_CRASH,
        ApplicationExitInfo.REASON_CRASH_NATIVE,
        ApplicationExitInfo.REASON_ANR -> true
        // Linux fatal signals: ILL, TRAP, ABRT, BUS, FPE, SEGV, SYS.
        // SIGKILL/SIGTERM and OS resource reclamation are not crash notices.
        ApplicationExitInfo.REASON_SIGNALED -> status in setOf(4, 5, 6, 7, 8, 11, 31)
        else -> false
    }

    fun shouldShowSavedReport(report: JSONObject): Boolean =
        !report.has("reason_code") ||
            isUnexpectedExit(report.optInt("reason_code"), report.optInt("status"))

    fun shouldKeepSavedReport(savedAt: Long, exitAt: Long, currentStart: Long): Boolean =
        savedAt >= currentStart || savedAt > exitAt + 5000L

    fun shouldNotify(report: JSONObject, notifiedAt: Long, dismissedAt: Long, now: Long): Boolean {
        val timestamp = report.optLong("timestamp")
        val age = now - timestamp
        val importance = report.optInt("importance_code", 0)
        return shouldShowSavedReport(report) && timestamp > maxOf(notifiedAt, dismissedAt) &&
            age in 0L..MAX_NOTICE_AGE_MS &&
            importance != ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED &&
            importance != ActivityManager.RunningAppProcessInfo.IMPORTANCE_GONE
    }

    fun initialize(applicationContext: Context) {
        context = applicationContext
        sessionStartedAt = System.currentTimeMillis()

        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                if (handlingCrash.compareAndSet(false, true)) {
                    val trace = BoundedWriter(MAX_TEXT)
                    error.printStackTrace(PrintWriter(trace))
                    val report = baseReport(System.currentTimeMillis())
                        .put("reason", "Unhandled Android exception")
                        .put("description", "${error.javaClass.name}: ${error.message.orEmpty()}".take(2000))
                        .put("trace", "Thread: ${thread.name}\n$trace")
                    synchronized(storageLock) { writeJson("pending", report) }
                }
            } catch (_: Throwable) {
                // A crash, especially OOM, must still reach Android's handler.
            } finally {
                if (previousHandler != null) {
                    previousHandler.uncaughtException(thread, error)
                } else {
                    Process.killProcess(Process.myPid())
                }
            }
        }

        // Recover even if the user never reaches Home on this launch. Trace I/O
        // must not block Application.onCreate or make the next launch an ANR.
        val executor = Executors.newSingleThreadExecutor()
        recovery = executor.submit {
            try {
                val prefs = context.getSharedPreferences("app_crash_reports", Context.MODE_PRIVATE)
                val previousStart = prefs.getLong("session_started_at", 0L)
                val previousVersion = prefs.getString("session_version", "Unknown") ?: "Unknown"
                prefs.edit().putLong("session_started_at", sessionStartedAt)
                    .putString("session_version", "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
                    .commit()
                recoverPreviousExit(previousStart, previousVersion)
            } catch (error: Exception) {
                Log.w("AppCrashReporter", "Could not read Android exit diagnostics", error)
            }
        }
        executor.shutdown()
    }

    fun pendingReport(noticeOnly: Boolean = true): Map<String, Any?>? {
        recovery?.get()
        return synchronized(storageLock) {
            val report = readJson("pending") ?: return@synchronized null
            // Older versions saved low-memory and ordinary OS kills as
            // crashes. Apply the same policy to those already persisted.
            if (!shouldShowSavedReport(report)) return@synchronized null
            val prefs = context.getSharedPreferences("app_crash_reports", Context.MODE_PRIVATE)
            if (noticeOnly && !shouldNotify(
                    report, prefs.getLong("notified_at", 0L), prefs.getLong("dismissed_at", 0L),
                    System.currentTimeMillis(),
                )
            ) return@synchronized null
            report.keys().asSequence().associateWith { key ->
                report.get(key).takeUnless { it == JSONObject.NULL }
            }
        }
    }

    fun markReportShown(id: String) {
        recovery?.get()
        synchronized(storageLock) {
            val report = readJson("pending") ?: return
            if (report.optString("id") != id) return
            val prefs = context.getSharedPreferences("app_crash_reports", Context.MODE_PRIVATE)
            check(prefs.edit().putLong("notified_at", report.optLong("timestamp")).commit())
        }
    }

    fun dismissReport(id: String) {
        recovery?.get()
        synchronized(storageLock) {
            val report = readJson("pending") ?: return
            if (report.optString("id") != id) return
            val prefs = context.getSharedPreferences("app_crash_reports", Context.MODE_PRIVATE)
            check(prefs.edit().putLong("dismissed_at", report.optLong("timestamp")).commit())
            // Keep the latest report available in diagnostics after hiding the notice.
        }
    }

    fun recordRuntimeError(error: String, stack: String, logs: String) {
        val snapshot = JSONObject()
            .put("session_started_at", sessionStartedAt)
            .put("timestamp", System.currentTimeMillis())
            .put("error", error.take(4000))
            .put("stack", stack.take(48 * 1024))
            .put("logs", logs.takeLast(32 * 1024))
        synchronized(storageLock) { writeJson("runtime_error", snapshot) }
    }

    private fun recoverPreviousExit(previousStart: Long, previousVersion: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || previousStart <= 0L) return
        val manager = context.getSystemService(ActivityManager::class.java)
        val exit = manager.getHistoricalProcessExitReasons(context.packageName, 0, 32)
            .firstOrNull {
                LibraryScanExitInfo.matches(it.processName, it.timestamp, context.packageName, previousStart) &&
                    it.timestamp < sessionStartedAt
            } ?: return
        // Do not call force-stop, updates, or ordinary task removal a crash.
        if (!isUnexpectedExit(exit.reason, exit.status)) return
        val prefs = context.getSharedPreferences("app_crash_reports", Context.MODE_PRIVATE)
        if (exit.timestamp <= prefs.getLong("dismissed_at", 0L)) return

        val report = baseReport(exit.timestamp)
            .put("version", previousVersion)
            .put("reason", LibraryScanExitInfo.reasonLabel(exit.reason))
            .put("reason_code", exit.reason)
            .put("description", exit.description.orEmpty().take(2000))
            .put("status", exit.status)
            .put("process_name", exit.processName)
            .put("process_id", exit.pid)
            .put("importance_code", exit.importance)
            .put("importance_label", LibraryScanExitInfo.importanceLabel(exit.importance))
            .put("session_duration_ms", (exit.timestamp - previousStart).coerceAtLeast(0L))
            .put("pss_kb", exit.pss)
            .put("rss_kb", exit.rss)
        try {
            exit.traceInputStream?.use { stream ->
                val bytes = stream.takeBounded(MAX_TRACE_BYTES)
                val trace = if (exit.reason == ApplicationExitInfo.REASON_CRASH_NATIVE) {
                    NativeCrashTrace.decode(bytes)
                } else {
                    bytes.toString(Charsets.UTF_8)
                }
                report.put("trace", trace.take(MAX_TEXT))
            }
        } catch (error: Exception) {
            report.put("trace_error", "Android crash trace unavailable: ${error.javaClass.simpleName}")
        }
        synchronized(storageLock) {
            val stored = readJson("pending")
            // A second startup crash can happen while the previous tombstone
            // is being read. Never overwrite its newer synchronous report.
            if (stored != null && shouldKeepSavedReport(
                    stored.optLong("timestamp"), exit.timestamp, sessionStartedAt,
                )
            ) return
            if (stored != null && stored.optLong("timestamp") >= previousStart &&
                stored.optString("trace").isNotEmpty()
            ) {
                report.put("trace", stored.optString("trace"))
                report.put("description", stored.optString("description"))
            }
            val runtime = readJson("runtime_error")
            if (runtime?.optLong("session_started_at") == previousStart) {
                report.put("runtime_error", runtime.optString("error"))
                    .put("runtime_stack", runtime.optString("stack"))
                    .put("recent_logs", runtime.optString("logs"))
            }
            writeJson("pending", report)
        }
    }

    private fun baseReport(timestamp: Long): JSONObject = JSONObject()
        .put("id", timestamp.toString())
        .put("timestamp", timestamp)
        .put("version", "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
        .put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
        .put("android", Build.VERSION.RELEASE)
        .put("sdk", Build.VERSION.SDK_INT)
        .put("abis", Build.SUPPORTED_ABIS.joinToString())

    private fun file(name: String) = AtomicFile(File(context.filesDir, "app_crash_$name.json"))

    private fun readJson(name: String): JSONObject? = try {
        JSONObject(file(name).openRead().bufferedReader().use { it.readText() })
    } catch (_: Exception) {
        null
    }

    private fun writeJson(name: String, report: JSONObject) {
        val target = file(name)
        val output = target.startWrite()
        try {
            output.write(report.toString().toByteArray(Charsets.UTF_8))
            target.finishWrite(output)
        } catch (error: Throwable) {
            target.failWrite(output)
            throw error
        }
    }

    private fun java.io.InputStream.takeBounded(limit: Int): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (output.size() < limit) {
            val count = read(buffer, 0, minOf(buffer.size, limit - output.size()))
            if (count < 0) break
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    private class BoundedWriter(private val limit: Int) : Writer() {
        private val text = StringBuilder()
        override fun write(chars: CharArray, offset: Int, length: Int) {
            val count = minOf(length, limit - text.length)
            if (count > 0) text.append(chars, offset, count)
        }
        override fun flush() = Unit
        override fun close() = Unit
        override fun toString(): String = text.toString()
    }
}
