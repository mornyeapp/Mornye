package com.zarz.mornye

import android.content.Context
import android.net.Uri
import com.mornye.backend.CancellationDomain
import com.mornye.backend.CancellationRegistry
import com.mornye.backend.DownloadState
import com.mornye.backend.ExtensionManager
import com.mornye.backend.ExtensionRepository
import com.mornye.backend.LyricsRequest
import com.mornye.backend.RequestLease
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest
import org.json.JSONObject

internal fun createCoreBackend(context: Context): CoreBackend = RustCoreBackend.initialize(context)

internal suspend fun MainActivity.dispatchBackendApplication(call: MethodCall, result: MethodChannel.Result): Boolean {
    if (call.method == "cancelNativeDataJob") {
        val args = call.arguments as? Map<*, *>
        NativeDataJobs.cancel(args?.get("request_id") as? String ?: "")
        result.success(null)
        return true
    }
    val jobId = if (call.method == "runNativeDataJob") {
        (call.arguments as? Map<*, *>)?.get("request_id") as? String
            ?: error("Missing data job ID")
    } else null
    val jobLease = jobId?.let { NativeDataJobs.acquire(it) }
    val response = try {
        withContext(Dispatchers.IO) {
            when (call.method) {
                "runNativeDataJob" -> runNativeDataJobPlatform(call.arguments, checkNotNull(jobLease))
                "getLyricsLRC", "getLyricsLRCWithSource", "fetchAndSaveLyrics" -> {
                    val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    readLyricsRequestWithSafCopy(
                        call.method,
                        arguments,
                        copyToTemp = { copyUriToTemp(coreBackend, Uri.parse(it))?.let(::File) },
                        read = { request ->
                            coreBackend.invokeApplication(call.method, request)
                        },
                    ) ?: when (call.method) {
                        "getLyricsLRC" -> ""
                        "fetchAndSaveLyrics" -> """{"success":false,"error":"Failed to access the audio document"}"""
                        else -> """{"lyrics":"","source":"","sync_type":"","instrumental":false}"""
                    }
                }
                else -> coreBackend.invokeApplication(call.method, call.arguments)
            }
        }
    } finally {
        if (jobLease != null) NativeDataJobs.release(checkNotNull(jobId), jobLease)
    }
    result.success(response)
    return true
}

internal object RustCoreBackend : CoreBackend {
    override val implementation = "rust"
    private lateinit var workspace: NativeMediaWorkspace
    internal var manager: ExtensionManager? = null
    private var repository: ExtensionRepository? = null
    private var requests: CancellationRegistry? = null
    internal var identity: Triple<String, String, List<Byte>>? = null
    internal var loggingEnabled = false
    internal var allowPrivateNetwork = false
    internal var allowHttpFallback = false
    internal var fallbackProviders: List<String>? = null
    internal var runtimeState: Pair<String, String>? = null
    internal val directoryScopes = mutableMapOf<String, AutoCloseable>()
    private var libraryCoverScope: AutoCloseable? = null
    @Volatile private var libraryCoverDirectory: File? = null

    @Synchronized
    fun initialize(context: Context): RustCoreBackend {
        if (!::workspace.isInitialized) {
            workspace = NativeMediaWorkspace(context.applicationContext.noBackupFilesDir)
        }
        return this
    }

    @Synchronized
    internal fun owner(): ExtensionManager {
        return checkNotNull(manager) { "Rust backend is not initialized" }
    }

    internal fun <T> ExtensionManager.withDownloadState(block: (DownloadState) -> T): T =
        environment().use { environment ->
            environment.downloadState().use(block)
        }

    private fun directoryAliases(value: String, sources: String, data: String): List<String> {
        require(File(value).isAbsolute) { "Output directories must be absolute" }
        val path = File(value).canonicalPath
        require(path != "/" && listOf(sources, data).none {
            path == it || path.startsWith("$it/") || it.startsWith("$path/")
        }) { "Output directory overlaps extension storage" }
        return listOf(path, File(value).absolutePath).distinct()
    }

    @Synchronized
    override fun openDownloadDirectory(path: String): AutoCloseable {
        val current = owner()
        val storage = checkNotNull(identity)
        val scope = current.environment().use {
            it.grantDownloadDirectories(directoryAliases(path, storage.first, storage.second))
        }
        return object : AutoCloseable {
            private var released = false

            @Synchronized
            override fun close() {
                if (released) return
                released = true
                try { scope.release() } finally { scope.close() }
            }
        }
    }

    @Synchronized
    internal fun setDownloadDirectory(path: String) {
        val current = owner()
        val storage = checkNotNull(identity)
        val files = workspace.ensureDirectory()
        val allowed = listOf(files.canonicalPath, files.absolutePath) +
            if (path.isEmpty()) emptyList() else directoryAliases(path, storage.first, storage.second)
        current.environment().use { it.setAllowedDownloadDirectories(allowed.distinct()) }
    }

    @Synchronized
    internal fun requestRegistry(): CancellationRegistry = requests ?: CancellationRegistry(
        CancellationDomain.EXTENSION_REQUEST,
    ).also { requests = it }

    @Synchronized
    internal fun acquireRequest(id: String): Pair<ExtensionManager, RequestLease> =
        owner() to requestRegistry().acquire(id)

    internal fun runDataJob(request: JSONObject, bytes: ByteArray, lease: RequestLease): String {
        if (request.optString("operation") != "library_scan_incremental") {
            return com.mornye.backend.runNativeDataJob(request.toString(), bytes, lease)
        }
        val folder = request.getString("folder_path")
        return withLibraryDirectories(listOf(folder)) { current ->
            val snapshot = request.optString("snapshot_path")
            val staged = if (snapshot.isEmpty()) null else workspace.createTemporaryFile("library_snapshot_", ".tsv")
            try {
                if (staged != null) {
                    File(snapshot).copyTo(staged, overwrite = true)
                    request.put("snapshot_path", staged.canonicalPath)
                }
                current.runNativeDataJob(request.toString(), bytes, lease)
            } finally { staged?.delete() }
        }
    }

    @Synchronized
    internal fun repositoryOwner(): ExtensionRepository =
        checkNotNull(repository) { "Extension repository is not initialized" }

    @Synchronized
    internal fun initializeRepository(cachePath: String) {
        val current = owner()
        if (repository != null) return
        val cache = File(cachePath)
        require(cache.isAbsolute) { "Repository cache directory must be absolute" }
        repository = ExtensionRepository(current, cache.canonicalPath)
    }

    @Synchronized
    internal fun initializeOwner(arguments: Map<*, *>) {
        val sourcePath = File(arguments["extensions_dir"] as String)
        val dataPath = File(arguments["data_dir"] as String)
        require(sourcePath.isAbsolute && dataPath.isAbsolute) { "Extension storage directories must be absolute" }
        val sources = sourcePath.canonicalPath
        val data = dataPath.canonicalPath
        val key = arguments["master_key"] as String
        val requested = Triple(
            sources,
            data,
            MessageDigest.getInstance("SHA-256").digest(key.toByteArray()).toList(),
        )
        val files = workspace.ensureDirectory()
        val rawDirectories = arguments["allowed_directories"]
        require(rawDirectories == null || rawDirectories is List<*>) { "Invalid output directories" }
        val allowedDirectories = listOf(files.canonicalPath, files.absolutePath) +
            (rawDirectories as? List<*>).orEmpty().flatMap { value ->
                require(value is String) { "Output directories must be strings" }
                directoryAliases(value, sources, data)
            }
        if (manager != null) {
            check(identity == requested) { "Rust backend is already initialized with different storage" }
            manager!!.environment().use { it.setAllowedDownloadDirectories(allowedDirectories.distinct()) }
            return
        }
        val preparedRuntime = runtimeState
        require(preparedRuntime == null || preparedRuntime.first == data) {
            "Runtime state directory does not match the initialized owner"
        }
        val created = ExtensionManager.withLyricsSettings(
            sources,
            data,
            key,
            BuildConfig.VERSION_NAME,
            30_000uL,
            arguments["lyrics_providers_json"] as? String ?: "[]",
            arguments["lyrics_options_json"] as? String ?: "{}",
        )
        try {
            created.environment().use { environment ->
                environment.setAllowedDownloadDirectories(allowedDirectories.distinct())
                environment.setAllowPrivateNetwork(allowPrivateNetwork)
                environment.setNetworkCompatibilityOptions(allowHttpFallback, false)
                environment.logBuffer().use { it.setEnabled(loggingEnabled) }
                preparedRuntime?.let { environment.setRuntimeState(it.second) }
            }
            created.setFallbackProviders(fallbackProviders)
        } catch (error: Exception) {
            created.shutdown()
            created.close()
            throw error
        }
        identity = requested
        manager = created
    }

    @Synchronized
    internal fun shutdownOwner() {
        requests?.let {
            it.shutdown()
            it.close()
        }
        requests = null
        repository?.let {
            it.shutdown()
            it.close()
        }
        repository = null
        manager?.let {
            it.shutdown()
            it.close()
        }
        manager = null
        directoryScopes.values.forEach { it.close() }
        directoryScopes.clear()
        libraryCoverScope?.close()
        libraryCoverScope = null
        libraryCoverDirectory = null
        identity = null
        runtimeState = null
    }

    override fun fileMetadataImplementation(path: String): String = "rust"

    override fun readFileMetadata(path: String, hint: String): String =
        com.mornye.backend.readFileMetadata(path, hint, null)

    override fun checkHiResAuthenticity(path: String, optionsJson: String): String =
        com.mornye.backend.checkHiresAuthenticity(path, optionsJson, null)

    override fun readAudioMetadata(path: String, hint: String, cacheKey: String): String {
        val descriptor = path.removePrefix("/proc/self/fd/").toIntOrNull()
        if (path.startsWith("/proc/self/fd/") && descriptor != null) {
            val directory = libraryCoverDirectory
            // Never key artwork by the descriptor number: Android reuses it.
            val key = cacheKey.trim().takeIf { it.isNotEmpty() }
            val slot = if (directory != null && key != null) {
                com.mornye.backend.libraryCoverSlot(directory.path, key)
            } else null
            val cached = slot?.cached?.let { File(it) }
            val result = com.mornye.backend.readLibraryMetadataFromDescriptor(
                descriptor, hint, java.time.Instant.now().toString(),
                slot != null && cached == null, null,
            )
            val metadata = JSONObject(result.metadataJson)
            var cover = cached
            if (directory != null && slot != null && result.coverBytes.isNotEmpty()) {
                try {
                    val extension = if (result.coverMime.contains("png")) "png" else "jpg"
                    val output = File(directory, "${slot.stem}.$extension")
                    val staged = File.createTempFile("cover_", ".tmp", directory)
                    try {
                        staged.writeBytes(result.coverBytes)
                        check(staged.renameTo(output)) { "Could not publish library artwork" }
                        cover = output
                    } finally { staged.delete() }
                } catch (error: Exception) {
                    android.util.Log.w("Mornye", "Could not cache document artwork", error)
                }
            }
            cover?.let { metadata.put("coverPath", it.path) }
            return metadata.toString()
        }
        return withMediaFiles(listOf(path)) {
            it.readAudioMetadata(File(path).canonicalPath, hint, cacheKey, null)
        }
    }

    // Native callers have already selected/resolved these files through app or
    // SAF access. Retain only their parent directories for this operation.
    internal fun <T> withMediaFiles(paths: List<String>, block: (ExtensionManager) -> T): T =
        withLibraryDirectories(paths.filter { it.isNotBlank() }.map { path ->
            require(File(path).isAbsolute) { "Media paths must be absolute" }
            File(path).absoluteFile.parent!!
        }.distinct(), block)

    private fun <T> withLibraryDirectories(paths: List<String>, block: (ExtensionManager) -> T): T {
        val (current, scope) = synchronized(this) {
            val current = owner()
            val storage = checkNotNull(identity)
            val aliases = paths.flatMap { directoryAliases(it, storage.first, storage.second) }.distinct()
            current to current.environment().use { it.grantDownloadDirectories(aliases) }
        }
        return scope.use {
            try { block(current) } finally { it.release() }
        }
    }

    @Synchronized
    override fun setLibraryCoverCacheDirectory(path: String) {
        val current = owner()
        require(path.isEmpty() || File(path).isAbsolute) { "Library cover directory must be absolute" }
        val directory = if (path.isEmpty()) null else File(path).canonicalFile
        if (directory != null) check(directory.mkdirs() || directory.isDirectory)
        val next = directory?.let { openDownloadDirectory(it.path) }
        try { current.setLibraryCoverCacheDirectory(directory?.path.orEmpty()) }
        catch (error: Exception) { next?.close(); throw error }
        libraryCoverScope?.close()
        libraryCoverScope = next
        libraryCoverDirectory = directory
    }

    override fun scanLibraryFolderToNdjsonFile(folder: String, output: String): Long =
        withLibraryDirectories(listOf(folder)) { current ->
            require(File(output).isAbsolute && File(output).extension.equals("ndjson", ignoreCase = true)) {
                "Library scan output must be an absolute NDJSON path"
            }
            // The support directory also contains extension storage. Keep the
            // Rust write inside its existing private staging root, then publish
            // the completed result through the native app's file access.
            val staged = workspace.createTemporaryFile("library_scan_", ".ndjson")
            try {
                val count = current.scanLibraryFolderToNdjsonFile(File(folder).canonicalPath, staged.canonicalPath, null)
                check(staged.renameTo(File(output))) { "Failed to publish library scan output" }
                count.toLong()
            } finally { staged.delete() }
        }

    override fun scanLibraryFolderIncremental(folder: String, existing: String): String =
        withLibraryDirectories(listOf(folder)) {
            it.scanLibraryFolderIncremental(File(folder).canonicalPath, existing, null)
        }

    override fun getLibraryScanProgress(): String =
        synchronized(this) { manager }?.getLibraryScanProgress() ?: "{}"

    override fun cancelLibraryScan() { synchronized(this) { manager }?.cancelLibraryScan() }

    override fun pauseLibraryScan() { synchronized(this) { manager }?.pauseLibraryScan() }

    override fun resumeLibraryScan() { synchronized(this) { manager }?.resumeLibraryScan() }

    override fun parseCueSheet(path: String, audioDirectory: String): String {
        val cue = File(path).canonicalFile
        val audio = if (audioDirectory.isEmpty()) cue.parentFile!! else File(audioDirectory).canonicalFile
        return withLibraryDirectories(listOf(cue.parent, audio.path)) {
            it.parseCueFileJson(cue.path, audio.path, null)
        }
    }

    override fun parseCueSheetWithResolvedAudio(path: String, audioPath: String): String {
        val cue = File(path).canonicalFile
        return withLibraryDirectories(listOf(cue.parent)) {
            it.parseCueFileJsonWithResolvedAudio(cue.path, audioPath, null)
        }
    }

    override fun scanCueForLibraryWithResolvedAudio(path: String, audioPath: String, audioName: String, virtualPrefix: String, modTime: Long, cacheKey: String): String {
        val cue = File(path).canonicalFile
        fun scan(descriptor: Int): String {
            // Artwork remains optional, as in the filesystem CUE scanner.
            // A cover extraction failure must not discard valid CUE rows.
            val coverPath = try {
                JSONObject(readAudioMetadata("/proc/self/fd/$descriptor", audioName, cacheKey)).optString("coverPath", "")
            } catch (error: Exception) {
                if (error is java.util.concurrent.CancellationException) throw error
                android.util.Log.w("Mornye", "Could not read CUE artwork", error)
                ""
            }
            return withLibraryDirectories(listOf(requireNotNull(cue.parent))) {
                it.scanCueFileForLibraryFromDescriptor(
                    cue.path, descriptor, audioName, virtualPrefix, modTime,
                    coverPath, java.time.Instant.now().toString(), null,
                )
            }
        }
        val descriptor = audioPath.removePrefix("/proc/self/fd/").toIntOrNull()
        if (audioPath.startsWith("/proc/self/fd/") && descriptor != null) return scan(descriptor)
        return android.os.ParcelFileDescriptor.open(File(audioPath), android.os.ParcelFileDescriptor.MODE_READ_ONLY).use {
            scan(it.fd)
        }
    }

    override fun editFileMetadata(path: String, metadataJson: String): String {
        val cover = if (metadataJson.trim() == "null") "" else JSONObject(metadataJson).optString("cover_path", "")
        return withMediaFiles(listOf(path, cover)) {
            it.editFileMetadata(File(path).canonicalPath, metadataJson, null)
        }
    }

    internal fun mediaPath(path: String): String = if (path.isEmpty()) "" else File(path).canonicalPath

    override fun reEnrichFile(requestJson: String): String {
        val request = JSONObject(requestJson)
        val path = request.opt("file_path") as? String
        if (!request.optBoolean("preview_only", false) && path?.startsWith("/") == true) {
            request.put("file_path", mediaPath(path))
        }
        return if (!request.optBoolean("preview_only", false) && !path.isNullOrBlank()) {
            withMediaFiles(listOf(path)) { it.reenrichFile(request.toString(), null) }
        } else owner().reenrichFile(request.toString(), null)
    }

    override fun rewriteSplitArtistTags(path: String, artist: String, albumArtist: String): String =
        withMediaFiles(listOf(path)) { it.rewriteSplitArtistTags(mediaPath(path), artist, albumArtist, null) }

    override fun extractCoverToFile(audioPath: String, outputPath: String, hint: String) {
        val descriptor = if (audioPath.startsWith("/proc/self/fd/")) {
            audioPath.removePrefix("/proc/self/fd/").toIntOrNull()
        } else null
        if (descriptor != null) {
            val artwork = com.mornye.backend.extractCoverFromDescriptor(
                descriptor, hint, null,
            )
            check(artwork.isNotEmpty()) { "No embedded artwork" }
            val output = File(outputPath)
            val staged = File.createTempFile("cover_", ".tmp", output.parentFile)
            try {
                staged.writeBytes(artwork)
                check(staged.renameTo(output)) { "Could not publish artwork" }
            } finally { staged.delete() }
            return
        }
        withMediaFiles(listOf(audioPath, outputPath)) {
            it.extractCoverToFile(mediaPath(audioPath), mediaPath(outputPath), null)
        }
    }

    override fun writeM4aFreeformTags(path: String, metadataJson: String): String =
        withMediaFiles(listOf(path)) { it.writeM4aFreeformTags(mediaPath(path), metadataJson, null) }

    override fun ensureAc4Config(path: String, reference: String): String =
        owner().ensureAc4Config(mediaPath(path), mediaPath(reference), null)

    override fun writeAc4Metadata(path: String, metadataJson: String, coverPath: String): String =
        owner().writeAc4Metadata(mediaPath(path), metadataJson, mediaPath(coverPath), null)

    override fun getLyricsLrc(
        spotifyId: String,
        trackName: String,
        artistName: String,
        filePath: String,
        durationMs: Long,
    ): String = owner().getLyricsLrc(
        LyricsRequest(spotifyId, trackName, artistName, filePath, durationMs),
        null,
    )

    override fun downloadCoverToFileSized(
        url: String,
        outputPath: String,
        maxDimension: Long,
    ) = owner().downloadCoverToFileSized(
        url,
        File(outputPath).canonicalPath,
        maxDimension,
        null,
    )

    override fun releaseIdleResources() {
        owner().releaseMemory(false)
    }

    override fun releaseMemoryUnderPressure() {
        owner().releaseMemory(true)
    }

    override fun createTemporaryMediaFile(
        context: Context,
        prefix: String,
        suffix: String,
    ): File {
        owner()
        return workspace.createTemporaryFile(prefix, suffix)
    }

    override fun openExtensionExecution(): CoreExtensionExecution {
        val current = owner()
        val commands = current.environment().use { it.ffmpegCommands() }
        return object : CoreExtensionExecution {
            override fun download(requestJson: String): String = current.downloadByStrategy(requestJson)
            override fun postProcess(inputJson: String, metadataJson: String): String =
                current.runPostProcessing(inputJson, metadataJson, 120_000uL)
            override fun waitPending(timeoutMs: Long): List<CoreFFmpegCommand> =
                parseCoreFFmpegCommands(commands.waitPending(timeoutMs))
            override fun commandIsActive(commandId: String): Boolean = commands.getCommand(commandId).isNotEmpty()
            override fun complete(commandId: String, success: Boolean, output: String, error: String) {
                commands.complete(commandId, success, output, error)
            }
            override fun close() { commands.close() }
        }
    }

    override fun openDownloadProgress(): CoreDownloadProgress {
        val current = owner()
        val subscription = current.environment().use { environment ->
            environment.downloadState().use { it.subscribeProgress() }
        }
        return object : CoreDownloadProgress {
            override fun waitDelta(since: Long, timeoutMs: Long): String = subscription.waitDelta(since, timeoutMs)
            override fun close() {
                subscription.stop()
                subscription.close()
            }
        }
    }

    override fun initItemProgress(itemId: String) {
        val current = owner()
        current.withDownloadState { state -> state.initItemProgress(itemId) }
    }

    override fun clearItemProgress(itemId: String) {
        val current = owner()
        current.withDownloadState { state -> state.clearItemProgress(itemId) }
    }

    override fun cancelDownload(itemId: String) {
        val current = owner()
        current.withDownloadState { state -> state.cancelDownload(itemId) }
    }

    override fun resetDownloadCancel(itemId: String) {
        val current = owner()
        current.withDownloadState { state -> state.resetDownloadCancel(itemId) }
    }

    override fun completeAuthCallback(state: String, code: String, sessionGrant: Boolean, onResolved: (String) -> Unit) {
        val current = owner()
        current.environment().use { environment ->
            val id = if (sessionGrant) environment.resolveCallbackState(state) else environment.consumeCallbackState(state)
            onResolved(id)
            if (sessionGrant) {
                completeSessionGrant(current, id, code)
            } else {
                environment.setAuthCode(id, code)
                current.invokeAction(id, "completeSpotifyLogin")
            }
        }
    }

    internal fun completeSessionGrant(current: ExtensionManager, id: String, grant: String) {
        current.environment().use { it.setSessionGrant(id, grant) }
        requireSuccessfulExtensionAction(id, "completeGrant", current.invokeAction(id, "completeGrant"))
    }

    override fun invokeApplication(method: String, arguments: Any?): Any? = dispatchApplication(method, arguments)

    override fun buildFilename(template: String, metadataJson: String): String =
        com.mornye.backend.buildFilename(template, metadataJson)

    override fun sanitizeFilename(filename: String): String =
        com.mornye.backend.sanitizeFilename(filename)
}
