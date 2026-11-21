package com.zarz.mornye

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

internal suspend fun MainActivity.handleSetLibraryCoverCacheDir(call: MethodCall, result: MethodChannel.Result) {
    val cacheDir = call.argument<String>("cache_dir") ?: ""
    withContext(Dispatchers.IO) {
        coreBackend.setLibraryCoverCacheDirectory(cacheDir)
    }
    result.success(null)
}

internal suspend fun MainActivity.handleScanLibraryFolderToNDJSONFile(call: MethodCall, result: MethodChannel.Result) {
    val folderPath = call.argument<String>("folder_path") ?: ""
    val outputPath = call.argument<String>("output_path") ?: ""
    val response = withContext(Dispatchers.IO) {
        safScanActive = false
        val count = coreBackend.scanLibraryFolderToNdjsonFile(
            folderPath,
            outputPath,
        )
        mapOf(
            "path" to outputPath,
            "count" to count,
            "error_count" to JSONObject(coreBackend.getLibraryScanProgress())
                .getInt("error_count"),
        )
    }
    result.success(response)
}

internal suspend fun MainActivity.handleScanLibraryFolderIncremental(call: MethodCall, result: MethodChannel.Result) {
    val folderPath = call.argument<String>("folder_path") ?: ""
    val existingFiles = call.argument<String>("existing_files") ?: "{}"
    val response = withContext(Dispatchers.IO) {
        safScanActive = false
        bridgeJsonResult(
            coreBackend.scanLibraryFolderIncremental(folderPath, existingFiles)
        )
    }
    result.success(response)
}

internal suspend fun MainActivity.handleScanSafTreeToNDJSONFile(call: MethodCall, result: MethodChannel.Result) {
    val treeUri = call.argument<String>("tree_uri") ?: ""
    val outputPath = call.argument<String>("output_path") ?: ""
    val response = withContext(Dispatchers.IO) {
        scanSafTree(treeUri, outputPath)
    }
    result.success(response)
}

internal suspend fun MainActivity.handleScanSafTreeIncremental(call: MethodCall, result: MethodChannel.Result) {
    val treeUri = call.argument<String>("tree_uri") ?: ""
    val existingFiles = call.argument<String>("existing_files") ?: "{}"
    val response = withContext(Dispatchers.IO) {
        scanSafTreeIncremental(treeUri, existingFiles)
    }
    result.success(response)
}

internal suspend fun MainActivity.handleGetLibraryScanProgress(call: MethodCall, result: MethodChannel.Result) {
    val parsed = withContext(Dispatchers.IO) {
        val response = if (safScanActive) {
            safProgressToJson()
        } else {
            coreBackend.getLibraryScanProgress()
        }
        parseJsonPayload(response)
    }
    result.success(parsed)
}

internal suspend fun MainActivity.handleGetLibraryScanExitInfo(call: MethodCall, result: MethodChannel.Result) {
    val startedAfter = call.argument<Number>("started_after")?.toLong() ?: 0L
    val response = withContext(Dispatchers.IO) {
        LibraryScanExitInfo.read(applicationContext, startedAfter)
    }
    result.success(response)
}

internal suspend fun MainActivity.handleCancelLibraryScan(call: MethodCall, result: MethodChannel.Result) {
    withContext(Dispatchers.IO) {
        safScanCancel = true
        safScanPaused = false
        coreBackend.cancelLibraryScan()
    }
    result.success(null)
}

internal suspend fun MainActivity.handlePauseLibraryScan(call: MethodCall, result: MethodChannel.Result) {
    withContext(Dispatchers.IO) {
        safScanPaused = true
        coreBackend.pauseLibraryScan()
    }
    result.success(null)
}

internal suspend fun MainActivity.handleResumeLibraryScan(call: MethodCall, result: MethodChannel.Result) {
    withContext(Dispatchers.IO) {
        safScanPaused = false
        coreBackend.resumeLibraryScan()
    }
    result.success(null)
}
