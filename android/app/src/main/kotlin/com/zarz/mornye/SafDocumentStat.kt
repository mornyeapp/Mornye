package com.zarz.mornye

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import org.json.JSONObject

internal fun querySafDocumentStat(resolver: ContentResolver, uri: Uri): JSONObject {
    val projection = arrayOf(
        DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
    )
    // DocumentFile.exists/length swallow provider and security exceptions.
    // Query once, keep nullable metadata, and let failures reach the channel.
    val cursor = resolver.query(uri, projection, null, null, null)
        ?: return safDocumentStatResult(hasRow = null)
    return cursor.use {
        val loading = it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false)
        val hasRow = it.moveToFirst()
        if (!hasRow || loading) return@use safDocumentStatResult(hasRow, loading)
        fun nullableLong(column: String): Long? {
            val index = it.getColumnIndex(column)
            return if (index < 0 || it.isNull(index)) null else it.getLong(index)
        }
        val mimeIndex = it.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
        val nameIndex = it.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        safDocumentStatResult(
            hasRow = true,
            size = nullableLong(DocumentsContract.Document.COLUMN_SIZE),
            modified = nullableLong(DocumentsContract.Document.COLUMN_LAST_MODIFIED),
            mimeType = if (mimeIndex < 0 || it.isNull(mimeIndex)) null else it.getString(mimeIndex),
            displayName = if (nameIndex < 0 || it.isNull(nameIndex)) null else it.getString(nameIndex),
        )
    }
}
