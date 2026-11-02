package com.zarz.mornye

import java.io.IOException
import org.json.JSONObject

/** Only a completed, empty document query proves absence. */
internal fun safDocumentStatResult(
    hasRow: Boolean?,
    loading: Boolean = false,
    size: Long? = null,
    modified: Long? = null,
    mimeType: String? = null,
    displayName: String? = null,
): JSONObject {
    if (hasRow == null || loading) throw IOException("SAF document metadata is unavailable")
    return JSONObject()
        .put("exists", hasRow)
        .put("size", if (hasRow) size ?: JSONObject.NULL else JSONObject.NULL)
        .put("modified", if (hasRow) modified ?: JSONObject.NULL else JSONObject.NULL)
        .put("mime_type", if (hasRow) mimeType ?: JSONObject.NULL else JSONObject.NULL)
        .put("display_name", if (hasRow) displayName ?: JSONObject.NULL else JSONObject.NULL)
}
