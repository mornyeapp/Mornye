package com.zarz.mornye

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

internal suspend fun Context.handleSafExists(call: MethodCall, result: MethodChannel.Result) {
    val uriStr = call.argument<String>("uri") ?: ""
    val exists = withContext(Dispatchers.IO) {
        val uri = Uri.parse(uriStr)
        DocumentFile.fromSingleUri(this@handleSafExists, uri)?.exists() == true
    }
    result.success(exists)
}

internal suspend fun Context.handleSafExistsBatch(call: MethodCall, result: MethodChannel.Result) {
    val urisJson = call.argument<String>("uris_json") ?: "[]"
    val response = withContext(Dispatchers.IO) {
        safExistsBatch(urisJson)
    }
    result.success(response)
}

internal suspend fun MainActivity.handleProbeSafTreeReadAccess(call: MethodCall, result: MethodChannel.Result) {
    val uriStr = call.argument<String>("tree_uri") ?: ""
    val readable = withContext(Dispatchers.IO) {
        probeSafTreeReadAccess(
            hasReadPermission = {
                val uri = Uri.parse(uriStr)
                val root = DocumentsContract.buildDocumentUriUsingTree(
                    uri,
                    DocumentsContract.getTreeDocumentId(uri),
                )
                checkUriPermission(
                    root,
                    android.os.Process.myPid(),
                    android.os.Process.myUid(),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                ) == android.content.pm.PackageManager.PERMISSION_GRANTED
            },
            readRoot = {
                val uri = Uri.parse(uriStr)
                val root = DocumentsContract.buildDocumentUriUsingTree(
                    uri,
                    DocumentsContract.getTreeDocumentId(uri),
                )
                val rootPresent = contentResolver.query(
                    root,
                    arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                    null, null, null,
                )?.use { cursor ->
                    when {
                        cursor.moveToFirst() -> true
                        cursor.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) -> null
                        else -> false
                    }
                }
                if (rootPresent == true) {
                    true
                } else {
                    // A reconnecting remote provider may not have
                    // queryDocument metadata yet. A completed child
                    // listing is stronger evidence of read access.
                    val directory = DocumentFile.fromTreeUri(this@handleProbeSafTreeReadAccess, uri)
                    if (directory != null && listSafChildrenOrThrow(directory).isNotEmpty()) {
                        true
                    } else {
                        rootPresent
                    }
                }
            },
            onFailure = { error ->
                android.util.Log.w("Mornye", "SAF library read probe failed", error)
            },
        )
    }
    result.success(readable)
}

internal suspend fun MainActivity.handleIsSafTreeAccessible(call: MethodCall, result: MethodChannel.Result) {
    val uriStr = call.argument<String>("tree_uri") ?: ""
    val accessible = withContext(Dispatchers.IO) {
        try {
            val uri = Uri.parse(uriStr)
            val persisted = contentResolver.persistedUriPermissions.any {
                it.uri == uri && it.isReadPermission && it.isWritePermission
            }
            if (!persisted) {
                false
            } else {
                val doc = DocumentFile.fromTreeUri(this@handleIsSafTreeAccessible, uri)
                doc != null && doc.exists() && doc.canWrite()
            }
        } catch (e: Exception) {
            android.util.Log.w("Mornye", "SAF tree access check failed: ${e.message}")
            false
        }
    }
    result.success(accessible)
}

internal suspend fun MainActivity.handleSafDelete(call: MethodCall, result: MethodChannel.Result) {
    val uriStr = call.argument<String>("uri") ?: ""
    val deleted = withContext(Dispatchers.IO) {
        val uri = Uri.parse(uriStr)
        DocumentFile.fromSingleUri(this@handleSafDelete, uri)?.delete() == true
    }
    result.success(deleted)
}

internal suspend fun MainActivity.handleSafStat(call: MethodCall, result: MethodChannel.Result) {
    val uriStr = call.argument<String>("uri") ?: ""
    val response = withContext(Dispatchers.IO) {
        querySafDocumentStat(contentResolver, Uri.parse(uriStr)).toString()
    }
    result.success(response)
}

internal suspend fun MainActivity.handleResolveSafFile(call: MethodCall, result: MethodChannel.Result) {
    val treeUriStr = call.argument<String>("tree_uri") ?: ""
    val relativeDir = call.argument<String>("relative_dir") ?: ""
    val fileName = call.argument<String>("file_name") ?: ""
    val response = withContext(Dispatchers.IO) {
        resolveSafFile(treeUriStr, relativeDir, fileName)
    }
    result.success(response)
}

internal suspend fun MainActivity.handleInspectSafFiles(call: MethodCall, result: MethodChannel.Result) {
    val requestsJson = call.argument<String>("requests_json") ?: "[]"
    val response = withContext(Dispatchers.IO) {
        inspectSafFiles(requestsJson)
    }
    result.success(response)
}

internal suspend fun MainActivity.handleSafCopyToTemp(call: MethodCall, result: MethodChannel.Result) {
    val uriStr = call.argument<String>("uri") ?: ""
    val tempPath = withContext(Dispatchers.IO) {
        copyUriToTemp(coreBackend, Uri.parse(uriStr))
    }
    result.success(tempPath)
}

internal suspend fun Context.handleSafOpenPlaybackLease(call: MethodCall, result: MethodChannel.Result) {
    val uriStr = call.argument<String>("uri") ?: ""
    val lease = withContext(Dispatchers.IO) {
        SafPlaybackLeases.open(this@handleSafOpenPlaybackLease, uriStr)
    }
    result.success(lease)
}

internal fun handleSafClosePlaybackLease(call: MethodCall, result: MethodChannel.Result) {
    val token = call.argument<String>("token") ?: ""
    SafPlaybackLeases.close(token)
    result.success(null)
}

internal suspend fun MainActivity.handleSafCreateFromPath(call: MethodCall, result: MethodChannel.Result) {
    val treeUriStr = call.argument<String>("tree_uri") ?: ""
    val relativeDir = call.argument<String>("relative_dir") ?: ""
    val fileName = SafDownloadHandler.sanitizeFilename(call.argument<String>("file_name") ?: "")
    val mimeType = call.argument<String>("mime_type") ?: "application/octet-stream"
    val srcPath = call.argument<String>("src_path") ?: ""
    val createdUri = withContext(Dispatchers.IO) {
        if (treeUriStr.isBlank()) return@withContext null
        if (fileName.isBlank()) return@withContext null
        val dir = SafDownloadHandler.ensureDocumentDir(this@handleSafCreateFromPath, Uri.parse(treeUriStr), relativeDir) ?: return@withContext null
        val existing = findSafChild(this@handleSafCreateFromPath, dir, fileName)
        val createdNew = existing == null
        val doc = SafDownloadHandler.createOrReuseDocumentFile(this@handleSafCreateFromPath, dir, mimeType, fileName)
            ?: return@withContext null
        if (!writeUriFromPath(doc.uri, srcPath)) {
            if (createdNew) {
                doc.delete()
            }
            return@withContext null
        }
        doc.uri.toString()
    }
    result.success(createdUri)
}

internal suspend fun MainActivity.handleSafCreateIfAbsentFromPath(call: MethodCall, result: MethodChannel.Result) {
    val treeUriStr = call.argument<String>("tree_uri") ?: ""
    val relativeDir = call.argument<String>("relative_dir") ?: ""
    val fileName = call.argument<String>("file_name") ?: ""
    val mimeType = call.argument<String>("mime_type") ?: "application/octet-stream"
    val srcPath = call.argument<String>("src_path") ?: ""
    val response = withContext(Dispatchers.IO) {
        if (treeUriStr.isBlank() || fileName.isBlank()) return@withContext null
        SafDownloadHandler.writeFileToSafIfAbsent(
            context = this@handleSafCreateIfAbsentFromPath,
            treeUriStr = treeUriStr,
            relativeDir = relativeDir,
            fileName = fileName,
            mimeType = mimeType,
            srcPath = srcPath,
        )?.let { writeResult ->
            JSONObject()
                .put("uri", writeResult.uri)
                .put("file_name", writeResult.fileName)
                .put("already_exists", writeResult.alreadyExists)
                .put("publish_timings_ms", JSONObject(writeResult.publishTimingsMs))
                .toString()
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleSafCreateUniqueFromPath(call: MethodCall, result: MethodChannel.Result) {
    val treeUriStr = call.argument<String>("tree_uri") ?: ""
    val relativeDir = call.argument<String>("relative_dir") ?: ""
    val fileName = call.argument<String>("file_name") ?: ""
    val mimeType = call.argument<String>("mime_type") ?: "application/octet-stream"
    val srcPath = call.argument<String>("src_path") ?: ""
    val preservedSuffix = call.argument<String>("preserved_suffix") ?: ""
    val response = withContext(Dispatchers.IO) {
        if (treeUriStr.isBlank() || fileName.isBlank()) return@withContext null
        SafDownloadHandler.writeFileToSafUnique(
            context = this@handleSafCreateUniqueFromPath,
            treeUriStr = treeUriStr,
            relativeDir = relativeDir,
            fileName = fileName,
            mimeType = mimeType,
            srcPath = srcPath,
            preservedSuffix = preservedSuffix,
        )?.let { writeResult ->
            JSONObject()
                .put("uri", writeResult.uri)
                .put("file_name", writeResult.fileName)
                .put("publish_timings_ms", JSONObject(writeResult.publishTimingsMs))
                .toString()
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleSafCreateCollisionAwareFromPath(call: MethodCall, result: MethodChannel.Result) {
    val treeUriStr = call.argument<String>("tree_uri") ?: ""
    val relativeDir = call.argument<String>("relative_dir") ?: ""
    val cleanFileName = call.argument<String>("clean_file_name") ?: ""
    val variantFileName = call.argument<String>("variant_file_name") ?: ""
    val mimeType = call.argument<String>("mime_type") ?: "application/octet-stream"
    val srcPath = call.argument<String>("src_path") ?: ""
    val preservedSuffix = call.argument<String>("preserved_suffix") ?: ""
    val response = withContext(Dispatchers.IO) {
        if (
            treeUriStr.isBlank() ||
            cleanFileName.isBlank() ||
            variantFileName.isBlank()
        ) return@withContext null
        SafDownloadHandler.writeFileToSafCollisionAware(
            context = this@handleSafCreateCollisionAwareFromPath,
            treeUriStr = treeUriStr,
            relativeDir = relativeDir,
            cleanFileName = cleanFileName,
            variantFileName = variantFileName,
            mimeType = mimeType,
            srcPath = srcPath,
            preservedSuffix = preservedSuffix,
        )?.let { writeResult ->
            JSONObject()
                .put("uri", writeResult.uri)
                .put("file_name", writeResult.fileName)
                .put("publish_timings_ms", JSONObject(writeResult.publishTimingsMs))
                .toString()
        }
    }
    result.success(response)
}

internal fun MainActivity.handleOpenContentUri(call: MethodCall, result: MethodChannel.Result) {
    val uriStr = call.argument<String>("uri") ?: ""
    val mimeType = call.argument<String>("mime_type") ?: ""
    try {
        val uri = Uri.parse(uriStr)
        val type = if (mimeType.isNotBlank()) mimeType else contentResolver.getType(uri) ?: "*/*"
        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, type)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(intent)
        result.success(null)
    } catch (e: Exception) {
        result.error("open_failed", e.message, null)
    }
}

internal fun MainActivity.handleShareContentUri(call: MethodCall, result: MethodChannel.Result) {
    val uriStr = call.argument<String>("uri") ?: ""
    val title = call.argument<String>("title") ?: ""
    try {
        val uri = Uri.parse(uriStr)
        val type = contentResolver.getType(uri) ?: "audio/*"
        val shareIntent = Intent(Intent.ACTION_SEND).apply {
            putExtra(Intent.EXTRA_STREAM, uri)
            setType(type)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (title.isNotBlank()) {
                putExtra(Intent.EXTRA_SUBJECT, title)
            }
        }
        startActivity(Intent.createChooser(shareIntent, title.ifBlank { "Share" }))
        result.success(true)
    } catch (e: Exception) {
        result.error("share_failed", e.message, null)
    }
}

internal suspend fun MainActivity.handleWriteTempToSaf(call: MethodCall, result: MethodChannel.Result) {
    val tempPath = call.argument<String>("temp_path") ?: ""
    val safUri = call.argument<String>("saf_uri") ?: ""
    val response = withContext(Dispatchers.IO) {
        try {
            val uri = Uri.parse(safUri)
            if (writeUriFromPath(uri, tempPath)) {
                """{"success":true}"""
            } else {
                """{"success":false,"error":"Failed to write back to SAF"}"""
            }
        } finally {
            try { File(tempPath).delete() } catch (_: Exception) {}
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleWriteSafSidecarLrc(call: MethodCall, result: MethodChannel.Result) {
    val safUri = call.argument<String>("saf_uri") ?: ""
    val lyrics = call.argument<String>("lyrics") ?: ""
    val response = withContext(Dispatchers.IO) {
        try {
            val uri = Uri.parse(safUri)
            if (writeSafSidecarLrc(uri, lyrics)) {
                """{"success":true}"""
            } else {
                """{"success":false,"error":"Failed to write LRC sidecar"}"""
            }
        } catch (e: Exception) {
            """{"success":false,"error":"${e.message?.replace("\"", "'")}"}"""
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleGetSafFileModTimes(call: MethodCall, result: MethodChannel.Result) {
    val uris = call.argument<String>("uris") ?: "[]"
    val response = withContext(Dispatchers.IO) {
        getSafFileModTimes(uris)
    }
    result.success(response)
}
