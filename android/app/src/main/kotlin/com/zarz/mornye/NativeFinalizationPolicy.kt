package com.zarz.mornye

import java.util.Locale
import kotlin.math.roundToInt

/**
 * Pure finalization decisions shared by the Android background pipeline.
 *
 * Keeping format and naming policy free of Android/FFmpeg dependencies lets
 * local JVM tests cover the branches that otherwise live inside the native
 * finalizer's I/O-heavy orchestration.
 */
internal object NativeFinalizationPolicy {
    fun durationMilliseconds(requestMilliseconds: Long, trackSeconds: Long): Long {
        if (requestMilliseconds > 0) return requestMilliseconds
        return trackSeconds.coerceIn(0, Long.MAX_VALUE / 1000) * 1000
    }

    fun resolvedAlbumRelativeDirectory(
        relativeDirectory: String,
        albumFolderTemplate: String,
        resolvedAlbumFolder: String,
    ): String {
        val albumFolder = resolvedAlbumFolder.trim()
        if (!albumFolderTemplate.contains("{album}") || albumFolder.isEmpty()) {
            return relativeDirectory
        }
        // The backend supplies one sanitized leaf, never a relative path.
        if (albumFolder == "." || albumFolder == ".." ||
            albumFolder.contains('/') || albumFolder.contains('\\')) {
            return relativeDirectory
        }
        val parent = relativeDirectory.substringBeforeLast('/', "")
        return if (parent.isEmpty()) albumFolder else "$parent/$albumFolder"
    }

    private val lyricsMetadataLinePattern = Regex(
        "^\\[[a-z][a-z0-9_-]*:.*]$",
        RegexOption.IGNORE_CASE,
    )
    private val lyricsBackgroundPattern = Regex(
        "^\\[bg:(.*)]$",
        RegexOption.IGNORE_CASE,
    )
    private val lyricsTimestampPattern = Regex(
        "^\\[\\d{1,3}:\\d{1,2}(?:[.:]\\d{1,3})?]",
    )
    private val lyricsInlineTimestampPattern = Regex(
        "<\\d{1,3}:\\d{1,2}(?:[.:]\\d{1,3})?>",
    )
    private val lyricsVoicePrefixPattern = Regex("^v[1-9][0-9]*:", RegexOption.IGNORE_CASE)

    fun hasUsableLyricsContent(raw: String?): Boolean {
        val lyrics = raw.orEmpty().trim()
        if (lyrics.equals("[instrumental:true]", ignoreCase = true)) return true

        for (line in lyrics.lineSequence()) {
            var cleaned = line.trim()
            if (cleaned.isEmpty()) continue

            val background = lyricsBackgroundPattern.matchEntire(cleaned)
            if (background != null) {
                cleaned = background.groupValues[1].trim()
            } else if (lyricsMetadataLinePattern.matches(cleaned)) {
                continue
            }

            while (lyricsTimestampPattern.containsMatchIn(cleaned)) {
                cleaned = lyricsTimestampPattern.replaceFirst(cleaned, "").trim()
            }
            cleaned = lyricsInlineTimestampPattern.replace(cleaned, "").trim()
            cleaned = lyricsVoicePrefixPattern.replaceFirst(cleaned, "").trim()
            if (cleaned.isNotEmpty()) return true
        }
        return false
    }

    fun resolveLyricsContent(existing: String?, fetch: () -> String): String {
        val supplied = existing.orEmpty().trim()
        if (hasUsableLyricsContent(supplied)) return supplied
        val fetched = fetch().trim()
        return if (hasUsableLyricsContent(fetched)) fetched else ""
    }

    data class AutoConversionTarget(
        val codec: String,
        val extension: String,
        val bitrateKbps: Int,
    )

    fun autoConversionTarget(
        enabled: Boolean,
        format: String?,
        bitrate: String?,
    ): AutoConversionTarget? {
        if (!enabled) return null
        val codec = when (format?.trim()?.lowercase(Locale.ROOT)) {
            "aac", "m4a" -> "aac"
            "opus" -> "opus"
            else -> "mp3"
        }
        val normalizedBitrate = Regex("(\\d+)")
            .find(bitrate.orEmpty())
            ?.groupValues
            ?.getOrNull(1)
            ?.toIntOrNull()
            ?.takeIf { it in setOf(128, 192, 256, 320) }
            ?: 320
        val extension = when (codec) {
            "aac" -> ".m4a"
            "opus" -> ".opus"
            else -> ".mp3"
        }
        return AutoConversionTarget(codec, extension, normalizedBitrate)
    }

    fun autoConversionAlreadySatisfied(
        target: AutoConversionTarget,
        audioCodec: String?,
        bitrateKbps: Int?,
    ): Boolean {
        return normalizeAudioCodec(audioCodec) == target.codec &&
            bitrateKbps == target.bitrateKbps
    }

    fun normalizeAudioCodec(codec: String?): String? {
        val normalized = normalizeOptional(codec)
            ?.lowercase(Locale.ROOT)
            ?.replace('-', '_')
            ?: return null
        return when (normalized) {
            "mp4a" -> "aac"
            "ec_3" -> "eac3"
            "ac_3" -> "ac3"
            "ac_4" -> "ac4"
            "mp4" -> "m4a"
            "ogg" -> "opus"
            else -> normalized
        }
    }

    /**
     * Audio-only ISO-BMFF files conventionally use .m4a. AC-4 remains .mp4
     * because its passthrough and standards-repair path depends on that
     * container identity.
     */
    fun isoBmffAudioExtension(audioCodec: String?): String {
        return if (normalizeAudioCodec(audioCodec) == "ac4") ".mp4" else ".m4a"
    }

    fun audioFormatForCodec(codec: String?): String? {
        return when (normalizeAudioCodec(codec)) {
            "flac" -> "FLAC"
            "alac" -> "ALAC"
            "aac" -> "AAC"
            "eac3" -> "EAC3"
            "ac3" -> "AC3"
            "ac4" -> "AC4"
            "mp3" -> "MP3"
            "opus" -> "OPUS"
            else -> null
        }
    }

    fun isLossyAudioCodec(codec: String?): Boolean {
        return when (normalizeAudioCodec(codec)) {
            "aac", "eac3", "ac3", "ac4", "mp3", "opus", "m4a" -> true
            else -> false
        }
    }

    fun isLosslessAudioCodec(codec: String?): Boolean {
        val normalized = normalizeAudioCodec(codec) ?: return false
        if (normalized.startsWith("pcm_")) return true
        return normalized in setOf(
            "alac",
            "flac",
            "wavpack",
            "ape",
            "tta",
            "mlp",
            "truehd",
            "shorten",
        )
    }

    /**
     * Decides whether a stream should enter the lossless container conversion
     * path. A missing or generic M4A/MP4 codec is inconclusive rather than
     * proof of lossy audio; an extension capability may explicitly request
     * that FFmpeg attempt the conversion. Known lossy codecs remain native.
     */
    fun shouldAttemptLosslessContainerConversion(
        forceConversion: Boolean,
        probedCodec: String?,
    ): Boolean {
        if (isLosslessAudioCodec(probedCodec)) return true
        val normalized = normalizeAudioCodec(probedCodec)
        val inconclusive = normalized == null || normalized == "m4a"
        return forceConversion && inconclusive
    }

    fun displayAudioQuality(
        filePath: String,
        fileName: String,
        bitDepth: Int?,
        sampleRate: Int?,
        bitrateKbps: Int?,
        audioCodec: String? = null,
        storedQuality: String?,
    ): String? {
        val format = audioFormatForCodec(audioCodec)
            ?: audioFormatForPath(filePath, fileName)
        if (
            format == "OPUS" ||
            format == "MP3" ||
            format == "AAC" ||
            format == "EAC3" ||
            format == "AC3" ||
            format == "AC4" ||
            (format == "M4A" && (bitDepth == null || bitDepth <= 0))
        ) {
            return if (bitrateKbps != null && bitrateKbps >= 16) {
                "$format ${bitrateKbps}kbps"
            } else {
                nonPlaceholderQuality(storedQuality) ?: format
            }
        }

        if (bitDepth != null && bitDepth > 0 && sampleRate != null && sampleRate > 0) {
            return "$bitDepth-bit/${sampleRateLabel(sampleRate)}kHz"
        }
        return nonPlaceholderQuality(storedQuality) ?: normalizeOptional(storedQuality)
    }

    fun qualityVariantFilenameLabel(
        measuredQuality: String,
        bitDepth: Int?,
        sampleRate: Int?,
        bitrateKbps: Int?,
        audioCodec: String?,
    ): String? {
        if (isLossyAudioCodec(audioCodec)) {
            val bitrate = bitrateKbps ?: Regex(
                "\\b(\\d+)\\s*kbps\\b",
                RegexOption.IGNORE_CASE,
            ).find(measuredQuality)?.groupValues?.getOrNull(1)?.toIntOrNull()
            return bitrate?.takeIf { it >= 16 }?.let { "${it}kbps" }
        }

        var resolvedBitDepth = bitDepth
        var resolvedSampleRate = sampleRate
        if (resolvedBitDepth == null || resolvedSampleRate == null) {
            val match = Regex(
                "\\b(\\d+)\\s*(?:-|\\s)?bit\\s*[/_-]\\s*(\\d+(?:\\.\\d+)?)\\s*k?hz\\b",
                RegexOption.IGNORE_CASE,
            ).find(measuredQuality)
            resolvedBitDepth =
                resolvedBitDepth ?: match?.groupValues?.getOrNull(1)?.toIntOrNull()
            resolvedSampleRate =
                resolvedSampleRate
                    ?: match?.groupValues?.getOrNull(2)?.toDoubleOrNull()?.let { rate ->
                        if (rate < 1000) {
                            (rate * 1000).roundToInt()
                        } else {
                            rate.roundToInt()
                        }
                    }
        }
        if (
            resolvedBitDepth == null ||
            resolvedBitDepth <= 0 ||
            resolvedSampleRate == null ||
            resolvedSampleRate <= 0
        ) {
            return null
        }
        return "${resolvedBitDepth}bit-${sampleRateLabel(resolvedSampleRate)}kHz"
    }

    fun applyQualityVariantFilenameLabel(
        fileName: String,
        stagingLabel: String,
        qualityLabel: String,
    ): String {
        if (stagingLabel.isNotEmpty() && fileName.contains(stagingLabel)) {
            return fileName.replace(stagingLabel, qualityLabel)
        }
        if (fileName.contains(qualityLabel)) return fileName
        val dotIndex = fileName.lastIndexOf('.')
        val hasExtension = dotIndex > 0
        val stem = if (hasExtension) fileName.substring(0, dotIndex) else fileName
        val extension = if (hasExtension) fileName.substring(dotIndex) else ""
        return "$stem - $qualityLabel$extension"
    }

    fun removeQualityVariantStagingLabel(
        fileName: String,
        stagingLabel: String,
    ): String {
        if (stagingLabel.isEmpty() || !fileName.contains(stagingLabel)) return fileName
        val dotIndex = fileName.lastIndexOf('.')
        val hasExtension = dotIndex > 0
        val stem = if (hasExtension) fileName.substring(0, dotIndex) else fileName
        val extension = if (hasExtension) fileName.substring(dotIndex) else ""
        val cleanedStem = stem
            .replace(stagingLabel, "")
            .replace(Regex("[\\s_-]+$"), "")
            .trim()
            .ifBlank { "track" }
        return "$cleanedStem$extension"
    }

    fun resolveQualityVariantFilename(
        fileName: String,
        stagingLabel: String,
        qualityLabel: String,
        collisionOnly: Boolean,
        cleanNameExists: Boolean,
    ): String {
        if (!collisionOnly || cleanNameExists) {
            return applyQualityVariantFilenameLabel(fileName, stagingLabel, qualityLabel)
        }
        return removeQualityVariantStagingLabel(fileName, stagingLabel)
    }

    /**
     * Returns the user-facing name that a deferred SAF download was assigned
     * before its audio was materialized in the app cache. Container and
     * decryption passes may replace [currentFileName] with a temporary
     * `native_saf_work_*` name, which must never become the published name.
     */
    fun logicalOutputFileName(
        deferredSafPublish: Boolean,
        resultSafFileName: String?,
        requestSafFileName: String?,
        currentFileName: String,
    ): String {
        if (!deferredSafPublish) return currentFileName
        return normalizeOptional(resultSafFileName)
            ?: normalizeOptional(requestSafFileName)
            ?: currentFileName
    }

    fun resolvePreferredDecryptionExtension(
        inputPath: String,
        requested: String,
    ): String {
        val normalizedRequest = normalizeExtension(requested)
        if (normalizedRequest.isNotBlank()) return normalizedRequest
        val lower = inputPath.lowercase(Locale.ROOT)
        return when {
            lower.endsWith(".m4a") -> ".flac"
            lower.endsWith(".flac") -> ".flac"
            lower.endsWith(".mp3") -> ".mp3"
            lower.endsWith(".opus") -> ".opus"
            lower.endsWith(".mp4") -> ".mp4"
            else -> ".flac"
        }
    }

    fun formatIndexTag(number: Int, total: Int): String {
        if (number <= 0) return "0"
        return if (total > 0) "$number/$total" else number.toString()
    }

    /**
     * The app request contains the album artist after batch normalization and
     * user metadata filters. Provider results are only a fallback: preferring
     * them would reintroduce per-track collaboration credits while finalizing.
     */
    fun authoritativeAlbumArtist(
        requestValue: String?,
        trackValue: String?,
        providerResultValue: String?,
    ): String {
        return normalizeOptional(requestValue)
            ?: normalizeOptional(trackValue)
            ?: normalizeOptional(providerResultValue)
            ?: ""
    }

    fun metadataCoverUrl(resultValue: String?, requestValue: String?, trackValue: String?): String {
        // The backend result preserves the selected metadata cover, including
        // full-size artwork returned by source enrichment.
        return normalizeOptional(resultValue)
            ?: normalizeOptional(requestValue)
            ?: normalizeOptional(trackValue)
            ?: ""
    }

    // Same separator set as the Rust writer and Dart's primaryArtistTagValue.
    // Android's regex engine rejects Pattern.UNICODE_CHARACTER_CLASS when this
    // object initializes, so Unicode spaces are listed explicitly instead.
    private const val PRIMARY_ARTIST_SPACE = "[\\s\\p{Z}]"
    private val primaryArtistSeparator = Regex(
        "$PRIMARY_ARTIST_SPACE*[,;&]$PRIMARY_ARTIST_SPACE*" +
            "|$PRIMARY_ARTIST_SPACE+x$PRIMARY_ARTIST_SPACE+" +
            "|$PRIMARY_ARTIST_SPACE+(?:feat(?:uring|ured|ure)?|ft|with)\\.?" +
            "(?:$PRIMARY_ARTIST_SPACE+|$)",
        RegexOption.IGNORE_CASE,
    )

    /**
     * Artist tag value for [mode]. Only "primary" changes the value: the first
     * credited artist for every format. Joined and split values pass through;
     * the backend writer owns Vorbis splitting.
     */
    fun artistTagValue(value: String, mode: String?): String {
        if (!mode.orEmpty().trim().equals("primary", ignoreCase = true)) return value
        val trimmed = value.trim()
        return trimmed.split(primaryArtistSeparator)
            .map(String::trim)
            .firstOrNull(String::isNotEmpty)
            ?: trimmed
    }

    private val metadataListSeparator = Regex("\\s*[,;]\\s*")

    fun metadataTagValue(value: String, separator: String?): String {
        val delimiter = separator.orEmpty()
        if (delimiter.isEmpty() || delimiter.length > 16 ||
            delimiter.any { it <= '\u001f' || it == '\u007f' }) return value
        return value.split(metadataListSeparator).map(String::trim)
            .filter(String::isNotEmpty).joinToString(delimiter)
    }

    private fun audioFormatForPath(filePath: String, fileName: String): String? {
        for (candidate in listOf(filePath, fileName)) {
            val lower = candidate.trim().lowercase(Locale.ROOT)
            when {
                lower.endsWith(".opus") || lower.endsWith(".ogg") -> return "OPUS"
                lower.endsWith(".mp3") -> return "MP3"
                lower.endsWith(".aac") -> return "AAC"
                lower.endsWith(".m4a") || lower.endsWith(".mp4") -> return "M4A"
            }
        }
        return null
    }

    private fun nonPlaceholderQuality(quality: String?): String? {
        val normalized = normalizeOptional(quality) ?: return null
        val bitrateMatch =
            Regex("\\b(\\d+)\\s*kbps\\b", RegexOption.IGNORE_CASE).find(normalized)
        if (bitrateMatch != null) {
            val bitrate = bitrateMatch.groupValues.getOrNull(1)?.toIntOrNull()
            if (bitrate != null && bitrate < 16) return null
        }
        val key = normalized
            .lowercase(Locale.ROOT)
            .replace(Regex("[^a-z0-9]+"), "_")
            .trim('_')
        val placeholders = setOf(
            "best",
            "lossless",
            "hi_res",
            "hires",
            "hi_res_lossless",
            "hires_lossless",
            "high",
            "cd",
            "flac_best_available",
        )
        return if (placeholders.contains(key)) null else normalized
    }

    private fun sampleRateLabel(sampleRate: Int): String {
        val khz = sampleRate / 1000.0
        val precision = if (sampleRate % 1000 == 0) 0 else 1
        return "%.${precision}f".format(Locale.US, khz)
    }

    private fun normalizeOptional(value: String?): String? {
        val trimmed = value?.trim().orEmpty()
        if (trimmed.isEmpty() || trimmed.equals("null", ignoreCase = true)) {
            return null
        }
        return trimmed
    }

    internal fun normalizeExtension(extension: String?): String {
        val trimmed = extension?.trim().orEmpty()
        if (trimmed.isEmpty()) return ""
        val lower = trimmed.lowercase(Locale.ROOT)
        return if (lower.startsWith(".")) lower else ".$lower"
    }
}
