package com.zarz.mornye

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Registers what playback needs on the shared engine before Dart starts,
 * whichever component creates it. A media browser such as Android Auto
 * starts the engine through AudioService without an Activity, and the app
 * then browses, searches and plays the Library until one attaches.
 */
internal object SharedEngineChannels {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    fun configure(context: Context, engine: FlutterEngine) {
        engine.plugins.add(LocalNetworkPlugin())
        engine.plugins.add(UsbBitPerfectPlugin())
        engine.plugins.add(MusicHapticsPlugin())
        PlayerWidgetBridge.attach(context, engine)
        registerPlaybackBackend(context, MethodChannel(engine.dartExecutor.binaryMessenger, BACKEND_CHANNEL))
    }

    /**
     * The backend methods playback calls. MainActivity replaces this handler
     * with the whole backend channel when it attaches; until then the other
     * methods are not implemented.
     */
    private fun registerPlaybackBackend(context: Context, channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            scope.launch {
                try {
                    when (call.method) {
                        "safExists" -> context.handleSafExists(call, result)
                        "safExistsBatch" -> context.handleSafExistsBatch(call, result)
                        "safOpenPlaybackLease" -> context.handleSafOpenPlaybackLease(call, result)
                        "safClosePlaybackLease" -> handleSafClosePlaybackLease(call, result)
                        "readFileMetadata" -> context.handleReadFileMetadata(call, result, createCoreBackend(context))
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error(ForegroundServiceStartPolicy.errorCode(e), e.message, null)
                }
            }
        }
    }

    private const val BACKEND_CHANNEL = "com.zarz.mornye/backend"
}
