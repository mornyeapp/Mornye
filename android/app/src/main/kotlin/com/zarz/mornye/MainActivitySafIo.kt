package com.zarz.mornye

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.system.Os
import android.system.OsConstants
import androidx.documentfile.provider.DocumentFile
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.time.Instant
import java.util.Locale

internal fun errorJson(message: String): String {
        val obj = JSONObject()
        obj.put("success", false)
        obj.put("error", message)
        obj.put("message", message)
        return obj.toString()
    }

    /**
     * Detect whether a content URI belongs to the MediaStore provider.
     * Samsung One UI may return MediaStore URIs from SAF tree traversal,
     * which require READ_MEDIA_AUDIO / READ_EXTERNAL_STORAGE permission
     * instead of SAF tree permission.
     */
internal fun isMediaStoreUri(uri: Uri): Boolean {
        val authority = uri.authority ?: return false
        return authority == "media" ||
               authority.startsWith("media.") ||
               authority.contains("media")
    }

    /**
     * Resolve extension from a MediaStore URI by querying DISPLAY_NAME or MIME_TYPE.
     */
internal fun Context.resolveMediaStoreExt(uri: Uri, fallbackExt: String?): String {
        try {
            contentResolver.query(uri, arrayOf(android.provider.MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val name = cursor.getString(0)?.lowercase(Locale.ROOT) ?: ""
                    val ext = extFromFileName(name)
                    if (ext.isNotBlank()) return ext
                }
            }
        } catch (_: Exception) {}

        try {
            val mime = contentResolver.getType(uri)
            val ext = extFromMimeType(mime)
            if (ext.isNotBlank()) return ext
        } catch (_: Exception) {}

        return fallbackExt ?: ""
    }

internal fun extFromFileName(name: String): String {
        return when {
            name.endsWith(".m4a") -> ".m4a"
            name.endsWith(".mp4") -> ".mp4"
            name.endsWith(".aac") -> ".aac"
            name.endsWith(".mp3") -> ".mp3"
            name.endsWith(".opus") -> ".opus"
            name.endsWith(".flac") -> ".flac"
            name.endsWith(".ogg") -> ".ogg"
            name.endsWith(".wave") -> ".wav"
            name.endsWith(".wav") -> ".wav"
            name.endsWith(".aiff") -> ".aiff"
            name.endsWith(".aifc") -> ".aifc"
            name.endsWith(".aif") -> ".aif"
            name.endsWith(".dsf") -> ".dsf"
            name.endsWith(".dff") -> ".dff"
            else -> ""
        }
    }

internal fun extFromMimeType(mime: String?): String {
        return when (mime) {
            "audio/mp4" -> ".m4a"
            "audio/aac" -> ".aac"
            "audio/eac3" -> ".m4a"
            "audio/ac3" -> ".m4a"
            "audio/ac4" -> ".m4a"
            "audio/mpeg" -> ".mp3"
            "audio/ogg" -> ".opus"
            "audio/flac" -> ".flac"
            "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave" -> ".wav"
            "audio/aiff", "audio/x-aiff" -> ".aiff"
            else -> ""
        }
    }

/** [displayName] skips a provider name query when the caller already listed it. */
internal fun Context.copyUriToTemp(
    coreBackend: CoreBackend,
    uri: Uri,
    fallbackExt: String? = null,
    displayName: String? = null,
): String? {
        try {
            val nameHint = (
                displayName
                    ?: try { DocumentFile.fromSingleUri(this, uri)?.name } catch (_: Exception) { null }
                    ?: uri.lastPathSegment
                    ?: ""
            ).lowercase(Locale.ROOT)
            val extFromName = extFromFileName(nameHint)
            // The MIME type only matters when the name has no extension.
            val extFromMime = if (extFromName.isNotBlank()) "" else extFromMimeType(
                try { contentResolver.getType(uri) } catch (_: Exception) { null },
            )
            val ext = if (extFromName.isNotBlank()) extFromName else if (extFromMime.isNotBlank()) extFromMime else (fallbackExt ?: "")
            val suffix = ext.ifBlank { ".tmp" }
            val tempFile = coreBackend.createTemporaryMediaFile(this, "saf_", suffix)
            return copyToTemporaryMediaFile(tempFile) {
                contentResolver.openInputStream(uri)
            }?.absolutePath
        } catch (e: SecurityException) {
            // SAF permission denied - try MediaStore fallback for Samsung One UI
            // which may return MediaStore URIs from SAF tree traversal
            if (isMediaStoreUri(uri)) {
                android.util.Log.d(
                    "Mornye",
                    "SAF denied for MediaStore URI, trying MediaStore fallback: $uri",
                )
                val result = copyMediaStoreUriToTemp(coreBackend, uri, fallbackExt)
                if (result != null) {
                    return result
                }
            }
            android.util.Log.w(
                "Mornye",
                "SAF read denied for $uri: ${e.message}",
            )
            return null
        } catch (e: Exception) {
            android.util.Log.w(
                "Mornye",
                "Failed copying SAF uri $uri to temp: ${e.message}",
            )
            return null
        }
    }

    /**
     * Fallback for Samsung One UI: read a MediaStore content URI using
     * READ_MEDIA_AUDIO / READ_EXTERNAL_STORAGE permission instead of SAF.
     * This handles the case where SAF tree traversal returns MediaStore URIs
     * that the SAF document provider cannot access.
     */
internal fun Context.copyMediaStoreUriToTemp(coreBackend: CoreBackend, uri: Uri, fallbackExt: String?): String? {
        try {
            val ext = resolveMediaStoreExt(uri, fallbackExt)
            val suffix = ext.ifBlank { ".tmp" }
            val tempFile = coreBackend.createTemporaryMediaFile(this, "ms_", suffix)
            val copied = copyToTemporaryMediaFile(tempFile) {
                contentResolver.openInputStream(uri)
            } ?: return null

            android.util.Log.d(
                "Mornye",
                "MediaStore fallback succeeded for $uri",
            )
            return copied.absolutePath
        } catch (e: Exception) {
            android.util.Log.w(
                "Mornye",
                "MediaStore fallback also failed for $uri: ${e.message}",
            )
            return null
        }
    }

internal fun Context.buildUriDisplayName(
        uri: Uri,
        displayNameHint: String? = null,
        fallbackExt: String? = null,
    ): String {
        val explicitName = displayNameHint?.trim().orEmpty()
        if (explicitName.isNotEmpty()) return explicitName

        val docName = try { DocumentFile.fromSingleUri(this, uri)?.name } catch (_: Exception) { null }
        val uriName = uri.lastPathSegment
        val resolvedName = (docName ?: uriName ?: "").trim()
        if (resolvedName.isNotEmpty()) return resolvedName

        val ext = when {
            fallbackExt.isNullOrBlank().not() -> fallbackExt
            isMediaStoreUri(uri) -> resolveMediaStoreExt(uri, fallbackExt)
            else -> ""
        }
        return if (ext.isNullOrBlank()) "audio" else "audio$ext"
    }

internal fun buildLibraryCoverCacheKey(stablePath: String, lastModified: Long): String {
        val normalizedPath = stablePath.trim()
        if (normalizedPath.isEmpty()) return ""
        return if (lastModified > 0L) "$normalizedPath|$lastModified" else normalizedPath
    }

internal fun isSeekableSafDescriptor(descriptor: ParcelFileDescriptor): Boolean {
    return try {
        val position = Os.lseek(
            descriptor.fileDescriptor,
            0L,
            OsConstants.SEEK_CUR,
        )
        Os.lseek(descriptor.fileDescriptor, position, OsConstants.SEEK_SET)
        true
    } catch (_: Exception) {
        false
    }
}

/** Read-only metadata uses a seekable descriptor first. Capability belongs to
 * this descriptor: a pipe or revoked URI must not disable other providers. */
private fun Context.readMetadataFromUri(
    coreBackend: CoreBackend,
    uri: Uri,
    displayNameHint: String? = null,
    fallbackExt: String? = null,
    acceptRead: (JSONObject) -> Boolean = { true },
    retryDirectOnFailure: Boolean = false,
    onFailure: (String) -> Unit = {},
    read: (String, String) -> JSONObject?,
): JSONObject? {
    val displayName = buildUriDisplayName(uri, displayNameHint, fallbackExt)
    return readSafMetadataWithFallback(
        directRead = {
            contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                if (!isSeekableSafDescriptor(descriptor)) return@use null
                read("/proc/self/fd/${descriptor.fd}", displayName)
            }
        },
        fallbackRead = {
            val tempPath = copyUriToTemp(coreBackend, uri, fallbackExt, displayName = displayName)
            if (tempPath == null) null else try {
                read(tempPath, displayName)
            } finally {
                try { File(tempPath).delete() } catch (_: Exception) {}
            }
        },
        accept = acceptRead,
        retryDirectOnFailure = retryDirectOnFailure,
        onFailure = { error ->
            onFailure(error?.message ?: "No readable audio metadata for $displayName")
        },
    )
}

internal fun Context.readAudioMetadataFromUri(
    coreBackend: CoreBackend,
    uri: Uri,
    displayNameHint: String? = null,
    fallbackExt: String? = null,
    coverCacheKey: String = "",
    onFailure: (String) -> Unit = {},
): JSONObject? = readMetadataFromUri(
    coreBackend, uri, displayNameHint, fallbackExt,
    acceptRead = {
        val fromFilename = it.optBoolean("metadataFromFilename", false)
        if (fromFilename) {
            val detail = it.optString("metadataReadError", "").trim()
            throw IOException(if (detail.isEmpty()) {
                "Audio tags unreadable; only filename-derived metadata available"
            } else {
                "Audio metadata read failed: $detail"
            })
        }
        !fromFilename
    },
    retryDirectOnFailure = true,
    onFailure = onFailure,
) { path, name ->
    if (name.endsWith(".dsf", true) || name.endsWith(".dff", true) || name.endsWith(".wv", true)) {
        DsdSource.open(path)?.use { source ->
            return@readMetadataFromUri JSONObject().apply {
                put("trackName", name.substringBeforeLast('.'))
                put("artistName", "Unknown Artist")
                put("albumName", "Unknown Album")
                put("filePath", uri.toString())
                // The Rust readers stamp their rows; the library import
                // requires the same scan time on this platform row.
                put("scannedAt", Instant.now().toString())
                put("format", name.substringAfterLast('.').lowercase(Locale.ROOT))
                put("sampleRate", source.rate)
                put("bitDepth", 1)
                put("duration", source.durationUs / 1000000)
                put("hasLyrics", false)
            }
        }
    }
    readAudioMetadataForScan(coreBackend, path, name, coverCacheKey)
}

internal fun readAudioMetadataForScan(
    coreBackend: CoreBackend,
    path: String,
    name: String,
    coverCacheKey: String,
): JSONObject {
    val obj = coreBackend.readAudioMetadataObject(path, name, coverCacheKey)
    if (obj.has("error")) throw IOException(obj.optString("error", "Audio metadata read failed"))
    return obj
}

/** The Hi-Res check reads only a window from the middle of the file, so a
 * seekable descriptor avoids copying the whole track out of SAF. */
internal fun Context.checkHiResAuthenticityFromUri(
    coreBackend: CoreBackend,
    uri: Uri,
    optionsJson: String,
): JSONObject? = readMetadataFromUri(coreBackend, uri) { path, _ ->
    JSONObject(coreBackend.checkHiResAuthenticity(path, optionsJson))
}?.put("file_path", uri.toString())

internal fun Context.readCompleteMetadataFromUri(
    coreBackend: CoreBackend,
    uri: Uri,
    displayNameHint: String? = null,
): JSONObject? = readMetadataFromUri(coreBackend, uri, displayNameHint) { path, name ->
    JSONObject(coreBackend.readFileMetadata(path, name)).takeUnless { it.has("error") }
}

/** Keep the resolved audio descriptor alive for quality and artwork reads.
 * Only nonseekable providers need a staged audio copy. */
internal fun Context.scanCueFromUri(
    coreBackend: CoreBackend,
    cuePath: String,
    audioUri: Uri,
    audioName: String,
    virtualPrefix: String,
    modTime: Long,
    cacheKey: String,
): String {
    val result = readMetadataFromUri(coreBackend, audioUri, audioName) { path, name ->
        JSONObject().put("rows", coreBackend.scanCueForLibraryWithResolvedAudio(
            cuePath, path, name, virtualPrefix, modTime, cacheKey,
        ))
    }
    return result?.getString("rows") ?: error("Could not read resolved CUE audio")
}

/** Seekable remote documents need only tag reads, not a full audio download. */
internal fun Context.extractCoverFromUri(coreBackend: CoreBackend, uri: Uri, outputPath: String) {
    val name = buildUriDisplayName(uri)
    contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
        if (isSeekableSafDescriptor(descriptor)) {
            coreBackend.extractCoverToFile("/proc/self/fd/${descriptor.fd}", outputPath, name)
            return
        }
    }
    // Providers exposing a pipe cannot support random-access tag readers.
    val tempPath = copyUriToTemp(coreBackend, uri, displayName = name)
        ?: error("Failed to read document artwork")
    try {
        coreBackend.extractCoverToFile(tempPath, outputPath)
    } finally { File(tempPath).delete() }
}

internal fun Context.writeUriFromPath(uri: Uri, srcPath: String): Boolean {
        val srcFile = File(srcPath)
        if (!srcFile.exists()) return false
        contentResolver.openOutputStream(uri, "wt")?.use { output ->
            FileInputStream(srcFile).use { input ->
                input.copyTo(output, bufferSize = 256 * 1024)
            }
        } ?: return false
        return true
    }

    /**
     * Get the parent DocumentFile directory for a SAF document URI.
     * The child URI must be a tree-based document URI (e.g. from SAF tree scan).
     * Returns a DocumentFile that supports findFile() for sibling lookup.
     */
internal fun Context.safParentDir(childUri: Uri): DocumentFile? {
        try {
            val docId = DocumentsContract.getDocumentId(childUri)
            val treeDocId = DocumentsContract.getTreeDocumentId(childUri)
            if (docId.isNullOrEmpty() || treeDocId.isNullOrEmpty() || docId == treeDocId) return null

            // Document IDs are opaque, including when they contain slashes.
            // Ask the provider for the ancestry instead of treating IDs as paths.
            val path = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    DocumentsContract.findDocumentPath(contentResolver, childUri)?.path
                } catch (_: Exception) {
                    null
                }
            } else null
            if (path != null) {
                if (path.size < 2 || path.first() != treeDocId || path.last() != docId) return null
                val parentUri = DocumentsContract.buildDocumentUriUsingTree(
                    childUri, path[path.lastIndex - 1]
                )
                return DocumentFile.fromTreeUri(this, parentUri)
            }

            // Older providers may only expose path-like IDs. Accept that
            // fallback only if the candidate actually lists this document.
            val lastSlash = docId.lastIndexOf('/')
            if (lastSlash <= 0) return null
            val parentUri = DocumentsContract.buildDocumentUriUsingTree(
                childUri, docId.substring(0, lastSlash)
            )
            val parent = DocumentFile.fromTreeUri(this, parentUri) ?: return null
            val name = DocumentFile.fromSingleUri(this, childUri)?.name ?: return null
            val child = findSafChild(this, parent, name) ?: return null
            return parent.takeIf { DocumentsContract.getDocumentId(child.uri) == docId }
        } catch (e: Exception) {
            android.util.Log.w("Mornye", "Failed to get SAF parent dir: ${e.message}")
            return null
        }
    }

/** Export an already rendered sidecar using the scanned document's grant. */
internal fun Context.writeSafSidecarFromPath(
    audioUri: Uri,
    fileName: String,
    mimeType: String,
    srcPath: String,
): String? {
    if (fileName.isBlank() || fileName == "." || fileName == ".." ||
        fileName.any { it == '/' || it == '\\' || it.code < 32 }) return null
    val source = File(srcPath)
    if (!source.isFile || source.length() == 0L) return null
    try {
        val audio = DocumentFile.fromSingleUri(this, audioUri) ?: return null
        if (fileName == audio.name) return null
        val parent = safParentDir(audioUri) ?: return null
        val existing = findSafChild(this, parent, fileName)
        val target = SafDownloadHandler.createOrReuseDocumentFile(
            this, parent, mimeType, fileName,
        ) ?: return null
        if (DocumentsContract.getDocumentId(target.uri) == DocumentsContract.getDocumentId(audioUri)) {
            return null
        }
        if (!writeUriFromPath(target.uri, srcPath)) {
            if (existing == null) target.delete()
            return null
        }
        return target.uri.toString()
    } catch (error: Exception) {
        android.util.Log.w("Mornye", "Sidecar export failed: ${error.message}")
        return null
    }
}

    /**
     * Write a ".lrc" sidecar next to a SAF audio document. The sidecar reuses
     * the audio file's base name (e.g. "Song.flac" -> "Song.lrc") and is created
     * in the same parent directory. Used by re-enrich when the user's lyrics
     * mode requests an external/both sidecar. Callers must handle false so a
     * failed lyrics write cannot be reported as a successful refresh.
     */
internal fun Context.writeSafSidecarLrc(audioUri: Uri, lrcContent: String): Boolean {
        if (lrcContent.isBlank()) return false
        try {
            val parent = safParentDir(audioUri) ?: run {
                android.util.Log.w("Mornye", "LRC sidecar: no SAF parent dir")
                return false
            }
            val audioName = try {
                DocumentFile.fromSingleUri(this, audioUri)?.name
            } catch (_: Exception) {
                null
            } ?: return false
            val baseName = audioName.substringBeforeLast('.', audioName)
            val lrcName = "$baseName.lrc"

            val target = SafDownloadHandler.createOrReuseDocumentFile(
                this,
                parent,
                "application/octet-stream",
                lrcName
            ) ?: run {
                android.util.Log.w("Mornye", "LRC sidecar: failed to create $lrcName")
                return false
            }

            contentResolver.openOutputStream(target.uri, "wt")?.use { output ->
                output.write(lrcContent.toByteArray(Charsets.UTF_8))
            } ?: return false
            android.util.Log.d("Mornye", "LRC sidecar written: $lrcName")
            return true
        } catch (e: Exception) {
            android.util.Log.w("Mornye", "LRC sidecar write failed: ${e.message}")
            return false
        }
    }

internal fun Context.runPostProcessingSafV2(
    coreBackend: CoreBackend,
    fileUriStr: String,
    metadataJson: String,
    itemId: String,
): String {
    val uri = Uri.parse(fileUriStr)
    val doc = DocumentFile.fromSingleUri(this, uri)
        ?: return errorJson("SAF file not found")
    val tempInput = copyUriToTemp(coreBackend, uri) ?: return errorJson("Failed to copy SAF file to temp")
    return withOwnedTemporaryMediaFile(File(tempInput)) {
        val inputObj = JSONObject()
        inputObj.put("item_id", itemId)
        inputObj.put("path", tempInput)
        inputObj.put("uri", fileUriStr)
        inputObj.put("name", doc.name ?: File(tempInput).name)
        inputObj.put("mime_type", doc.type ?: contentResolver.getType(uri) ?: "")
        inputObj.put("size", doc.length())
        inputObj.put("is_saf", true)

        val response = coreBackend.runPostProcessing(inputObj.toString(), metadataJson)
        val respObj = JSONObject(response)
        if (!respObj.optBoolean("success", false)) {
            return@withOwnedTemporaryMediaFile response
        }

        val newPath = respObj.optString("new_file_path", "")
        val outputPath = if (newPath.isNotBlank()) newPath else tempInput
        val outputFile = File(outputPath)
        if (!outputFile.exists()) {
            respObj.put("success", false)
            respObj.put("error", "postProcess output not found")
            return@withOwnedTemporaryMediaFile respObj.toString()
        }

        val newName = outputFile.name
        if (!newName.isNullOrBlank() && doc.name != null && doc.name != newName) {
            try {
                doc.renameTo(newName)
            } catch (_: Exception) {}
        }

        val writeOk = writeUriFromPath(uri, outputFile.absolutePath)
        if (!writeOk) {
            respObj.put("success", false)
            respObj.put("error", "failed to write postProcess output to SAF")
            return@withOwnedTemporaryMediaFile respObj.toString()
        }

        try {
            if (outputPath != tempInput) {
                outputFile.delete()
            }
        } catch (_: Exception) {}

        respObj.put("new_file_path", uri.toString())
        respObj.put("file_path", uri.toString())
        respObj.toString()
    }
}
