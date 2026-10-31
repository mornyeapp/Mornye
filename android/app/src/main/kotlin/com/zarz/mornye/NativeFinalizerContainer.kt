package com.zarz.mornye

import android.content.Context
import android.util.Log
import com.zarz.mornye.SafDownloadHandler.normalizeExt
import com.zarz.mornye.NativeFinalizationPolicy.normalizeAudioCodec
import java.io.File
import java.util.Locale

internal fun NativeDownloadFinalizer.finalizeAutoConversion(
    context: Context,
    input: NativeDownloadFinalizer.FinalizeInput,
    state: NativeDownloadFinalizer.FinalizeState,
    shouldCancel: () -> Boolean,
) {
    val target = NativeFinalizationPolicy.autoConversionTarget(
        enabled = input.request.optBoolean("auto_convert_downloads", false),
        format = input.request.optString("auto_convert_format", ""),
        bitrate = input.request.optString("auto_convert_bitrate", ""),
        maxBitDepth = input.request.optInt("auto_convert_max_bit_depth", 16),
        maxSampleRate = input.request.optInt("auto_convert_max_sample_rate", 48000),
    ) ?: return
    if (target.codec == "flac") {
        refreshFinalAudioQualityMetadata(context, input.result, state)
        val codec = normalizeAudioCodec(state.audioCodec).orEmpty()
        if (!NativeFinalizationPolicy.isLosslessAudioCodec(codec)) return
        check(target.maxBitDepth == null || state.bitDepth != null) {
            "Cannot inspect source bit depth for FLAC conversion"
        }
        check(target.maxSampleRate == null || state.sampleRate != null) {
            "Cannot inspect source sample rate for FLAC conversion"
        }
    }
    if (
        NativeFinalizationPolicy.autoConversionAlreadySatisfied(
            target,
            state.audioCodec,
            state.bitrateKbps,
            state.bitDepth,
            state.sampleRate,
        )
    ) return

    val localInput = materializeForFFmpeg(context, input, state)
    val sourceWasSaf = state.filePath.startsWith("content://")
    val sameLocalExtension = !sourceWasSaf &&
        normalizeExt(File(localInput).extension) == target.extension
    val output = if (sameLocalExtension) {
        buildOutputPath(localInput, target.extension)
    } else {
        uniqueAutoConversionOutputPath(localInput, target.extension)
    }
    val stagedOutput = stagedConversionPath(output)
    val bitrate = "${target.bitrateKbps}k"
    var adoptedOutput = false
    try {
        val command = when (target.codec) {
            "opus" -> "-v error -hide_banner -i ${q(localInput)} -codec:a libopus -b:a $bitrate -vbr on -compression_level 10 -map 0:a ${q(stagedOutput)} -y"
            "aac" -> "-v error -hide_banner -i ${q(localInput)} -codec:a aac -b:a $bitrate -map 0:a -f mp4 ${q(stagedOutput)} -y"
            else -> "-v error -hide_banner -i ${q(localInput)} -codec:a libmp3lame -b:a $bitrate -map 0:a -id3v2_version 3 ${q(stagedOutput)} -y"
        }
        val conversion = if (target.codec == "flac") {
            runFFmpegArguments(
                NativeFinalizationPolicy.flacAutoConversionArguments(
                    target, localInput, stagedOutput, state.bitDepth, state.sampleRate,
                ).toTypedArray(),
                shouldCancel,
            )
        } else {
            runFFmpeg(command, shouldCancel)
        }
        if (!conversion.first || !File(stagedOutput).exists()) {
            throw IllegalStateException("automatic conversion failed: ${conversion.second}")
        }
        val metadataFormat = if (target.codec == "aac") "m4a" else target.codec
        embedBasicMetadata(context, stagedOutput, input, metadataFormat)
        if (!promoteStagedConversion(stagedOutput, output)) {
            throw IllegalStateException("failed to promote automatic conversion output")
        }

        if (sameLocalExtension) {
            state.filePath = localInput
            state.fileName = File(localInput).name
        } else {
            replaceStatePath(context, input, state, output, deleteOld = true)
        }
        adoptedOutput = true
    } finally {
        if (!adoptedOutput) {
            File(stagedOutput).delete()
            if (output != localInput) File(output).delete()
        }
        if (sourceWasSaf) File(localInput).delete()
    }

    state.audioCodec = target.codec
    if (target.codec == "flac") {
        state.bitDepth = state.bitDepth?.let { depth -> target.maxBitDepth?.let { minOf(depth, it) } ?: depth }
        state.sampleRate = state.sampleRate?.let { rate -> target.maxSampleRate?.let { minOf(rate, it) } ?: rate }
        state.bitrateKbps = null
        state.quality = NativeFinalizationPolicy.displayAudioQuality(
            state.filePath, state.fileName, state.bitDepth, state.sampleRate, null, "flac", null,
        ) ?: "FLAC"
        input.result.remove("actual_bitrate")
        input.result.remove("bitrate")
        input.result.put("actual_bit_depth", state.bitDepth)
        input.result.put("actual_sample_rate", state.sampleRate)
        input.result.put("actual_container", "flac")
        input.result.put("actual_extension", ".flac")
        input.result.put("output_extension", ".flac")
    } else {
        state.quality = "${if (target.codec == "aac") "AAC" else target.codec.uppercase(Locale.ROOT)} ${target.bitrateKbps}kbps"
        state.bitDepth = null
        state.sampleRate = null
        state.bitrateKbps = target.bitrateKbps
    }
}

private fun NativeDownloadFinalizer.uniqueAutoConversionOutputPath(inputPath: String, extension: String): String {
    val source = File(inputPath)
    val requested = File(source.parentFile, "${source.nameWithoutExtension}$extension")
    if (!requested.exists()) return requested.absolutePath
    for (index in 2..Int.MAX_VALUE) {
        val candidate = File(
            source.parentFile,
            "${source.nameWithoutExtension} ($index)$extension",
        )
        if (!candidate.exists()) return candidate.absolutePath
    }
    throw IllegalStateException("could not allocate automatic conversion output")
}

internal fun NativeDownloadFinalizer.finalizeContainerConversion(
    context: Context,
    input: NativeDownloadFinalizer.FinalizeInput,
    state: NativeDownloadFinalizer.FinalizeState,
    shouldCancel: () -> Boolean,
) {
    if (outputExt(input) != ".flac") return
    val forceContainerConversion = shouldForceContainerConversion(input, state)
    // The decrypted container may still contain FLAC. Only the measured
    // stream codec can decide whether an M4A/MP4 should be preserved.
    val mayNeedContainerConversion = forceContainerConversion ||
        looksLikeM4a(state.filePath, state.fileName) ||
        isMP4ContainerFile(state.filePath) ||
        state.filePath.startsWith("content://")
    if (!mayNeedContainerConversion) return

    val localInput = materializeForFFmpeg(context, input, state)
    val deleteLocalInput = state.filePath.startsWith("content://")
    val output = buildOutputPath(localInput, ".flac")
    val stagedOutput = stagedConversionPath(output)
    var adoptedOutput = false
    var createdOutput = false
    try {
        val codec = probePrimaryAudioCodec(localInput, shouldCancel)
        val isAlreadyNativeFlac = codec == "flac" && isNativeFlacFile(localInput)
        if (!NativeFinalizationPolicy.shouldAttemptLosslessContainerConversion(
                forceContainerConversion,
                codec,
            )
        ) {
            Log.d(TAG, "Preserving native container; audio codec is ${codec.ifBlank { "unknown" }}")
            // The preserved stream is not FLAC but still carries the
            // requested .flac name. Rename to the real container so the
            // metadata/ReplayGain writers pick the right format: an
            // MP4 stream under a .flac name fails "fLaC head incorrect"
            // on every subsequent write and the file is never repaired.
            adoptPreservedContainerExtension(state, localInput, codec)
            return
        }
        if (isAlreadyNativeFlac) {
            Log.d(TAG, "Native FLAC payload detected; publishing as FLAC and embedding metadata")
            val nativeFlacOutput = if (localInput.lowercase(Locale.ROOT).endsWith(".flac")) {
                localInput
            } else {
                File(localInput).copyTo(File(stagedOutput), overwrite = true)
                if (!promoteStagedConversion(stagedOutput, output)) {
                    throw IllegalStateException("failed to publish native FLAC output")
                }
                createdOutput = true
                output
            }
            embedBasicMetadata(context, nativeFlacOutput, input, "flac")
            replaceStatePath(context, input, state, nativeFlacOutput, deleteOld = true)
            state.audioCodec = "flac"
            adoptedOutput = true
            return
        }
        convertToStagedFlac(
            input = localInput,
            stagedOutput = stagedOutput,
            codec = codec,
            execute = { arguments -> runFFmpegArguments(arguments, shouldCancel) },
            checkCancelled = { checkCancelled(shouldCancel) },
        )
        // Tag the staged file before replacing a same-suffix source.
        embedBasicMetadata(context, stagedOutput, input, "flac")
        if (!promoteStagedConversion(stagedOutput, output)) {
            throw IllegalStateException("failed to publish container conversion output")
        }
        createdOutput = true
        replaceStatePath(context, input, state, output, deleteOld = true)
        state.audioCodec = "flac"
        adoptedOutput = true
    } finally {
        if (!adoptedOutput) {
            File(stagedOutput).delete()
            if (createdOutput && output != localInput) File(output).delete()
        }
        if (deleteLocalInput) File(localInput).delete()
    }
}

/// Renames a preserved lossy/unknown stream away from its requested .flac
/// name to match its actual container (mirrors the Dart pipeline's
/// post-download rename). Local files only: legacy content:// outputs are
/// left untouched. No-op when the container cannot be identified.
private fun NativeDownloadFinalizer.adoptPreservedContainerExtension(
    state: NativeDownloadFinalizer.FinalizeState,
    localInput: String,
    codec: String,
) {
    if (state.filePath.startsWith("content://")) return
    val currentFile = File(state.filePath)
    if (!currentFile.exists()) return
    if (!currentFile.name.lowercase(Locale.ROOT).endsWith(".flac")) return

    val newExt = when {
        isMP4ContainerFile(localInput) ->
            NativeFinalizationPolicy.isoBmffAudioExtension(codec)
        codec == "mp3" -> ".mp3"
        codec == "opus" -> ".opus"
        else -> return
    }
    val renamed = File(uniqueAutoConversionOutputPath(currentFile.path, newExt))
    if (!currentFile.renameTo(renamed)) {
        Log.w(TAG, "Failed to rename preserved container to ${renamed.name}")
        return
    }
    Log.i(TAG, "Preserved container renamed: ${currentFile.name} -> ${renamed.name}")
    state.filePath = renamed.absolutePath
    if (state.fileName.isNotBlank()) {
        state.fileName = renamed.name
    }
    state.audioCodec = normalizeAudioCodec(codec)
}

private fun NativeDownloadFinalizer.outputExt(input: NativeDownloadFinalizer.FinalizeInput): String {
    val safExt = input.request.optString("saf_output_ext", "")
    val ext = safExt.ifBlank { input.request.optString("output_ext", "") }
    return normalizeExt(ext.ifBlank { ".flac" })
}

private fun NativeDownloadFinalizer.looksLikeM4a(path: String, fileName: String): Boolean {
    val lowerPath = path.lowercase(Locale.ROOT)
    val lowerName = fileName.lowercase(Locale.ROOT)
    return lowerPath.endsWith(".m4a") ||
        lowerPath.endsWith(".mp4") ||
        lowerName.endsWith(".m4a") ||
        lowerName.endsWith(".mp4")
}
