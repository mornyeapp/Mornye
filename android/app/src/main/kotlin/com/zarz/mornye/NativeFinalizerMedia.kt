package com.zarz.mornye

import android.content.Context
import android.util.Base64
import android.util.Log
import com.zarz.mornye.SafDownloadHandler.mimeTypeForExt
import com.zarz.mornye.SafDownloadHandler.normalizeExt
import com.zarz.mornye.NativeFinalizationPolicy.applyQualityVariantFilenameLabel
import com.zarz.mornye.NativeFinalizationPolicy.artistTagValue
import com.zarz.mornye.NativeFinalizationPolicy.metadataTagValue
import com.zarz.mornye.NativeFinalizationPolicy.formatIndexTag
import com.zarz.mornye.NativeFinalizationPolicy.logicalOutputFileName
import com.zarz.mornye.NativeFinalizationPolicy.removeQualityVariantStagingLabel
import com.zarz.mornye.NativeFinalizationPolicy.resolveQualityVariantFilename
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.util.Locale

internal fun NativeDownloadFinalizer.qualityVariantFilenameLabel(state: NativeDownloadFinalizer.FinalizeState): String? {
    return NativeFinalizationPolicy.qualityVariantFilenameLabel(
        measuredQuality = state.quality,
        bitDepth = state.bitDepth,
        sampleRate = state.sampleRate,
        bitrateKbps = state.bitrateKbps,
        audioCodec = state.audioCodec,
    )
}

internal fun NativeDownloadFinalizer.finalizeQualityVariantFilename(
    context: Context,
    input: NativeDownloadFinalizer.FinalizeInput,
    state: NativeDownloadFinalizer.FinalizeState,
) {
    if (!input.request.optBoolean("allow_quality_variant", false)) return
    val stagingLabel = input.request.optString("quality_variant", "").trim()
    val qualityLabel = qualityVariantFilenameLabel(state)
    if (qualityLabel == null) {
        Log.w(TAG, "Keeping temporary quality label because final audio specifications are unavailable")
        return
    }

    val logicalFileName = logicalOutputFileName(
        deferredSafPublish = isDeferredSafPublish(input),
        resultSafFileName = input.result.optString("saf_final_file_name", ""),
        requestSafFileName = input.request.optString("saf_file_name", ""),
        currentFileName = state.fileName,
    )
    val variantName = applyQualityVariantFilenameLabel(
        fileName = logicalFileName,
        stagingLabel = stagingLabel,
        qualityLabel = qualityLabel,
    )
    val cleanName = removeQualityVariantStagingLabel(logicalFileName, stagingLabel)
    val collisionOnly = input.request.optBoolean("quality_variant_collision_only", false)
    val preferredName = variantName
    if (preferredName == logicalFileName && preferredName == state.fileName) return
    input.result.put("quality_variant_file_name", preferredName)
    if (isDeferredSafPublish(input)) {
        state.fileName = preferredName
        return
    }

    if (state.filePath.startsWith("content://")) {
        val tempPath = SafDownloadHandler.copyContentUriToTemp(context, state.filePath) ?: return
        try {
            val treeUri = input.request.optString("saf_tree_uri", "")
            val relativeDir = input.request.optString("saf_relative_dir", "")
            val writeResult = if (collisionOnly) {
                SafDownloadHandler.writeFileToSafCollisionAware(
                    context = context,
                    treeUriStr = treeUri,
                    relativeDir = relativeDir,
                    cleanFileName = cleanName,
                    variantFileName = variantName,
                    mimeType = mimeTypeForExt(File(variantName).extension),
                    srcPath = tempPath,
                    preservedSuffix = qualityLabel,
                )
            } else {
                SafDownloadHandler.writeFileToSafUnique(
                    context = context,
                    treeUriStr = treeUri,
                    relativeDir = relativeDir,
                    fileName = preferredName,
                    mimeType = mimeTypeForExt(File(preferredName).extension),
                    srcPath = tempPath,
                    preservedSuffix = qualityLabel,
                )
            } ?: return
            SafDownloadHandler.deleteContentUri(context, state.filePath)
            state.filePath = writeResult.uri
            state.fileName = writeResult.fileName
        } finally {
            File(tempPath).delete()
        }
    } else {
        val source = File(state.filePath)
        val cleanTarget = File(source.parentFile, cleanName)
        val lockTarget = if (collisionOnly) cleanTarget else File(source.parentFile, preferredName)
        val lockKey = lockTarget.absolutePath.lowercase(Locale.ROOT)
        qualityVariantNameLocks.withLock(lockKey) {
            val selectedName = if (collisionOnly) {
                resolveQualityVariantFilename(
                    fileName = logicalFileName,
                    stagingLabel = stagingLabel,
                    qualityLabel = qualityLabel,
                    collisionOnly = true,
                    cleanNameExists = cleanTarget.absolutePath != source.absolutePath && cleanTarget.exists(),
                )
            } else {
                preferredName
            }
            input.result.put("quality_variant_file_name", selectedName)
            if (selectedName == state.fileName) return@withLock
            val target = uniqueLocalFile(source.parentFile, selectedName)
            if (!source.renameTo(target)) {
                Log.w(TAG, "Could not rename quality variant output: ${source.absolutePath}")
                return@withLock
            }
            state.filePath = target.absolutePath
            state.fileName = target.name
        }
    }

    input.result.put("file_path", state.filePath)
    input.result.put("file_name", state.fileName)
    input.result.optJSONObject("replaygain")?.let { replayGain ->
        replayGain.put("file_path", state.filePath)
        replayGain.put("file_name", state.fileName)
    }
}

internal fun NativeDownloadFinalizer.uniqueLocalFile(parent: File?, preferredName: String): File {
    val directory = parent ?: return File(preferredName)
    var candidate = File(directory, preferredName)
    if (!candidate.exists()) return candidate
    val dotIndex = preferredName.lastIndexOf('.')
    val hasExtension = dotIndex > 0
    val stem = if (hasExtension) preferredName.substring(0, dotIndex) else preferredName
    val extension = if (hasExtension) preferredName.substring(dotIndex) else ""
    var counter = 2
    while (candidate.exists()) {
        candidate = File(directory, "$stem ($counter)$extension")
        counter++
    }
    return candidate
}

internal fun NativeDownloadFinalizer.writeExternalLrc(context: Context, input: NativeDownloadFinalizer.FinalizeInput, state: NativeDownloadFinalizer.FinalizeState) {
    if (!input.request.optBoolean("embed_metadata", false) || !input.request.optBoolean("embed_lyrics", false)) return
    val lyricsMode = input.request.optString("lyrics_mode", "")
    if (lyricsMode != "external" && lyricsMode != "both") return
    val lrc = resolveLyricsLrc(context, input)
    if (
        !NativeFinalizationPolicy.hasUsableLyricsContent(lrc) ||
        lrc.trim().equals("[instrumental:true]", ignoreCase = true)
    ) return
    val audioFileName = if (isDeferredSafRequest(input)) {
        desiredFileName(input, state, File(state.filePath).extension)
    } else {
        state.fileName
    }
    val baseName = audioFileName.replace(Regex("\\.[^.]+$"), "")
    if (isDeferredSafRequest(input)) {
        state.pendingExternalLrc = lrc
        state.pendingExternalLrcFileName = "$baseName.lrc"
        return
    }
    if (state.filePath.startsWith("content://")) {
        val treeUri = input.request.optString("saf_tree_uri", "")
        val relativeDir = input.request.optString("saf_relative_dir", "")
        val temp = File(context.cacheDir, "native_lrc_${System.nanoTime()}.lrc")
        temp.writeText(lrc)
        try {
            val uri = SafDownloadHandler.writeFileToSaf(
                context = context,
                treeUriStr = treeUri,
                relativeDir = relativeDir,
                fileName = "$baseName.lrc",
                mimeType = "application/octet-stream",
                srcPath = temp.absolutePath,
            )
            state.externalLrcWritten = uri != null
        } finally {
            temp.delete()
        }
    } else {
        val target = File(File(state.filePath).parentFile, "$baseName.lrc")
        target.writeText(lrc)
        state.externalLrcWritten = true
    }
}

internal fun NativeDownloadFinalizer.resolveLyricsLrc(context: Context, input: NativeDownloadFinalizer.FinalizeInput): String {
    return try {
        val fetched = NativeFinalizationPolicy.resolveLyricsContent(
            input.result.optString("lyrics_lrc", ""),
        ) {
            val spotifyId = trackString(input, "id", input.request.optString("spotify_id", ""))
            val trackName = trackString(input, "name", input.request.optString("track_name", ""))
            val artistName = trackString(input, "artistName", input.request.optString("artist_name", ""))
            if (trackName.isBlank() || artistName.isBlank()) return@resolveLyricsContent ""
            createCoreBackend(context).getLyricsLrc(
                spotifyId,
                trackName,
                artistName,
                "",
                lyricsDurationMs(input),
            )
        }
        if (fetched.isNotEmpty()) {
            input.result.put("lyrics_lrc", fetched)
        }
        fetched
    } catch (error: Exception) {
        Log.w(TAG, "Lyrics lookup failed during download: ${error.message}")
        ""
    }
}

internal fun NativeDownloadFinalizer.lyricsDurationMs(input: NativeDownloadFinalizer.FinalizeInput): Long {
    val requestDuration = input.request.optLong("duration_ms", 0L)
    val trackDuration = trackInt(input, "duration", 0).toLong()
    return NativeFinalizationPolicy.durationMilliseconds(requestDuration, trackDuration)
}

internal fun nativeMetadataEditHandled(response: String): Boolean {
    val result = JSONObject(response)
    val error = if (result.isNull("error")) "" else result.optString("error", "").trim()
    val method = result.optString("method", "").trim()
    check(result.opt("success") == true && error.isEmpty() && method.isNotEmpty()) {
        error.ifEmpty { "Native metadata editor returned no successful result" }
    }
    return method != "ffmpeg"
}

internal fun NativeDownloadFinalizer.embedBasicMetadata(context: Context, path: String, input: NativeDownloadFinalizer.FinalizeInput, format: String) {
    if (!input.request.optBoolean("embed_metadata", false)) return
    val title = resultString(input, "title").ifBlank {
        trackString(input, "name", requestString(input, "track_name"))
    }
    val artist = resultString(input, "artist").ifBlank {
        trackString(input, "artistName", requestString(input, "artist_name"))
    }
    val album = resultString(input, "album").ifBlank {
        trackString(input, "albumName", requestString(input, "album_name"))
    }
    val albumArtist = resolvedAlbumArtist(input)
    val date = resultString(input, "release_date").ifBlank {
        resultString(input, "date").ifBlank {
            trackString(input, "releaseDate", requestString(input, "release_date"))
        }
    }
    val trackNumberValue = positiveOrNull(input.result.optInt("track_number", 0), trackInt(input, "trackNumber", input.request.optInt("track_number", 0))) ?: 0
    val totalTracksValue = positiveOrNull(input.result.optInt("total_tracks", 0), trackInt(input, "totalTracks", input.request.optInt("total_tracks", 0))) ?: 0
    val discNumberValue = positiveOrNull(input.result.optInt("disc_number", 0), trackInt(input, "discNumber", input.request.optInt("disc_number", 0))) ?: 0
    val totalDiscsValue = positiveOrNull(input.result.optInt("total_discs", 0), trackInt(input, "totalDiscs", input.request.optInt("total_discs", 0))) ?: 0
    val trackNumber = formatIndexTag(trackNumberValue, totalTracksValue)
    val discNumber = formatIndexTag(discNumberValue, totalDiscsValue)
    val isrc = resultString(input, "isrc").ifBlank {
        trackString(input, "isrc", requestString(input, "isrc"))
    }
    val composer = resultString(input, "composer").ifBlank {
        trackString(input, "composer", requestString(input, "composer"))
    }
    val genre = resultString(input, "genre").ifBlank { requestString(input, "genre") }
    val label = resultString(input, "label").ifBlank { requestString(input, "label") }
    val copyright = resultString(input, "copyright").ifBlank { requestString(input, "copyright") }
    val comment = resultString(input, "comment").ifBlank {
        trackString(input, "comment", requestString(input, "comment"))
    }
    val albumType = resultString(input, "album_type").ifBlank {
        trackString(input, "albumType", requestString(input, "album_type"))
    }
    val upc = resultString(input, "upc").ifBlank {
        trackString(input, "upc", requestString(input, "upc"))
    }
    val isExplicit = input.result.optBoolean("explicit", false) ||
        input.track.optBoolean("explicit", false) ||
        input.request.optBoolean("explicit", false)
    val isCompilation = albumType.equals("compilation", ignoreCase = true)
    val lyricsMode = input.request.optString("lyrics_mode", "embed")
    val shouldResolveLyrics = input.request.optBoolean("embed_lyrics", false) &&
        (lyricsMode == "embed" || lyricsMode == "both")
    val lyrics = if (shouldResolveLyrics) resolveLyricsLrc(context, input) else ""
    val shouldEmbedLyrics = shouldResolveLyrics &&
        NativeFinalizationPolicy.hasUsableLyricsContent(lyrics) &&
        !lyrics.trim().equals("[instrumental:true]", ignoreCase = true)
    val artistTagMode = input.request.optString("artist_tag_mode", "")
    val separators = input.request.optJSONObject("metadata_separators") ?: JSONObject()
    // FLAC, MP3, Opus, and M4A all have backend tag writers that edit the
    // tag block atomically without an ffmpeg remux (which drops foreign
    // frames and rewrites the whole container). The backend answers
    // method=ffmpeg when it cannot handle the file natively.
    if (format == "flac" || format == "mp3" || format == "opus" || format == "m4a") {
        val nativeCover = downloadCoverForMetadata(context, input)
        val handledNatively = try {
            val fields = JSONObject()
                .put("title", title)
                .put("artist", artist)
                .put("album", album)
                .put("album_artist", albumArtist)
                .put("artist_tag_mode", artistTagMode)
                .put("date", date)
                .put("isrc", isrc)
                .put("composer", composer)
                .put("genre", genre)
                .put("label", label)
                .put("copyright", copyright)
                .put("comment", comment)
            for (key in listOf("artist", "album_artist", "composer", "genre")) {
                fields.put("${key}_separator", separators.optString(key, ""))
            }
            if (trackNumberValue > 0) fields.put("track_number", trackNumberValue.toString())
            if (totalTracksValue > 0) fields.put("track_total", totalTracksValue.toString())
            if (discNumberValue > 0) fields.put("disc_number", discNumberValue.toString())
            if (totalDiscsValue > 0) fields.put("disc_total", totalDiscsValue.toString())
            if (isExplicit) fields.put("explicit", "1")
            if (albumType.isNotBlank()) fields.put("album_type", albumType)
            if (upc.isNotBlank()) fields.put("upc", upc)
            if (isCompilation) fields.put("compilation", "1")
            if (nativeCover != null) fields.put("cover_path", nativeCover.absolutePath)
            if (shouldEmbedLyrics) {
                fields.put("lyrics", lyrics)
                fields.put("unsyncedlyrics", lyrics)
            }
            val response = createCoreBackend(context).editFileMetadata(path, fields.toString())
            nativeMetadataEditHandled(response)
        } catch (e: Exception) {
            if (format == "flac") throw e
            Log.w(TAG, "Native tag embed failed for $format: ${e.message}; falling back to ffmpeg")
            false
        } finally {
            nativeCover?.delete()
        }
        if (handledNatively) return
    }

    val ext = normalizeExt(File(path).extension).ifBlank { ".tmp" }
    val inputFile = File(path)
    // ".partial<ext>" keeps the temp invisible to library scans while FFmpeg
    // still infers the muxer from the real trailing extension.
    val temp = File(inputFile.parentFile, "${inputFile.nameWithoutExtension}_tagged.partial$ext")
    val isM4a = format == "m4a"
    val isOpus = format == "opus"
    val coverFile = if (isM4a || isOpus) downloadCoverForMetadata(context, input) else null
    val labelKey = if (isM4a) "organization" else "label"
    // The backend writer applies the artist mode itself; this FFmpeg fallback
    // must store the same primary artist when that mode is selected.
    val metadataPairs = mutableListOf(
        "title" to title,
        "artist" to metadataTagValue(artistTagValue(artist, artistTagMode), separators.optString("artist")),
        "album" to album,
        "album_artist" to metadataTagValue(artistTagValue(albumArtist, artistTagMode), separators.optString("album_artist")),
        "date" to date,
        "track" to trackNumber,
        "disc" to discNumber,
        "isrc" to isrc,
        "composer" to metadataTagValue(composer, separators.optString("composer")),
        "genre" to metadataTagValue(genre, separators.optString("genre")),
        labelKey to label,
        "copyright" to copyright,
        "comment" to comment,
        "ITUNESADVISORY" to if (isExplicit) "1" else "",
        "RELEASETYPE" to albumType.lowercase(),
        "BARCODE" to upc,
        "COMPILATION" to if (isCompilation) "1" else "",
        "lyrics" to if (shouldEmbedLyrics) lyrics else "",
        "unsyncedlyrics" to if (shouldEmbedLyrics) lyrics else "",
    )
    if (isM4a) {
        metadataPairs.add("rtng" to if (isExplicit) "1" else "")
        metadataPairs.add("cpil" to if (isCompilation) "1" else "")
    }
    if (isOpus && coverFile != null) {
        createMetadataBlockPicture(coverFile)?.let {
            metadataPairs.add("METADATA_BLOCK_PICTURE" to it)
        }
    }
    val metadataArgs = metadataPairs
        .filter { it.second.isNotBlank() && it.second != "0" }
        .joinToString(" ") { "-metadata ${it.first}=${q(it.second)}" }
    if (metadataArgs.isBlank() && coverFile == null) return
    val mp3Flags = if (format == "mp3") "-id3v2_version 3 " else ""
    var adoptedTemp = false
    var originalDeleted = false

    fun buildEmbedCommand(forceMov: Boolean): String {
        return if (isM4a && coverFile != null) {
            "-v error -hide_banner -i ${q(path)} -i ${q(coverFile.absolutePath)} " +
                "-map 0:a -c:a copy -map_metadata 0 -map 1:v -c:v copy " +
                "-disposition:v:0 attached_pic " +
                "-metadata:s:v ${q("title=Album cover")} " +
                "-metadata:s:v ${q("comment=Cover (front)")} " +
                "$metadataArgs -f ${if (forceMov) "mov" else "mp4"} ${q(temp.absolutePath)} -y"
        } else {
            val movFlag = if (forceMov) "-f mov " else ""
            "-v error -hide_banner -i ${q(path)} -map 0 -c copy -map_metadata 0 $metadataArgs $mp3Flags$movFlag${q(temp.absolutePath)} -y"
        }
    }

    try {
        var result = runFFmpeg(buildEmbedCommand(false))
        // MOV muxer fallback for codecs the MP4 muxer rejects (e.g. AC-4).
        if (!result.first && (isM4a || ext.equals(".mp4", ignoreCase = true))) {
            temp.delete()
            result = runFFmpeg(buildEmbedCommand(true))
        }
        if (result.first && temp.exists()) {
            fsyncQuietly(temp)
            // Rename directly over the original: a process kill between a
            // delete-first and the rename would lose the file entirely.
            adoptedTemp = temp.renameTo(inputFile)
            if (!adoptedTemp && inputFile.delete()) {
                originalDeleted = true
                adoptedTemp = temp.renameTo(inputFile)
            }
        }
    } finally {
        if (!adoptedTemp && !originalDeleted) {
            temp.delete()
        }
        coverFile?.delete()
    }
}

/**
 * Best-effort fsync so a file's bytes are durable before it is renamed
 * over another file; fsync on a fresh handle flushes the page cache pages
 * written earlier by ffmpeg in this process.
 */
internal fun NativeDownloadFinalizer.fsyncQuietly(file: File) {
    try {
        RandomAccessFile(file, "rw").use { it.fd.sync() }
    } catch (_: Exception) {
    }
}

internal fun NativeDownloadFinalizer.createMetadataBlockPicture(coverFile: File): String? {
    return try {
        if (!coverFile.exists() || coverFile.length() <= 0L) return null
        val imageData = coverFile.readBytes()
        if (imageData.isEmpty()) return null
        val mimeType = detectCoverMimeType(coverFile, imageData)
        val mimeBytes = mimeType.toByteArray(Charsets.UTF_8)
        val descriptionBytes = ByteArray(0)
        val blockSize = 4 + 4 + mimeBytes.size + 4 + descriptionBytes.size + 4 + 4 + 4 + 4 + 4 + imageData.size
        val buffer = ByteBuffer.allocate(blockSize)
        buffer.putInt(3)
        buffer.putInt(mimeBytes.size)
        buffer.put(mimeBytes)
        buffer.putInt(descriptionBytes.size)
        buffer.put(descriptionBytes)
        buffer.putInt(0)
        buffer.putInt(0)
        buffer.putInt(0)
        buffer.putInt(0)
        buffer.putInt(imageData.size)
        buffer.put(imageData)
        Base64.encodeToString(buffer.array(), Base64.NO_WRAP)
    } catch (e: Exception) {
        Log.w(TAG, "Failed to create Opus cover picture block: ${e.message}")
        null
    }
}

internal fun NativeDownloadFinalizer.detectCoverMimeType(coverFile: File, imageData: ByteArray): String {
    if (imageData.size >= 8 &&
        imageData[0] == 0x89.toByte() &&
        imageData[1] == 0x50.toByte() &&
        imageData[2] == 0x4E.toByte() &&
        imageData[3] == 0x47.toByte()
    ) {
        return "image/png"
    }
    if (imageData.size >= 3 &&
        imageData[0] == 0xFF.toByte() &&
        imageData[1] == 0xD8.toByte() &&
        imageData[2] == 0xFF.toByte()
    ) {
        return "image/jpeg"
    }
    val ext = coverFile.extension.lowercase(Locale.ROOT)
    if (ext == "png") return "image/png"
    return "image/jpeg"
}

internal fun NativeDownloadFinalizer.downloadCoverForMetadata(context: Context, input: NativeDownloadFinalizer.FinalizeInput): File? {
    val coverUrl = metadataCoverUrl(input).ifBlank { resultString(input, "cover_url") }
    if (coverUrl.isBlank()) return null

    val safeItemId = input.itemId.ifBlank { "item" }.replace(Regex("[^A-Za-z0-9._-]"), "_")
    val maxDimension = input.request.optLong("cover_max_dimension", 0L).coerceAtLeast(0L)
    val backend = createCoreBackend(context)
    val output = backend.createTemporaryMediaFile(context, "native_cover_${safeItemId}_", ".jpg")
    return try {
        backend.downloadCoverToFileSized(
            coverUrl,
            output.absolutePath,
            maxDimension
        )
        if (output.exists() && output.length() > 0L) {
            output
        } else {
            output.delete()
            null
        }
    } catch (e: Exception) {
        Log.w(TAG, "Failed to download metadata cover: ${e.message}")
        output.delete()
        null
    }
}
