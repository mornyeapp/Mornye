package com.zarz.mornye

import android.util.AtomicFile
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicReference

/**
 * The compact subset of backend progress needed by the Android worker UI. Keeping
 * this as a Kotlin value avoids sharing mutable JSONObject instances between
 * the polling coroutine and worker coroutines.
 */
internal data class NativeBackendProgress(
    val status: String,
    val bytesReceived: Long,
    val bytesTotal: Long,
    val progress: Double,
)

internal fun DownloadService.writeNativeWorkerSnapshot(
    isRunning: Boolean,
    isPaused: Boolean,
    currentItemId: String,
    message: String,
    lastResult: JSONObject? = null,
    settingsJson: String = "",
    includeItems: Boolean = false,
    progressItemIds: Collection<String>? = null,
    progressCoordinatorEpoch: Long? = null,
    snapshotSerial: Long = snapshotWriteSerial.incrementAndGet()
) {
    try {
        synchronized(snapshotWriteLock) {
            // A stopped/superseded progress coordinator must not publish a
            // newer running snapshot after the queue's terminal snapshot.
            if (
                progressCoordinatorEpoch != null &&
                nativeWorkerProgressEpoch.get() != progressCoordinatorEpoch
            ) {
                return
            }
            if (includeItems) {
                if (snapshotSerial < latestCommittedStateSnapshotSerial) return
            } else {
                if (snapshotSerial < latestCommittedProgressSnapshotSerial) return
            }

            val counts = nativeWorkerCounts()
            val snapshot = JSONObject()
                .put("contract_version", DownloadService.NATIVE_WORKER_CONTRACT_VERSION)
                .put("run_id", nativeWorkerRunId.ifBlank { readNativeWorkerRunIdFromSnapshotFile() })
                .put("is_running", isRunning)
                .put("is_paused", isPaused)
                .put("total", counts.total)
                .put("completed", counts.completed)
                .put("failed", counts.failed)
                .put("skipped", counts.skipped)
                .put("current_item_id", currentItemId)
                .put("message", message)
                .put("updated_at", System.currentTimeMillis())
                .put("snapshot_serial", snapshotSerial)
                .put("state_serial", if (includeItems) snapshotSerial else latestCommittedStateSnapshotSerial)
                .put("snapshot_mode", if (includeItems) "compact_items" else "delta")
            if (includeItems) {
                // The queue index is structural state. Progress deltas carry
                // only the changed item; repeating every ID here made each
                // tick grow linearly with a large queue.
                snapshot.put("item_ids", nativeWorkerItemIds())
            }
            // Snapshot of the header before the per-item payload is
            // attached; served to pollers that already consumed this
            // items payload (see getNativeWorkerSnapshot).
            val headerCandidate = if (includeItems) snapshot.toString() else null
            if (includeItems) {
                snapshot.put("items", nativeWorkerItemsSnapshot(includeStatic = false))
            } else if (progressItemIds != null) {
                snapshot.put(
                    "item_deltas",
                    nativeWorkerItemsSnapshot(progressItemIds, includeStatic = false),
                )
            } else {
                nativeWorkerItemSnapshot(currentItemId, includeStatic = false)?.let {
                    snapshot.put("item_delta", it)
                }
            }
            if (settingsJson.isNotBlank() && includeItems) {
                snapshot.put("settings_json", settingsJson)
            }
            if (lastResult != null) {
                snapshot.put("last_result", lastResult)
            }

            synchronized(DownloadService.NATIVE_WORKER_STATE_FILE_LOCK) {
                val targetFileName = if (includeItems) {
                    DownloadService.NATIVE_WORKER_STATE_FILE
                } else {
                    DownloadService.NATIVE_WORKER_PROGRESS_FILE
                }
                val file = AtomicFile(File(filesDir, targetFileName))
                var stream: java.io.FileOutputStream? = null
                try {
                    stream = file.startWrite()
                    stream.write(snapshot.toString().toByteArray(Charsets.UTF_8))
                    file.finishWrite(stream)
                    stream = null
                    if (includeItems) {
                        latestCommittedStateSnapshotSerial = snapshotSerial
                        if (headerCandidate != null) {
                            DownloadService.lastStateHeaderJson = headerCandidate
                            DownloadService.lastStateHeaderSerial = snapshotSerial
                        }
                    } else {
                        latestCommittedProgressSnapshotSerial = snapshotSerial
                    }
                } finally {
                    if (stream != null) {
                        file.failWrite(stream)
                    }
                }
            }
        }
    } catch (e: Exception) {
        android.util.Log.w("DownloadService", "Failed to write native worker snapshot: ${e.message}")
    }
}

internal fun DownloadService.writeNativeWorkerSnapshotAsync(
    isRunning: Boolean,
    isPaused: Boolean,
    currentItemId: String,
    message: String,
    lastResult: JSONObject? = null,
    settingsJson: String = "",
    includeItems: Boolean = false
) {
    val snapshotSerial = snapshotWriteSerial.incrementAndGet()
    serviceScope.launch {
        writeNativeWorkerSnapshot(
            isRunning = isRunning,
            isPaused = isPaused,
            currentItemId = currentItemId,
            message = message,
            lastResult = lastResult,
            settingsJson = settingsJson,
            includeItems = includeItems,
            snapshotSerial = snapshotSerial
        )
    }
}

internal fun DownloadService.scheduleNativeWorkerItemsSnapshot(
    isRunning: Boolean,
    isPaused: Boolean,
    currentItemId: String,
    message: String,
) {
    pendingNativeItemsSnapshotJob?.cancel()
    pendingNativeItemsSnapshotJob = serviceScope.launch {
        delay(250)
        writeNativeWorkerSnapshot(
            isRunning = isRunning,
            isPaused = isPaused,
            currentItemId = currentItemId,
            message = message,
            includeItems = true,
        )
    }
}

internal fun DownloadService.flushScheduledNativeWorkerItemsSnapshot(
    isRunning: Boolean,
    isPaused: Boolean,
    currentItemId: String,
    message: String,
) {
    pendingNativeItemsSnapshotJob?.cancel()
    pendingNativeItemsSnapshotJob = null
    writeNativeWorkerSnapshotAsync(
        isRunning = isRunning,
        isPaused = isPaused,
        currentItemId = currentItemId,
        message = message,
        includeItems = true,
    )
}

internal fun DownloadService.cancelScheduledNativeWorkerItemsSnapshot() {
    pendingNativeItemsSnapshotJob?.cancel()
    pendingNativeItemsSnapshotJob = null
}

internal fun DownloadService.readNativeWorkerRunIdFromSnapshotFile(): String {
    return try {
        synchronized(DownloadService.NATIVE_WORKER_STATE_FILE_LOCK) {
            val file = File(filesDir, DownloadService.NATIVE_WORKER_STATE_FILE)
            if (!file.exists()) {
                ""
            } else {
                val text = AtomicFile(file).openRead().bufferedReader(Charsets.UTF_8).use {
                    it.readText()
                }
                JSONObject(text).optString("run_id", "")
            }
        }
    } catch (_: Exception) {
        ""
    }
}

internal fun DownloadService.updateNativeWorkerItem(itemId: String, updater: (DownloadService.NativeWorkerItem) -> Unit) {
    synchronized(nativeWorkerItems) {
        nativeWorkerItems.firstOrNull { it.itemId == itemId }?.let(updater)
    }
}

/**
 * Polls the selected backend delta API once for the whole native queue. Workers
 * update their item state from [nativeWorkerProgressItems] instead of making
 * independent full-payload calls. The generation check prevents a delayed
 * native call from an old queue from contaminating a replacement queue.
 */
internal fun DownloadService.startNativeWorkerProgressCoordinator(generation: Long): Job {
    stopNativeWorkerProgressCoordinator()
    val coordinatorEpoch = nativeWorkerProgressEpoch.incrementAndGet()
    synchronized(nativeWorkerProgressLock) {
        nativeWorkerProgressItems.clear()
        nativeWorkerProgressSeq = 0L
    }

    val connection = AtomicReference<CoreDownloadProgress?>(null)
    nativeWorkerProgressConnection = connection
    val job = serviceScope.launch {
        val lastSignatures = mutableMapOf<String, String?>()
        while (isActive && isNativeWorkerProgressActive(generation)) {
            refreshNativeWorkerWakeLock()
            awaitNativeWorkerProgressNeeded(generation)
            if (!isNativeWorkerProgressActive(generation)) break
            val changedItemIds = pollNativeWorkerProgress(generation, connection)
            val snapshotItemIds = mutableListOf<String>()
            for (itemId in changedItemIds) {
                if (!updateNativeWorkerItemProgress(itemId, emitNotification = false)) {
                    continue
                }
                val signature = synchronized(nativeWorkerItems) {
                    nativeWorkerItems.firstOrNull { it.itemId == itemId }?.let {
                        "${it.status}:${it.bytesReceived}:${it.bytesTotal}:${it.progress}"
                    }
                }
                if (signature != null && lastSignatures[itemId] != signature) {
                    lastSignatures[itemId] = signature
                    snapshotItemIds.add(itemId)
                }
            }

            if (snapshotItemIds.isNotEmpty() && isNativeWorkerProgressActive(generation)) {
                // Only the active item is visible in the foreground
                // notification. Apply it once after all cache updates so a
                // concurrent queue never emits one notification per worker.
                val activeItemId = nativeWorkerCurrentItemIdSnapshot()
                if (activeItemId.isNotBlank() && activeItemId in snapshotItemIds) {
                    updateNativeWorkerItemProgress(activeItemId, emitNotification = true)
                }
                val orderedItemIds = snapshotItemIds
                    .filter { it != activeItemId }
                    .let { ids ->
                        if (activeItemId in snapshotItemIds) ids + activeItemId else ids
                    }
                // Commit every changed worker in one AtomicFile write. Writing
                // one item_delta per worker would overwrite the same progress
                // file repeatedly and expose only the last delta to Flutter.
                writeNativeWorkerSnapshot(
                    isRunning = true,
                    isPaused = isNativeWorkerPaused(),
                    currentItemId = activeItemId.ifBlank { orderedItemIds.last() },
                    message = if (isNativeWorkerPaused()) nativeWorkerPauseMessage() else "Downloading",
                    progressItemIds = orderedItemIds,
                    progressCoordinatorEpoch = coordinatorEpoch,
                )
            }
            delay(1000)
        }
    }
    job.invokeOnCompletion { connection.getAndSet(null)?.close() }
    nativeWorkerProgressJob = job
    return job
}

internal fun DownloadService.stopNativeWorkerProgressCoordinator(job: Job? = nativeWorkerProgressJob) {
    if (job == null) return
    if (nativeWorkerProgressJob === job) {
        nativeWorkerProgressJob = null
        nativeWorkerProgressConnection?.getAndSet(null)?.close()
        nativeWorkerProgressConnection = null
        nativeWorkerProgressEpoch.incrementAndGet()
    }
    job.cancel()
}

internal fun DownloadService.cancelNativeWorkerProgressCoordinator() {
    stopNativeWorkerProgressCoordinator()
    synchronized(nativeWorkerProgressLock) {
        nativeWorkerProgressItems.clear()
        nativeWorkerProgressSeq = 0L
    }
}

private fun DownloadService.pollNativeWorkerProgress(
    generation: Long,
    connection: AtomicReference<CoreDownloadProgress?>,
): Set<String> {
    val sinceSeq = synchronized(nativeWorkerProgressLock) { nativeWorkerProgressSeq }
    val raw = try {
        val reader = connection.get() ?: coreBackend.openDownloadProgress().also { connection.set(it) }
        if (nativeWorkerProgressConnection !== connection || !isNativeWorkerProgressActive(generation)) {
            connection.getAndSet(null)?.close()
            return emptySet()
        }
        reader.waitDelta(sinceSeq, 5_000L)
    } catch (_: Exception) {
        connection.getAndSet(null)?.close()
        synchronized(nativeWorkerProgressLock) {
            if (nativeWorkerProgressConnection === connection) {
                nativeWorkerProgressItems.clear()
                nativeWorkerProgressSeq = 0L
            }
        }
        return emptySet()
    }
    if (raw.isBlank() || nativeWorkerProgressConnection !== connection || !isNativeWorkerProgressActive(generation)) return emptySet()

    return try {
        val root = JSONObject(raw)
        val nextSeq = root.optLong("seq", sinceSeq)
        val reset = root.optBoolean("reset", false)
        val updated = mutableMapOf<String, NativeBackendProgress>()
        root.optJSONObject("items")?.let { items ->
            val keys = items.keys()
            while (keys.hasNext()) {
                val itemId = keys.next()
                val item = items.optJSONObject(itemId) ?: continue
                val bytesReceived = item.optLong("bytes_received", 0L).coerceAtLeast(0L)
                val bytesTotal = item.optLong("bytes_total", 0L).coerceAtLeast(0L)
                val progress = item.optDouble("progress", 0.0)
                    .takeUnless { it.isNaN() }
                    ?.coerceIn(0.0, 1.0)
                    ?: 0.0
                updated[itemId] = NativeBackendProgress(
                    status = item.optString("status", "downloading"),
                    bytesReceived = bytesReceived,
                    bytesTotal = bytesTotal,
                    progress = progress,
                )
            }
        }
        val removed = mutableListOf<String>()
        root.optJSONArray("removed")?.let { ids ->
            for (index in 0 until ids.length()) {
                ids.optString(index, "").takeIf { it.isNotBlank() }?.let(removed::add)
            }
        }
        synchronized(nativeWorkerProgressLock) {
            if (nativeWorkerProgressConnection !== connection || !isNativeWorkerProgressActive(generation)) return emptySet()
            if (reset) nativeWorkerProgressItems.clear()
            nativeWorkerProgressItems.putAll(updated)
            removed.forEach { nativeWorkerProgressItems.remove(it) }
            if (reset || nextSeq > nativeWorkerProgressSeq) {
                nativeWorkerProgressSeq = nextSeq
            }
        }
        updated.keys
    } catch (_: Exception) {
        emptySet()
    }
}

internal fun DownloadService.updateNativeWorkerItemProgress(
    itemId: String,
    emitNotification: Boolean = true,
): Boolean {
    return try {
        val progress = synchronized(nativeWorkerProgressLock) {
            nativeWorkerProgressItems[itemId]
        } ?: return false

        val backendStatus = progress.status
        if (backendStatus == "preparing") {
            updateNativeWorkerItem(itemId) {
                it.status = "preparing"
                it.progress = 0.0
                it.bytesReceived = 0L
                it.bytesTotal = 0L
            }
            if (emitNotification) {
                currentStatus = "preparing"
                lastProgress = 0L
                lastTotal = 0L
                updateNotification(0L, 0L)
            }
            return true
        }

        val progressValue = if (progress.bytesTotal > 0L) {
            progress.bytesReceived.toDouble() / progress.bytesTotal.toDouble()
        } else {
            progress.progress
        }.coerceIn(0.0, 1.0)
        val itemStatus = if (backendStatus == "finalizing") "finalizing" else "downloading"
        updateNativeWorkerItem(itemId) {
            it.status = itemStatus
            it.progress = progressValue
            it.bytesReceived = progress.bytesReceived
            it.bytesTotal = progress.bytesTotal
        }
        if (emitNotification) {
            currentStatus = itemStatus
            if (progress.bytesTotal > 0L) {
                lastProgress = progress.bytesReceived
                lastTotal = progress.bytesTotal
            } else if (progressValue > 0.0) {
                lastProgress = (progressValue * DownloadService.NOTIFICATION_PERCENT_TOTAL).toLong()
                    .coerceIn(0L, DownloadService.NOTIFICATION_PERCENT_TOTAL)
                lastTotal = DownloadService.NOTIFICATION_PERCENT_TOTAL
            } else {
                lastProgress = 0L
                lastTotal = 0L
            }
            updateNotification(lastProgress, lastTotal)
        }
        true
    } catch (_: Exception) {
        false
    }
}

internal fun DownloadService.nativeWorkerCounts(): DownloadService.NativeWorkerCounts {
    var total = 0
    var completed = 0
    var failed = 0
    var skipped = 0
    synchronized(nativeWorkerItems) {
        total = nativeWorkerTerminalStatuses.size + nativeWorkerItems.size
        for (status in nativeWorkerTerminalStatuses.values) {
            when (status) {
                "completed" -> completed++
                "failed" -> failed++
                "skipped" -> skipped++
            }
        }
        for (item in nativeWorkerItems) {
            when (item.status) {
                "completed" -> completed++
                "failed" -> failed++
                "skipped" -> skipped++
            }
        }
    }
    return DownloadService.NativeWorkerCounts(
        total = maxOf(queueCount, total),
        completed = completed,
        failed = failed,
        skipped = skipped
    )
}

internal fun DownloadService.nativeWorkerItemSnapshot(itemId: String, includeStatic: Boolean): JSONObject? {
    if (itemId.isBlank()) return null
    synchronized(nativeWorkerItems) {
        val item = nativeWorkerItems.firstOrNull { it.itemId == itemId } ?: return null
        return nativeWorkerItemSnapshotLocked(item, includeStatic)
    }
}

internal fun DownloadService.nativeWorkerItemIds(): JSONArray {
    val array = JSONArray()
    synchronized(nativeWorkerItems) {
        for (item in nativeWorkerItems) {
            array.put(item.itemId)
        }
    }
    return array
}

internal fun DownloadService.nativeWorkerItemsSnapshot(includeStatic: Boolean): JSONArray {
    val array = JSONArray()
    synchronized(nativeWorkerItems) {
        for (item in nativeWorkerItems) {
            array.put(nativeWorkerItemSnapshotLocked(item, includeStatic))
        }
    }
    return array
}

internal fun DownloadService.nativeWorkerItemsSnapshot(
    itemIds: Collection<String>,
    includeStatic: Boolean,
): JSONArray {
    val requested = itemIds.toSet()
    val array = JSONArray()
    synchronized(nativeWorkerItems) {
        for (item in nativeWorkerItems) {
            if (item.itemId in requested) {
                array.put(nativeWorkerItemSnapshotLocked(item, includeStatic))
            }
        }
    }
    return array
}

internal fun DownloadService.nativeWorkerItemSnapshotLocked(item: DownloadService.NativeWorkerItem, includeStatic: Boolean): JSONObject {
    val json = JSONObject()
        .put("item_id", item.itemId)
        .put("status", item.status)
        .put("progress", item.progress)
        .put("bytes_received", item.bytesReceived)
        .put("bytes_total", item.bytesTotal)
    if (includeStatic) {
        json.put("track_name", item.trackName)
            .put("artist_name", item.artistName)
    }
    if (item.error.isNotBlank()) {
        json.put("error", item.error)
    }
    item.resultJson?.let { json.put("result", it) }
    return json
}
