package com.zarz.mornye

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import org.json.JSONArray
import org.json.JSONObject

// A failed DocumentsProvider query must never be mistaken for a missing file.
// Unlike DocumentFile.exists(), this keeps null cursors/exceptions inconclusive.
internal fun Context.safExistsBatch(urisJson: String): String {
    val result = JSONObject()
    val uris = JSONArray(urisJson)
    val accessibleTrees = mutableMapOf<String, Boolean>()
    val permissions = contentResolver.persistedUriPermissions
    val projection = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
    for (index in 0 until uris.length()) {
        val path = uris.optString(index)
        if (path.isBlank()) continue
        var status = "unknown"
        try {
            val uri = Uri.parse(path)
            val treeAccessible = if (DocumentsContract.isTreeUri(uri)) {
                val treeId = DocumentsContract.getTreeDocumentId(uri)
                val tree = DocumentsContract.buildTreeDocumentUri(uri.authority, treeId)
                accessibleTrees.getOrPut(tree.toString()) {
                    val granted = permissions.any { it.uri == tree && it.isReadPermission }
                    if (!granted) false else {
                        val root = DocumentsContract.buildDocumentUriUsingTree(tree, treeId)
                        contentResolver.query(root, projection, null, null, null)?.use {
                            it.moveToFirst()
                        } == true
                    }
                }
            } else false
            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                status = if (cursor.moveToFirst()) "found"
                    else if (treeAccessible &&
                        !cursor.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false))
                        "missing" else "unknown"
            }
        } catch (_: Exception) {
            // Revoked permission, offline storage and provider errors: retain row.
        }
        result.put(path, status)
    }
    return result.toString()
}

/**
 * Resolve SAF file last-modified values for a list of content URIs.
 * Returns JSON object mapping uri -> lastModified (unix millis).
 */
internal fun MainActivity.getSafFileModTimes(urisJson: String): String {
        val result = JSONObject()
        val uris = try {
            JSONArray(urisJson)
        } catch (_: Exception) {
            JSONArray()
        }

        for (i in 0 until uris.length()) {
            val uriStr = uris.optString(i, "")
            if (uriStr.isBlank()) continue
            try {
                val uri = Uri.parse(uriStr)
                val doc = DocumentFile.fromSingleUri(this, uri)
                if (doc != null && doc.exists()) {
                    result.put(uriStr, doc.lastModified())
                }
            } catch (_: Exception) {}
        }

        return result.toString()
    }
