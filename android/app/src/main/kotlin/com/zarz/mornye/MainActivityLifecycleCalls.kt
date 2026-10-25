package com.zarz.mornye

import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal fun MainActivity.handleSetScreenAwake(call: MethodCall, result: MethodChannel.Result) {
    val flag = android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
    if (call.argument<Boolean>("enabled") == true) {
        window.addFlags(flag)
    } else {
        window.clearFlags(flag)
    }
    result.success(null)
}

/** Whether the device is on external power, from the sticky battery broadcast. */
internal fun MainActivity.handleIsCharging(call: MethodCall, result: MethodChannel.Result) {
    val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    result.success((battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0)
}

internal fun MainActivity.handleConsumeVerificationNotification(call: MethodCall, result: MethodChannel.Result) {
    val payload = pendingVerificationNotification
    pendingVerificationNotification = null
    result.success(payload)
}

internal suspend fun MainActivity.handleEnsureInstallMarker(call: MethodCall, result: MethodChannel.Result) {
    val installState = withContext(Dispatchers.IO) {
        ensureInstallMarker()
    }
    result.success(installState)
}

/**
 * [selectedBackend] is the backend configureFlutterEngine selected before
 * registering the channel; the call writes the runtime state into it.
 */
internal suspend fun MainActivity.handlePrepareRuntimeState(
    call: MethodCall,
    result: MethodChannel.Result,
    selectedBackend: CoreBackend,
) {
    val dataDir = call.argument<String>("data_dir") ?: ""
    val runtimeState = withContext(Dispatchers.IO) {
        require(dataDir.isNotBlank()) {
            "Extension data directory is required"
        }
        val payload = prepareRuntimeState(dataDir)
        selectedBackend.setRuntimeState(dataDir, payload)
        mapOf("ready" to true)
    }
    result.success(runtimeState)
}

internal fun MainActivity.handleExitApp(call: MethodCall, result: MethodChannel.Result) {
    flutterBackCallback?.isEnabled = false
    finishAndRemoveTask()
    result.success(null)
}

internal fun MainActivity.handleGetBackendImplementations(call: MethodCall, result: MethodChannel.Result) {
    result.success(
        mapOf(
            "filename" to coreBackend.implementation,
            "file_metadata" to coreBackend.fileMetadataImplementation(call.argument<String>("file_path") ?: ""),
            "extensions" to coreBackend.implementation,
            "downloads" to coreBackend.implementation,
        )
    )
}

internal suspend fun MainActivity.handleReleaseMemory(call: MethodCall, result: MethodChannel.Result) {
    withContext(Dispatchers.IO) {
        coreBackend.releaseIdleResources()
    }
    result.success(null)
}

internal suspend fun MainActivity.handleReleaseMemoryUnderPressure(call: MethodCall, result: MethodChannel.Result) {
    withContext(Dispatchers.IO) {
        coreBackend.releaseMemoryUnderPressure()
    }
    android.util.Log.d("Mornye", "Backend memory pressure release completed")
    result.success(null)
}
