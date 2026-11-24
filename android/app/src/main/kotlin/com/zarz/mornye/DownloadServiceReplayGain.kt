package com.zarz.mornye

import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

internal fun DownloadService.writeNativeAlbumReplayGainIfComplete(): Boolean {
    val entries = synchronized(nativeReplayGainEntries) {
        nativeReplayGainEntries.map { JSONObject(it.toString()) }
    }
    if (entries.size <= 1) return true

    val statuses = nativeWorkerStatusesSnapshot()
    val requestKeys = synchronized(nativeReplayGainRequestAlbumKeys) {
        nativeReplayGainRequestAlbumKeys.toMap()
    }
    val eligible = buildEligibleNativeAlbumReplayGain(entries, statuses, requestKeys)
    if (eligible.length() <= 1) {
        return !hasPendingNativeAlbumReplayGainWork(statuses)
    }
    return writeNativeAlbumReplayGainEntries(eligible)
}

internal fun DownloadService.buildEligibleNativeAlbumReplayGain(
    entries: List<JSONObject>,
    statuses: Map<String, String>,
    requestKeys: Map<String, String>
): JSONArray {
    val eligibleIndexes = NativeReplayGainPolicy.eligibleEntryIndexes(
        entryAlbumKeys = entries.map { it.optString("album_key", "") },
        statuses = statuses,
        requestAlbumKeys = requestKeys,
    )
    val eligible = JSONArray()
    for (index in eligibleIndexes) {
        eligible.put(entries[index])
    }
    return eligible
}

internal fun DownloadService.writeNativeAlbumReplayGainEntries(eligible: JSONArray): Boolean {
    if (eligible.length() <= 1) return true
    try {
        val result = JSONObject(NativeDownloadFinalizer.writeAlbumReplayGain(this, eligible.toString()))
        return result.optBoolean("success", false)
    } catch (e: Exception) {
        android.util.Log.w("DownloadService", "Native album ReplayGain failed: ${e.message}")
        return false
    }
}

internal fun DownloadService.hasPendingNativeAlbumReplayGainWork(statuses: Map<String, String>): Boolean {
    return NativeReplayGainPolicy.hasPendingWork(statuses)
}

internal fun DownloadService.writeNativeReplayGainJournal() {
    val requestKeys = synchronized(nativeReplayGainRequestAlbumKeys) {
        nativeReplayGainRequestAlbumKeys.toMap()
    }
    if (requestKeys.isEmpty()) return

    val entries = synchronized(nativeReplayGainEntries) {
        ArrayList(nativeReplayGainEntries)
    }
    val statuses = nativeWorkerStatusesSnapshot()
    synchronized(DownloadService.NATIVE_REPLAYGAIN_JOURNAL_FILE_LOCK) {
        val file = AtomicFile(File(filesDir, DownloadService.NATIVE_REPLAYGAIN_JOURNAL_FILE))
        val existing = cachedReplayGainJournal ?: readNativeReplayGainJournalLocked(file)
        val mergedEntries = mergeNativeReplayGainJournalEntries(
            existing?.optJSONArray("entries"),
            entries,
        )
        val mergedRequestKeys = mergeJsonObjectStringMap(
            existing?.optJSONObject("request_album_keys"),
            requestKeys,
        )
        val mergedStatuses = mergeJsonObjectStringMap(
            existing?.optJSONObject("statuses"),
            statuses,
        )
        val root = JSONObject()
            .put("run_id", nativeWorkerRunId)
            .put("updated_at", System.currentTimeMillis())
            .put("entries", mergedEntries)
            .put("request_album_keys", JSONObject(mergedRequestKeys))
            .put("statuses", JSONObject(mergedStatuses))
        cachedReplayGainJournal = root

        var stream: java.io.FileOutputStream? = null
        try {
            stream = file.startWrite()
            stream.write(root.toString().toByteArray(Charsets.UTF_8))
            file.finishWrite(stream)
            stream = null
        } catch (e: Exception) {
            android.util.Log.w("DownloadService", "Failed to write native ReplayGain journal: ${e.message}")
        } finally {
            if (stream != null) {
                file.failWrite(stream)
            }
        }
    }
}

internal fun DownloadService.nativeWorkerStatusesSnapshot(): Map<String, String> {
    return synchronized(nativeWorkerItems) {
        val statuses = nativeWorkerTerminalStatuses.toMutableMap()
        for (item in nativeWorkerItems) {
            statuses[item.itemId] = item.status
        }
        statuses
    }
}

internal fun DownloadService.readNativeReplayGainJournalLocked(file: AtomicFile): JSONObject? {
    return try {
        if (!file.baseFile.exists()) return null
        val text = file.openRead().bufferedReader(Charsets.UTF_8).use {
            it.readText()
        }
        JSONObject(text)
    } catch (e: Exception) {
        android.util.Log.w("DownloadService", "Failed to merge native ReplayGain journal: ${e.message}")
        null
    }
}

internal fun DownloadService.mergeNativeReplayGainJournalEntries(
    existingEntries: JSONArray?,
    currentEntries: List<JSONObject>
): JSONArray {
    val byKey = linkedMapOf<String, JSONObject>()

    fun add(entry: JSONObject) {
        val trackId = entry.optString("track_id", "")
        val path = entry.optString("file_path", "")
        val key = if (trackId.isNotBlank()) {
            "track:$trackId"
        } else {
            "path:$path"
        }
        if (key != "path:") {
            byKey[key] = entry
        }
    }

    if (existingEntries != null) {
        for (index in 0 until existingEntries.length()) {
            existingEntries.optJSONObject(index)?.let(::add)
        }
    }
    for (entry in currentEntries) add(entry)

    return JSONArray().apply {
        for (entry in byKey.values) put(entry)
    }
}

internal fun DownloadService.mergeJsonObjectStringMap(
    existing: JSONObject?,
    current: Map<String, String>
): Map<String, String> {
    val merged = linkedMapOf<String, String>()
    if (existing != null) {
        for (key in existing.keys()) {
            merged[key] = existing.optString(key, "")
        }
    }
    for ((key, value) in current) {
        merged[key] = value
    }
    return merged
}

internal fun DownloadService.clearNativeReplayGainJournal() {
    synchronized(DownloadService.NATIVE_REPLAYGAIN_JOURNAL_FILE_LOCK) {
        cachedReplayGainJournal = null
        try {
            AtomicFile(File(filesDir, DownloadService.NATIVE_REPLAYGAIN_JOURNAL_FILE)).delete()
        } catch (_: Exception) {
        }
    }
}

internal fun DownloadService.flushNativeAlbumReplayGainJournalIfComplete() {
    val root = synchronized(DownloadService.NATIVE_REPLAYGAIN_JOURNAL_FILE_LOCK) {
        cachedReplayGainJournal ?: try {
            val file = File(filesDir, DownloadService.NATIVE_REPLAYGAIN_JOURNAL_FILE)
            if (!file.exists()) return
            val text = AtomicFile(file).openRead().bufferedReader(Charsets.UTF_8).use {
                it.readText()
            }
            JSONObject(text).also { cachedReplayGainJournal = it }
        } catch (e: Exception) {
            android.util.Log.w("DownloadService", "Failed to read native ReplayGain journal: ${e.message}")
            return
        }
    }

    val entriesArray = root.optJSONArray("entries") ?: return
    val entries = mutableListOf<JSONObject>()
    for (index in 0 until entriesArray.length()) {
        entriesArray.optJSONObject(index)?.let { entries.add(JSONObject(it.toString())) }
    }
    val statusesJson = root.optJSONObject("statuses") ?: JSONObject()
    val statuses = mutableMapOf<String, String>()
    for (key in statusesJson.keys()) {
        statuses[key] = statusesJson.optString(key, "")
    }
    val requestKeysJson = root.optJSONObject("request_album_keys") ?: JSONObject()
    val requestKeys = mutableMapOf<String, String>()
    for (key in requestKeysJson.keys()) {
        requestKeys[key] = requestKeysJson.optString(key, "")
    }

    val eligible = buildEligibleNativeAlbumReplayGain(entries, statuses, requestKeys)
    if (eligible.length() <= 1 && hasPendingNativeAlbumReplayGainWork(statuses)) {
        return
    }
    if (writeNativeAlbumReplayGainEntries(eligible)) {
        clearNativeReplayGainJournal()
    }
}
