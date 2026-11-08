package com.zarz.mornye

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.Spatializer
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.EventChannel

/**
 * `com.zarz.mornye/spatial_audio`: the spatializer facts of
 * [AudioRouteInfo.spatializer] on listen, then again whenever the
 * spatializer's state or head tracker changes (Android 12L and 13 listeners)
 * or an output device comes or goes. Read-only; main thread only.
 */
internal class SpatialAudioEvents(context: Context) : EventChannel.StreamHandler {
    private val appContext = context.applicationContext
    private val manager = appContext.getSystemService(AudioManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var listeners: Any? = null

    private val emitNow = Runnable { emit() }

    private val devices = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) = routeChanged()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) = routeChanged()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (Build.VERSION.SDK_INT >= 32 && listeners == null) {
            listeners = SpatializerListeners(manager.spatializer, appContext) { emit() }
        }
        // It also reports the devices already present, a harmless re-read.
        manager.registerAudioDeviceCallback(devices, main)
        emit()
    }

    override fun onCancel(arguments: Any?) {
        manager.unregisterAudioDeviceCallback(devices)
        if (Build.VERSION.SDK_INT >= 32) (listeners as? SpatializerListeners)?.remove()
        listeners = null
        main.removeCallbacks(emitNow)
        sink = null
    }

    /** The spatializer may follow a new route a moment later; read twice. */
    private fun routeChanged() {
        emit()
        main.removeCallbacks(emitNow)
        main.postDelayed(emitNow, ROUTE_SETTLE_MS)
    }

    private fun emit() {
        val events = sink ?: return
        val spatializer = runCatching { AudioRouteInfo.spatializer(manager) }.getOrNull()
        events.success(mapOf("platform" to "android", "sdk" to Build.VERSION.SDK_INT, "spatializer" to spatializer))
    }

    @RequiresApi(32)
    private class SpatializerListeners(
        private val spatializer: Spatializer,
        context: Context,
        changed: () -> Unit,
    ) {
        private val state = object : Spatializer.OnSpatializerStateChangedListener {
            override fun onSpatializerEnabledChanged(spatializer: Spatializer, enabled: Boolean) = changed()
            override fun onSpatializerAvailableChanged(spatializer: Spatializer, available: Boolean) = changed()
        }
        private val headTracker: Any? = if (Build.VERSION.SDK_INT >= 33) {
            Spatializer.OnHeadTrackerAvailableListener { _, _ -> changed() }
        } else {
            null
        }

        init {
            val executor = context.mainExecutor
            spatializer.addOnSpatializerStateChangedListener(executor, state)
            if (Build.VERSION.SDK_INT >= 33) {
                spatializer.addOnHeadTrackerAvailableListener(
                    executor,
                    headTracker as Spatializer.OnHeadTrackerAvailableListener,
                )
            }
        }

        fun remove() {
            spatializer.removeOnSpatializerStateChangedListener(state)
            if (Build.VERSION.SDK_INT >= 33) {
                spatializer.removeOnHeadTrackerAvailableListener(
                    headTracker as Spatializer.OnHeadTrackerAvailableListener,
                )
            }
        }
    }

    private companion object {
        const val ROUTE_SETTLE_MS = 750L
    }
}
