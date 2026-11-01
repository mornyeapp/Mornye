package com.zarz.mornye

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal suspend fun MainActivity.handleDownloadByStrategy(call: MethodCall, result: MethodChannel.Result) {
    val requestJson = call.arguments as String
    val response = withContext(Dispatchers.IO) {
        SafDownloadHandler.handle(this@handleDownloadByStrategy, requestJson, coreBackend)
    }
    result.success(response)
}

internal fun MainActivity.handleStartDownloadService(call: MethodCall, result: MethodChannel.Result) {
    val trackName = call.argument<String>("track_name") ?: ""
    val artistName = call.argument<String>("artist_name") ?: ""
    val queueCount = call.argument<Int>("queue_count") ?: 0
    DownloadService.start(this@handleStartDownloadService, trackName, artistName, queueCount)
    result.success(null)
}

internal fun MainActivity.handleUpdateDownloadServiceProgress(call: MethodCall, result: MethodChannel.Result) {
    val trackName = call.argument<String>("track_name") ?: ""
    val artistName = call.argument<String>("artist_name") ?: ""
    val progress = (call.argument<Number>("progress") ?: 0).toLong()
    val total = (call.argument<Number>("total") ?: 0).toLong()
    val queueCount = (call.argument<Number>("queue_count") ?: 0).toInt()
    val status = call.argument<String>("status") ?: "downloading"
    DownloadService.updateProgress(this@handleUpdateDownloadServiceProgress, trackName, artistName, progress, total, queueCount, status)
    result.success(null)
}

internal fun MainActivity.handleStartBackgroundWork(call: MethodCall, result: MethodChannel.Result) {
    result.success(
        BackgroundWorkService.start(
            this@handleStartBackgroundWork,
            call.argument<String>("kind") ?: "",
            call.argument<String>("title") ?: "",
            call.argument<String>("text") ?: "",
        ),
    )
}

internal fun MainActivity.handleUpdateBackgroundWork(call: MethodCall, result: MethodChannel.Result) {
    BackgroundWorkService.update(
        call.argument<String>("kind") ?: "",
        call.argument<String>("title") ?: "",
        call.argument<String>("text") ?: "",
        call.argument<Int>("progress") ?: -1,
    )
    result.success(null)
}

internal fun MainActivity.handleStartNativeDownloadWorker(call: MethodCall, result: MethodChannel.Result) {
    val requestsJson = call.argument<String>("requests_json") ?: "[]"
    val settingsJson = call.argument<String>("settings_json") ?: "{}"
    val requestsPath = call.argument<String>("requests_path") ?: ""
    val settingsPath = call.argument<String>("settings_path") ?: ""
    if (requestsPath.isNotBlank()) {
        DownloadService.startNativeQueueFromFiles(
            this@handleStartNativeDownloadWorker,
            requestsPath,
            settingsPath
        )
    } else {
        DownloadService.startNativeQueue(this@handleStartNativeDownloadWorker, requestsJson, settingsJson)
    }
    result.success(null)
}

internal fun MainActivity.handleAppendNativeDownloadWorkerRequests(call: MethodCall, result: MethodChannel.Result) {
    val requestsPath = call.argument<String>("requests_path") ?: ""
    val runId = call.argument<String>("run_id") ?: ""
    if (requestsPath.isNotBlank() && runId.isNotBlank()) {
        DownloadService.appendNativeQueueFromFile(
            this@handleAppendNativeDownloadWorkerRequests,
            requestsPath,
            runId,
        )
    }
    result.success(null)
}

internal fun MainActivity.handleFinishNativeDownloadWorkerPreparation(call: MethodCall, result: MethodChannel.Result) {
    val runId = call.argument<String>("run_id") ?: ""
    if (runId.isNotBlank()) {
        DownloadService.finishNativeQueuePreparation(
            this@handleFinishNativeDownloadWorkerPreparation,
            runId,
        )
    }
    result.success(null)
}

internal fun MainActivity.handleAcknowledgeNativeDownloadWorkerItems(call: MethodCall, result: MethodChannel.Result) {
    val runId = call.argument<String>("run_id") ?: ""
    val itemIdsJson = call.argument<String>("item_ids_json") ?: "[]"
    if (runId.isNotBlank()) {
        DownloadService.acknowledgeNativeQueueItems(
            this@handleAcknowledgeNativeDownloadWorkerItems,
            runId,
            itemIdsJson,
        )
    }
    result.success(null)
}

internal suspend fun MainActivity.handleGetNativeDownloadWorkerSnapshot(call: MethodCall, result: MethodChannel.Result) {
    val sinceStateSerial =
        (call.argument<Number>("since_state_serial") ?: 0L).toLong()
    // Keep large snapshots as JSON rather than re-encoding a map on Main.
    val payload = withContext(Dispatchers.IO) {
        DownloadService.getNativeWorkerSnapshot(
            this@handleGetNativeDownloadWorkerSnapshot,
            sinceStateSerial
        )
    }
    result.success(payload)
}
