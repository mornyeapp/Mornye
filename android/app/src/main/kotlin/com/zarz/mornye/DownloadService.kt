package com.zarz.mornye

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.util.AtomicFile
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Foreground service to keep downloads running when app is in background.
 * This prevents Android from killing the download process or throttling network.
 *
 * Note: Android 15+ (API 35+) has a 6-hour timeout for dataSync foreground services.
 * The service will be stopped automatically after 6 hours of cumulative runtime in 24 hours.
 */
class DownloadService : Service() {
    internal val coreBackend: CoreBackend by lazy { createCoreBackend(applicationContext) }

    companion object {
        private const val CHANNEL_ID = "download_channel"
        private const val ALERT_CHANNEL_ID = "download_alerts_v1"
        private const val NOTIFICATION_ID = 1001
        private const val WIDGET_PROGRESS_INTERVAL_MS = 1000L
        private const val DOWNLOAD_RESULT_NOTIFICATION_ID = 1
        private const val VERIFICATION_REQUIRED_NOTIFICATION_ID = 4
        private const val WAKELOCK_TAG = "Mornye:DownloadWakeLock"

        const val ACTION_START = "com.zarz.mornye.action.START_DOWNLOAD"
        const val ACTION_STOP = "com.zarz.mornye.action.STOP_DOWNLOAD"
        const val ACTION_UPDATE_PROGRESS = "com.zarz.mornye.action.UPDATE_PROGRESS"
        const val ACTION_START_NATIVE_QUEUE = "com.zarz.mornye.action.START_NATIVE_QUEUE"
        const val ACTION_APPEND_NATIVE_QUEUE = "com.zarz.mornye.action.APPEND_NATIVE_QUEUE"
        const val ACTION_FINISH_NATIVE_QUEUE_PREPARATION =
            "com.zarz.mornye.action.FINISH_NATIVE_QUEUE_PREPARATION"
        const val ACTION_ACKNOWLEDGE_NATIVE_QUEUE_ITEMS =
            "com.zarz.mornye.action.ACKNOWLEDGE_NATIVE_QUEUE_ITEMS"
        const val ACTION_PAUSE_NATIVE_QUEUE = "com.zarz.mornye.action.PAUSE_NATIVE_QUEUE"
        const val ACTION_RESUME_NATIVE_QUEUE = "com.zarz.mornye.action.RESUME_NATIVE_QUEUE"
        const val ACTION_CANCEL_NATIVE_QUEUE = "com.zarz.mornye.action.CANCEL_NATIVE_QUEUE"

        const val EXTRA_TRACK_NAME = "track_name"
        const val EXTRA_ARTIST_NAME = "artist_name"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_TOTAL = "total"
        const val EXTRA_QUEUE_COUNT = "queue_count"
        const val EXTRA_STATUS = "status"
        const val EXTRA_REQUESTS_JSON = "requests_json"
        const val EXTRA_SETTINGS_JSON = "settings_json"
        const val EXTRA_REQUESTS_PATH = "requests_path"
        const val EXTRA_SETTINGS_PATH = "settings_path"
        const val EXTRA_RUN_ID = "run_id"
        const val EXTRA_ITEM_IDS_JSON = "item_ids_json"
        internal const val NATIVE_WORKER_STATE_FILE = "native_download_worker_state.json"
        internal const val NATIVE_WORKER_PROGRESS_FILE = "native_download_worker_progress.json"
        internal const val NATIVE_REPLAYGAIN_JOURNAL_FILE = "native_replaygain_journal.json"
        internal const val NATIVE_WORKER_CONTRACT_VERSION = NativeDownloadFinalizer.NATIVE_WORKER_CONTRACT_VERSION
        internal const val NOTIFICATION_PERCENT_TOTAL = 10_000L
        private const val LEGACY_NOTIFICATION_PERCENT_TOTAL = 100L
        internal val NATIVE_WORKER_STATE_FILE_LOCK = Any()
        internal val NATIVE_REPLAYGAIN_JOURNAL_FILE_LOCK = Any()

        private var isRunning = false

        internal fun isPercentOnlyNotificationTotal(total: Long): Boolean =
            total == NOTIFICATION_PERCENT_TOTAL || total == LEGACY_NOTIFICATION_PERCENT_TOTAL

        fun isServiceRunning(): Boolean = isRunning

        fun start(context: Context, trackName: String = "", artistName: String = "", queueCount: Int = 0) {
            val intent = Intent(context, DownloadService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TRACK_NAME, trackName)
                putExtra(EXTRA_ARTIST_NAME, artistName)
                putExtra(EXTRA_QUEUE_COUNT, queueCount)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, DownloadService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }

        fun updateProgress(context: Context, trackName: String, artistName: String, progress: Long, total: Long, queueCount: Int, status: String = "downloading") {
            val intent = Intent(context, DownloadService::class.java).apply {
                action = ACTION_UPDATE_PROGRESS
                putExtra(EXTRA_TRACK_NAME, trackName)
                putExtra(EXTRA_ARTIST_NAME, artistName)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_TOTAL, total)
                putExtra(EXTRA_QUEUE_COUNT, queueCount)
                putExtra(EXTRA_STATUS, status)
            }
            context.startService(intent)
        }

        fun startNativeQueue(context: Context, requestsJson: String, settingsJson: String = "") {
            val intent = Intent(context, DownloadService::class.java).apply {
                action = ACTION_START_NATIVE_QUEUE
                putExtra(EXTRA_REQUESTS_JSON, requestsJson)
                putExtra(EXTRA_SETTINGS_JSON, settingsJson)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun startNativeQueueFromFiles(context: Context, requestsPath: String, settingsPath: String = "") {
            val intent = Intent(context, DownloadService::class.java).apply {
                action = ACTION_START_NATIVE_QUEUE
                putExtra(EXTRA_REQUESTS_PATH, requestsPath)
                putExtra(EXTRA_SETTINGS_PATH, settingsPath)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun appendNativeQueueFromFile(context: Context, requestsPath: String, runId: String) {
            val intent = Intent(context, DownloadService::class.java).apply {
                action = ACTION_APPEND_NATIVE_QUEUE
                putExtra(EXTRA_REQUESTS_PATH, requestsPath)
                putExtra(EXTRA_RUN_ID, runId)
            }
            context.startService(intent)
        }

        fun finishNativeQueuePreparation(context: Context, runId: String) {
            val intent = Intent(context, DownloadService::class.java).apply {
                action = ACTION_FINISH_NATIVE_QUEUE_PREPARATION
                putExtra(EXTRA_RUN_ID, runId)
            }
            context.startService(intent)
        }

        fun acknowledgeNativeQueueItems(
            context: Context,
            runId: String,
            itemIdsJson: String,
        ) {
            val intent = Intent(context, DownloadService::class.java).apply {
                action = ACTION_ACKNOWLEDGE_NATIVE_QUEUE_ITEMS
                putExtra(EXTRA_RUN_ID, runId)
                putExtra(EXTRA_ITEM_IDS_JSON, itemIdsJson)
            }
            context.startService(intent)
        }

        fun pauseNativeQueue(context: Context) {
            val intent = Intent(context, DownloadService::class.java).apply {
                action = ACTION_PAUSE_NATIVE_QUEUE
            }
            context.startService(intent)
        }

        fun resumeNativeQueue(context: Context) {
            val intent = Intent(context, DownloadService::class.java).apply {
                action = ACTION_RESUME_NATIVE_QUEUE
            }
            context.startService(intent)
        }

        fun cancelNativeQueue(context: Context) {
            val intent = Intent(context, DownloadService::class.java).apply {
                action = ACTION_CANCEL_NATIVE_QUEUE
            }
            context.startService(intent)
        }

        // Header of the last written state snapshot (all fields except the
        // per-item payload). Lets steady-state polls skip re-reading and
        // re-parsing the full state file — which grows with every completed
        // item (results embed history rows and lyrics) — once the caller has
        // already consumed that items payload.
        @Volatile internal var lastStateHeaderJson: String? = null
        @Volatile internal var lastStateHeaderSerial = 0L

        fun getNativeWorkerSnapshot(context: Context, sinceStateSerial: Long = 0L): String {
            synchronized(NATIVE_WORKER_STATE_FILE_LOCK) {
                val stateFile = File(context.filesDir, NATIVE_WORKER_STATE_FILE)
                if (!stateFile.exists()) {
                    return JSONObject()
                        .put("run_id", "")
                        .put("is_running", false)
                        .put("is_paused", false)
                        .put("total", 0)
                        .put("completed", 0)
                        .put("failed", 0)
                        .put("skipped", 0)
                        .put("state_serial", 0L)
                        .put("items", JSONArray())
                        .toString()
                }

                val headerJson = lastStateHeaderJson
                val headerSerial = lastStateHeaderSerial
                val state: JSONObject
                if (sinceStateSerial > 0 &&
                    headerSerial in 1..sinceStateSerial &&
                    headerJson != null
                ) {
                    // Caller already consumed this items payload; serve the
                    // cached compact header instead of re-parsing the file.
                    state = JSONObject(headerJson)
                } else {
                    state = AtomicFile(stateFile).openRead().bufferedReader(Charsets.UTF_8).use {
                        it.readText()
                    }.let { JSONObject(it) }
                    val stateSerial = state.optLong("snapshot_serial", 0L)
                    state.put("state_serial", stateSerial)
                    if (sinceStateSerial > 0 && stateSerial in 1..sinceStateSerial) {
                        state.remove("items")
                        state.remove("item_ids")
                        state.remove("last_result")
                        state.remove("settings_json")
                    }
                }

                val progressFile = File(context.filesDir, NATIVE_WORKER_PROGRESS_FILE)
                if (progressFile.exists()) {
                    try {
                        val progress = AtomicFile(progressFile).openRead().bufferedReader(Charsets.UTF_8).use {
                            it.readText()
                        }.let { JSONObject(it) }
                        if (progress.optString("run_id", "") == state.optString("run_id", "") &&
                            progress.optLong("snapshot_serial", 0L) > state.optLong("snapshot_serial", 0L)
                        ) {
                            mergeNativeWorkerProgressSnapshot(state, progress)
                        }
                    } catch (_: Exception) {
                    }
                }
                return state.toString()
            }
        }

        private fun mergeNativeWorkerProgressSnapshot(state: JSONObject, progress: JSONObject) {
            val dynamicKeys = listOf(
                "is_running",
                "is_paused",
                "total",
                "completed",
                "failed",
                "skipped",
                "current_item_id",
                "message",
                "updated_at",
                "snapshot_serial",
                "item_ids"
            )
            for (key in dynamicKeys) {
                if (progress.has(key)) {
                    state.put(key, progress.get(key))
                }
            }
            if (progress.has("item_delta")) {
                state.put("item_delta", progress.get("item_delta"))
            }
            if (progress.has("item_deltas")) {
                state.put("item_deltas", progress.get("item_deltas"))
            }
            state.put("snapshot_mode", "compact_with_delta")
        }
    }

    internal data class NativeDownloadRequest(
        val itemId: String,
        val requestJson: String,
        val trackName: String,
        val artistName: String,
        val itemJson: String
    )

    internal data class NativeWorkerItem(
        val itemId: String,
        val trackName: String,
        val artistName: String,
        var status: String = "queued",
        var progress: Double = 0.0,
        var bytesReceived: Long = 0L,
        var bytesTotal: Long = 0L,
        var error: String = "",
        var resultJson: JSONObject? = null
    )

    internal data class NativeWorkerCounts(
        val total: Int,
        val completed: Int,
        val failed: Int,
        val skipped: Int
    )

    internal val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    internal var nativeWorkerJob: Job? = null
    @Volatile internal var pendingNativeItemsSnapshotJob: Job? = null
    private var nativeWorkerRequestChannel: Channel<NativeDownloadRequest>? = null
    @Volatile private var nativeWorkerPreparationComplete = true
    private val wakeLock = ForegroundWorkLock(this, WAKELOCK_TAG, "DownloadService")
    private var currentTrackName = ""
    private var currentArtistName = ""
    internal var currentStatus = "preparing"
    internal var queueCount = 0
    // Signature of the last home-screen widget push; keeps widget updates
    // event-driven (track/status/queue changes, throttled percent ticks),
    // never per byte.
    private var widgetSignature = ""
    private var lastWidgetPushAt = 0L
    // NotificationManager updates are also deduplicated by the visible
    // notification state. Progress writers can report many byte-level changes
    // that render the same percentage/text.
    private var lastNotificationSignature: String? = null
    internal var lastProgress = 0L
    internal var lastTotal = 0L
    internal var nativeWorkerRunId = ""
    @Volatile private var nativeWorkerCurrentItemId = ""
    internal val nativeWorkerItems = mutableListOf<NativeWorkerItem>()
    internal val nativeWorkerTerminalStatuses = mutableMapOf<String, String>()
    internal val nativeReplayGainEntries = mutableListOf<JSONObject>()
    internal val nativeReplayGainRequestAlbumKeys = mutableMapOf<String, String>()
    // One coordinator polls the backend's delta progress stream for all native workers.
    // Individual workers consume this cache instead of parsing the complete
    // multi-progress JSON independently.
    internal val nativeWorkerProgressLock = Any()
    internal val nativeWorkerProgressItems = mutableMapOf<String, NativeBackendProgress>()
    internal var nativeWorkerProgressSeq = 0L
    internal val nativeWorkerProgressEpoch = AtomicLong(0L)
    @Volatile internal var nativeWorkerProgressJob: Job? = null
    @Volatile internal var nativeWorkerProgressConnection: AtomicReference<CoreDownloadProgress?>? = null
    internal val snapshotWriteLock = Any()
    internal val snapshotWriteSerial = AtomicLong(0L)
    internal var latestCommittedStateSnapshotSerial = 0L
    internal var latestCommittedProgressSnapshotSerial = 0L
    @Volatile private var nativeWorkerPaused = false
    private val nativeWorkerPausePendingIds = mutableSetOf<String>()
    private var nativeWorkerResumePending = false
    @Volatile internal var nativeWorkerNetworkPaused = false
    @Volatile internal var nativeWorkerVerificationPaused = false
    @Volatile private var nativeWorkerCancelRequested = false
    internal var nativeWorkerDownloadNetworkMode = "any"
    internal var nativeWorkerNetworkCallback: ConnectivityManager.NetworkCallback? = null
    internal var nativeWorkerNetworkFallbackJob: Job? = null
    internal val nativeWorkerWifiNetworks = mutableSetOf<Network>()
    // Bumped every time a new native queue replaces the current one. A worker
    // coroutine that observes a different generation than its own must stop
    // without touching the snapshot or the service lifecycle: cancel() alone
    // cannot interrupt the blocking native call it may be sitting in, and
    // the shared pause/cancel flags get reset for the new run.
    @Volatile private var nativeWorkerGeneration = 0L

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            flushNativeAlbumReplayGainJournalIfComplete()
            writeNativeWorkerSnapshot(
                isRunning = false,
                isPaused = false,
                currentItemId = "",
                message = "Service restart ignored",
                includeItems = true
            )
            stopForegroundService(cancelNativeWorker = false)
            return START_NOT_STICKY
        }

        when (intent.action) {
            ACTION_START -> {
                currentTrackName = intent.getStringExtra(EXTRA_TRACK_NAME) ?: ""
                currentArtistName = intent.getStringExtra(EXTRA_ARTIST_NAME) ?: ""
                currentStatus = "preparing"
                queueCount = intent.getIntExtra(EXTRA_QUEUE_COUNT, 0)
                lastProgress = 0L
                lastTotal = 0L
                startForegroundService()
            }
            ACTION_STOP -> {
                stopForegroundService()
            }
            ACTION_START_NATIVE_QUEUE -> {
                // Satisfy Android's foreground deadline before file I/O,
                // queue parsing or ReplayGain recovery can block startup.
                // Invalid payloads must also enter foreground before stopping.
                startForegroundService()
                val requestsJson = readNativeQueuePayload(
                    intent,
                    EXTRA_REQUESTS_JSON,
                    EXTRA_REQUESTS_PATH,
                    "[]"
                )
                val settingsJson = readNativeQueuePayload(
                    intent,
                    EXTRA_SETTINGS_JSON,
                    EXTRA_SETTINGS_PATH,
                    "{}"
                )
                startNativeWorker(requestsJson, settingsJson)
            }
            ACTION_APPEND_NATIVE_QUEUE -> {
                val requestsJson = readNativeQueuePayload(
                    intent,
                    EXTRA_REQUESTS_JSON,
                    EXTRA_REQUESTS_PATH,
                    "[]"
                )
                appendNativeWorkerRequests(
                    requestsJson,
                    intent.getStringExtra(EXTRA_RUN_ID).orEmpty(),
                )
            }
            ACTION_FINISH_NATIVE_QUEUE_PREPARATION -> {
                finishNativeWorkerPreparation(
                    intent.getStringExtra(EXTRA_RUN_ID).orEmpty(),
                )
            }
            ACTION_ACKNOWLEDGE_NATIVE_QUEUE_ITEMS -> {
                acknowledgeNativeWorkerItems(
                    intent.getStringExtra(EXTRA_RUN_ID).orEmpty(),
                    intent.getStringExtra(EXTRA_ITEM_IDS_JSON).orEmpty(),
                )
            }
            ACTION_PAUSE_NATIVE_QUEUE -> {
                synchronized(nativeWorkerItems) {
                    nativeWorkerResumePending = false
                    nativeWorkerPaused = true
                }
                cancelActiveNativeItemForPause()
                writeNativeWorkerSnapshotAsync(
                    isRunning = nativeWorkerJob?.isActive == true,
                    isPaused = true,
                    currentItemId = "",
                    message = "Paused",
                    includeItems = true
                )
            }
            ACTION_RESUME_NATIVE_QUEUE -> {
                synchronized(nativeWorkerItems) {
                    nativeWorkerResumePending = nativeWorkerPausePendingIds.isNotEmpty()
                    nativeWorkerPaused = nativeWorkerResumePending
                }
                val stillPaused = isNativeWorkerPaused()
                writeNativeWorkerSnapshotAsync(
                    isRunning = nativeWorkerJob?.isActive == true,
                    isPaused = stillPaused,
                    currentItemId = "",
                    message = if (stillPaused) nativeWorkerPauseMessage() else "Resumed",
                    includeItems = true
                )
            }
            ACTION_CANCEL_NATIVE_QUEUE -> {
                nativeWorkerCancelRequested = true
                synchronized(nativeWorkerItems) {
                    nativeWorkerResumePending = false
                    nativeWorkerPausePendingIds.clear()
                }
                nativeWorkerVerificationPaused = false
                nativeWorkerPreparationComplete = true
                nativeWorkerRequestChannel?.close()
                cancelScheduledNativeWorkerItemsSnapshot()
                cancelNativeVerificationNotification()
                synchronized(nativeWorkerItems) {
                    for (item in nativeWorkerItems) {
                        if (item.status == "queued" ||
                            item.status == "downloading" ||
                            item.status == "finalizing"
                        ) {
                            item.status = "skipped"
                            try {
                                coreBackend.cancelDownload(item.itemId)
                            } catch (_: Exception) {
                            }
                        }
                    }
                }
                NativeDownloadFinalizer.cancelActiveWork()
                nativeWorkerJob?.cancel(CancellationException("Native queue cancelled"))
                writeNativeWorkerSnapshotAsync(
                    isRunning = false,
                    isPaused = false,
                    currentItemId = "",
                    message = "Cancelled",
                    includeItems = true
                )
            }
            ACTION_UPDATE_PROGRESS -> {
                currentTrackName = intent.getStringExtra(EXTRA_TRACK_NAME) ?: currentTrackName
                currentArtistName = intent.getStringExtra(EXTRA_ARTIST_NAME) ?: currentArtistName
                val progress = intent.getLongExtra(EXTRA_PROGRESS, 0)
                val total = intent.getLongExtra(EXTRA_TOTAL, 0)
                currentStatus = intent.getStringExtra(EXTRA_STATUS) ?: currentStatus
                queueCount = intent.getIntExtra(EXTRA_QUEUE_COUNT, queueCount)
                lastProgress = progress
                lastTotal = total
                updateNotification(progress, total)
            }
        }
        return START_NOT_STICKY
    }

    private fun readNativeQueuePayload(
        intent: Intent,
        jsonExtra: String,
        pathExtra: String,
        defaultValue: String,
    ): String {
        val path = intent.getStringExtra(pathExtra).orEmpty()
        if (path.isNotBlank()) {
            return try {
                val file = File(path)
                val payload = file.readText()
                if (!file.delete()) {
                    android.util.Log.w(
                        "DownloadService",
                        "Failed to delete native worker payload file: $path"
                    )
                }
                payload.ifBlank { defaultValue }
            } catch (e: Exception) {
                android.util.Log.w(
                    "DownloadService",
                    "Failed to read native worker payload file: ${e.message}"
                )
                defaultValue
            }
        }

        return intent.getStringExtra(jsonExtra) ?: defaultValue
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Called when the foreground service timeout is reached (Android 15+, API 35+).
     * dataSync services have a 6-hour limit in a 24-hour period.
     * We must call stopSelf() within a few seconds to avoid a crash.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        android.util.Log.w("DownloadService", "Foreground service timeout reached (6 hours limit). Stopping service.")

        stopNativeWorkerForSystemTimeout()
    }

    private fun stopNativeWorkerForSystemTimeout() {
        if (!hasNativeWorkerState()) {
            stopForegroundService()
            return
        }
        nativeWorkerCancelRequested = true
        nativeWorkerPreparationComplete = true
        nativeWorkerRequestChannel?.close()
        pendingNativeItemsSnapshotJob?.cancel()
        pendingNativeItemsSnapshotJob = null
        // Supersede the coroutine before cancelling it. Its catch/finally
        // blocks must not publish a skipped/finished state over the recovery
        // snapshot written below.
        nativeWorkerGeneration++
        val activeItemIds = synchronized(nativeWorkerItems) {
            nativeWorkerItems
                .filter { NativeWorkerPolicy.statusAfterWorkerStop(it.status) != it.status }
                .map { it.itemId }
        }
        for (itemId in activeItemIds) {
            try {
                coreBackend.cancelDownload(itemId)
            } catch (_: Exception) {
            }
        }
        NativeDownloadFinalizer.cancelActiveWork()
        nativeWorkerJob?.cancel(
            CancellationException("Native queue stopped by Android timeout")
        )
        synchronized(nativeWorkerItems) {
            for (item in nativeWorkerItems) {
                val recoveredStatus = NativeWorkerPolicy.statusAfterWorkerStop(item.status)
                if (recoveredStatus == item.status) continue
                item.status = recoveredStatus
                item.progress = 0.0
                item.bytesReceived = 0L
                item.bytesTotal = 0L
                item.error = ""
                item.resultJson = null
            }
        }
        nativeWorkerCurrentItemId = ""
        writeNativeWorkerSnapshot(
            isRunning = false,
            isPaused = false,
            currentItemId = "",
            message = "Android background time limit reached",
            includeItems = true,
        )
        // Cancellation and the final recovery snapshot were handled above.
        // Only tear down the foreground-service resources here.
        stopForegroundService(cancelNativeWorker = false)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val progressChannel = NotificationChannel(
                CHANNEL_ID,
                "Download Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows download progress"
                setShowBadge(false)
            }
            val alertChannel = NotificationChannel(
                ALERT_CHANNEL_ID,
                "Download Alerts",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Important download status and actions that need attention"
                enableVibration(true)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(progressChannel)
            manager.createNotificationChannel(alertChannel)
        }
    }

    private fun startForegroundService() {
        val notification = buildNotification(0, 0)
        startDataSyncForeground(NOTIFICATION_ID, notification)

        isRunning = true
        lastNotificationSignature = null
        ensureWakeLock()
        pushWidgetState(0, 0)
    }

    private fun startNativeWorker(requestsJson: String, settingsJson: String) {
        flushNativeAlbumReplayGainJournalIfComplete()
        val requestedRunId = parseNativeWorkerRunId(settingsJson)
        val requests = try {
            parseNativeDownloadRequests(requestsJson)
        } catch (e: Exception) {
            if (nativeWorkerJob?.isActive != true) {
                nativeWorkerRunId = requestedRunId
                writeNativeWorkerSnapshot(
                    isRunning = false,
                    isPaused = false,
                    currentItemId = "",
                    message = "Invalid native queue payload: ${e.message}",
                    settingsJson = settingsJson,
                    includeItems = true
                )
                stopForegroundService(cancelNativeWorker = false)
            }
            return
        }
        nativeWorkerRunId = requestedRunId
        cancelNativeVerificationNotification()
        // Abort the previous run's in-flight work before the shared flags are
        // reset for the new run: the coroutine cancel below cannot interrupt a
        // blocking native download by itself.
        synchronized(nativeWorkerItems) {
            for (item in nativeWorkerItems) {
                if (item.status == "preparing" ||
                    item.status == "downloading" ||
                    item.status == "finalizing"
                ) {
                    try {
                        coreBackend.cancelDownload(item.itemId)
                    } catch (_: Exception) {
                    }
                }
            }
        }
        NativeDownloadFinalizer.cancelActiveWork()
        nativeWorkerRequestChannel?.close()
        pendingNativeItemsSnapshotJob?.cancel()
        pendingNativeItemsSnapshotJob = null
        nativeWorkerGeneration++
        val generation = nativeWorkerGeneration
        nativeWorkerJob?.cancel(CancellationException("Native queue replaced"))
        synchronized(nativeWorkerItems) {
            nativeWorkerPaused = false
            nativeWorkerResumePending = false
            nativeWorkerPausePendingIds.clear()
        }
        nativeWorkerNetworkPaused = false
        nativeWorkerVerificationPaused = false
        nativeWorkerCancelRequested = false
        unregisterNativeWorkerNetworkCallback()
        val workerSettings = try {
            JSONObject(settingsJson)
        } catch (_: Exception) {
            JSONObject()
        }
        val streamingPreparation = workerSettings.optBoolean(
            "preparation_streaming",
            false,
        )
        nativeWorkerPreparationComplete = !streamingPreparation
        queueCount = workerSettings
            .optInt("expected_total_items", requests.size)
            .coerceAtLeast(requests.size)
        synchronized(nativeReplayGainEntries) {
            nativeReplayGainEntries.clear()
        }
        synchronized(nativeReplayGainRequestAlbumKeys) {
            nativeReplayGainRequestAlbumKeys.clear()
            for (request in requests) {
                try {
                    val key = NativeDownloadFinalizer.replayGainAlbumKey(
                        request.requestJson,
                        request.itemJson
                    )
                    if (key.isNotBlank()) {
                        nativeReplayGainRequestAlbumKeys[request.itemId] = key
                    }
                } catch (_: Exception) {
                }
            }
        }
        synchronized(nativeWorkerItems) {
            nativeWorkerItems.clear()
            nativeWorkerTerminalStatuses.clear()
            nativeWorkerItems.addAll(
                requests.map {
                    NativeWorkerItem(
                        itemId = it.itemId,
                        trackName = it.trackName,
                        artistName = it.artistName,
                    )
                }
            )
        }
        configureNativeWorkerNetworkPolicy(settingsJson)
        writeNativeReplayGainJournal()
        currentStatus = "preparing"
        currentTrackName = requests.firstOrNull()?.trackName ?: ""
        currentArtistName = requests.firstOrNull()?.artistName ?: ""
        lastProgress = 0L
        lastTotal = 0L
        startForegroundService()
        writeNativeWorkerSnapshot(
            isRunning = true,
            isPaused = isNativeWorkerPaused(),
            currentItemId = "",
            message = if (isNativeWorkerPaused()) nativeWorkerPauseMessage() else "Starting",
            settingsJson = settingsJson,
            includeItems = true
        )

        val requestChannel = Channel<NativeDownloadRequest>(Channel.UNLIMITED)
        nativeWorkerRequestChannel = requestChannel
        for (request in requests) {
            requestChannel.trySend(request)
        }
        if (!streamingPreparation) {
            requestChannel.close()
        }
        nativeWorkerJob = serviceScope.launch {
            runNativeWorkerConcurrent(requestChannel, settingsJson, generation)
        }
    }

    private fun parseNativeWorkerRunId(settingsJson: String): String {
        return try {
            JSONObject(settingsJson).optString("run_id", "")
        } catch (_: Exception) {
            ""
        }
    }

    private fun appendNativeWorkerRequests(requestsJson: String, runId: String) {
        if (runId.isBlank() || runId != nativeWorkerRunId || nativeWorkerPreparationComplete) {
            return
        }
        val channel = nativeWorkerRequestChannel ?: return
        val requests = try {
            parseNativeDownloadRequests(requestsJson)
        } catch (e: Exception) {
            android.util.Log.w(
                "DownloadService",
                "Ignoring invalid native queue append: ${e.message}",
            )
            return
        }
        if (requests.isEmpty()) return

        val knownIds = synchronized(nativeWorkerItems) {
            nativeWorkerItems.mapTo(mutableSetOf()) { it.itemId }.apply {
                addAll(nativeWorkerTerminalStatuses.keys)
            }
        }
        val additions = requests.filter { knownIds.add(it.itemId) }
        if (additions.isEmpty()) return

        synchronized(nativeReplayGainRequestAlbumKeys) {
            for (request in additions) {
                try {
                    val key = NativeDownloadFinalizer.replayGainAlbumKey(
                        request.requestJson,
                        request.itemJson,
                    )
                    if (key.isNotBlank()) {
                        nativeReplayGainRequestAlbumKeys[request.itemId] = key
                    }
                } catch (_: Exception) {
                }
            }
        }
        synchronized(nativeWorkerItems) {
            nativeWorkerItems.addAll(
                additions.map {
                    NativeWorkerItem(
                        itemId = it.itemId,
                        trackName = it.trackName,
                        artistName = it.artistName,
                    )
                },
            )
            queueCount = maxOf(queueCount, nativeWorkerItems.size)
        }
        for (request in additions) {
            channel.trySend(request)
        }
        writeNativeReplayGainJournal()
        scheduleNativeWorkerItemsSnapshot(
            isRunning = nativeWorkerJob?.isActive == true,
            isPaused = isNativeWorkerPaused(),
            currentItemId = nativeWorkerCurrentItemId,
            message = "Preparing queue",
        )
    }

    private fun finishNativeWorkerPreparation(runId: String) {
        if (runId.isBlank() || runId != nativeWorkerRunId) return
        nativeWorkerPreparationComplete = true
        nativeWorkerRequestChannel?.close()
        flushScheduledNativeWorkerItemsSnapshot(
            isRunning = nativeWorkerJob?.isActive == true,
            isPaused = isNativeWorkerPaused(),
            currentItemId = nativeWorkerCurrentItemId,
            message = "Queue prepared",
        )
        writeNativeAlbumReplayGainIfComplete()
    }

    private fun acknowledgeNativeWorkerItems(runId: String, itemIdsJson: String) {
        if (runId.isBlank() || runId != nativeWorkerRunId || itemIdsJson.isBlank()) return
        val itemIds = try {
            val array = JSONArray(itemIdsJson)
            mutableSetOf<String>().apply {
                for (index in 0 until array.length()) {
                    val itemId = array.optString(index, "").trim()
                    if (itemId.isNotEmpty()) {
                        add(itemId)
                    }
                }
            }
        } catch (_: Exception) {
            return
        }
        if (itemIds.isEmpty()) return

        var releasedAny = false
        synchronized(nativeWorkerItems) {
            val iterator = nativeWorkerItems.iterator()
            while (iterator.hasNext()) {
                val item = iterator.next()
                if (item.itemId !in itemIds || !NativeWorkerPolicy.isTerminalStatus(item.status)) {
                    continue
                }
                nativeWorkerTerminalStatuses[item.itemId] = item.status
                iterator.remove()
                releasedAny = true
            }
        }
        if (!releasedAny) return
        scheduleNativeWorkerItemsSnapshot(
            isRunning = nativeWorkerJob?.isActive == true,
            isPaused = isNativeWorkerPaused(),
            currentItemId = nativeWorkerCurrentItemId,
            message = "Queue updated",
        )
    }

    internal fun isNativeWorkerPaused(): Boolean =
        nativeWorkerPaused ||
            nativeWorkerNetworkPaused ||
            nativeWorkerVerificationPaused

    internal fun nativeWorkerPauseMessage(): String = when {
        nativeWorkerVerificationPaused -> "Verification required"
        nativeWorkerNetworkPaused -> "Waiting for Wi-Fi"
        else -> "Paused"
    }

    internal fun cancelActiveNativeItemForPause() {
        cancelConcurrentNativeDownloadsForPause()
    }

    private fun parseNativeDownloadRequests(requestsJson: String): List<NativeDownloadRequest> {
        val array = JSONArray(requestsJson)
        val requests = ArrayList<NativeDownloadRequest>(array.length())
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val wrapperVersion = item.optInt("contract_version", -1)
            if (wrapperVersion != NATIVE_WORKER_CONTRACT_VERSION) {
                throw IllegalArgumentException(
                    "unsupported native worker item contract v$wrapperVersion at index $index"
                )
            }
            val itemId = item.optString("item_id").trim()
            val requestJson = item.optString("request_json").trim()
            if (itemId.isEmpty() || requestJson.isEmpty()) {
                continue
            }
            val request = JSONObject(requestJson)
            validateNativeDownloadRequest(itemId, request)
            val itemJson = item.optString("item_json").trim()
            requests.add(
                NativeDownloadRequest(
                    itemId = itemId,
                    requestJson = requestJson,
                    trackName = item.optString("track_name"),
                    artistName = item.optString("artist_name"),
                    itemJson = itemJson
                )
            )
        }
        return requests
    }

    private fun validateNativeDownloadRequest(itemId: String, request: JSONObject) {
        val requestVersion = request.optInt("contract_version", -1)
        if (requestVersion != NATIVE_WORKER_CONTRACT_VERSION) {
            throw IllegalArgumentException(
                "unsupported native worker request contract v$requestVersion for $itemId"
            )
        }

        val requestItemId = request.optString("item_id", "").trim()
        if (requestItemId != itemId) {
            throw IllegalArgumentException("native worker item id mismatch for $itemId")
        }

        val required = listOf("service", "track_name", "quality", "storage_mode")
        val missing = required.filter { request.optString(it, "").trim().isEmpty() }
        if (missing.isNotEmpty()) {
            throw IllegalArgumentException(
                "native worker request for $itemId missing fields: ${missing.joinToString()}"
            )
        }
    }

    private fun nativeWorkerConcurrency(settingsJson: String): Int {
        return try {
            JSONObject(settingsJson).optInt("concurrent_downloads", 1).coerceIn(1, 3)
        } catch (_: Exception) {
            1
        }
    }

    private fun nativeRequestProviderKey(request: NativeDownloadRequest): String {
        return try {
            val payload = JSONObject(request.requestJson)
            payload.optString("download_provider", "")
                .ifBlank { payload.optString("service", "") }
                .trim()
                .lowercase()
                .ifBlank { "default" }
        } catch (_: Exception) {
            "default"
        }
    }

    private fun nativeRequestProviderConcurrency(request: NativeDownloadRequest): Int {
        return try {
            JSONObject(request.requestJson)
                .optInt("network_concurrency_limit", 3)
                .coerceIn(1, 3)
        } catch (_: Exception) {
            3
        }
    }

    private fun cancelConcurrentNativeDownloadsForPause(excludeItemId: String = "") {
        val ids = synchronized(nativeWorkerItems) {
            nativeWorkerItems
                .filter {
                    it.itemId != excludeItemId &&
                        it.itemId !in nativeWorkerPausePendingIds &&
                        (it.status == "preparing" ||
                            it.status == "downloading" ||
                            it.status == "finalizing")
                }
                .map { item ->
                    nativeWorkerPausePendingIds.add(item.itemId)
                    item.status = "queued"
                    item.progress = 0.0
                    item.bytesReceived = 0L
                    item.bytesTotal = 0L
                    item.error = ""
                    item.itemId
                }
        }
        for (itemId in ids) {
            try {
                coreBackend.cancelDownload(itemId)
            } catch (_: Exception) {
            }
        }
        if (ids.isNotEmpty()) {
            NativeDownloadFinalizer.cancelActiveWork()
        }
    }

    private fun finishNativePauseCancellation(itemId: String, generation: Long) {
        synchronized(nativeWorkerItems) {
            if (generation != nativeWorkerGeneration) return
            nativeWorkerPausePendingIds.remove(itemId)
            // Resume may arrive before the blocking download unwinds. Keep the
            // pause reason until every cancelled attempt has decided to retry.
            if (nativeWorkerResumePending && nativeWorkerPausePendingIds.isEmpty()) {
                nativeWorkerResumePending = false
                nativeWorkerPaused = false
            }
        }
    }

    private suspend fun processConcurrentNativeRequest(
        request: NativeDownloadRequest,
        settingsJson: String,
        generation: Long,
        networkSemaphore: Semaphore,
        providerSemaphore: Semaphore,
        finalizerMutex: Mutex,
        rateLimitAttempts: ConcurrentHashMap<String, Int>,
    ) {
        while (!nativeWorkerCancelRequested && generation == nativeWorkerGeneration) {
            while (isNativeWorkerPaused() &&
                !nativeWorkerCancelRequested &&
                generation == nativeWorkerGeneration
            ) {
                delay(500)
            }
            if (nativeWorkerCancelRequested || generation != nativeWorkerGeneration) return

            var progressInitialized = false
            var retryCurrentRequest = false
            var directoryScope: AutoCloseable? = null
            var failureStage = "preparing output directory"
            try {
                directoryScope = coreBackend.openDownloadDirectoryForRequest(request.requestJson)
                // Acquire the provider permit first. If several requests from
                // one provider are queued, they must not occupy every global
                // network slot while waiting for that provider's lower limit.
                val response = providerSemaphore.withPermit {
                    networkSemaphore.withPermit {
                        if (isNativeWorkerPaused() ||
                            nativeWorkerCancelRequested ||
                            generation != nativeWorkerGeneration
                        ) {
                            throw CancellationException("Native queue paused")
                        }
                        nativeWorkerCurrentItemId = request.itemId
                        currentTrackName = request.trackName
                        currentArtistName = request.artistName
                        currentStatus = "preparing"
                        lastProgress = 0L
                        lastTotal = 0L
                        updateNotification(0L, 0L)
                        updateNativeWorkerItem(request.itemId) {
                            it.status = "preparing"
                            it.progress = 0.0
                            it.bytesReceived = 0L
                            it.bytesTotal = 0L
                            it.error = ""
                            it.resultJson = null
                        }
                        writeNativeWorkerSnapshot(
                            isRunning = true,
                            isPaused = false,
                            currentItemId = request.itemId,
                            message = "Preparing",
                            settingsJson = settingsJson,
                            includeItems = true,
                        )
                        coreBackend.initItemProgress(request.itemId)
                        progressInitialized = true
                        currentStatus = "downloading"
                        updateNativeWorkerItem(request.itemId) {
                            it.status = "downloading"
                        }
                        failureStage = "downloading"
                        try {
                            SafDownloadHandler.handle(this, request.requestJson, coreBackend)
                        } finally {
                            updateNativeWorkerItemProgress(request.itemId)
                            try {
                                coreBackend.clearItemProgress(request.itemId)
                            } catch (_: Exception) {
                            }
                            progressInitialized = false
                        }
                    }
                }
                if (generation != nativeWorkerGeneration) return

                var result = JSONObject(response)
                if (result.optBoolean("success", false)) {
                    failureStage = "finalizing"
                    currentStatus = "finalizing"
                    updateNativeWorkerItem(request.itemId) {
                        it.status = "finalizing"
                        it.progress = 0.95
                        it.error = ""
                    }
                    writeNativeWorkerSnapshot(
                        isRunning = true,
                        isPaused = false,
                        currentItemId = request.itemId,
                        message = "Finalizing",
                        settingsJson = settingsJson,
                    )
                    // Finalization is intentionally independent from the
                    // network semaphore: the next transfer can begin while
                    // metadata/FFmpeg/SAF work remains serialized here.
                    result = finalizerMutex.withLock {
                        NativeDownloadFinalizer.finalize(
                            this,
                            request.itemId,
                            request.requestJson,
                            request.itemJson,
                            result,
                            settingsJson,
                        ) {
                            nativeWorkerCancelRequested ||
                                isNativeWorkerPaused() ||
                                generation != nativeWorkerGeneration
                        }
                    }
                }

                if (result.optBoolean("success", false)) {
                    result.optJSONObject("replaygain")?.let { replayGain ->
                        synchronized(nativeReplayGainEntries) {
                            nativeReplayGainEntries.add(JSONObject(replayGain.toString()))
                        }
                    }
                    updateNativeWorkerItem(request.itemId) {
                        it.status = "completed"
                        it.progress = 1.0
                        it.error = ""
                        it.resultJson = result
                    }
                    writeNativeReplayGainJournal()
                    if (nativeWorkerPreparationComplete) {
                        writeNativeAlbumReplayGainIfComplete()
                    }
                } else {
                    result.put("failure_stage", failureStage)
                    val errorType = result.optString("error_type")
                    val errorMessage = result.optString("error")
                    if (errorType == "cancelled" &&
                        isNativeWorkerPaused() &&
                        !nativeWorkerCancelRequested
                    ) {
                        updateNativeWorkerItem(request.itemId) {
                            it.status = "queued"
                            it.progress = 0.0
                            it.bytesReceived = 0L
                            it.bytesTotal = 0L
                            it.error = ""
                            it.resultJson = null
                        }
                        retryCurrentRequest = true
                    } else if (NativeWorkerPolicy.shouldRetryRateLimit(
                            errorType = errorType,
                            errorMessage = errorMessage,
                            attempts = rateLimitAttempts[request.itemId] ?: 0,
                        )
                    ) {
                        rateLimitAttempts.compute(request.itemId) { _, value ->
                            (value ?: 0) + 1
                        }
                        val delaySeconds = NativeWorkerPolicy.rateLimitDelaySeconds(
                            retryAfterSeconds = result
                                .optInt("retry_after_seconds", 0)
                                .takeIf { it > 0 },
                            errorMessage = errorMessage,
                        )
                        currentStatus = "rate_limited"
                        updateNativeWorkerItem(request.itemId) {
                            it.status = "queued"
                            it.progress = 0.0
                            it.bytesReceived = 0L
                            it.bytesTotal = 0L
                            it.error = "Rate limited, retrying in ${delaySeconds}s"
                            it.resultJson = null
                        }
                        writeNativeWorkerSnapshot(
                            isRunning = true,
                            isPaused = isNativeWorkerPaused(),
                            currentItemId = request.itemId,
                            message = "Rate limited, retrying in ${delaySeconds}s",
                            settingsJson = settingsJson,
                            includeItems = true,
                        )
                        delay(delaySeconds * 1000L)
                        retryCurrentRequest = true
                    } else if (NativeWorkerPolicy.isVerificationRequired(
                            errorType = errorType,
                            errorMessage = errorMessage,
                        )
                    ) {
                        nativeWorkerVerificationPaused = true
                        currentStatus = "verification_required"
                        updateNativeWorkerItem(request.itemId) {
                            it.status = "failed"
                            it.error = errorMessage
                            it.resultJson = result
                        }
                        cancelConcurrentNativeDownloadsForPause(request.itemId)
                        writeNativeReplayGainJournal()
                        writeNativeWorkerSnapshot(
                            isRunning = true,
                            isPaused = true,
                            currentItemId = request.itemId,
                            message = "Verification required",
                            lastResult = result,
                            settingsJson = settingsJson,
                            includeItems = true,
                        )
                        showNativeVerificationRequired(request, result)
                        updateNotification(0L, 0L)
                        retryCurrentRequest = true
                    } else {
                        updateNativeWorkerItem(request.itemId) {
                            it.status = if (errorType == "cancelled") "skipped" else "failed"
                            it.error = errorMessage
                            it.resultJson = result
                        }
                        writeNativeReplayGainJournal()
                    }
                }

                if (!retryCurrentRequest) {
                    writeNativeWorkerSnapshot(
                        isRunning = true,
                        isPaused = false,
                        currentItemId = request.itemId,
                        message = if (result.optBoolean("success", false)) "Completed" else "Failed",
                        lastResult = result,
                        settingsJson = settingsJson,
                        includeItems = true,
                    )
                }
            } catch (e: CancellationException) {
                if (nativeWorkerCancelRequested && generation == nativeWorkerGeneration) {
                    updateNativeWorkerItem(request.itemId) {
                        it.status = "skipped"
                        it.error = "Cancelled"
                    }
                    throw e
                }
                if (isNativeWorkerPaused() && !nativeWorkerCancelRequested) {
                    updateNativeWorkerItem(request.itemId) {
                        it.status = "queued"
                        it.progress = 0.0
                        it.bytesReceived = 0L
                        it.bytesTotal = 0L
                        it.error = ""
                        it.resultJson = null
                    }
                    retryCurrentRequest = true
                } else {
                    throw e
                }
            } catch (e: Exception) {
                val errorMessage = "Native download failed during $failureStage: ${e.message ?: e.javaClass.simpleName}"
                val failure = JSONObject()
                    .put("success", false)
                    .put("error", errorMessage)
                    .put("failure_stage", failureStage)
                android.util.Log.w(
                    "DownloadService",
                    "Native item ${request.itemId} failed during $failureStage",
                    e,
                )
                updateNativeWorkerItem(request.itemId) {
                    it.status = "failed"
                    it.error = errorMessage
                    it.resultJson = failure
                }
                writeNativeReplayGainJournal()
                writeNativeWorkerSnapshot(
                    isRunning = true,
                    isPaused = false,
                    currentItemId = request.itemId,
                    message = errorMessage,
                    lastResult = failure,
                    settingsJson = settingsJson,
                    includeItems = true,
                )
            } finally {
                directoryScope?.close()
                finishNativePauseCancellation(request.itemId, generation)
                if (progressInitialized) {
                    updateNativeWorkerItemProgress(request.itemId)
                    try {
                        coreBackend.clearItemProgress(request.itemId)
                    } catch (_: Exception) {
                    }
                }
            }

            if (!retryCurrentRequest) {
                if (nativeWorkerCurrentItemId == request.itemId) {
                    nativeWorkerCurrentItemId = ""
                }
                return
            }
        }
    }

    private suspend fun runNativeWorkerConcurrent(
        requests: Channel<NativeDownloadRequest>,
        settingsJson: String,
        generation: Long,
    ) {
        val concurrency = nativeWorkerConcurrency(settingsJson)
        val networkSemaphore = Semaphore(concurrency)
        val finalizerMutex = Mutex()
        val providerSemaphores = ConcurrentHashMap<String, Semaphore>()
        val rateLimitAttempts = ConcurrentHashMap<String, Int>()
        val progressCoordinatorJob = startNativeWorkerProgressCoordinator(generation)

        try {
            supervisorScope {
                val workers = List(concurrency) {
                    launch {
                        for (request in requests) {
                            if (nativeWorkerCancelRequested ||
                                generation != nativeWorkerGeneration
                            ) {
                                break
                            }
                            val providerKey = nativeRequestProviderKey(request)
                            val providerLimit = minOf(
                                concurrency,
                                nativeRequestProviderConcurrency(request),
                            )
                            val providerSemaphore = providerSemaphores.computeIfAbsent(
                                providerKey,
                            ) {
                                Semaphore(providerLimit)
                            }
                            processConcurrentNativeRequest(
                                request = request,
                                settingsJson = settingsJson,
                                generation = generation,
                                networkSemaphore = networkSemaphore,
                                providerSemaphore = providerSemaphore,
                                finalizerMutex = finalizerMutex,
                                rateLimitAttempts = rateLimitAttempts,
                            )
                        }
                    }
                }
                workers.joinAll()
            }
        } finally {
            stopNativeWorkerProgressCoordinator(progressCoordinatorJob)
            if (generation == nativeWorkerGeneration) {
                cancelScheduledNativeWorkerItemsSnapshot()
                nativeWorkerRequestChannel = null
                nativeWorkerPreparationComplete = true
                if (!nativeWorkerCancelRequested) {
                    flushNativeAlbumReplayGainJournalIfComplete()
                }
                val counts = nativeWorkerCounts()
                val shouldNotifyCompletion = NativeWorkerPolicy.shouldNotifyQueueComplete(
                    cancelRequested = nativeWorkerCancelRequested,
                    completed = counts.completed,
                    failed = counts.failed,
                )
                currentStatus = "finalizing"
                releaseIdleDownloadMemory()
                writeNativeWorkerSnapshot(
                    isRunning = false,
                    isPaused = false,
                    currentItemId = "",
                    message = if (nativeWorkerCancelRequested) "Cancelled" else "Finished",
                    settingsJson = settingsJson,
                    includeItems = true,
                )
                stopForegroundService(cancelNativeWorker = false)
                if (shouldNotifyCompletion) {
                    showNativeQueueComplete(counts)
                }
            }
        }
    }

    private fun releaseIdleDownloadMemory() {
        try {
            // All workers and album tagging have finished. Release idle backend
            // resources once for the batch, preserving caches between tracks.
            coreBackend.releaseIdleResources()
        } catch (e: Exception) {
            android.util.Log.w("Mornye", "Failed to release idle download memory: ${e.message}")
        }
    }

    @Synchronized
    private fun ensureWakeLock() {
        wakeLock.ensure()
    }

    @Synchronized
    private fun releaseWakeLock() {
        wakeLock.release()
    }

    @Synchronized
    private fun stopForegroundService(cancelNativeWorker: Boolean = true) {
        cancelScheduledNativeWorkerItemsSnapshot()
        cancelNativeWorkerProgressCoordinator()
        if (cancelNativeWorker) {
            nativeWorkerCancelRequested = true
            nativeWorkerPreparationComplete = true
            nativeWorkerRequestChannel?.close()
            NativeDownloadFinalizer.cancelActiveWork()
            nativeWorkerJob?.cancel(CancellationException("Download service stopped"))
            nativeWorkerPaused = false
            nativeWorkerNetworkPaused = false
            nativeWorkerVerificationPaused = false
            cancelNativeVerificationNotification()
        }
        if (cancelNativeWorker && hasNativeWorkerState()) {
            writeNativeWorkerSnapshot(
                isRunning = false,
                isPaused = false,
                currentItemId = "",
                message = "Service stopped",
                includeItems = true
            )
        }
        unregisterNativeWorkerNetworkCallback()
        nativeWorkerDownloadNetworkMode = "any"
        nativeWorkerNetworkPaused = false
        nativeWorkerJob = null
        isRunning = false
        lastNotificationSignature = null
        widgetSignature = ""
        try {
            DownloadQueueWidgetProvider.push(this, running = false)
        } catch (e: Exception) {
            android.util.Log.w("DownloadService", "Widget clear failed: ${e.message}")
        }
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun hasNativeWorkerState(): Boolean {
        if (nativeWorkerRunId.isNotBlank()) return true
        synchronized(nativeWorkerItems) {
            return nativeWorkerItems.isNotEmpty()
        }
    }

    internal fun isNativeWorkerProgressActive(generation: Long): Boolean =
        generation == nativeWorkerGeneration &&
            !nativeWorkerCancelRequested &&
            isRunning

    internal fun nativeWorkerCurrentItemIdSnapshot(): String = nativeWorkerCurrentItemId

    @Synchronized
    internal fun updateNotification(progress: Long, total: Long) {
        if (!isRunning) return
        // Keep the foreground-service wake lock alive even when the visible
        // notification is unchanged and therefore deduplicated below.
        ensureWakeLock()

        val visibleProgress = when {
            total <= 0L -> "indeterminate"
            isPercentOnlyNotificationTotal(total) ->
                "percent:${(progress * 100 / total).toInt()}"
            else -> {
                // buildNotification renders one decimal place for MB and an
                // integer percentage. Suppress byte-level updates that would
                // produce the same visible notification.
                val progressTenthsMb = progress / (1024L * 1024L / 10L)
                val totalTenthsMb = total / (1024L * 1024L / 10L)
                val percent = (progress * 100 / total).toInt()
                "mb:${progressTenthsMb}:${totalTenthsMb}:$percent"
            }
        }
        val signature = "$currentTrackName|$currentArtistName|$currentStatus|$queueCount|$visibleProgress"
        if (signature == lastNotificationSignature) return
        lastNotificationSignature = signature

        val notification = buildNotification(progress, total)
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification)
        pushWidgetState(progress, total)
    }

    internal fun maintainNativeWorkerWakeLock() {
        if (isRunning) ensureWakeLock()
    }

    private fun pushWidgetState(progress: Long, total: Long) {
        val percent = if (total > 0) {
            ((progress * 100) / total).toInt().coerceIn(0, 100)
        } else {
            -1
        }
        val event = "$currentTrackName|$currentStatus|$queueCount"
        val signature = "$event|$percent"
        if (signature == widgetSignature) return
        // Track, status and queue changes publish at once; percent ticks are
        // spaced so the widget moves in small steps without per-byte IPC.
        val now = SystemClock.elapsedRealtime()
        if (widgetSignature.startsWith("$event|") && percent in 1..99 &&
            now - lastWidgetPushAt < WIDGET_PROGRESS_INTERVAL_MS) return
        widgetSignature = signature
        lastWidgetPushAt = now

        val subtitle = when (currentStatus) {
            "verification_required" -> "Verification required"
            "rate_limited" -> "Rate limited, retrying..."
            "waiting_wifi" -> "Waiting for Wi-Fi..."
            "finalizing" -> "Finalizing..."
            // The widget shows the queue as its own chip.
            else -> currentArtistName
        }
        try {
            DownloadQueueWidgetProvider.push(
                this,
                running = true,
                title = currentTrackName,
                subtitle = subtitle,
                percent = percent,
                queued = queueCount,
            )
        } catch (e: Exception) {
            android.util.Log.w("DownloadService", "Widget update failed: ${e.message}")
        }
    }

    private fun buildNotification(progress: Long, total: Long): Notification {
        val pendingIntent = mainActivityContentIntent()

        val title = if (queueCount > 1) {
            "Downloading $queueCount tracks"
        } else if (currentTrackName.isNotEmpty()) {
            currentTrackName
        } else {
            "Downloading..."
        }

        val text = if (currentStatus == "verification_required") {
            "Open the app to complete verification"
        } else if (currentStatus == "rate_limited") {
            "Rate limited, retrying shortly..."
        } else if (currentStatus == "waiting_wifi") {
            "Waiting for Wi-Fi..."
        } else if (currentStatus == "finalizing") {
            if (currentArtistName.isNotEmpty()) currentArtistName else "Embedding metadata..."
        } else if (currentStatus == "preparing" && total <= 0) {
            "Preparing download..."
        } else if (currentArtistName.isNotEmpty() && queueCount <= 1) {
            currentArtistName
        } else if (isPercentOnlyNotificationTotal(total)) {
            val progressPercent = (progress * 100 / total).toInt()
            "$progressPercent%"
        } else if (total > 0) {
            val progressPercent = (progress * 100 / total).toInt()
            val progressMB = progress / (1024.0 * 1024.0)
            val totalMB = total / (1024.0 * 1024.0)
            String.format("%.1f / %.1f MB (%d%%)", progressMB, totalMB, progressPercent)
        } else {
            "Downloading..."
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)

        if ((currentStatus == "preparing" || currentStatus == "downloading") && total <= 0) {
            builder.setProgress(0, 0, true)
        } else if (total > 0) {
            builder.setProgress(100, (progress * 100 / total).toInt(), false)
        } else {
            builder.setProgress(0, 0, false)
        }

        return builder.build()
    }

    private fun showNativeQueueComplete(counts: NativeWorkerCounts) {
        val pendingIntent = mainActivityContentIntent()
        val title = if (counts.failed > 0) {
            "Downloads Finished (${counts.completed} done, ${counts.failed} failed)"
        } else {
            "All Downloads Complete"
        }
        val body = if (counts.failed > 0) {
            "${counts.completed} downloaded, ${counts.failed} failed"
        } else {
            "${counts.completed} tracks downloaded successfully"
        }
        val builder = NotificationCompat.Builder(this, ALERT_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_STATUS)

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setDefaults(Notification.DEFAULT_SOUND or Notification.DEFAULT_VIBRATE)
        }

        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(DOWNLOAD_RESULT_NOTIFICATION_ID, builder.build())
        } catch (e: SecurityException) {
            android.util.Log.w(
                "DownloadService",
                "Completion notification permission denied: ${e.message}",
            )
        }
    }

    private fun showNativeVerificationRequired(request: NativeDownloadRequest, result: JSONObject) {
        val extensionId = result.optString("service").trim().ifEmpty {
            JSONObject(request.requestJson).optString("service").trim()
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            VERIFICATION_REQUIRED_NOTIFICATION_ID,
            VerificationNotificationIntent.create(this, extensionId, request.itemId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = NotificationCompat.Builder(this, ALERT_CHANNEL_ID)
            .setContentTitle("Verification required")
            .setContentText("Open the app to complete verification and resume downloads")
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_ERROR)

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setDefaults(Notification.DEFAULT_SOUND or Notification.DEFAULT_VIBRATE)
        }

        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(VERIFICATION_REQUIRED_NOTIFICATION_ID, builder.build())
        } catch (e: SecurityException) {
            android.util.Log.w(
                "DownloadService",
                "Verification notification permission denied: ${e.message}",
            )
        }
    }

    private fun cancelNativeVerificationNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.cancel(VERIFICATION_REQUIRED_NOTIFICATION_ID)
    }

    override fun onDestroy() {
        cancelScheduledNativeWorkerItemsSnapshot()
        unregisterNativeWorkerNetworkCallback()
        nativeWorkerCancelRequested = true
        nativeWorkerPreparationComplete = true
        nativeWorkerRequestChannel?.close()
        NativeDownloadFinalizer.cancelActiveWork()
        nativeWorkerJob?.cancel(CancellationException("Download service destroyed"))
        if (hasNativeWorkerState()) {
            writeNativeWorkerSnapshot(
                isRunning = false,
                isPaused = false,
                currentItemId = "",
                message = "Service destroyed",
                includeItems = true
            )
        }
        serviceScope.cancel()
        isRunning = false
        releaseWakeLock()
        super.onDestroy()
    }
}
