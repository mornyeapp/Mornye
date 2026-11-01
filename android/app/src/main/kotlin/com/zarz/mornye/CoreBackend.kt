package com.zarz.mornye

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean

internal interface CoreDownloadProgress : AutoCloseable {
    fun waitDelta(since: Long, timeoutMs: Long): String
}

internal data class CoreFFmpegCommand(
    val id: String,
    val arguments: Array<String>,
    val outputPath: String = "",
)

internal interface CoreExtensionExecution : AutoCloseable {
    fun download(requestJson: String): String
    fun postProcess(inputJson: String, metadataJson: String): String
    fun waitPending(timeoutMs: Long): List<CoreFFmpegCommand>
    fun commandIsActive(commandId: String): Boolean
    fun complete(commandId: String, success: Boolean, output: String, error: String)
}

internal fun parseCoreFFmpegCommands(raw: String): List<CoreFFmpegCommand> {
    val commands = JSONArray(raw)
    return (0 until commands.length()).mapNotNull { index ->
        val command = commands.optJSONObject(index) ?: return@mapNotNull null
        val id = command.optString("command_id", "")
        if (id.isBlank()) return@mapNotNull null
        val arguments = command.optJSONArray("arguments")
        CoreFFmpegCommand(
            id,
            Array(arguments?.length() ?: 0) { arguments!!.optString(it, "") },
            command.optString("output_path", ""),
        )
    }
}

private object CoreFFmpegStaging {
    private val directories = mutableSetOf<String>()
    private val prefix = ".mornye-ffmpeg-${BuildConfig.APPLICATION_ID}-"

    @Synchronized
    fun create(target: File): File {
        val directory = requireNotNull(target.parentFile).canonicalFile
        // Sweep only before this process starts using the directory. Later
        // commands can share it with an FFmpeg operation that is still active.
        if (directory.path !in directories) {
            val entries = checkNotNull(directory.listFiles()) { "Cannot read FFmpeg output directory" }
            for (file in entries) {
                if (!file.name.startsWith(prefix)) continue
                val suffix = file.name.removePrefix(prefix)
                if (suffix.length <= 36 || suffix[36] != '.') continue
                if (runCatching { UUID.fromString(suffix.take(36)) }.isFailure) continue
                if (Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                    check(file.delete()) { "Failed to remove interrupted FFmpeg staging" }
                }
            }
            directories.add(directory.path)
        }
        val staged = File(directory, "$prefix${UUID.randomUUID()}.${target.extension}")
        check(staged.createNewFile()) { "Failed to create FFmpeg staging" }
        return staged
    }
}

internal fun executeCoreFFmpegCommand(
    command: CoreFFmpegCommand,
    cancelled: () -> Boolean,
    execute: (Array<String>, () -> Boolean) -> Pair<Boolean, String>,
): Pair<Boolean, String> {
    if (cancelled()) return false to "cancelled"
    if (command.outputPath.isEmpty()) return execute(command.arguments, cancelled)
    require(command.arguments.lastOrNull() == command.outputPath) { "FFmpeg output does not match command" }
    val target = File(command.outputPath)
    val staged = CoreFFmpegStaging.create(target)
    try {
        val arguments = command.arguments.copyOf()
        arguments[arguments.lastIndex] = staged.absolutePath
        val result = execute(arguments, cancelled)
        if (cancelled()) return false to "cancelled"
        if (!result.first) return result
        // Rename within the same filesystem publishes only a completed file.
        // An interrupted FFmpeg process can never become an existing-library hit.
        check(staged.renameTo(target)) { "Failed to publish FFmpeg output" }
        return result
    } finally {
        staged.delete()
    }
}

internal fun withCoreFFmpegExecution(
    execution: CoreExtensionExecution,
    execute: (Array<String>, () -> Boolean) -> Pair<Boolean, String> = { arguments, cancelled ->
        NativeDownloadFinalizer.runFFmpegArguments(arguments, cancelled, trackFinalizerSession = false)
    },
    block: (CoreExtensionExecution) -> String,
): String {
    val running = AtomicBoolean(true)
    val pump = Thread {
        try {
            while (running.get()) {
                val commands = try {
                    execution.waitPending(1_000L)
                } catch (_: Exception) {
                    break
                }
                // Finish every claimed command, even if our caller finishes first.
                // Another operation on this owner may be waiting for its result.
                for (command in commands) {
                    val cancelled = {
                        try { !execution.commandIsActive(command.id) } catch (_: Exception) { true }
                    }
                    val result = try {
                        when {
                            cancelled() -> false to "cancelled"
                            command.arguments.isEmpty() -> false to "FFmpeg arguments are empty"
                            else -> executeCoreFFmpegCommand(command, cancelled, execute)
                        }
                    } catch (error: Exception) {
                        false to (error.message ?: "FFmpeg execution failed")
                    }
                    try {
                        execution.complete(command.id, result.first, result.second, if (result.first) "" else result.second)
                    } catch (_: Exception) {
                        // Owner shutdown removes commands; late results cannot revive them.
                    }
                }
            }
        } finally {
            execution.close()
        }
    }
    pump.isDaemon = true
    try {
        pump.start()
    } catch (error: Throwable) {
        execution.close()
        throw error
    }
    return try {
        block(execution)
    } catch (error: Exception) {
        // Both bindings expose the backend's cancellation sentinel as an error.
        // Preserve its meaning for the worker's pause/retry state machine.
        if (error.message == "download cancelled") {
            throw CancellationException("download cancelled").apply { initCause(error) }
        }
        throw error
    } finally {
        // Do not interrupt a claimed command belonging to another operation.
        running.set(false)
    }
}

/** Native boundary to the Rust backend; each process holds one stateful instance. */
internal interface CoreBackend {
    val implementation: String
    fun invokeApplication(method: String, arguments: Any?): Any?
    fun setRuntimeState(dataDirectory: String, payload: String) {
        invokeApplication(
            "prepareRuntimeState",
            mapOf("data_dir" to dataDirectory, "runtime_state" to payload),
        )
    }
    fun completeAuthCallback(state: String, code: String, sessionGrant: Boolean, onResolved: (String) -> Unit)
    fun downloadByStrategy(requestJson: String): String =
        withCoreFFmpegExecution(openExtensionExecution()) { it.download(requestJson) }
    fun openDownloadProgress(): CoreDownloadProgress
    fun initItemProgress(itemId: String)
    fun clearItemProgress(itemId: String)
    fun cancelDownload(itemId: String)
    fun resetDownloadCancel(itemId: String)
    fun openExtensionExecution(): CoreExtensionExecution
    fun runPostProcessing(inputJson: String, metadataJson: String): String =
        withCoreFFmpegExecution(openExtensionExecution()) { it.postProcess(inputJson, metadataJson) }
    fun buildFilename(template: String, metadataJson: String): String
    fun sanitizeFilename(filename: String): String
    fun fileMetadataImplementation(path: String): String
    fun readFileMetadata(path: String, hint: String): String
    fun checkHiResAuthenticity(path: String, optionsJson: String): String
    fun readAudioMetadata(path: String, hint: String, cacheKey: String): String
    fun readAudioMetadataObject(path: String, hint: String, cacheKey: String): JSONObject =
        JSONObject(readAudioMetadata(path, hint, cacheKey))
    fun setLibraryCoverCacheDirectory(path: String)
    fun scanLibraryFolderToNdjsonFile(folder: String, output: String): Long
    fun scanLibraryFolderIncremental(folder: String, existing: String): String
    fun getLibraryScanProgress(): String
    fun cancelLibraryScan()
    fun pauseLibraryScan()
    fun resumeLibraryScan()
    fun parseCueSheet(path: String, audioDirectory: String): String
    fun parseCueSheetWithResolvedAudio(path: String, audioPath: String): String
    fun scanCueForLibraryWithResolvedAudio(path: String, audioPath: String, audioName: String, virtualPrefix: String, modTime: Long, cacheKey: String): String
    fun editFileMetadata(path: String, metadataJson: String): String
    fun reEnrichFile(requestJson: String): String
    fun rewriteSplitArtistTags(path: String, artist: String, albumArtist: String): String
    fun extractCoverToFile(audioPath: String, outputPath: String, hint: String = "")
    fun writeM4aFreeformTags(path: String, metadataJson: String): String
    fun ensureAc4Config(path: String, reference: String): String
    fun writeAc4Metadata(path: String, metadataJson: String, coverPath: String): String
    fun getLyricsLrc(spotifyId: String, trackName: String, artistName: String, filePath: String, durationMs: Long): String
    fun downloadCoverToFileSized(url: String, outputPath: String, maxDimension: Long)
    fun createTemporaryMediaFile(context: Context, prefix: String, suffix: String): File
    fun openDownloadDirectory(path: String): AutoCloseable
    fun openDownloadDirectoryForRequest(requestJson: String): AutoCloseable {
        val request = JSONObject(requestJson)
        return if (request.optString("storage_mode") == "saf") AutoCloseable {}
        else openDownloadDirectory(request.getString("output_dir"))
    }
    fun releaseIdleResources()
    fun releaseMemoryUnderPressure()
}

internal fun requireSuccessfulExtensionAction(extensionId: String, actionName: String, response: String) {
    val obj = try {
        JSONObject(response)
    } catch (e: Exception) {
        throw IllegalStateException(
            "Extension $actionName for $extensionId returned invalid JSON: ${response.take(240)}"
        )
    }
    if (obj.optBoolean("success", false)) {
        return
    }
    val error = obj.optString("error")
        .ifBlank { obj.optString("message") }
        .ifBlank { response.take(240) }
    throw IllegalStateException("Extension $actionName failed for $extensionId: $error")
}
