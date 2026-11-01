package com.zarz.mornye

import androidx.documentfile.provider.DocumentFile
import org.json.JSONArray
import java.io.File
import java.io.Reader
import java.util.Locale

    /**
     * Extract the audio filename referenced by a CUE sheet file.
     * Reads the FILE "name" TYPE line from the .cue text.
     * Returns just the filename (no path), or null if not found.
     */
internal fun MainActivity.extractCueAudioFileName(cueTempPath: String): String? = try {
    File(cueTempPath).bufferedReader().use(::extractCueAudioFileName)
} catch (e: Exception) {
    android.util.Log.w("Mornye", "Failed to extract audio filename from CUE: ${e.message}")
    null
}

internal fun extractCueAudioFileName(source: Reader): String? {
    val reader = source.buffered(8192)
    while (true) {
        val line = reader.readLine() ?: return null
        cueAudioFileName(line)?.let { return it }
    }
}

internal data class CueAudioReference(val filename: String?)

internal fun readCueAudioReference(
    open: () -> Reader?,
    retryOnDenied: Boolean,
): CueAudioReference? {
    fun read(): CueAudioReference? = open()?.use {
        CueAudioReference(extractCueAudioFileName(it))
    }
    return try {
        read()
    } catch (error: SecurityException) {
        if (!retryOnDenied) throw error
        read()
    }
}

private fun cueAudioFileName(line: String): String? {
    val trimmed = line.trim().let {
        if (it.startsWith("\uFEFF")) it.removePrefix("\uFEFF").trim() else it
    }
    if (!trimmed.uppercase(Locale.ROOT).startsWith("FILE ")) return null
    val rest = trimmed.substring(5).trim()
    val filename = if (rest.startsWith("\"")) {
        val endQuote = rest.indexOf('"', 1)
        if (endQuote > 0) rest.substring(1, endQuote) else rest
    } else {
        val parts = rest.split("\\s+".toRegex())
        if (parts.size >= 2) parts.dropLast(1).joinToString(" ") else rest
    }
    return filename.substringAfterLast("/").substringAfterLast("\\")
}

    private val cueSiblingAudioExtensions = listOf(
        ".flac", ".wav", ".ape", ".mp3", ".ogg", ".wv", ".m4a", ".mp4", ".aac"
    )

internal fun MainActivity.getSafChildFileLookup(
        dir: DocumentFile,
        cache: MutableMap<String, Map<String, DocumentFile>>,
    ): Map<String, DocumentFile> {
        val dirKey = dir.uri.toString()
        return cache.getOrPut(dirKey) { safChildFileLookup(listSafChildrenOrThrow(dir)) }
    }

private fun safChildFileLookup(children: List<SafChildEntry>): Map<String, DocumentFile> =
    buildMap {
        for (child in children) {
            if (child.isDirectory) continue
            val childName = child.name?.trim().orEmpty()
            if (childName.isBlank()) continue
            put(childName.lowercase(Locale.ROOT), child.doc)
        }
    }

/** Keeps a traversal listing for CUE sibling lookup so the directory is not
 * queried again; on network providers every listing is a round trip. */
internal fun rememberCueDirectoryListing(
    dir: DocumentFile,
    children: List<SafChildEntry>,
    cache: MutableMap<String, Map<String, DocumentFile>>,
) {
    if (children.any { !it.isDirectory && it.name?.endsWith(".cue", ignoreCase = true) == true }) {
        cache[dir.uri.toString()] = safChildFileLookup(children)
    }
}

internal fun MainActivity.resolveCueAudioSibling(
        parentDir: DocumentFile,
        cueName: String,
        audioFileName: String?,
        childLookupCache: MutableMap<String, Map<String, DocumentFile>>,
    ): DocumentFile? {
        val childLookup = getSafChildFileLookup(parentDir, childLookupCache)

        val directMatch = audioFileName
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.substringAfterLast("/")
            ?.substringAfterLast("\\")
            ?.lowercase(Locale.ROOT)
            ?.let(childLookup::get)
        if (directMatch != null) {
            return directMatch
        }

        val cueBaseName = cueName.substringBeforeLast('.').trim()
        if (cueBaseName.isBlank()) {
            return null
        }

        val cueBaseKey = cueBaseName.lowercase(Locale.ROOT)
        for (ext in cueSiblingAudioExtensions) {
            childLookup["$cueBaseKey$ext"]?.let { return it }
        }
        return null
    }

/** Resolves the audio document named by a CUE sheet copied to [tempCuePath]. */
internal fun MainActivity.resolveCueSheetAudio(
    tempCuePath: String,
    parentDir: DocumentFile,
    cueName: String,
    childLookupCache: MutableMap<String, Map<String, DocumentFile>>,
): DocumentFile? {
    val audioFileName = extractCueAudioFileName(tempCuePath)

    return resolveCueAudioSibling(
        parentDir = parentDir,
        cueName = cueName,
        audioFileName = audioFileName,
        childLookupCache = childLookupCache,
    )
}

/**
 * Reads the virtual track rows of a CUE sheet against its resolved audio.
 * [audioLastModifiedFallback] runs only when the audio's own timestamp
 * cannot be read; the two scans fall back to different values.
 */
internal fun MainActivity.scanSafCueTracks(
    tempCuePath: String,
    audioDoc: DocumentFile,
    cueUri: String,
    cueLastModified: Long,
    audioLastModifiedFallback: () -> Long,
): JSONArray {
    val audioName = try { audioDoc.name ?: "audio.flac" } catch (_: Exception) { "audio.flac" }
    val audioLastModified = try { audioDoc.lastModified() } catch (_: Exception) { audioLastModifiedFallback() }
    val coverCacheKey = buildLibraryCoverCacheKey(
        audioDoc.uri.toString(),
        audioLastModified,
    )

    val cueResultsJson = scanCueFromUri(
        coreBackend,
        tempCuePath,
        audioDoc.uri,
        audioName,
        cueUri,
        cueLastModified,
        coverCacheKey,
    )

    return JSONArray(cueResultsJson)
}
