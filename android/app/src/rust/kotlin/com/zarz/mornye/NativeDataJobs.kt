package com.zarz.mornye

import com.mornye.backend.CancellationDomain
import com.mornye.backend.CancellationRegistry
import com.mornye.backend.RequestLease
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

// Independent of extension initialization: palette/metadata jobs can start
// while app initialization is still running. Acquire before queuing on IO, so
// a following channel cancellation also reaches work that has not started.
internal object NativeDataJobs {
    private val registry = CancellationRegistry(CancellationDomain.EXTENSION_REQUEST)
    private val active = mutableMapOf<String, MutableList<RequestLease>>()

    @Synchronized
    fun acquire(id: String): RequestLease {
        val lease = registry.acquire(id)
        active.getOrPut(id) { mutableListOf() }.add(lease)
        return lease
    }

    @Synchronized
    fun cancel(id: String) {
        // The shared extension registry supports pre-cancel sentinels. Data
        // jobs are acquired in channel order instead and must not retain them.
        if (active[id]?.isNotEmpty() == true) registry.cancel(id)
    }

    @Synchronized
    fun release(id: String, lease: RequestLease) {
        val leases = active[id] ?: return
        val index = leases.indexOfFirst { it === lease }
        if (index < 0) return
        leases.removeAt(index)
        try {
            lease.release()
        } finally {
            try { lease.close() }
            finally { if (leases.isEmpty()) active.remove(id) }
        }
    }
}

internal fun MainActivity.runNativeDataJobPlatform(arguments: Any?, lease: RequestLease): Any {
    val args = arguments as? Map<*, *> ?: error("Missing data job arguments")
    val raw = args["request_json"] as? String ?: error("Missing data job request")
    val bytes = args["bytes"] as? ByteArray ?: byteArrayOf()
    val operation = args["operation"] as? String
    if (operation != null &&
        operation != "library_snapshot" &&
        operation != "library_scan_incremental"
    ) {
        check(!lease.isCancelled()) { "Native data job cancelled" }
        return bridgeJsonResult(com.mornye.backend.runNativeDataJob(raw, bytes, lease))
    }
    val request = JSONObject(raw)
    var spilledDelta: File? = null
    return run {
        fun checkActive() { check(!lease.isCancelled()) { "Native data job cancelled" } }
        try {
            checkActive()
            if (request.optString("operation") == "library_snapshot") {
                // SAF timestamps require ContentResolver, but DB paging and all
                // row mapping stay native. One lease spans every batch.
                val backfilled = JSONObject()
                var cursor = ""
                do {
                    checkActive()
                    val pageRequest = JSONObject(request.toString())
                        .put("operation", "library_snapshot_candidates")
                        .put("cursor", cursor).put("limit", 500)
                    val page = JSONObject(RustCoreBackend.runDataJob(pageRequest, byteArrayOf(), lease))
                    val paths = page.getJSONArray("paths")
                    val uris = JSONArray()
                    for (index in 0 until paths.length()) uris.put(paths.getJSONObject(index).getString("file_path"))
                    val times = JSONObject(getSafFileModTimes(uris.toString()))
                    val keys = times.keys()
                    while (keys.hasNext()) {
                        val path = keys.next()
                        backfilled.put(path, times.getLong(path))
                    }
                    cursor = page.getString("cursor")
                } while (page.getBoolean("has_more"))
                request.put("backfilled_mod_times", backfilled)
            }
            if (request.optString("operation") == "library_scan_incremental" && !request.has("tree_uri")) {
                safScanActive = false
            }
            if (request.optString("operation") == "library_scan_incremental" && request.has("tree_uri")) {
                checkActive()
                val delta = scanSafTreeIncremental(
                    request.getString("tree_uri"),
                    loadExistingFilesFromSnapshot(request.optString("snapshot_path")),
                    cancelled = { lease.isCancelled() },
                )
                val deltaPath = if (delta is String) null else {
                    (delta as? Map<*, *>)?.get("__json_file") as? String
                        ?: error("Invalid SAF scan result")
                }
                // Own a spilled response before checking cancellation, so the
                // finally block also removes a just-completed cancelled scan.
                spilledDelta = deltaPath?.let(::File)
                checkActive()
                request.put("operation", "library_incremental_import")
                if (delta is String) {
                    request.put("delta_json", delta)
                } else {
                    request.put("delta_path", deltaPath)
                }
            }
            bridgeJsonResult(RustCoreBackend.runDataJob(request, bytes, lease))
        } finally {
            spilledDelta?.delete()
        }
    }
}
