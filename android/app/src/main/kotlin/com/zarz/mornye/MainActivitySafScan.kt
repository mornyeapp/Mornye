package com.zarz.mornye

import androidx.documentfile.provider.DocumentFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.Locale

internal fun MainActivity.buildStableLibraryId(filePath: String): String {
        val digest = MessageDigest.getInstance("SHA-1")
        val bytes = digest.digest(filePath.toByteArray(Charsets.UTF_8))
        val hex = bytes.joinToString("") { "%02x".format(it) }
        return "lib_$hex"
    }

internal fun MainActivity.resetSafScanProgress() {
        synchronized(safScanLock) {
            safScanProgress = MainActivity.SafScanProgress()
        }
    }

internal fun MainActivity.updateSafScanProgress(block: (MainActivity.SafScanProgress) -> Unit) {
        synchronized(safScanLock) {
            block(safScanProgress)
        }
    }

/** How many failed documents a finished scan lists with their reason. The
 * error count still includes the rest. */
internal const val REPORTED_SCAN_FAILURES = 100

internal fun MainActivity.recordSafScanFailure(path: String, message: String) {
        updateSafScanProgress {
            if (it.failures.size < REPORTED_SCAN_FAILURES) {
                it.failures = it.failures + (path to message)
            }
        }
    }

internal fun MainActivity.safProgressToJson(): String {
        val snapshot = synchronized(safScanLock) { safScanProgress.copy() }
        val obj = JSONObject()
        obj.put("total_files", snapshot.totalFiles)
        obj.put("scanned_files", snapshot.scannedFiles)
        obj.put("current_file", snapshot.currentFile)
        obj.put("error_count", snapshot.errorCount)
        obj.put("progress_pct", snapshot.progressPct)
        obj.put("is_complete", snapshot.isComplete)
        // Sent once complete, as the Rust scanner does, so updates stay small.
        if (snapshot.isComplete && snapshot.failures.isNotEmpty()) {
            obj.put("failures", JSONArray(snapshot.failures.map { (path, message) ->
                JSONObject().put("path", path).put("message", message)
            }))
        }
        return obj.toString()
    }

internal fun MainActivity.readLibraryScanProgressJsonForStream(): String {
        return if (safScanActive) {
            safProgressToJson()
        } else {
            coreBackend.getLibraryScanProgress()
        }
    }


internal fun MainActivity.loadExistingFilesFromSnapshot(snapshotPath: String): MutableMap<String, Long> {
        val result = mutableMapOf<String, Long>()
        if (snapshotPath.isBlank()) {
            return result
        }

        val snapshotFile = File(snapshotPath)
        if (!snapshotFile.exists()) {
            return result
        }

        snapshotFile.forEachLine { line ->
            if (line.isBlank()) return@forEachLine
            val separatorIndex = line.indexOf('\t')
            if (separatorIndex <= 0 || separatorIndex >= line.length - 1) {
                return@forEachLine
            }
            val modTime = line.substring(0, separatorIndex).toLongOrNull() ?: 0L
            val filePath = line.substring(separatorIndex + 1)
            if (filePath.isNotEmpty()) {
                result[filePath] = modTime
            }
        }
        return result
    }

    // Keep the SAF folder walk aligned with the backend's supported audio formats.
    // CUE files are handled separately.
    private val libraryScanAudioExtensions = setOf(
        ".flac", ".m4a", ".mp4", ".aac", ".mp3", ".opus", ".ogg",
        ".ape", ".wv", ".mpc", ".wav", ".aiff", ".aif", ".dsf", ".dff"
    )

private const val SAF_SCAN_PAUSE_POLL_MS = 100L

/**
 * Holds a SAF scan at its checkpoint while paused, keeping its position in
 * memory. Returns true when the scan should stop because it was cancelled.
 */
internal fun MainActivity.safScanStopRequested(cancelled: () -> Boolean = { false }): Boolean {
    while (safScanPaused && !safScanCancel && !cancelled()) {
        Thread.sleep(SAF_SCAN_PAUSE_POLL_MS)
    }
    return safScanCancel || cancelled()
}

/** The `progress_pct` value for [done] of [total] items; callers guard zero. */
private fun safScanProgressPct(done: Int, total: Int): Double =
    done.toDouble() / total.toDouble() * 100.0

internal fun MainActivity.scanSafTree(
        treeUriStr: String,
        ndjsonOutputPath: String? = null,
    ): Any {
        val earlyCheckpoint = ndjsonOutputPath
            ?.takeIf {
                File(it).exists() && File(safScanCheckpointPath(it)).exists()
            }
            ?.let { loadSafScanCheckpoint(safScanCheckpointPath(it)) }
            ?: mutableMapOf()

        fun emptyResult(): Any {
            if (ndjsonOutputPath == null) return "[]"
            if (earlyCheckpoint.isNotEmpty() && File(ndjsonOutputPath).exists()) {
                throw IOException("SAF scan returned no files while a resumable scan exists")
            }
            File(ndjsonOutputPath).writeText("", Charsets.UTF_8)
            try { File(safScanCheckpointPath(ndjsonOutputPath)).delete() } catch (_: Exception) {}
            return mapOf("path" to ndjsonOutputPath, "count" to 0, "error_count" to 0)
        }

        fun cancelledResult(): Any {
            updateSafScanProgress { it.isComplete = true }
            if (ndjsonOutputPath == null) return "[]"
            // Preserve partial output so the next scan can resume.
            throw java.util.concurrent.CancellationException("SAF library scan cancelled")
        }

        val (_, root, rootChildren) = resolveReadableSafTreeOrThrow(treeUriStr)

        resetSafScanProgress()
        safScanCancel = false
        safScanActive = true
        updateSafScanProgress {
            it.scannedFiles = earlyCheckpoint.size
            it.currentFile = if (earlyCheckpoint.isEmpty()) {
                "Scanning folders..."
            } else {
                "Resuming scan..."
            }
        }

        val supportedAudioExt = libraryScanAudioExtensions
        data class SafAudioEntry(
            val doc: DocumentFile,
            val name: String,
            val lastModified: Long,
        )
        data class SafCueEntry(
            val doc: DocumentFile,
            val parentDir: DocumentFile,
            val name: String,
            val lastModified: Long,
        )
        val audioFiles = mutableListOf<SafAudioEntry>()
        val cueFiles = mutableListOf<SafCueEntry>()
        val visitedDirUris = mutableSetOf<String>()
        val safChildLookupCache = mutableMapOf<String, Map<String, DocumentFile>>()
        var traversalErrors = 0

        val queue: ArrayDeque<Pair<DocumentFile, String>> = ArrayDeque()
        queue.add(root to "")
        val lister = SafTreeLister(this)

        while (queue.isNotEmpty()) {
            if (safScanStopRequested()) {
                return cancelledResult()
            }

            val (dir, path) = queue.removeFirst()
            val dirUri = dir.uri.toString()
            if (!visitedDirUris.add(dirUri)) {
                continue
            }

            val listing = if (dir.uri == root.uri) {
                Result.success(rootChildren)
            } else {
                lister.list(dir, queue, visitedDirUris)
            }
            val children = listing.getOrNull()
            if (children == null) {
                traversalErrors++
                updateSafScanProgress { it.errorCount = traversalErrors }
                reportLibraryScanError(dirUri, "List folder", listing.exceptionOrNull()?.message ?: "No directory listing")
                continue
            }
            rememberCueDirectoryListing(dir, children, safChildLookupCache)

            for (child in children) {
                if (safScanStopRequested()) {
                    return cancelledResult()
                }

                try {
                    if (child.isDirectory) {
                        val childName = child.name ?: continue
                        val childPath = if (path.isBlank()) childName else "$path/$childName"
                        val childUri = child.doc.uri.toString()
                        if (childUri == dirUri || visitedDirUris.contains(childUri)) {
                            continue
                        }
                        queue.add(child.doc to childPath)
                    } else {
                        val name = child.name ?: continue
                        if (isIncompleteSafFileName(name)) continue
                        val lastModified = child.lastModified
                        val ext = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
                        if (ext == "cue") {
                            cueFiles.add(SafCueEntry(child.doc, dir, name, lastModified))
                        } else if (ext.isNotBlank() && supportedAudioExt.contains(".$ext")) {
                            audioFiles.add(SafAudioEntry(child.doc, name, lastModified))
                        }
                    }
                } catch (e: Exception) {
                    traversalErrors++
                    updateSafScanProgress { it.errorCount = traversalErrors }
                    reportLibraryScanError(child.doc.uri.toString(), "Inspect entry", e.message ?: e.javaClass.simpleName)
                }
            }
        }

        if (traversalErrors > 0) {
            throw IOException("SAF traversal failed for $traversalErrors entries")
        }

        val totalItems = audioFiles.size + cueFiles.size
        updateSafScanProgress {
            it.totalFiles = totalItems
            if (totalItems > 0 && earlyCheckpoint.isNotEmpty()) {
                it.scannedFiles = earlyCheckpoint.size.coerceAtMost(totalItems)
                it.progressPct = safScanProgressPct(it.scannedFiles, totalItems)
            }
        }

        if (audioFiles.isEmpty() && cueFiles.isEmpty()) {
            updateSafScanProgress {
                it.isComplete = true
                it.progressPct = 100.0
            }
            return emptyResult()
        }

        // Stream results to a spill file: a full-library scan's JSONArray plus
        // its serialized string would otherwise hold the whole payload on the
        // Java heap several times over.
        val spill = if (ndjsonOutputPath == null) this.SpillJsonWriter() else null
        val outputPath = ndjsonOutputPath
        val checkpointPath = outputPath?.let(::safScanCheckpointPath)
        val checkpoint = if (checkpointPath != null) {
            val outputFile = File(requireNotNull(outputPath))
            val checkpointFile = File(checkpointPath)
            outputFile.parentFile?.mkdirs()
            // Discard stale output that has no checkpoint.
            if (outputFile.exists() && !checkpointFile.exists()) {
                try { outputFile.delete() } catch (_: Exception) {}
            } else if (!outputFile.exists() && checkpointFile.exists()) {
                try { checkpointFile.delete() } catch (_: Exception) {}
            }
            repairSafScanOutput(outputFile.absolutePath)
            reconcileSafScanCheckpoint(
                outputFile.absolutePath,
                loadSafScanCheckpoint(checkpointPath),
            )
        } else {
            mutableMapOf()
        }
        val checkpointWriter = checkpointPath?.let {
            FileOutputStream(File(it), true).bufferedWriter(Charsets.UTF_8)
        }
        val ndjsonWriter = outputPath?.let {
            FileOutputStream(File(it), true).bufferedWriter(Charsets.UTF_8)
        }
        var resultCount = outputPath?.let(::countSafScanRows) ?: 0
        fun checkpointed(uri: String, lastModified: Long): Boolean =
            checkpoint[uri] == lastModified

        fun recordCheckpoint(uri: String, lastModified: Long) {
            if (checkpointWriter == null || uri.isBlank()) return
            checkpoint[uri] = lastModified
            checkpointWriter.write(uri)
            checkpointWriter.write('\t'.code)
            checkpointWriter.write(lastModified.toString())
            checkpointWriter.newLine()
            checkpointWriter.flush()
        }

        fun putResult(obj: JSONObject) {
            if (ndjsonWriter != null) {
                ndjsonWriter.write(obj.toString())
                ndjsonWriter.newLine()
            } else {
                spill!!.raw(if (resultCount == 0) "[" else ",")
                spill.raw(obj.toString())
            }
            resultCount++
        }
        try {
        var scanned = checkpoint.size.coerceAtMost(totalItems)
        var errors = traversalErrors

        fun reportScanned() {
            val pct = safScanProgressPct(scanned, totalItems)
            updateSafScanProgress {
                it.scannedFiles = scanned
                it.errorCount = errors
                it.progressPct = pct
            }
        }

        val cueReferencedAudioUris = mutableSetOf<String>()

        for (cue in cueFiles) {
            val cueDoc = cue.doc
            val parentDir = cue.parentDir
            val cueUri = cueDoc.uri.toString()
            val cueAlreadyIndexed = checkpointed(cueUri, cue.lastModified)
            if (safScanStopRequested()) {
                ndjsonWriter?.close()
                spill?.abandon()
                return cancelledResult()
            }

            val cueName = cue.name
            updateSafScanProgress { it.currentFile = cueName }

            var tempCuePath: String? = null
            try {
                tempCuePath = copyUriToTemp(coreBackend, cueDoc.uri, ".cue", cueName)
                if (tempCuePath == null) {
                    errors++
                    reportLibraryScanError(cueUri, "Read CUE", "Failed to copy CUE file")
                    scanned++
                    continue
                }

                val audioDoc = resolveCueSheetAudio(
                    tempCuePath,
                    parentDir,
                    cueName,
                    safChildLookupCache,
                )

                if (audioDoc == null) {
                    reportLibraryScanError(cueUri, "Resolve CUE audio", "No audio file found for $cueName")
                    errors++
                    scanned++
                    continue
                }

                cueReferencedAudioUris.add(audioDoc.uri.toString())

                if (cueAlreadyIndexed) {
                    continue
                }

                val cueArray = scanSafCueTracks(
                    tempCuePath,
                    audioDoc,
                    cueUri,
                    cue.lastModified,
                ) { cueDoc.lastModified() }
                for (j in 0 until cueArray.length()) {
                    putResult(cueArray.getJSONObject(j))
                }
                ndjsonWriter?.flush()
                recordCheckpoint(cueUri, cue.lastModified)

            } catch (e: Exception) {
                errors++
                reportLibraryScanError(cueUri, "Scan CUE", e.message ?: e.javaClass.simpleName)
            } finally {
                try { tempCuePath?.let { File(it).delete() } } catch (_: Exception) {}
            }

            scanned++
            reportScanned()
        }

        data class SafAudioScanOutcome(
            val uri: String,
            val name: String,
            val lastModified: Long,
            val metadata: JSONObject?,
            val error: String?,
        )

        val pendingAudio = mutableListOf<SafAudioEntry>()
        for (audio in audioFiles) {
            val doc = audio.doc
            if (safScanStopRequested()) {
                ndjsonWriter?.close()
                spill?.abandon()
                return cancelledResult()
            }

            val stableUri = doc.uri.toString()
            val lastModified = audio.lastModified
            if (checkpointed(stableUri, lastModified)) {
                continue
            }
            if (cueReferencedAudioUris.contains(stableUri)) {
                recordCheckpoint(stableUri, lastModified)
                scanned++
                val pct = safScanProgressPct(scanned, totalItems)
                updateSafScanProgress {
                    it.scannedFiles = scanned
                    it.progressPct = pct
                }
                continue
            }
            pendingAudio.add(audio)
        }

        // Descriptor reads stream from the provider without copying, so the
        // pool is bounded by provider round trips rather than copy memory.
        val completed = runSafReadsInOrder(
            pendingAudio,
            cancelled = { safScanStopRequested() },
            task = { audio ->
                val doc = audio.doc
                val stableUri = doc.uri.toString()
                val name = audio.name
                val lastModified = audio.lastModified
                val ext = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
                val fallbackExt = if (ext.isNotBlank()) ".${ext}" else null
                val coverCacheKey = buildLibraryCoverCacheKey(stableUri, lastModified)
                var error: String? = null
                val metadata = try {
                    readAudioMetadataFromUri(
                        coreBackend,
                        doc.uri,
                        name,
                        fallbackExt,
                        coverCacheKey,
                        onFailure = { error = it },
                    )
                } catch (e: Exception) {
                    error = e.message ?: e.javaClass.simpleName
                    null
                }
                SafAudioScanOutcome(stableUri, name, lastModified, metadata, error)
            },
        ) { audio, result ->
            val outcome = result.getOrNull()
            if (outcome == null) {
                errors++
                val error = result.exceptionOrNull()
                reportLibraryScanError(audio.doc.uri.toString(), "Read metadata", error?.message ?: "Metadata task failed")
            } else {
                updateSafScanProgress { it.currentFile = outcome.name }
                val metadataObj = outcome.metadata
                if (metadataObj == null) {
                    errors++
                    reportLibraryScanError(outcome.uri, "Read metadata", outcome.error ?: "No readable audio metadata for ${outcome.name}")
                } else {
                    try {
                        metadataObj.put("id", buildStableLibraryId(outcome.uri))
                        metadataObj.put("filePath", outcome.uri)
                        metadataObj.put("fileModTime", outcome.lastModified)
                        putResult(metadataObj)
                        // Flush before recording the checkpoint to avoid losing the row.
                        ndjsonWriter?.flush()
                        recordCheckpoint(outcome.uri, outcome.lastModified)
                    } catch (error: Exception) {
                        errors++
                        reportLibraryScanError(outcome.uri, "Index track", error.message ?: error.javaClass.simpleName)
                    }
                }
            }

            scanned++
            reportScanned()
        }
        if (!completed) {
            ndjsonWriter?.close()
            spill?.abandon()
            return cancelledResult()
        }

        updateSafScanProgress {
            it.isComplete = true
            it.progressPct = 100.0
        }

        if (ndjsonWriter != null) {
            ndjsonWriter.close()
            checkpointWriter?.close()
            return mapOf("path" to outputPath, "count" to resultCount, "error_count" to errors)
        }
        spill!!.raw(if (resultCount == 0) "[]" else "]")
        return spill.result()
        } catch (e: Exception) {
            try { ndjsonWriter?.close() } catch (_: Exception) {}
            try { checkpointWriter?.close() } catch (_: Exception) {}
            spill?.abandon()
            // Preserve partial output for resume.
            throw e
        }
    }

    /**
     * Incremental SAF tree scan - only scans new or modified files.
     * Supports .cue sheets: expands them into virtual track entries and
     * deduplicates audio files referenced by CUE sheets.
     * @param treeUriStr The SAF tree URI to scan
     * @param existingFilesJson JSON object mapping file URI -> lastModified timestamp
     * @return JSON object with new/changed files and removed URIs
     */
internal fun MainActivity.scanSafTreeIncremental(treeUriStr: String, existingFilesJson: String): Any {
        val existingFiles = mutableMapOf<String, Long>()
        try {
            val obj = JSONObject(existingFilesJson)
            val keys = obj.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                existingFiles[key] = obj.optLong(key, 0)
            }
        } catch (_: Exception) {}
        return scanSafTreeIncremental(treeUriStr, existingFiles)
    }

internal fun MainActivity.scanSafTreeIncremental(
        treeUriStr: String,
        existingFiles: Map<String, Long>,
        cancelled: () -> Boolean = { false },
    ): Any {
        val (_, root, rootChildren) = resolveReadableSafTreeOrThrow(treeUriStr)

        resetSafScanProgress()
        safScanCancel = false
        safScanActive = true
        updateSafScanProgress {
            it.currentFile = "Scanning folders..."
        }

        val supportedAudioExt = libraryScanAudioExtensions
        // Names and timestamps come from the directory listing; querying each
        // document again costs a provider round trip per changed file.
        data class ChangedAudio(val doc: DocumentFile, val name: String, val lastModified: Long)
        data class CueEntry(
            val doc: DocumentFile,
            val parentDir: DocumentFile,
            val name: String,
            val lastModified: Long,
        )
        val audioFiles = mutableListOf<ChangedAudio>()
        val cueFilesToScan = mutableListOf<CueEntry>()
        val unchangedCueFiles = mutableListOf<CueEntry>()
        val currentUris = mutableSetOf<String>()
        val visitedDirUris = mutableSetOf<String>()
        val safChildLookupCache = mutableMapOf<String, Map<String, DocumentFile>>()
        var traversalErrors = 0

        val existingCueVirtualPaths = mutableMapOf<String, MutableList<String>>()
        for (key in existingFiles.keys) {
            val hashIdx = key.indexOf("#track")
            if (hashIdx > 0) {
                val baseCueUri = key.substring(0, hashIdx)
                existingCueVirtualPaths.getOrPut(baseCueUri) { mutableListOf() }.add(key)
            }
        }

        val queue: ArrayDeque<Pair<DocumentFile, String>> = ArrayDeque()
        queue.add(root to "")
        val lister = SafTreeLister(this)

        while (queue.isNotEmpty()) {
            if (safScanStopRequested(cancelled)) {
                updateSafScanProgress { it.isComplete = true }
                val result = JSONObject()
                result.put("files", JSONArray())
                result.put("removedUris", JSONArray())
                result.put("skippedCount", 0)
                result.put("totalFiles", 0)
                result.put("cancelled", true)
                return result.toString()
            }

            val (dir, path) = queue.removeFirst()
            val dirUri = dir.uri.toString()
            if (!visitedDirUris.add(dirUri)) {
                continue
            }

            val listing = if (dir.uri == root.uri) {
                Result.success(rootChildren)
            } else {
                lister.list(dir, queue, visitedDirUris)
            }
            val children = listing.getOrNull()
            if (children == null) {
                traversalErrors++
                updateSafScanProgress { it.errorCount = traversalErrors }
                reportLibraryScanError(dirUri, "List folder", listing.exceptionOrNull()?.message ?: "No directory listing")
                continue
            }
            rememberCueDirectoryListing(dir, children, safChildLookupCache)

            for (child in children) {
                if (safScanStopRequested(cancelled)) {
                    updateSafScanProgress { it.isComplete = true }
                    val result = JSONObject()
                    result.put("files", JSONArray())
                    result.put("removedUris", JSONArray())
                    result.put("skippedCount", 0)
                    result.put("totalFiles", 0)
                    result.put("cancelled", true)
                    return result.toString()
                }

                try {
                    if (child.isDirectory) {
                        val childName = child.name ?: continue
                        val childPath = if (path.isBlank()) childName else "$path/$childName"
                        val childUri = child.doc.uri.toString()
                        if (childUri == dirUri || visitedDirUris.contains(childUri)) {
                            continue
                        }
                        queue.add(child.doc to childPath)
                    } else {
                        val uriStr = child.doc.uri.toString()
                        val name = child.name
                        if (name != null && isIncompleteSafFileName(name)) continue
                        currentUris.add(uriStr)
                        if (name == null) continue
                        val ext = name.substringAfterLast('.', "").lowercase(Locale.ROOT)

                        if (ext == "cue") {
                            val lastModified = child.lastModified

                            val virtualPaths = existingCueVirtualPaths[uriStr]
                            val existingModified = virtualPaths?.firstOrNull()?.let { existingFiles[it] }

                            if (existingModified != null && existingModified == lastModified) {
                                unchangedCueFiles.add(CueEntry(child.doc, dir, name, lastModified))
                                for (vp in virtualPaths) {
                                    currentUris.add(vp)
                                }
                            } else {
                                cueFilesToScan.add(CueEntry(child.doc, dir, name, lastModified))
                            }
                        } else if (ext.isNotBlank() && supportedAudioExt.contains(".$ext")) {
                            val existingModified = existingFiles[uriStr]
                            val lastModified = child.lastModified

                            if (existingModified == null || existingModified != lastModified) {
                                audioFiles.add(ChangedAudio(child.doc, name, lastModified))
                            }
                        }
                    }
                } catch (e: Exception) {
                    traversalErrors++
                    updateSafScanProgress { it.errorCount = traversalErrors }
                    reportLibraryScanError(child.doc.uri.toString(), "Inspect entry", e.message ?: e.javaClass.simpleName)
                }
            }
        }

        if (traversalErrors > 0) {
            throw IOException("SAF traversal failed for $traversalErrors entries")
        }

        val removedUris = existingFiles.keys.filter { !currentUris.contains(it) }
        val totalFiles = currentUris.size
        val filesToProcess = audioFiles.size + cueFilesToScan.size
        val skippedCount = (totalFiles - filesToProcess).coerceAtLeast(0)

        updateSafScanProgress {
            it.totalFiles = totalFiles
        }

        if (audioFiles.isEmpty() && cueFilesToScan.isEmpty()) {
            updateSafScanProgress {
                it.isComplete = true
                it.scannedFiles = totalFiles
                it.progressPct = 100.0
            }
            val result = JSONObject()
            result.put("files", JSONArray())
            result.put("removedUris", JSONArray(removedUris))
            result.put("skippedCount", skippedCount)
            result.put("totalFiles", totalFiles)
            return result.toString()
        }

        // Stream changed-file entries to a spill file — after a cache loss an
        // incremental scan can be as large as a full scan.
        val spill = this.SpillJsonWriter()
        spill.raw("{\"files\":[")
        var fileCount = 0
        fun putFile(obj: JSONObject) {
            if (fileCount > 0) spill.raw(",")
            spill.raw(obj.toString())
            fileCount++
        }
        var scanned = 0
        var errors = traversalErrors

        fun reportProcessed() {
            val processed = skippedCount + scanned
            val pct = if (totalFiles > 0) {
                safScanProgressPct(processed, totalFiles)
            } else {
                100.0
            }
            updateSafScanProgress {
                it.scannedFiles = processed
                it.errorCount = errors
                it.progressPct = pct
            }
        }

        val cueReferencedAudioUris = mutableSetOf<String>()

        for ((cueDoc, parentDir, cueName, cueLastModified) in cueFilesToScan) {
            if (safScanStopRequested(cancelled)) {
                updateSafScanProgress { it.isComplete = true }
                spill.abandon()
                val result = JSONObject()
                result.put("files", JSONArray())
                result.put("removedUris", JSONArray())
                result.put("skippedCount", skippedCount)
                result.put("totalFiles", totalFiles)
                result.put("cancelled", true)
                return result.toString()
            }

            updateSafScanProgress { it.currentFile = cueName }

            var tempCuePath: String? = null
            try {
                tempCuePath = copyUriToTemp(coreBackend, cueDoc.uri, ".cue", cueName)
                if (tempCuePath == null) {
                    errors++
                    reportLibraryScanError(cueDoc.uri.toString(), "Read CUE", "Failed to copy CUE file")
                    scanned++
                    continue
                }

                val audioDoc = resolveCueSheetAudio(
                    tempCuePath,
                    parentDir,
                    cueName,
                    safChildLookupCache,
                )

                if (audioDoc == null) {
                    reportLibraryScanError(cueDoc.uri.toString(), "Resolve CUE audio", "No audio file found for $cueName")
                    errors++
                    scanned++
                    continue
                }

                cueReferencedAudioUris.add(audioDoc.uri.toString())

                val cueArray = scanSafCueTracks(
                    tempCuePath,
                    audioDoc,
                    cueDoc.uri.toString(),
                    cueLastModified,
                ) { cueLastModified }
                for (j in 0 until cueArray.length()) {
                    val trackObj = cueArray.getJSONObject(j)
                    putFile(trackObj)
                    val virtualPath = trackObj.optString("filePath", "")
                    if (virtualPath.isNotBlank()) {
                        currentUris.add(virtualPath)
                    }
                }

            } catch (e: Exception) {
                errors++
                reportLibraryScanError(cueDoc.uri.toString(), "Scan CUE", e.message ?: e.javaClass.simpleName)
            } finally {
                try { tempCuePath?.let { File(it).delete() } } catch (_: Exception) {}
            }

            scanned++
            reportProcessed()
        }

        for ((cueDoc, parentDir, cueName) in unchangedCueFiles) {
            try {
                val reference = readCueAudioReference(
                    open = { contentResolver.openInputStream(cueDoc.uri)?.bufferedReader() },
                    retryOnDenied = isMediaStoreUri(cueDoc.uri),
                )
                if (reference != null) {
                    val audioDoc = resolveCueAudioSibling(
                        parentDir,
                        cueName,
                        reference.filename,
                        safChildLookupCache,
                    )
                    if (audioDoc != null) {
                        cueReferencedAudioUris.add(audioDoc.uri.toString())
                    }
                }
            } catch (e: Exception) {
                android.util.Log.w("Mornye", "SAF incremental scan: failed to resolve audio for unchanged CUE: ${e.message}")
            }
        }

        fun cancelledIncrementalResult(): String {
            updateSafScanProgress { it.isComplete = true }
            spill.abandon()
            val result = JSONObject()
            result.put("files", JSONArray())
            result.put("removedUris", JSONArray())
            result.put("skippedCount", skippedCount)
            result.put("totalFiles", totalFiles)
            result.put("cancelled", true)
            return result.toString()
        }

        val pendingAudio = mutableListOf<ChangedAudio>()
        for (audio in audioFiles) {
            if (safScanStopRequested(cancelled)) return cancelledIncrementalResult()
            if (cueReferencedAudioUris.contains(audio.doc.uri.toString())) {
                scanned++
                reportProcessed()
            } else {
                pendingAudio.add(audio)
            }
        }

        val completed = runSafReadsInOrder(
            pendingAudio,
            cancelled = { safScanStopRequested(cancelled) },
            task = { audio ->
                val ext = audio.name.substringAfterLast('.', "").lowercase(Locale.ROOT)
                val fallbackExt = if (ext.isNotBlank()) ".${ext}" else null
                readAudioMetadataFromUri(
                    coreBackend,
                    audio.doc.uri,
                    audio.name,
                    fallbackExt,
                    buildLibraryCoverCacheKey(audio.doc.uri.toString(), audio.lastModified),
                    onFailure = { message ->
                        reportLibraryScanError(audio.doc.uri.toString(), "Read metadata", message)
                    },
                )
            },
        ) { audio, result ->
            updateSafScanProgress { it.currentFile = audio.name }
            // A failed read aborts the incremental scan, as it did when serial.
            val metadataObj = try {
                result.getOrThrow()
            } catch (error: Exception) {
                reportLibraryScanError(audio.doc.uri.toString(), "Read metadata", error.message ?: error.javaClass.simpleName)
                throw error
            }
            if (metadataObj == null) {
                errors++
            } else {
                try {
                    val stableUri = audio.doc.uri.toString()
                    metadataObj.put("id", buildStableLibraryId(stableUri))
                    metadataObj.put("filePath", stableUri)
                    metadataObj.put("fileModTime", audio.lastModified)
                    metadataObj.put("lastModified", audio.lastModified)
                    putFile(metadataObj)
                } catch (error: Exception) {
                    errors++
                    reportLibraryScanError(audio.doc.uri.toString(), "Index track", error.message ?: error.javaClass.simpleName)
                }
            }
            scanned++
            reportProcessed()
        }
        if (!completed) return cancelledIncrementalResult()

        val finalRemovedUris = existingFiles.keys.filter { !currentUris.contains(it) }

        updateSafScanProgress {
            it.isComplete = true
            it.progressPct = 100.0
        }

        spill.raw("],\"removedUris\":")
        spill.raw(JSONArray(finalRemovedUris).toString())
        spill.raw(",\"skippedCount\":$skippedCount,\"totalFiles\":$totalFiles}")
        return spill.result()
    }
