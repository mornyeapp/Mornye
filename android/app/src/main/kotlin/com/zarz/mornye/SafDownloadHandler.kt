package com.zarz.mornye

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Locale

/**
 * Shared SAF download wrapper for foreground activity calls and service-owned
 * native workers.
 */
object SafDownloadHandler {
    private val safDirLock = Any()
    private const val MAX_SAF_DISPLAY_NAME_UTF8_BYTES = 180

    // Serializes the exists-check/create/write/publish sequence per target
    // file so concurrent downloads that sanitize to the same display name
    // cannot interleave writes into one document. Different names keep
    // downloading in parallel; the second same-name caller blocks, then hits
    // the exists check and reports already_exists.
    private val safNameLocks = KeyedLockPool<String>()

    data class UniqueWriteResult(
        val uri: String,
        val fileName: String,
        val publishTimingsMs: Map<String, Long> = emptyMap(),
    )
    data class ExistingAwareWriteResult(
        val uri: String,
        val fileName: String,
        val alreadyExists: Boolean,
        val publishTimingsMs: Map<String, Long> = emptyMap(),
    )

    private class PublishTrace {
        private val started = System.nanoTime()
        private var previous = started
        private val stages = linkedMapOf<String, Long>()

        fun mark(stage: String) {
            val now = System.nanoTime()
            stages[stage] = (now - previous) / 1_000_000
            previous = now
        }

        fun finish(): Map<String, Long> = stages.toMap() +
            ("total" to (System.nanoTime() - started) / 1_000_000)
    }

    private fun <T> withSafNameLock(
        treeUriStr: String,
        relativeDir: String,
        fileName: String,
        block: () -> T
    ): T {
        val key = "$treeUriStr|$relativeDir|${fileName.lowercase(Locale.ROOT)}"
        return safNameLocks.withLock(key, block)
    }

    /**
     * Flushes and fsyncs a SAF output stream so the copied bytes are durable
     * before the staged document is renamed to its final name; without this a
     * power loss right after the rename can leave a truncated "complete" file.
     */
    fun syncOutputStream(output: OutputStream) {
        try {
            output.flush()
            (output as? FileOutputStream)?.fd?.sync()
        } catch (_: Exception) {
        }
    }

    internal fun handle(context: Context, requestJson: String, backend: CoreBackend): String {
        val req = JSONObject(requestJson)
        val storageMode = req.optString("storage_mode", "")
        val treeUriStr = req.optString("saf_tree_uri", "")
        if (storageMode != "saf" || treeUriStr.isBlank()) {
            return backend.downloadByStrategy(requestJson)
        }

        val relativeDir = sanitizeRelativeDir(req.optString("saf_relative_dir", ""))
        val outputExt = normalizeExt(req.optString("saf_output_ext", ""))
        val fileName = buildSafFileName(req, outputExt)
        return withSafNameLock(treeUriStr, relativeDir, fileName) {
            handleSafLocked(context, req, backend, treeUriStr, relativeDir, outputExt, fileName)
        }
    }

    private fun handleSafLocked(
        context: Context,
        req: JSONObject,
        backend: CoreBackend,
        treeUriStr: String,
        relativeDir: String,
        outputExt: String,
        fileName: String
    ): String {
        val treeUri = Uri.parse(treeUriStr)
        val mimeType = mimeTypeForExt(outputExt)
        val deferSafPublish = req.optBoolean("defer_saf_publish", false)
        // Downloads are always written under a staged ".partial" name so a
        // killed process can never leave a half-written file under the final
        // name (which the exists check would then accept as complete forever).
        // Callers that set stage_saf_output own the promotion to the final
        // name (the native finalizer); for everyone else — the foreground
        // Dart queue — this handler promotes right after a successful write.
        val finalizerPromotesStaged = req.optBoolean("stage_saf_output", false) && !deferSafPublish
        val useStagedOutput = !deferSafPublish
        val stagedFileName = if (useStagedOutput) buildStagedSafFileName(fileName) else fileName
        // Providers may retain the creation MIME after rename. A temporary
        // name must not turn completed audio into an unclassified file.
        val stagedMimeType = mimeType

        val existingDir = findDocumentDir(context, treeUri, relativeDir)
        if (existingDir != null && req.optString("album_folder_template", "").isBlank()) {
            val existing = findSafChild(context, existingDir, fileName)
            if (existing != null && existing.isFile && existing.length() > 0) {
                deleteStaleStagedFiles(context, existingDir, fileName, outputExt)
                val obj = JSONObject()
                obj.put("success", true)
                obj.put("message", "File already exists")
                obj.put("file_path", existing.uri.toString())
                obj.put("file_name", existing.name ?: fileName)
                obj.put("already_exists", true)
                return obj.toString()
            }
        }

        if (deferSafPublish) {
            existingDir?.let { deleteStaleStagedFiles(context, it, fileName, outputExt) }
            val workingExt = outputExt.ifBlank { ".tmp" }
            val workingFile = backend.createTemporaryMediaFile(context, "native_saf_work_", workingExt)
            return try {
                req.put("output_path", workingFile.absolutePath)
                req.put("output_ext", outputExt)
                req.remove("output_fd")
                val response = backend.downloadByStrategy(req.toString())
                val respObj = JSONObject(response)
                if (respObj.optBoolean("success", false)) {
                    val actualExt = normalizeExt(respObj.optString("actual_extension", ""))
                        .ifBlank { outputExt }
                    val resolvedFileName = respObj.optString("resolved_file_name", "")
                        .trim()
                        .let { forceFilenameExt(it.ifBlank { fileName }, actualExt) }
                    val reportedPath = respObj.optString("file_path", "").trim()
                    if (reportedPath.isEmpty() || reportedPath.startsWith("/proc/self/fd/")) {
                        respObj.put("file_path", workingFile.absolutePath)
                    } else if (reportedPath != workingFile.absolutePath) {
                        workingFile.delete()
                    }
                    respObj.put("file_name", resolvedFileName)
                    respObj.put("saf_deferred_publish", true)
                    respObj.put("saf_final_file_name", resolvedFileName)
                    val resolvedDir = NativeFinalizationPolicy.resolvedAlbumRelativeDirectory(
                        relativeDirectory = relativeDir,
                        albumFolderTemplate = req.optString("album_folder_template", ""),
                        resolvedAlbumFolder = respObj.optString("resolved_album_folder", ""),
                    )
                    respObj.put("saf_relative_dir", resolvedDir)
                    respObj.put("saf_tree_uri", treeUriStr)
                    respObj.put("saf_output_ext", actualExt)
                    respObj.put("saf_final_mime_type", mimeTypeForExt(actualExt))
                } else {
                    workingFile.delete()
                }
                respObj.toString()
            } catch (e: Exception) {
                workingFile.delete()
                errorJson("SAF deferred download failed: ${e.message}")
            }
        }

        val targetDir = ensureDocumentDir(context, treeUri, relativeDir)
            ?: return errorJson("Failed to access SAF directory")

        // Remove any stale partial from a previous killed attempt before
        // creating the staged document: reusing it would let a shorter new
        // write leave the old tail bytes in place (fd truncation is
        // best-effort on some providers).
        deleteStaleStagedFiles(context, targetDir, fileName, outputExt)
        var document = createOrReuseDocumentFile(
            context, targetDir, stagedMimeType, stagedFileName, privateStaging = useStagedOutput,
        )
            ?: return errorJson("Failed to create SAF file")

        var workingFile: File? = null
        try {
            // The OS adapter retains descriptor ownership. The backend writes
            // into its granted staging directory, then the existing SAF
            // copy/promotion publishes the completed output.
            val staged = backend.createTemporaryMediaFile(
                context,
                "native_saf_work_",
                outputExt.ifBlank { ".tmp" },
            )
            workingFile = staged
            req.put("output_path", staged.absolutePath)
            req.remove("output_fd")
            req.put("output_ext", outputExt)
            val response = backend.downloadByStrategy(req.toString())
            val respObj = JSONObject(response)
            if (respObj.optBoolean("success", false)) {
                val resolvedFileName = respObj.optString("resolved_file_name", "").trim()
                var finalFileName = if (resolvedFileName.isNotEmpty()) {
                    forceFilenameExt(resolvedFileName, outputExt)
                } else {
                    fileName
                }
                val backendFilePath = respObj.optString("file_path", "")
                val localFilePath = backendFilePath.takeIf {
                    it.isNotEmpty() && !it.startsWith("content://") &&
                        !it.startsWith("/proc/self/fd/")
                } ?: workingFile?.absolutePath
                if (localFilePath != null) {
                    try {
                        val srcFile = File(localFilePath)
                        if (!srcFile.exists() || srcFile.length() <= 0) {
                            throw IllegalStateException("extension output missing or empty: $localFilePath")
                        }
                        val actualExt = normalizeExt(srcFile.extension)
                        if (actualExt.isNotBlank()) {
                            respObj.put("actual_extension", actualExt)
                        }
                        if (actualExt.isNotBlank() && actualExt != outputExt) {
                            val actualFileName = if (resolvedFileName.isNotEmpty()) {
                                forceFilenameExt(resolvedFileName, actualExt)
                            } else {
                                buildSafFileName(req, actualExt)
                            }
                            val actualStagedFileName = if (useStagedOutput) {
                                buildStagedSafFileName(actualFileName)
                            } else {
                                actualFileName
                            }
                            val actualMimeType = mimeTypeForExt(actualExt)
                            val replacement = createOrReuseDocumentFile(
                                context,
                                targetDir,
                                actualMimeType,
                                actualStagedFileName,
                                privateStaging = useStagedOutput,
                            ) ?: throw IllegalStateException(
                                "failed to create SAF output with actual extension"
                            )
                            if (replacement.uri != document.uri) {
                                document.delete()
                                document = replacement
                            }
                            finalFileName = actualFileName
                        }
                        context.contentResolver.openOutputStream(document.uri, "wt")?.use { output ->
                            srcFile.inputStream().use { input ->
                                input.copyTo(output)
                            }
                            syncOutputStream(output)
                        } ?: throw IllegalStateException("failed to open SAF output stream")
                        srcFile.delete()
                    } catch (e: Exception) {
                        document.delete()
                        android.util.Log.w(
                            "Mornye",
                            "Failed to copy extension output to SAF: ${e.message}"
                        )
                        return errorJson("Failed to copy extension output to SAF: ${e.message}")
                    }
                }
                respObj.put("file_path", document.uri.toString())
                respObj.put("file_name", document.name ?: fileName)
                if (finalizerPromotesStaged) {
                    respObj.put("saf_staged_output", true)
                    respObj.put("saf_staged_file_name", document.name ?: stagedFileName)
                } else if (useStagedOutput) {
                    // Legacy caller (foreground Dart queue): publish here by
                    // renaming the staged file to its final name.
                    val published = replaceFinalDocument(context, targetDir, document, finalFileName)
                    if (published == null) {
                        document.delete()
                        return errorJson("Failed to publish SAF download")
                    }
                    respObj.put("file_path", published.uri.toString())
                    respObj.put("file_name", published.name ?: finalFileName)
                }
            } else {
                document.delete()
            }
            return respObj.toString()
        } catch (e: Exception) {
            document.delete()
            return errorJson("SAF download failed: ${e.message}")
        } finally {
            workingFile?.delete()
        }
    }

    /**
     * Swaps [document] into place under [finalName] without a window where the
     * previous file is gone but the new one is not yet in place. Any existing
     * file is renamed aside first and only deleted once the staged file holds
     * the final name; a failed swap restores it. Returns the published
     * document, or null when the swap failed (the caller owns [document]).
     */
    private fun replaceFinalDocument(
        context: Context,
        targetDir: DocumentFile,
        document: DocumentFile,
        finalName: String
    ): DocumentFile? {
        val existingFinal = findSafChild(context, targetDir, finalName)
        var aside: DocumentFile? = null
        if (existingFinal != null && existingFinal.uri != document.uri) {
            val asideName = buildReplacedSafFileName(finalName)
            try {
                findSafChild(context, targetDir, asideName)?.delete()
            } catch (_: Exception) {
            }
            if (!existingFinal.renameTo(asideName)) {
                return null
            }
            // TreeDocumentFile.renameTo updates this object's URI, including
            // providers whose document IDs change with the display name.
            aside = existingFinal
        }
        if (!document.renameTo(finalName)) {
            aside?.renameTo(finalName)
            return null
        }
        aside?.delete()
        return document
    }

    internal fun buildReplacedSafFileName(fileName: String): String {
        val suffix = ".replaced"
        val name = fitPrivatePublicationName(
            fileName, MAX_SAF_DISPLAY_NAME_UTF8_BYTES - suffix.length - 1,
        )
        return ".$name$suffix"
    }

    fun copyContentUriToTemp(context: Context, uriStr: String): String? {
        var temp: File? = null
        return try {
            val uri = Uri.parse(uriStr)
            val extension = DocumentFile.fromSingleUri(context, uri)
                ?.name
                ?.substringAfterLast('.', "")
                ?.takeIf { it.isNotBlank() }
                ?.let { ".$it" }
                ?: ".tmp"
            val createdTemp = createCoreBackend(context).createTemporaryMediaFile(context, "native_saf_", extension)
            temp = createdTemp
            context.contentResolver.openInputStream(uri)?.use { input ->
                createdTemp.outputStream().use { output ->
                    input.copyTo(output)
                }
            } ?: run {
                createdTemp.delete()
                return null
            }
            createdTemp.absolutePath
        } catch (e: Exception) {
            try { temp?.delete() } catch (_: Exception) {}
            android.util.Log.w("Mornye", "Failed to copy SAF URI to temp: ${e.message}")
            null
        }
    }

    fun writeFileToSaf(
        context: Context,
        treeUriStr: String,
        relativeDir: String,
        fileName: String,
        mimeType: String,
        srcPath: String
    ): String? {
        val finalName = sanitizeFilename(fileName)
        return withSafNameLock(treeUriStr, sanitizeRelativeDir(relativeDir), finalName) {
            try {
                val targetDir = ensureDocumentDir(context, Uri.parse(treeUriStr), relativeDir)
                    ?: return@withSafNameLock null
                writeFileToSafLocked(context, targetDir, finalName, mimeType, srcPath)
            } catch (e: Exception) {
                android.util.Log.w("Mornye", "Failed to write file to SAF: ${e.message}")
                null
            }
        }
    }

    fun writeFileToSafUnique(
        context: Context,
        treeUriStr: String,
        relativeDir: String,
        fileName: String,
        mimeType: String,
        srcPath: String,
        preservedSuffix: String = "",
    ): UniqueWriteResult? {
        val safeRelativeDir = sanitizeRelativeDir(relativeDir)
        val preferredName = sanitizeFilenamePreservingSuffix(fileName, preservedSuffix)
        val trace = PublishTrace()
        return withSafNameLock(treeUriStr, safeRelativeDir, preferredName) {
            trace.mark("lock_wait")
            val treeUri = Uri.parse(treeUriStr)
            val targetDir = ensureDocumentDir(context, treeUri, safeRelativeDir) ?: return@withSafNameLock null
            trace.mark("directory")
            val availableName = findAvailableFileName(
                context,
                targetDir,
                preferredName,
                preservedSuffix,
            )
            trace.mark("existing_check")
            val uri = writeFileToSafLocked(
                context,
                targetDir,
                availableName,
                mimeType,
                srcPath,
                trace,
            ) ?: return@withSafNameLock null
            UniqueWriteResult(uri = uri, fileName = availableName, publishTimingsMs = trace.finish())
        }
    }

    fun writeFileToSafCollisionAware(
        context: Context,
        treeUriStr: String,
        relativeDir: String,
        cleanFileName: String,
        variantFileName: String,
        mimeType: String,
        srcPath: String,
        preservedSuffix: String = "",
    ): UniqueWriteResult? {
        val safeRelativeDir = sanitizeRelativeDir(relativeDir)
        val cleanName = sanitizeFilename(cleanFileName)
        val preferredVariant = sanitizeFilenamePreservingSuffix(
            variantFileName,
            preservedSuffix,
        )
        val trace = PublishTrace()
        return withSafNameLock(treeUriStr, safeRelativeDir, cleanName) {
            trace.mark("lock_wait")
            val treeUri = Uri.parse(treeUriStr)
            val targetDir = ensureDocumentDir(context, treeUri, safeRelativeDir)
                ?: return@withSafNameLock null
            trace.mark("directory")
            val selectedName = if (findSafChild(context, targetDir, cleanName) == null) {
                cleanName
            } else {
                findAvailableFileName(context, targetDir, preferredVariant, preservedSuffix)
            }
            trace.mark("existing_check")
            val uri = writeFileToSafLocked(
                context,
                targetDir,
                selectedName,
                mimeType,
                srcPath,
                trace,
            ) ?: return@withSafNameLock null
            UniqueWriteResult(uri = uri, fileName = selectedName, publishTimingsMs = trace.finish())
        }
    }

    fun writeFileToSafIfAbsent(
        context: Context,
        treeUriStr: String,
        relativeDir: String,
        fileName: String,
        mimeType: String,
        srcPath: String,
    ): ExistingAwareWriteResult? {
        val safeRelativeDir = sanitizeRelativeDir(relativeDir)
        val finalName = sanitizeFilename(fileName)
        val trace = PublishTrace()
        return withSafNameLock(treeUriStr, safeRelativeDir, finalName) {
            trace.mark("lock_wait")
            val treeUri = Uri.parse(treeUriStr)
            val targetDir = ensureDocumentDir(context, treeUri, safeRelativeDir)
                ?: return@withSafNameLock null
            trace.mark("directory")
            val existing = findSafChild(context, targetDir, finalName)
            trace.mark("existing_check")
            if (existing != null && existing.isFile && existing.length() > 0L) {
                return@withSafNameLock ExistingAwareWriteResult(
                    uri = existing.uri.toString(),
                    fileName = existing.name ?: finalName,
                    alreadyExists = true,
                    publishTimingsMs = trace.finish(),
                )
            }
            val uri = writeFileToSafLocked(
                context,
                targetDir,
                finalName,
                mimeType,
                srcPath,
                trace,
            ) ?: return@withSafNameLock null
            ExistingAwareWriteResult(
                uri = uri,
                fileName = finalName,
                alreadyExists = false,
                publishTimingsMs = trace.finish(),
            )
        }
    }

    private fun sanitizeFilenamePreservingSuffix(fileName: String, suffix: String): String {
        val sanitized = sanitizeFilename(fileName)
        val trimmedSuffix = suffix.trim()
        if (trimmedSuffix.isEmpty() || sanitized.contains(trimmedSuffix)) return sanitized

        val dotIndex = fileName.lastIndexOf('.')
        val hasExtension = dotIndex > 0 && dotIndex < fileName.length - 1
        val extension = if (hasExtension) fileName.substring(dotIndex) else ""
        val rawStem = if (hasExtension) fileName.substring(0, dotIndex) else fileName
        val rawPrefix = rawStem.replace(trimmedSuffix, "").trim(' ', '_', '-')
        val safeSuffix = sanitizeFilename(trimmedSuffix)
        val reserved = " - $safeSuffix$extension"
        val prefixBytes = (MAX_SAF_DISPLAY_NAME_UTF8_BYTES - reserved.toByteArray(Charsets.UTF_8).size)
            .coerceAtLeast(1)
        val safePrefix = truncateUtf8Bytes(sanitizeFilename(rawPrefix), prefixBytes)
            .trim()
            .trim('.', ' ', '_', '-')
            .ifBlank { "track" }
        return "$safePrefix$reserved"
    }

    private fun findAvailableFileName(
        context: Context,
        parent: DocumentFile,
        preferredName: String,
        preservedSuffix: String,
    ): String {
        if (findSafChild(context, parent, preferredName) == null) return preferredName
        for (counter in 2..9999) {
            val candidate = appendFilenameCounter(
                preferredName,
                counter.toLong(),
                preservedSuffix,
            )
            if (findSafChild(context, parent, candidate) == null) return candidate
        }
        return appendFilenameCounter(
            preferredName,
            System.currentTimeMillis(),
            preservedSuffix,
        )
    }

    private fun appendFilenameCounter(
        fileName: String,
        counter: Long,
        preservedSuffix: String,
    ): String {
        val dotIndex = fileName.lastIndexOf('.')
        val hasExtension = dotIndex > 0 && dotIndex < fileName.length - 1
        val extension = if (hasExtension) fileName.substring(dotIndex) else ""
        val originalStem = if (hasExtension) fileName.substring(0, dotIndex) else fileName
        val safePreservedSuffix = preservedSuffix.trim()
        val hasPreservedSuffix = safePreservedSuffix.isNotEmpty() && originalStem.contains(safePreservedSuffix)
        val stem = if (hasPreservedSuffix) {
            originalStem.replace(safePreservedSuffix, "").trim(' ', '_', '-')
        } else {
            originalStem
        }
        val suffix = if (hasPreservedSuffix) {
            " - $safePreservedSuffix ($counter)"
        } else {
            " ($counter)"
        }
        val reservedBytes = extension.toByteArray(Charsets.UTF_8).size +
            suffix.toByteArray(Charsets.UTF_8).size
        val maxStemBytes = (MAX_SAF_DISPLAY_NAME_UTF8_BYTES - reservedBytes).coerceAtLeast(1)
        val safeStem = truncateUtf8Bytes(stem, maxStemBytes).trim().trim('.', ' ').ifBlank { "track" }
        return "$safeStem$suffix$extension"
    }

    private fun writeFileToSafLocked(
        context: Context,
        targetDir: DocumentFile,
        finalName: String,
        mimeType: String,
        srcPath: String,
        trace: PublishTrace = PublishTrace(),
    ): String? {
        var stagedDocument: DocumentFile? = null
        return try {
            val ext = normalizeExt(finalName.substringAfterLast('.', ""))
            val stagedName = buildStagedSafFileName(finalName)
            deleteStaleStagedFiles(context, targetDir, finalName, ext)
            trace.mark("cleanup")
            val document = createOrReuseDocumentFile(
                context, targetDir, mimeType, stagedName, privateStaging = true,
            )
                ?: return null
            trace.mark("create")
            stagedDocument = document
            val outputStream = context.contentResolver.openOutputStream(document.uri, "wt")
            if (outputStream == null) {
                document.delete()
                stagedDocument = null
                return null
            }
            trace.mark("open")
            outputStream.use { output ->
                File(srcPath).inputStream().use { input ->
                    input.copyTo(output, bufferSize = 64 * 1024)
                }
                trace.mark("copy")
                syncOutputStream(output)
                trace.mark("sync")
            }
            trace.mark("close")

            val published = replaceFinalDocument(context, targetDir, document, finalName)
            trace.mark("replace")
            if (published == null) {
                document.delete()
                return null
            }
            stagedDocument = null
            published.uri.toString()
        } catch (e: Exception) {
            stagedDocument?.delete()
            android.util.Log.w("Mornye", "Failed to write file to SAF: ${e.message}")
            null
        }
    }

    fun deleteContentUri(context: Context, uriStr: String): Boolean {
        return try {
            DocumentFile.fromSingleUri(context, Uri.parse(uriStr))?.delete() == true
        } catch (_: Exception) {
            false
        }
    }

    // Same result for every input; pinned by ExtensionMimeTablesTest.
    internal fun normalizeExt(ext: String?): String =
        NativeFinalizationPolicy.normalizeExtension(ext)

    internal fun mimeTypeForExt(ext: String?): String {
        return when (normalizeExt(ext)) {
            ".m4a", ".mp4" -> "audio/mp4"
            ".mp3" -> "audio/mpeg"
            ".opus", ".ogg" -> "audio/ogg"
            ".flac" -> "audio/flac"
            ".wav" -> "audio/wav"
            ".aiff", ".aif", ".aifc" -> "audio/aiff"
            ".lrc" -> "application/octet-stream"
            else -> "application/octet-stream"
        }
    }

    private fun forceFilenameExt(name: String, outputExt: String): String {
        val normalizedExt = normalizeExt(outputExt)
        if (normalizedExt.isBlank()) return sanitizeFilename(name)

        val safeName = sanitizeFilename(name)
        val lower = safeName.lowercase(Locale.ROOT)
        val knownExts = listOf(".flac", ".m4a", ".mp4", ".mp3", ".opus", ".lrc")
        for (knownExt in knownExts) {
            if (lower.endsWith(knownExt)) {
                return safeName.dropLast(knownExt.length) + normalizedExt
            }
        }
        return safeName + normalizedExt
    }

    internal fun buildStagedSafFileName(fileName: String): String {
        // Filesystem providers append an audio extension when it does not
        // match the MIME. Keep the extension and hide the staging name so
        // MediaStore and other players cannot index unfinished audio.
        val name = fitPrivatePublicationName(
            fileName, MAX_SAF_DISPLAY_NAME_UTF8_BYTES - ".partial".length - 1,
        )
        return ".${buildLegacyStagedSafFileName(name, "")}"
    }

    private fun fitPrivatePublicationName(fileName: String, maxBytes: Int): String {
        val safeName = sanitizeFilename(fileName)
        if (safeName.toByteArray(Charsets.UTF_8).size <= maxBytes) return safeName
        // Keep distinct final names distinct when reserving staging suffixes.
        val hash = MessageDigest.getInstance("SHA-256")
            .digest(safeName.toByteArray(Charsets.UTF_8))
            .take(8)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val suffix = "-$hash"
        val fitted = truncateSafDisplayName(safeName, maxBytes - suffix.length)
        val dot = fitted.lastIndexOf('.')
        return if (dot > 0 && fitted.length - dot <= 10) {
            fitted.substring(0, dot) + suffix + fitted.substring(dot)
        } else {
            fitted + suffix
        }
    }

    private fun buildLegacyStagedSafFileName(fileName: String, outputExt: String): String {
        val safeName = sanitizeFilename(fileName)
        val ext = normalizeExt(outputExt)
        if (ext.isNotBlank() && safeName.lowercase(Locale.ROOT).endsWith(ext)) {
            return safeName.dropLast(ext.length).trimEnd('.', ' ') + ".partial$ext"
        }
        val dot = safeName.lastIndexOf('.')
        if (dot > 0 && dot < safeName.lastIndex) {
            return safeName.substring(0, dot).trimEnd('.', ' ') +
                ".partial" +
                safeName.substring(dot)
        }
        return "$safeName.partial"
    }

    private fun deleteStaleStagedFiles(context: Context, parent: DocumentFile, fileName: String, outputExt: String) {
        val stagedNames = linkedSetOf(
            buildStagedSafFileName(fileName),
            "${sanitizeFilename(fileName)}.partial",
            buildLegacyStagedSafFileName(fileName, outputExt),
            buildReplacedSafFileName(fileName),
            "${sanitizeFilename(fileName)}.replaced",
        )
        val staleDocuments = try {
            findSafChildren(context, parent, stagedNames)
        } catch (_: Exception) {
            return
        }
        for (document in staleDocuments.values) {
            try {
                document.delete()
            } catch (_: Exception) {
            }
        }
    }

    internal fun sanitizeFilename(name: String): String {
        var sanitized = name
            .replace("/", " ")
            .replace(Regex("[\\\\:*?\"<>|]"), " ")
            .filter { ch ->
                val code = ch.code
                !((code < 0x20 && ch != '\t' && ch != '\n' && ch != '\r') ||
                    code == 0x7F ||
                    (Character.isISOControl(ch) && ch != '\t' && ch != '\n' && ch != '\r'))
            }
            .trim()
            .trim('.', ' ')

        sanitized = sanitized
            .replace(Regex("\\s+"), " ")
            .replace(Regex("_+"), "_")
            .trim('_', ' ')

        sanitized = truncateSafDisplayName(sanitized, MAX_SAF_DISPLAY_NAME_UTF8_BYTES)
        sanitized = sanitized.trim().trim('.', ' ').trim('_', ' ')
        return if (sanitized.isBlank()) "Unknown" else sanitized
    }

    private fun truncateSafDisplayName(name: String, maxBytes: Int): String {
        if (maxBytes <= 0 || name.toByteArray(Charsets.UTF_8).size <= maxBytes) return name

        val dotIndex = name.lastIndexOf('.')
        val ext = if (
            dotIndex > 0 &&
            dotIndex < name.length - 1 &&
            name.length - dotIndex <= 10
        ) {
            name.substring(dotIndex)
        } else {
            ""
        }
        val stem = if (ext.isNotEmpty()) name.substring(0, dotIndex) else name
        val maxStemBytes = (maxBytes - ext.toByteArray(Charsets.UTF_8).size).coerceAtLeast(1)
        return truncateUtf8Bytes(stem, maxStemBytes).trim().trim('.', ' ').trim('_', ' ') + ext
    }

    private fun truncateUtf8Bytes(value: String, maxBytes: Int): String {
        if (maxBytes <= 0 || value.toByteArray(Charsets.UTF_8).size <= maxBytes) return value

        val builder = StringBuilder()
        var usedBytes = 0
        var index = 0
        while (index < value.length) {
            val codePoint = value.codePointAt(index)
            val char = String(Character.toChars(codePoint))
            val charBytes = char.toByteArray(Charsets.UTF_8).size
            if (usedBytes + charBytes > maxBytes) break
            builder.append(char)
            usedBytes += charBytes
            index += Character.charCount(codePoint)
        }
        return builder.toString()
    }

    internal fun sanitizeRelativeDir(relativeDir: String): String {
        if (relativeDir.isBlank()) return ""
        return relativeDir
            .split("/")
            .map { sanitizeFilename(it) }
            .filter { it.isNotBlank() && it != "." && it != ".." }
            .joinToString("/")
    }

    internal fun ensureDocumentDir(
        context: Context,
        treeUri: Uri,
        relativeDir: String
    ): DocumentFile? {
        val safeRelativeDir = sanitizeRelativeDir(relativeDir)
        if (safeRelativeDir.isBlank()) {
            return DocumentFile.fromTreeUri(context, treeUri)
        }

        synchronized(safDirLock) {
            var current = DocumentFile.fromTreeUri(context, treeUri) ?: return null
            val parts = safeRelativeDir.split("/").filter { it.isNotBlank() }
            for (part in parts) {
                val existing = findSafChild(context, current, part)
                current = if (existing != null && existing.isDirectory) {
                    existing
                } else {
                    val created = current.createDirectory(part) ?: return null
                    val createdName = created.name ?: part
                    if (createdName != part) {
                        created.delete()
                        findSafChild(context, current, part) ?: return null
                    } else {
                        created
                    }
                }
            }
            return current
        }
    }

    internal fun findDocumentDir(
        context: Context,
        treeUri: Uri,
        relativeDir: String
    ): DocumentFile? {
        var current = DocumentFile.fromTreeUri(context, treeUri) ?: return null
        val safeRelativeDir = sanitizeRelativeDir(relativeDir)
        if (safeRelativeDir.isBlank()) return current

        val parts = safeRelativeDir.split("/").filter { it.isNotBlank() }
        for (part in parts) {
            val existing = findSafChild(context, current, part)
            if (existing == null || !existing.isDirectory) return null
            current = existing
        }
        return current
    }

    internal fun createOrReuseDocumentFile(
        context: Context,
        parent: DocumentFile,
        mimeType: String,
        fileName: String,
        privateStaging: Boolean = false,
    ): DocumentFile? {
        val safeFileName = if (privateStaging) {
            ".${truncateSafDisplayName(sanitizeFilename(fileName), MAX_SAF_DISPLAY_NAME_UTF8_BYTES - 1)}"
        } else {
            sanitizeFilename(fileName)
        }
        if (safeFileName.isBlank()) return null

        synchronized(safDirLock) {
            val existing = findSafChild(context, parent, safeFileName)
            if (existing != null && existing.isFile) {
                return existing
            }

            val created = parent.createFile(mimeType, safeFileName) ?: return null
            val createdName = created.name ?: safeFileName
            if (createdName == safeFileName) {
                return created
            }

            val winner = findSafChild(context, parent, safeFileName)
            if (winner != null && winner.isFile) {
                if (winner.uri != created.uri) {
                    try {
                        created.delete()
                    } catch (_: Exception) {
                    }
                }
                return winner
            }

            return created
        }
    }

    private fun buildSafFileName(req: JSONObject, outputExt: String): String {
        val provided = req.optString("saf_file_name", "")
        if (provided.isNotBlank()) return forceFilenameExt(provided, outputExt)

        val trackName = req.optString("track_name", "track")
        val artistName = req.optString("artist_name", "")
        val baseName = if (artistName.isNotBlank()) "$artistName - $trackName" else trackName
        return forceFilenameExt(baseName, outputExt)
    }
}
