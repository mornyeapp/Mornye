package com.zarz.mornye

import android.util.Log
import com.antonkarpenko.ffmpegkit.FFmpegKit
import com.antonkarpenko.ffmpegkit.FFmpegKitConfig
import com.antonkarpenko.ffmpegkit.FFmpegKitFlutterPlugin
import com.antonkarpenko.ffmpegkit.FFmpegSession
import com.antonkarpenko.ffmpegkit.LogRedirectionStrategy
import com.antonkarpenko.ffmpegkit.ReturnCode
import com.zarz.mornye.SafDownloadHandler.normalizeExt
import java.io.File
import java.io.RandomAccessFile
import java.util.Locale
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.pow

internal fun isMP4ContainerFile(path: String): Boolean {
    return try {
        File(path).inputStream().use { stream ->
            val header = ByteArray(12)
            val read = stream.read(header)
            read >= 8 &&
                header[4] == 'f'.code.toByte() &&
                header[5] == 't'.code.toByte() &&
                header[6] == 'y'.code.toByte() &&
                header[7] == 'p'.code.toByte()
        }
    } catch (_: Exception) {
        false
    }
}

internal fun NativeDownloadFinalizer.formatForPath(path: String): String {
    return when (normalizeExt(File(path).extension)) {
        ".mp3" -> "mp3"
        ".opus", ".ogg" -> "opus"
        ".m4a", ".mp4", ".aac" -> "m4a"
        else -> "flac"
    }
}

internal fun NativeDownloadFinalizer.scanReplayGain(path: String, shouldCancel: () -> Boolean = { false }): NativeDownloadFinalizer.ReplayGainScan? {
    val command = "-hide_banner -nostats -loglevel info -i ${q(path)} -map 0:a:0 -vn -sn -dn -af ebur128=peak=true:framelog=quiet -f null -"
    val result = runFFmpeg(command, shouldCancel)
    val output = result.second
    if (!result.first) {
        val diagnostic = output.lineSequence()
            .filter { Regex("decoder|error|invalid|failed", RegexOption.IGNORE_CASE).containsMatchIn(it) }
            .take(3)
            .joinToString(" ")
            .take(500)
        Log.w(TAG, "ReplayGain scan failed: $diagnostic")
        return null
    }
    val integrated = Regex("I:\\s+(-?\\d+\\.?\\d*)\\s+LUFS")
        .findAll(output)
        .lastOrNull()
        ?.groupValues
        ?.getOrNull(1)
        ?.toDoubleOrNull() ?: return null
    val truePeak = Regex("Peak:\\s+(-?\\d+\\.?\\d*)\\s+dBFS")
        .findAll(output)
        .mapNotNull { it.groupValues.getOrNull(1)?.toDoubleOrNull() }
        .maxOrNull()
    val gain = -18.0 - integrated
    val peak = if (truePeak != null) 10.0.pow(truePeak / 20.0) else 1.0
    return NativeDownloadFinalizer.ReplayGainScan(
        trackGain = "${if (gain >= 0) "+" else ""}${"%.2f".format(Locale.US, gain)} dB",
        trackPeak = "%.6f".format(Locale.US, peak),
        integratedLufs = integrated,
        truePeakLinear = peak,
    )
}

internal fun NativeDownloadFinalizer.runFFmpeg(command: String, shouldCancel: () -> Boolean = { false }): Pair<Boolean, String> {
    return runFFmpegArguments(FFmpegKitConfig.parseArguments(command), shouldCancel)
}

internal fun NativeDownloadFinalizer.runFFmpegArguments(arguments: Array<String>, shouldCancel: () -> Boolean = { false }, trackFinalizerSession: Boolean = true): Pair<Boolean, String> {
    checkCancelled(shouldCancel)
    installNativeFFmpegCallbackFilter()
    val latch = CountDownLatch(1)
    var completedSession: FFmpegSession? = null
    val session = FFmpegSession.create(
        arguments,
        { finishedSession ->
            completedSession = finishedSession
            latch.countDown()
        },
        null,
        null,
        LogRedirectionStrategy.NEVER_PRINT_LOGS,
    )
    val sessionId = session.sessionId
    synchronized(activeFFmpegSessionLock) {
        if (trackFinalizerSession) activeFFmpegSessionIds.add(sessionId)
    }
    nativeFFmpegSessionIds.add(sessionId)
    FFmpegKitConfig.asyncFFmpegExecute(session)
    try {
        var cancelRequested = false
        while (!latch.await(200, TimeUnit.MILLISECONDS)) {
            if (shouldCancel()) {
                cancelRequested = true
                try {
                    FFmpegKit.cancel(sessionId)
                } catch (_: Exception) {
                }
                break
            }
        }
        if (cancelRequested) {
            latch.await(5, TimeUnit.SECONDS)
            throw CancellationException("Native FFmpeg session cancelled")
        }
        val finalSession = completedSession ?: session
        val output = finalSession.getAllLogsAsString(1000) ?: ""
        checkCancelled(shouldCancel)
        return ReturnCode.isSuccess(finalSession.returnCode) to output
    } finally {
        synchronized(activeFFmpegSessionLock) {
            activeFFmpegSessionIds.remove(sessionId)
        }
    }
}

internal fun NativeDownloadFinalizer.installNativeFFmpegCallbackFilter() {
    // The plugin registers its callback once, possibly later; wrap it only after that.
    FFmpegKitFlutterPlugin.ensureGlobalCallbacksRegistered()
    synchronized(ffmpegCompleteCallbackLock) {
        val current = FFmpegKitConfig.getFFmpegSessionCompleteCallback()
        if (current !== nativeFilteringFFmpegCompleteCallback) {
            forwardedFFmpegCompleteCallback = current
            FFmpegKitConfig.enableFFmpegSessionCompleteCallback(nativeFilteringFFmpegCompleteCallback)
        }
    }
}

/**
 * Staged sibling name for conversion outputs: "song.flac" -> "song.partial.flac".
 * The ".partial<ext>" shape is ignored by library scans and duplicate checks,
 * while the real trailing extension still lets FFmpeg infer the muxer. A
 * process kill mid-conversion therefore never leaves a partial file under a
 * real audio name in the user's music folder.
 */
internal fun NativeDownloadFinalizer.stagedConversionPath(finalPath: String): String {
    val file = File(finalPath)
    val ext = file.extension
    val name = if (ext.isBlank()) "${file.name}.partial" else "${file.nameWithoutExtension}.partial.$ext"
    return File(file.parentFile, name).absolutePath
}

internal fun NativeDownloadFinalizer.promoteStagedConversion(stagedPath: String, finalPath: String): Boolean {
    val staged = File(stagedPath)
    if (!staged.isFile || staged.length() == 0L) return false
    fsyncQuietly(staged)
    val final = File(finalPath)
    val backup = File("$finalPath.mornye-backup-${System.nanoTime()}")
    val backedUp = final.exists()
    if (backedUp && (!final.isFile || !final.renameTo(backup))) return false
    if (staged.renameTo(final)) {
        if (backedUp) backup.delete()
        return true
    }
    if (backedUp) check(backup.renameTo(final)) { "failed to restore conversion source" }
    return false
}

internal fun NativeDownloadFinalizer.buildOutputPath(inputPath: String, extension: String): String {
    val ext = normalizeExt(extension).ifBlank { ".tmp" }
    val file = File(inputPath)
    val base = file.nameWithoutExtension.ifBlank { "track" }
    // This is the final name. FFmpeg writes via stagedConversionPath even
    // when the source and final extensions match.
    return File(file.parentFile, "$base$ext").absolutePath
}

internal fun NativeDownloadFinalizer.desiredFileName(input: NativeDownloadFinalizer.FinalizeInput, state: NativeDownloadFinalizer.FinalizeState, extension: String): String {
    val ext = normalizeExt(extension).ifBlank { normalizeExt(File(state.fileName).extension).ifBlank { ".flac" } }
    val rawName = input.result.optString("quality_variant_file_name", "")
        .ifBlank { input.result.optString("resolved_file_name", "") }
        .ifBlank { input.request.optString("saf_file_name", "") }
        .ifBlank { state.fileName }
        .ifBlank { "${trackString(input, "artistName", input.request.optString("artist_name", "Artist"))} - ${trackString(input, "name", input.request.optString("track_name", "Track"))}" }
    val knownExts = listOf(".flac", ".m4a", ".mp4", ".aac", ".mp3", ".opus", ".ogg", ".lrc")
    var base = rawName.trim()
    val lower = base.lowercase(Locale.ROOT)
    for (knownExt in knownExts) {
        if (lower.endsWith(knownExt)) {
            base = base.dropLast(knownExt.length)
            break
        }
    }
    base = base
        .replace("/", " ")
        .replace(Regex("[\\\\:*?\"<>|]"), " ")
        .trim()
        .trim('.', ' ')
        .ifBlank { "track" }
    return "$base$ext"
}

internal fun NativeDownloadFinalizer.shouldForceContainerConversion(input: NativeDownloadFinalizer.FinalizeInput, state: NativeDownloadFinalizer.FinalizeState): Boolean {
    if (input.result.optBoolean("requires_container_conversion", false)) return true
    if (input.request.optBoolean("requires_container_conversion", false)) return true
    return false
}

internal fun NativeDownloadFinalizer.probePrimaryAudioCodec(path: String, shouldCancel: () -> Boolean = { false }): String {
    val result = runFFmpeg("-hide_banner -nostdin -i ${q(path)} -map 0:a:0 -frames:a 1 -f null -", shouldCancel)
    val output = result.second
    val match = Regex("Audio:\\s*([^,\\s]+)", RegexOption.IGNORE_CASE).find(output)
    return match?.groupValues?.getOrNull(1)
        ?.trim()
        ?.lowercase(Locale.ROOT)
        ?.replace('-', '_')
        .orEmpty()
}

/**
 * Returns true when the file on [path] starts with the native FLAC magic
 * bytes (`fLaC`). A file may contain a FLAC audio stream yet live inside
 * an MP4/fMP4 container; native FLAC tag writers require the raw fLaC
 * header, so detect that mismatch before skipping container conversion.
 */
internal fun NativeDownloadFinalizer.isNativeFlacFile(path: String): Boolean {
    return try {
        RandomAccessFile(path, "r").use { raf ->
            if (raf.length() < 4L) return false
            val header = ByteArray(4)
            raf.readFully(header)
            header[0] == 0x66.toByte() && // 'f'
                header[1] == 0x4C.toByte() && // 'L'
                header[2] == 0x61.toByte() && // 'a'
                header[3] == 0x43.toByte() // 'C'
        }
    } catch (e: Exception) {
        Log.w(TAG, "Native FLAC magic probe failed for $path: ${e.message}")
        false
    }
}
