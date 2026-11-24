package com.zarz.mornye

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.json.JSONTokener

private val DOWNLOAD_PROGRESS_STREAM_CHANNEL =
    "com.zarz.mornye/download_progress_stream"
private val LIBRARY_SCAN_PROGRESS_STREAM_CHANNEL =
    "com.zarz.mornye/library_scan_progress_stream"
// A progress bar can't show sub-second granularity; 400ms halves the
// disk-read wakeups during a scan vs the previous 200ms.
private val LIBRARY_SCAN_PROGRESS_STREAM_POLLING_INTERVAL_MS = 400L

private class ProgressStreams(messenger: BinaryMessenger) {
    val messenger = WeakReference(messenger)
    val downloads = ProgressStreamRelay(
        MainActivity::startDownloadProgressStream,
        MainActivity::stopDownloadProgressStream,
    )
    val libraryScans = ProgressStreamRelay(
        MainActivity::startLibraryScanProgressStream,
        MainActivity::stopLibraryScanProgressStream,
    )

    init {
        EventChannel(messenger, DOWNLOAD_PROGRESS_STREAM_CHANNEL)
            .setStreamHandler(downloads)
        EventChannel(messenger, LIBRARY_SCAN_PROGRESS_STREAM_CHANNEL)
            .setStreamHandler(libraryScans)
    }
}

// Registered once per engine. A handler registered again for each Activity
// has no sink for the stream Dart still listens to, so its cancel fails.
private var progressStreams: ProgressStreams? = null

internal fun MainActivity.attachProgressStreams(messenger: BinaryMessenger) {
    val streams = progressStreams?.takeIf { it.messenger.get() === messenger }
        ?: ProgressStreams(messenger).also { progressStreams = it }
    streams.downloads.attach(this)
    streams.libraryScans.attach(this)
}

internal fun MainActivity.detachProgressStreams() {
    val streams = progressStreams
    if (streams == null) {
        stopDownloadProgressStream()
        stopLibraryScanProgressStream()
        return
    }
    streams.downloads.detach(this)
    streams.libraryScans.detach(this)
}

internal fun downloadProgressSequence(payload: String, previous: Long): Long {
    if (payload.isEmpty()) return previous
    val progress = try {
        JSONTokener(payload).nextValue() as? JSONObject ?: return previous
    } catch (_: Exception) {
        return previous
    }
    val seq = (progress.opt("seq") as? Number)?.toLong() ?: previous
    return if (progress.opt("reset") == true || seq > previous) seq else previous
}

private fun MainActivity.startDownloadProgressStream(sink: EventChannel.EventSink) {
    stopDownloadProgressStream()
    downloadProgressEventSink = sink
    lastDownloadProgressPayload = null
    lastDownloadProgressSeq = 0L
    val connection = AtomicReference<CoreDownloadProgress?>(null)
    downloadProgressConnection = connection
    downloadProgressStreamJob = scope.launch {
        try {
            while (isActive && downloadProgressConnection === connection) {
                try {
                    val (payload, sequence) = withContext(Dispatchers.IO) {
                        val reader = connection.get() ?: coreBackend.openDownloadProgress().also { connection.set(it) }
                        ensureActive()
                        val payload = reader.waitDelta(lastDownloadProgressSeq, 15_000L)
                        payload to downloadProgressSequence(payload, lastDownloadProgressSeq)
                    }
                    if (!isActive || downloadProgressConnection !== connection) break
                    if (payload.isNotEmpty() && payload != lastDownloadProgressPayload) {
                        lastDownloadProgressSeq = sequence
                        lastDownloadProgressPayload = payload
                        sink.success(payload)
                        delay(250L)
                    }
                } catch (e: Exception) {
                    connection.getAndSet(null)?.close()
                    if (!isActive || downloadProgressConnection !== connection) break
                    lastDownloadProgressSeq = 0L
                    lastDownloadProgressPayload = null
                    android.util.Log.w(
                        "Mornye",
                        "Download progress stream poll failed: ${e.message}",
                    )
                    delay(250L)
                }
            }
        } finally {
            connection.getAndSet(null)?.close()
        }
    }
}

internal fun MainActivity.stopDownloadProgressStream() {
    downloadProgressStreamJob?.cancel()
    downloadProgressStreamJob = null
    downloadProgressConnection?.getAndSet(null)?.close()
    downloadProgressConnection = null
    downloadProgressEventSink = null
    lastDownloadProgressPayload = null
    lastDownloadProgressSeq = 0L
}

private fun MainActivity.startLibraryScanProgressStream(sink: EventChannel.EventSink) {
    stopLibraryScanProgressStream()
    libraryScanProgressEventSink = sink
    lastLibraryScanProgressPayload = null
    libraryScanProgressStreamJob = scope.launch {
        try {
            val (initialPayload, parsedInitial) = withContext(Dispatchers.IO) {
                val raw = readLibraryScanProgressJsonForStream()
                raw to parseJsonPayload(raw)
            }
            if (!isActive || libraryScanProgressEventSink !== sink) return@launch
            lastLibraryScanProgressPayload = initialPayload
            sink.success(parsedInitial)
        } catch (e: Exception) {
            android.util.Log.w(
                "Mornye",
                "Library scan progress initial poll failed: ${e.message}",
            )
        }
        while (isActive && libraryScanProgressEventSink === sink) {
            try {
                val previous = lastLibraryScanProgressPayload
                val update = withContext(Dispatchers.IO) {
                    val raw = readLibraryScanProgressJsonForStream()
                    if (raw == previous) null else raw to parseJsonPayload(raw)
                }
                if (!isActive || libraryScanProgressEventSink !== sink) break
                if (update != null) {
                    lastLibraryScanProgressPayload = update.first
                    sink.success(update.second)
                }
            } catch (e: Exception) {
                android.util.Log.w(
                    "Mornye",
                    "Library scan progress stream poll failed: ${e.message}",
                )
            }
            delay(LIBRARY_SCAN_PROGRESS_STREAM_POLLING_INTERVAL_MS)
        }
    }
}

internal fun MainActivity.stopLibraryScanProgressStream() {
    libraryScanProgressStreamJob?.cancel()
    libraryScanProgressStreamJob = null
    libraryScanProgressEventSink = null
    lastLibraryScanProgressPayload = null
}
