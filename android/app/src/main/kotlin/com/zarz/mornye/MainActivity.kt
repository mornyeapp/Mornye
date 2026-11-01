package com.zarz.mornye

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServicePlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File
import java.util.LinkedHashMap
import java.util.concurrent.atomic.AtomicReference

class MainActivity: FlutterFragmentActivity() {
    // Mirrors audio_service's AudioServiceFragmentActivity: the shared engine
    // is owned by AudioServicePlugin's FlutterEngineCache. Without the
    // cached-engine-id + shouldDestroyEngineWithHost overrides, the activity
    // (via createFlutterFragment's destroyEngineWithFragment) destroys the
    // provided engine on exit while it stays registered in the cache; when
    // AudioService later stops, disposeFlutterEngine() destroys it a second
    // time and crashes with "FlutterJNI is not attached to native".
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        return AudioServicePlugin.getFlutterEngine(context)
    }

    override fun getCachedEngineId(): String {
        AudioServicePlugin.getFlutterEngine(this)
        return AudioServicePlugin.getFlutterEngineId()
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    private val CHANNEL = "com.zarz.mornye/backend"
    private val LARGE_JSON_RESULT_FILE_KEY = "__json_file"
    private val LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES = 256 * 1024
    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    internal var backendChannel: MethodChannel? = null
    internal var audioOutputChannel: MethodChannel? = null
    internal var concertCalendarChannel: MethodChannel? = null
    internal val coreBackend: CoreBackend by lazy { createCoreBackend(applicationContext) }
    private val nativeBackendMethods = setOf(
        "isAndroidTv",
        "getAndroidSdkVersion",
        "setScreenAwake",
        "isCharging",
        "getBackendImplementations",
        "ensureInstallMarker",
        "prepareRuntimeState",
        "downloadByStrategy",
        "runPostProcessingV2",
        "readAudioMetadata",
        "readFileMetadata",
        "checkHiResAuthenticity",
        "editFileMetadata",
        "reEnrichFile",
        "setLibraryCoverCacheDir",
        "scanLibraryFolderToNDJSONFile",
        "scanLibraryFolderIncremental",
        "scanSafTreeToNDJSONFile",
        "scanSafTreeIncremental",
        "getLibraryScanProgress",
        "getLibraryScanExitInfo",
        "getPendingAppCrash",
        "getLatestAppCrash",
        "markAppCrashShown",
        "dismissAppCrash",
        "recordAppRuntimeError",
        "cancelLibraryScan",
        "pauseLibraryScan",
        "resumeLibraryScan",
        "parseCueSheet",
        "pickSafTree",
        "readSetupFolderSelection",
        "acknowledgeSetupFolderSelection",
        "processPendingExtensionCallbacks",
        "safExists",
        "safExistsBatch",
        "isSafTreeAccessible",
        "probeSafTreeReadAccess",
        "safDelete",
        "safStat",
        "resolveSafFile",
        "inspectSafFiles",
        "safCopyToTemp",
        "safOpenPlaybackLease",
        "safClosePlaybackLease",
        "openContentUri",
        "shareContentUri",
        "getSafFileModTimes",
        "safCreateFromPath",
        "safWriteSidecarFromPath",
        "safCreateIfAbsentFromPath",
        "safCreateUniqueFromPath",
        "safCreateCollisionAwareFromPath",
        "writeTempToSaf",
        "writeSafSidecarLrc",
        "downloadCoverToFile",
        "extractCoverToFile",
        "rewriteSplitArtistTags",
        "writeM4AFreeformTags",
        "ensureAC4Config",
        "writeAC4Metadata",
        "releaseMemory",
        "releaseMemoryUnderPressure",
        "startDownloadService",
        "stopDownloadService",
        "updateDownloadServiceProgress",
        "isDownloadServiceRunning",
        "startBackgroundWork",
        "updateBackgroundWork",
        "stopBackgroundWork",
        "startLinkConnectionService",
        "stopLinkConnectionService",
        "startNativeDownloadWorker",
        "appendNativeDownloadWorkerRequests",
        "finishNativeDownloadWorkerPreparation",
        "acknowledgeNativeDownloadWorkerItems",
        "pauseNativeDownloadWorker",
        "resumeNativeDownloadWorker",
        "cancelNativeDownloadWorker",
        "getNativeDownloadWorkerSnapshot",
        "consumeVerificationNotification",
        "exitApp",
    )
    private var libraryStorageReceiver: BroadcastReceiver? = null
    internal val pendingSessionGrantEvents = mutableListOf<Map<String, Any>>()
    internal var pendingVerificationNotification: String? = null
    internal val setupFolderPickerStore by lazy {
        SetupFolderPickerStore(getSharedPreferences("setup_folder_picker", Context.MODE_PRIVATE))
    }
    internal val safScanLock = Any()
    internal var safScanProgress = SafScanProgress()
    internal var downloadProgressStreamJob: Job? = null
    internal var downloadProgressConnection: AtomicReference<CoreDownloadProgress?>? = null
    internal var downloadProgressEventSink: EventChannel.EventSink? = null
    internal var lastDownloadProgressPayload: String? = null
    internal var lastDownloadProgressSeq = 0L
    internal var libraryScanProgressStreamJob: Job? = null
    internal var libraryScanProgressEventSink: EventChannel.EventSink? = null
    internal var lastLibraryScanProgressPayload: String? = null
    internal var flutterBackCallback: OnBackPressedCallback? = null
    @Volatile internal var safScanCancel = false
    @Volatile internal var safScanPaused = false
    @Volatile internal var safScanActive = false
    internal val safTreeLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { activityResult ->
        handleSafTreeResult(activityResult)
    }

    data class SafScanProgress(
        var totalFiles: Int = 0,
        var scannedFiles: Int = 0,
        var currentFile: String = "",
        var errorCount: Int = 0,
        var progressPct: Double = 0.0,
        var isComplete: Boolean = false,
        /** Failed documents and why, up to [REPORTED_SCAN_FAILURES]. The list
         * is replaced, never changed, so a snapshot can be read unlocked. */
        var failures: List<Pair<String, String>> = emptyList(),
    )

    companion object {
        internal val extensionAuthCallbacks = ExtensionAuthCallbacks()
        // audio_service keeps the engine across Activity recreation. Retain
        // its outstanding picker reply for the same lifetime, not the Activity.
        internal var pendingSafTreeResult: MethodChannel.Result? = null
    }

    class ImpellerAwareFlutterFragment : FlutterFragment() {
        override fun getFlutterShellArgs(): FlutterShellArgs {
            val args = super.getFlutterShellArgs()
            for (argument in flutterRendererShellArgs()) {
                args.add(argument)
            }
            return args
        }
    }

    override fun createFlutterFragment(): FlutterFragment {
        val backgroundMode = getBackgroundMode()
        val renderMode = getRenderMode()
        val transparencyMode =
            if (backgroundMode == BackgroundMode.opaque) TransparencyMode.opaque else TransparencyMode.transparent
        val shouldDelayFirstAndroidViewDraw = renderMode == RenderMode.surface

        getCachedEngineId()?.let { cachedEngineId ->
            return FlutterFragment.CachedEngineFragmentBuilder(
                ImpellerAwareFlutterFragment::class.java,
                cachedEngineId
            )
                .renderMode(renderMode)
                .transparencyMode(transparencyMode)
                .handleDeeplinking(shouldHandleDeeplinking())
                .shouldAttachEngineToActivity(shouldAttachEngineToActivity())
                .destroyEngineWithFragment(shouldDestroyEngineWithHost())
                .shouldDelayFirstAndroidViewDraw(shouldDelayFirstAndroidViewDraw)
                .shouldAutomaticallyHandleOnBackPressed(true)
                .build()
        }

        getCachedEngineGroupId()?.let { cachedEngineGroupId ->
            return FlutterFragment.NewEngineInGroupFragmentBuilder(
                ImpellerAwareFlutterFragment::class.java,
                cachedEngineGroupId
            )
                .dartEntrypoint(getDartEntrypointFunctionName())
                .initialRoute(getInitialRoute())
                .handleDeeplinking(shouldHandleDeeplinking())
                .renderMode(renderMode)
                .transparencyMode(transparencyMode)
                .shouldAttachEngineToActivity(shouldAttachEngineToActivity())
                .shouldDelayFirstAndroidViewDraw(shouldDelayFirstAndroidViewDraw)
                .shouldAutomaticallyHandleOnBackPressed(true)
                .build()
        }

        return FlutterFragment.NewEngineFragmentBuilder(ImpellerAwareFlutterFragment::class.java)
            .dartEntrypoint(getDartEntrypointFunctionName())
            .dartLibraryUri(getDartEntrypointLibraryUri() ?: "")
            .dartEntrypointArgs(getDartEntrypointArgs() ?: emptyList())
            .initialRoute(getInitialRoute())
            .appBundlePath(getAppBundlePath())
            .flutterShellArgs(FlutterShellArgs.fromIntent(intent))
            .handleDeeplinking(shouldHandleDeeplinking())
            .renderMode(renderMode)
            .transparencyMode(transparencyMode)
            .shouldAttachEngineToActivity(shouldAttachEngineToActivity())
            .shouldDelayFirstAndroidViewDraw(shouldDelayFirstAndroidViewDraw)
            .shouldAutomaticallyHandleOnBackPressed(true)
            .build()
    }

    private fun parseJsonValue(value: Any?): Any? {
        return when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> {
                val map = LinkedHashMap<String, Any?>()
                val keys = value.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    map[key] = parseJsonValue(value.opt(key))
                }
                map
            }
            is JSONArray -> {
                val list = ArrayList<Any?>()
                for (i in 0 until value.length()) {
                    list.add(parseJsonValue(value.opt(i)))
                }
                list
            }
            is Number, is Boolean, is String -> value
            else -> value.toString()
        }
    }

    internal fun parseJsonPayload(payload: String): Any {
        return try {
            parseJsonValue(JSONTokener(payload).nextValue()) ?: payload
        } catch (_: Exception) {
            payload
        }
    }

    internal fun bridgeJsonResult(payload: String): Any {
        // Decide on char count where possible: UTF-8 size is >= length and
        // <= 3*length, so only the ambiguous band needs the full encode —
        // avoids duplicating multi-MB payloads just to measure them.
        val definitelySmall = payload.length * 3 < LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES
        val definitelyLarge = payload.length >= LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES
        if (definitelySmall ||
            (!definitelyLarge &&
                payload.toByteArray(Charsets.UTF_8).size < LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES)
        ) {
            return payload
        }

        return try {
            val file = File(cacheDir, "bridge_json_${System.nanoTime()}.json")
            file.writeText(payload, Charsets.UTF_8)
            mapOf(LARGE_JSON_RESULT_FILE_KEY to file.absolutePath)
        } catch (e: Exception) {
            android.util.Log.w(
                "Mornye",
                "Failed to spill large bridge JSON result to file: ${e.message}",
            )
            payload
        }
    }

    /**
     * Streams a JSON payload piecewise to a cache spill file so large scan
     * results never materialize on the Java heap. [result] hands back the
     * payload inline when it is small (same contract as [bridgeJsonResult]),
     * otherwise the spill-file map.
     */
    internal inner class SpillJsonWriter {
        val file = File(cacheDir, "bridge_json_${System.nanoTime()}.json")
        private val writer = file.bufferedWriter(Charsets.UTF_8)

        fun raw(fragment: String) = writer.write(fragment)

        fun result(): Any {
            writer.close()
            if (file.length() < LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES) {
                val payload = file.readText(Charsets.UTF_8)
                file.delete()
                return payload
            }
            return mapOf(LARGE_JSON_RESULT_FILE_KEY to file.absolutePath)
        }

        fun abandon() {
            try { writer.close() } catch (_: Exception) {}
            try { file.delete() } catch (_: Exception) {}
        }
    }

    // Disable Flutter's built-in deep linking so that incoming ACTION_VIEW URLs
    // (Spotify, Deezer, Tidal, YouTube Music) are NOT forwarded to GoRouter.
    // We handle these URLs ourselves via receive_sharing_intent + ShareIntentService.
    override fun shouldHandleDeeplinking(): Boolean = false

    // Bridge spill files and SAF temp copies are deleted after use on the
    // normal path, but a process kill mid-operation orphans them in cacheDir
    // forever (names embed nanoTime, so nothing overwrites them). Sweep
    // leftovers from previous sessions; the 1h age guard protects in-flight
    // files from concurrent work in this session.
    private fun sweepStaleCacheFiles() {
        scope.launch(Dispatchers.IO) {
            try {
                val cutoff = System.currentTimeMillis() - 60 * 60 * 1000L
                cacheDir.listFiles()?.forEach { file ->
                    val stale = file.isFile &&
                        file.lastModified() < cutoff &&
                        (file.name.startsWith("bridge_json_") ||
                            file.name.startsWith("saf_") ||
                            file.name.startsWith("native_saf_") ||
                            file.name.startsWith("ms_"))
                    if (stale) file.delete()
                }
            } catch (_: Exception) {}
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        requestedOrientation = if (isTelevisionDevice()) {
            ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        } else {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        // Ensure the shared audio_service engine exists before the activity
        // delegate looks it up by cached id (see getCachedEngineId above).
        AudioServicePlugin.getFlutterEngine(this)
        super.onCreate(savedInstanceState)
        handleVerificationNotificationIntent(intent)
        handleExtensionOAuthIntent(intent)
        PlayerWidgetBridge.handleIntent(intent)
    }

    private fun isTelevisionDevice(): Boolean =
        resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TELEVISION)

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleVerificationNotificationIntent(intent)
        handleExtensionOAuthIntent(intent)
        PlayerWidgetBridge.handleIntent(intent)
    }

    internal fun reportLibraryScanError(path: String, operation: String, message: String) {
        android.util.Log.e("Mornye", "Library scan: $operation [$path]: $message")
        recordSafScanFailure(path, message)
        val payload = mapOf(
            "path" to path,
            "operation" to operation,
            "message" to message,
        )
        runOnUiThread {
            backendChannel?.invokeMethod("libraryScanError", payload)
        }
    }

    override fun onDestroy() {
        if (isFinishing) {
            val pending = pendingSafTreeResult
            pendingSafTreeResult = null
            pending?.success(null)
        }
        concertCalendarChannel?.setMethodCallHandler(null)
        concertCalendarChannel = null
        audioOutputChannel?.setMethodCallHandler(null)
        audioOutputChannel = null
        libraryStorageReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        libraryStorageReceiver = null
        // The backend belongs to the process/shared Flutter engine and download
        // service. Activity recreation must not shut it down (or wait for its
        // active scans/downloads on the UI thread).
        stopDownloadProgressStream()
        stopLibraryScanProgressStream()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Select and initialize the runtime before Flutter can dispatch a call.
        val selectedBackend = coreBackend
        sweepStaleCacheFiles()

        // Always-enabled back callback to ensure back presses reach Flutter.
        // Nested tab navigators can incorrectly set frameworkHandlesBack(false),
        // which disables Flutter's own OnBackPressedCallback and causes the
        // system default (finish activity) to run. This callback guarantees
        // popRoute is always forwarded to Flutter, where PopScope handles it.
        flutterBackCallback = object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                flutterEngine.navigationChannel.popRoute()
            }
        }
        onBackPressedDispatcher.addCallback(this, flutterBackCallback!!)

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        registerConcertCalendarChannel(messenger)
        registerAudioOutputChannel(messenger)

        registerProgressStreams(messenger)

        // Replaces the playback subset the engine registered without an
        // Activity (see SharedEngineChannels) with every backend method.
        val channel = MethodChannel(messenger, CHANNEL)
        backendChannel = channel
        registerLibraryStorageReceiver()
        if (pendingSessionGrantEvents.isNotEmpty()) {
            val events = pendingSessionGrantEvents.toList()
            pendingSessionGrantEvents.clear()
            for (event in events) {
                channel.invokeMethod("extensionSessionGrantCompleted", event)
            }
        }

        channel.setMethodCallHandler { call, result ->
            scope.launch {
                try {
                    if (call.method !in nativeBackendMethods && dispatchBackendApplication(call, result)) {
                        return@launch
                    }
                    when (call.method) {
                        "isAndroidTv" -> result.success(isTelevisionDevice())
                        "getAndroidSdkVersion" -> result.success(Build.VERSION.SDK_INT)
                        "processPendingExtensionCallbacks" -> {
                            processPendingExtensionCallbacks()
                            result.success(null)
                        }
                        "setScreenAwake" -> handleSetScreenAwake(call, result)
                        "isCharging" -> handleIsCharging(call, result)
                        "consumeVerificationNotification" -> handleConsumeVerificationNotification(call, result)
                        "ensureInstallMarker" -> handleEnsureInstallMarker(call, result)
                        "prepareRuntimeState" -> handlePrepareRuntimeState(call, result, selectedBackend)
                        "exitApp" -> handleExitApp(call, result)
                        "downloadByStrategy" -> handleDownloadByStrategy(call, result)
                        "getBackendImplementations" -> handleGetBackendImplementations(call, result)
                        "pickSafTree" -> {
                            launchSafTreePicker(call, result)
                        }
                        "readSetupFolderSelection" -> {
                            result.success(setupFolderPickerStore.read())
                        }
                        "acknowledgeSetupFolderSelection" -> {
                            setupFolderPickerStore.acknowledge(call.argument<String>("payload") ?: "")
                            result.success(null)
                        }
                        "safExists" -> handleSafExists(call, result)
                        "safExistsBatch" -> handleSafExistsBatch(call, result)
                        "probeSafTreeReadAccess" -> handleProbeSafTreeReadAccess(call, result)
                        "isSafTreeAccessible" -> handleIsSafTreeAccessible(call, result)
                        "safDelete" -> handleSafDelete(call, result)
                        "safStat" -> handleSafStat(call, result)
                        "resolveSafFile" -> handleResolveSafFile(call, result)
                        "inspectSafFiles" -> handleInspectSafFiles(call, result)
                        "safCopyToTemp" -> handleSafCopyToTemp(call, result)
                        "safOpenPlaybackLease" -> handleSafOpenPlaybackLease(call, result)
                        "safClosePlaybackLease" -> handleSafClosePlaybackLease(call, result)
                        "safCreateFromPath" -> handleSafCreateFromPath(call, result)
                        "safWriteSidecarFromPath" -> handleSafWriteSidecarFromPath(call, result)
                        "safCreateIfAbsentFromPath" -> handleSafCreateIfAbsentFromPath(call, result)
                        "safCreateUniqueFromPath" -> handleSafCreateUniqueFromPath(call, result)
                        "safCreateCollisionAwareFromPath" -> handleSafCreateCollisionAwareFromPath(call, result)
                        "openContentUri" -> handleOpenContentUri(call, result)
                        "shareContentUri" -> handleShareContentUri(call, result)
                        "rewriteSplitArtistTags" -> handleRewriteSplitArtistTags(call, result)
                        "readFileMetadata" -> handleReadFileMetadata(call, result, selectedBackend)
                        "checkHiResAuthenticity" -> handleCheckHiResAuthenticity(call, result)
                        "editFileMetadata" -> handleEditFileMetadata(call, result)
                        "writeM4AFreeformTags" -> handleWriteM4AFreeformTags(call, result)
                        "ensureAC4Config" -> handleEnsureAC4Config(call, result)
                        "writeAC4Metadata" -> handleWriteAC4Metadata(call, result)
                        "writeTempToSaf" -> handleWriteTempToSaf(call, result)
                        "writeSafSidecarLrc" -> handleWriteSafSidecarLrc(call, result)
                        "downloadCoverToFile" -> handleDownloadCoverToFile(call, result)
                        "extractCoverToFile" -> handleExtractCoverToFile(call, result)
                        "reEnrichFile" -> handleReEnrichFile(call, result)
                        "startDownloadService" -> handleStartDownloadService(call, result)
                        "stopDownloadService" -> {
                            DownloadService.stop(this@MainActivity)
                            result.success(null)
                        }
                        "updateDownloadServiceProgress" -> handleUpdateDownloadServiceProgress(call, result)
                        "isDownloadServiceRunning" -> {
                            result.success(DownloadService.isServiceRunning())
                        }
                        "startBackgroundWork" -> handleStartBackgroundWork(call, result)
                        "startLinkConnectionService" -> {
                            result.success(
                                LinkConnectionService.start(
                                    this@MainActivity,
                                    call.argument<String>("name") ?: "Mornye",
                                ),
                            )
                        }
                        "stopLinkConnectionService" -> {
                            LinkConnectionService.stop(this@MainActivity)
                            result.success(null)
                        }
                        "updateBackgroundWork" -> handleUpdateBackgroundWork(call, result)
                        "stopBackgroundWork" -> {
                            BackgroundWorkService.stop(call.argument<String>("kind") ?: "")
                            result.success(null)
                        }
                        "startNativeDownloadWorker" -> handleStartNativeDownloadWorker(call, result)
                        "appendNativeDownloadWorkerRequests" -> handleAppendNativeDownloadWorkerRequests(call, result)
                        "finishNativeDownloadWorkerPreparation" -> handleFinishNativeDownloadWorkerPreparation(call, result)
                        "acknowledgeNativeDownloadWorkerItems" -> handleAcknowledgeNativeDownloadWorkerItems(call, result)
                        "pauseNativeDownloadWorker" -> {
                            DownloadService.pauseNativeQueue(this@MainActivity)
                            result.success(null)
                        }
                        "resumeNativeDownloadWorker" -> {
                            DownloadService.resumeNativeQueue(this@MainActivity)
                            result.success(null)
                        }
                        "cancelNativeDownloadWorker" -> {
                            DownloadService.cancelNativeQueue(this@MainActivity)
                            result.success(null)
                        }
                        "getNativeDownloadWorkerSnapshot" -> handleGetNativeDownloadWorkerSnapshot(call, result)
                        "releaseMemory" -> handleReleaseMemory(call, result)
                        "releaseMemoryUnderPressure" -> handleReleaseMemoryUnderPressure(call, result)
                        "runPostProcessingV2" -> handleRunPostProcessingV2(call, result)
                        "setLibraryCoverCacheDir" -> handleSetLibraryCoverCacheDir(call, result)
                        "scanLibraryFolderToNDJSONFile" -> handleScanLibraryFolderToNDJSONFile(call, result)
                        "scanLibraryFolderIncremental" -> handleScanLibraryFolderIncremental(call, result)
                        "scanSafTreeToNDJSONFile" -> handleScanSafTreeToNDJSONFile(call, result)
                        "scanSafTreeIncremental" -> handleScanSafTreeIncremental(call, result)
                        "getSafFileModTimes" -> handleGetSafFileModTimes(call, result)
                        "getLibraryScanProgress" -> handleGetLibraryScanProgress(call, result)
                        "getLibraryScanExitInfo" -> handleGetLibraryScanExitInfo(call, result)
                        "getPendingAppCrash" -> result.success(withContext(Dispatchers.IO) { AppCrashReporter.pendingReport() })
                        "getLatestAppCrash" -> result.success(withContext(Dispatchers.IO) { AppCrashReporter.pendingReport(noticeOnly = false) })
                        "markAppCrashShown" -> {
                            val id = call.argument<String>("id") ?: ""
                            withContext(Dispatchers.IO) { AppCrashReporter.markReportShown(id) }
                            result.success(null)
                        }
                        "dismissAppCrash" -> {
                            val id = call.argument<String>("id") ?: ""
                            withContext(Dispatchers.IO) { AppCrashReporter.dismissReport(id) }
                            result.success(null)
                        }
                        "recordAppRuntimeError" -> {
                            val error = call.argument<String>("error") ?: ""
                            val stack = call.argument<String>("stack") ?: ""
                            val logs = call.argument<String>("logs") ?: ""
                            withContext(Dispatchers.IO) { AppCrashReporter.recordRuntimeError(error, stack, logs) }
                            result.success(null)
                        }
                        "cancelLibraryScan" -> handleCancelLibraryScan(call, result)
                        "pauseLibraryScan" -> handlePauseLibraryScan(call, result)
                        "resumeLibraryScan" -> handleResumeLibraryScan(call, result)
                        "readAudioMetadata" -> handleReadAudioMetadata(call, result)
                        "parseCueSheet" -> handleParseCueSheet(call, result)
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error(
                        ForegroundServiceStartPolicy.errorCode(e),
                        e.message,
                        null,
                    )
                }
            }
        }
    }

    private fun registerLibraryStorageReceiver() {
        if (libraryStorageReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                backendChannel?.invokeMethod(
                    "libraryStorageChanged",
                    mapOf("action" to (intent?.action ?: "")),
                )
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_MEDIA_MOUNTED)
            addAction(Intent.ACTION_MEDIA_UNMOUNTED)
            addAction(Intent.ACTION_MEDIA_EJECT)
            addAction(Intent.ACTION_MEDIA_REMOVED)
            addAction(Intent.ACTION_MEDIA_BAD_REMOVAL)
            addDataScheme("file")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(receiver, filter)
        }
        libraryStorageReceiver = receiver
    }
}
