package com.zarz.mornye

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

internal fun Context.resolveSafFile(treeUriStr: String, relativeDir: String, fileName: String): String {
        val obj = JSONObject()
        if (treeUriStr.isBlank() || fileName.isBlank()) {
            obj.put("uri", "")
            obj.put("relative_dir", "")
            return obj.toString()
        }
        val safeRelativeDir = SafDownloadHandler.sanitizeRelativeDir(relativeDir)
        val safeFileName = SafDownloadHandler.sanitizeFilename(fileName)
        if (safeFileName.isBlank()) {
            obj.put("uri", "")
            obj.put("relative_dir", "")
            return obj.toString()
        }

        val treeUri = Uri.parse(treeUriStr)
        val targetDir = SafDownloadHandler.findDocumentDir(this, treeUri, safeRelativeDir)
        if (targetDir != null) {
            val direct = findSafChild(this, targetDir, safeFileName)
            if (direct != null && direct.isFile) {
                obj.put("uri", direct.uri.toString())
                obj.put("relative_dir", safeRelativeDir)
                return obj.toString()
            }
        }

        val root = DocumentFile.fromTreeUri(this, treeUri) ?: run {
            obj.put("uri", "")
            obj.put("relative_dir", "")
            return obj.toString()
        }

        val queue: ArrayDeque<Pair<DocumentFile, String>> = ArrayDeque()
        queue.add(root to "")
        var visited = 0
        val maxVisited = 20000

        while (queue.isNotEmpty()) {
            if (visited > maxVisited) break
            val (dir, path) = queue.removeFirst()
            val children = try {
                listSafChildrenOrThrow(dir, includeLastModified = false)
            } catch (_: Exception) {
                continue
            }
            for (child in children) {
                visited++
                if (child.isDirectory) {
                    val childName = child.name ?: continue
                    val childPath = if (path.isBlank()) childName else "$path/$childName"
                    queue.add(child.doc to childPath)
                } else if (child.isFile) {
                    if (child.name == safeFileName) {
                        obj.put("uri", child.doc.uri.toString())
                        obj.put("relative_dir", path)
                        return obj.toString()
                    }
                }
            }
        }

        obj.put("uri", "")
        obj.put("relative_dir", "")
        return obj.toString()
    }

private data class SafFileInspectionRequest(
    val key: String,
    val treeUri: String,
    val relativeDir: String,
    val currentUri: String,
    val fileNames: List<String>,
    val exactRelativeDir: Boolean,
)

/**
 * Inspects many SAF history entries while walking each document tree at most
 * once. The old per-file resolver could repeat a 20k-document breadth-first
 * search for every missing history row and every conversion filename variant.
 */
internal fun Context.inspectSafFiles(requestsJson: String): String {
    val output = JSONObject()
    val resultsByKey = linkedMapOf<String, JSONObject>()
    val requests = mutableListOf<SafFileInspectionRequest>()

    fun result(
        key: String,
        status: String,
        uri: String = "",
        fileName: String = "",
        relativeDir: String = "",
    ) = JSONObject().apply {
        put("key", key)
        put("status", status)
        put("uri", uri)
        put("file_name", fileName)
        put("relative_dir", relativeDir)
    }

    try {
        val rawRequests = JSONArray(requestsJson)
        for (index in 0 until rawRequests.length()) {
            val raw = rawRequests.optJSONObject(index) ?: continue
            val key = raw.optString("key").trim()
            if (key.isBlank()) continue
            val names = mutableListOf<String>()
            val rawNames = raw.optJSONArray("file_names")
            if (rawNames != null) {
                for (nameIndex in 0 until rawNames.length()) {
                    val sanitized = SafDownloadHandler.sanitizeFilename(
                        rawNames.optString(nameIndex).trim(),
                    )
                    if (sanitized.isNotBlank() && sanitized !in names) {
                        names.add(sanitized)
                    }
                }
            }
            requests.add(
                SafFileInspectionRequest(
                    key = key,
                    treeUri = raw.optString("tree_uri").trim(),
                    relativeDir = SafDownloadHandler.sanitizeRelativeDir(
                        raw.optString("relative_dir"),
                    ),
                    currentUri = raw.optString("current_uri").trim(),
                    fileNames = names,
                    exactRelativeDir = raw.optBoolean("exact_relative_dir", false),
                ),
            )
        }

        val pendingByTree = linkedMapOf<String, MutableList<SafFileInspectionRequest>>()
        for (request in requests) {
            if (request.currentUri.startsWith("content://")) {
                try {
                    val current = DocumentFile.fromSingleUri(this, Uri.parse(request.currentUri))
                    if (current != null && current.exists() && current.isFile) {
                        resultsByKey[request.key] = result(
                            key = request.key,
                            status = "found",
                            uri = request.currentUri,
                            fileName = current.name.orEmpty(),
                            relativeDir = request.relativeDir,
                        )
                        continue
                    }
                } catch (_: Exception) {
                    // Fall through to the persisted tree lookup.
                }
            }
            if (request.treeUri.isBlank() || request.fileNames.isEmpty()) {
                resultsByKey[request.key] = result(request.key, "unknown")
                continue
            }
            pendingByTree.getOrPut(request.treeUri) { mutableListOf() }.add(request)
        }

        for ((treeUriString, treeRequests) in pendingByTree) {
            val treeUri = try {
                Uri.parse(treeUriString)
            } catch (_: Exception) {
                null
            }
            val hasPermission = treeUri != null && contentResolver.persistedUriPermissions.any {
                it.uri == treeUri && it.isReadPermission && it.isWritePermission
            }
            val root = if (hasPermission) {
                try {
                    DocumentFile.fromTreeUri(this, treeUri)
                } catch (_: Exception) {
                    null
                }
            } else {
                null
            }
            if (root == null || !root.exists() || !root.canWrite()) {
                for (request in treeRequests) {
                    resultsByKey[request.key] = result(request.key, "unknown")
                }
                continue
            }

            val unresolved = mutableListOf<SafFileInspectionRequest>()
            val directoryCache = mutableMapOf<String, Map<String, SafChildEntry>>()
            val resolvedDirectoryCache = mutableMapOf<String, DocumentFile?>()
            for (request in treeRequests) {
                val directDir = if (resolvedDirectoryCache.containsKey(request.relativeDir)) {
                    resolvedDirectoryCache[request.relativeDir]
                } else {
                    val resolved = try {
                        SafDownloadHandler.findDocumentDir(this, treeUri!!, request.relativeDir)
                    } catch (_: Exception) {
                        null
                    }
                    resolvedDirectoryCache[request.relativeDir] = resolved
                    resolved
                }
                val lookup = if (directDir == null) {
                    emptyMap()
                } else {
                    directoryCache.getOrPut(directDir.uri.toString()) {
                        buildMap {
                            for (child in listSafChildrenOrThrow(directDir, includeLastModified = false)) {
                                if (child.isDirectory) continue
                                val name = child.name?.trim().orEmpty()
                                if (name.isNotBlank()) put(name.lowercase(Locale.ROOT), child)
                            }
                        }
                    }
                }
                val directName = request.fileNames.firstOrNull {
                    lookup.containsKey(it.lowercase(Locale.ROOT))
                }
                val direct = directName?.let { lookup[it.lowercase(Locale.ROOT)] }
                if (direct != null && direct.isFile) {
                    resultsByKey[request.key] = result(
                        key = request.key,
                        status = "found",
                        uri = direct.doc.uri.toString(),
                        fileName = direct.name ?: directName,
                        relativeDir = request.relativeDir,
                    )
                } else if (request.exactRelativeDir) {
                    resultsByKey[request.key] = result(
                        request.key,
                        if (directDir == null) "unknown" else "missing",
                    )
                } else {
                    unresolved.add(request)
                }
            }
            if (unresolved.isEmpty()) continue

            val wantedNames = unresolved
                .flatMap { it.fileNames }
                .map { it.lowercase(Locale.ROOT) }
                .toSet()
            val requestKeysByName = mutableMapOf<String, MutableSet<String>>()
            for (request in unresolved) {
                for (fileName in request.fileNames) {
                    requestKeysByName
                        .getOrPut(fileName.lowercase(Locale.ROOT)) { mutableSetOf() }
                        .add(request.key)
                }
            }
            val matches = mutableMapOf<String, Pair<SafChildEntry, String>>()
            val matchedRequestKeys = mutableSetOf<String>()
            val queue: ArrayDeque<Pair<DocumentFile, String>> = ArrayDeque()
            queue.add(root to "")
            var visited = 0
            val maxVisited = 50000
            var scanComplete = true

            while (queue.isNotEmpty() && matchedRequestKeys.size < unresolved.size) {
                if (visited >= maxVisited) {
                    scanComplete = false
                    break
                }
                val (directory, path) = queue.removeFirst()
                val children = try {
                    listSafChildrenOrThrow(directory, includeLastModified = false)
                } catch (_: Exception) {
                    scanComplete = false
                    break
                }
                for (child in children) {
                    visited++
                    if (visited >= maxVisited) {
                        scanComplete = false
                        break
                    }
                    if (child.isDirectory) {
                        val childName = child.name ?: continue
                        val childPath = if (path.isBlank()) childName else "$path/$childName"
                        queue.add(child.doc to childPath)
                    } else if (child.isFile) {
                        val childName = child.name ?: continue
                        val normalized = childName.lowercase(Locale.ROOT)
                        if (normalized in wantedNames && normalized !in matches) {
                            matches[normalized] = child to path
                            matchedRequestKeys.addAll(
                                requestKeysByName[normalized].orEmpty(),
                            )
                        }
                    }
                }
            }

            for (request in unresolved) {
                val matchedName = request.fileNames.firstOrNull {
                    matches.containsKey(it.lowercase(Locale.ROOT))
                }
                val match = matchedName?.let { matches[it.lowercase(Locale.ROOT)] }
                resultsByKey[request.key] = if (match != null) {
                    result(
                        key = request.key,
                        status = "found",
                        uri = match.first.doc.uri.toString(),
                        fileName = match.first.name ?: matchedName,
                        relativeDir = match.second,
                    )
                } else {
                    result(request.key, if (scanComplete) "missing" else "unknown")
                }
            }
        }
    } catch (error: Exception) {
        android.util.Log.w("Mornye", "Batch SAF inspection failed: ${error.message}")
        for (request in requests) {
            resultsByKey.putIfAbsent(request.key, result(request.key, "unknown"))
        }
    }

    val results = JSONArray()
    for (request in requests) {
        results.put(resultsByKey[request.key] ?: result(request.key, "unknown"))
    }
    output.put("results", results)
    return output.toString()
}
