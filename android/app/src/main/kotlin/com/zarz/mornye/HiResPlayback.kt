package com.zarz.mornye

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import io.flutter.plugin.common.MethodCall
import java.nio.ByteBuffer

/** Exact-rate PCM via Oboe's AAudio backend. DSD never enters a PCM stream. */
internal class HiResPlayback(context: Context, private val emit: (Map<String, Any>) -> Unit) {
    private val manager = context.getSystemService(AudioManager::class.java)
    private val thread = HandlerThread("Mornye-AAudio", android.os.Process.THREAD_PRIORITY_AUDIO).apply { start() }
    private val worker = Handler(thread.looper)
    private val wakeLock = context.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Mornye:AAudio")
    @Volatile private var revision = 0
    private var source: UsbPcmSource? = null
    private var output = 0L
    private var device = 0
    private var bits = 0
    private var token = 0
    private var pending: ByteBuffer? = null
    private var playing = false
    private var failed = false
    private var needsSeek = false
    private var baseUs = 0L
    private var pausedUs = 0L
    private var writtenFrames = 0L
    private val route = object : AudioDeviceCallback() {
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) {
            if (output != 0L && removed.any { it.id == device }) fail("AAudio device disconnected")
        }
    }
    init { manager.registerAudioDeviceCallback(route, worker) }

    fun command(call: MethodCall, done: (Any?, String?) -> Unit) {
        if (call.method == "prepare" || call.method == "stop") revision++
        val expected = revision
        worker.post {
            try {
                val result: Any? = when (call.method) {
                    "prepare" -> prepare(call, expected)
                    "resume" -> { resume(); null }
                    "pause" -> { pause(); null }
                    "seek" -> {
                        val wasPlaying = playing
                        pause()
                        pausedUs = ((call.argument<Number>("position")?.toLong() ?: 0) * 1000)
                            .coerceIn(0, source?.durationUs ?: 0)
                        if (wasPlaying) resume()
                        null
                    }
                    "position" -> positionUs() / 1000
                    "status" -> mapOf("token" to token, "reason" to when {
                        failed -> "route_changed"
                        output == 0L -> "idle"
                        playing -> "active"
                        else -> "ready"
                    })
                    "stop" -> { close(); null }
                    else -> error("Unknown hi-res command")
                }
                done(result, null)
            } catch (error: Exception) { done(null, error.message ?: "AAudio output failed") }
        }
    }

    private fun prepare(call: MethodCall, expected: Int): Map<String, Any> {
        close()
        if (expected != revision) return mapOf("reason" to "cancelled")
        if (Build.VERSION.SDK_INT < 27) return mapOf("reason" to "exclusive_unavailable")
        token = call.argument<Int>("token") ?: 0
        var isDsd = call.argument<Boolean>("requiresDsd") == true
        var failureReason = "format"
        try {
            val path = requireNotNull(call.argument<String>("path"))
            isDsd = isDsd || DsdSource.isDsd(path)
            if (!isDsd) DsdSource.open(path)?.use { isDsd = true }
            if (isDsd) return mapOf("reason" to "dsd_unsupported", "fatal" to true)
            val pcm = UsbPcmSource(path).also { source = it }
            val devices = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            val wired = devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES || it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET }
            failureReason = "exclusive_unavailable"
            output = NativeAudio.openOboe(pcm.rate, pcm.channels, pcm.bits, wired?.id ?: 0)
            bits = NativeAudio.bitsOboe(output)
            device = NativeAudio.deviceOboe(output)
            failureReason = "format"
            val deadline = android.os.SystemClock.elapsedRealtime() + 5000
            while (pending == null && !pcm.ended) {
                require(expected == revision) { "AAudio prepare cancelled" }
                require(android.os.SystemClock.elapsedRealtime() < deadline) { "Decoder timed out" }
                pending = pcm.read(bits)
                if (pending == null) Thread.sleep(2)
            }
            if (expected != revision) { close(); return mapOf("reason" to "cancelled") }
            return mapOf("ready" to true, "driver" to "aaudio_exclusive", "transport" to "pcm",
                "sampleRate" to pcm.rate, "bitDepth" to bits, "sourceBitDepth" to pcm.bits,
                "duration" to pcm.durationUs / 1000,
                "device" to (devices.firstOrNull { it.id == device }?.productName?.toString() ?: "AAudio"))
        } catch (error: Exception) {
            close()
            if (expected != revision) return mapOf("reason" to "cancelled")
            val reason = if (isDsd) "dsd_unsupported" else failureReason
            val detail = error.message.orEmpty().take(3000)
            android.util.Log.i("HiResPlayback", "$reason: $detail")
            return mapOf("reason" to reason, "fatal" to isDsd, "detail" to detail)
        }
    }

    private fun fill() {
        val pcm = requireNotNull(source)
        repeat(8) {
            if (pending == null) pending = pcm.read(bits)
            val data = pending ?: return
            val frame = pcm.channels * (bits / 8)
            val remaining = minOf(data.remaining(), 65536) / frame * frame
            val count = NativeAudio.writeOboe(output, data, data.position(), remaining)
            data.position(data.position() + count)
            writtenFrames += count / (pcm.channels * (bits / 8))
            if (data.hasRemaining()) return
            pending = null
        }
    }
    private fun resume() {
        check(!failed && output != 0L) { "AAudio route changed; reopen track" }
        if (needsSeek) {
            source?.seek(pausedUs)
            baseUs = pausedUs
            pending = null
            writtenFrames = 0
            needsSeek = false
        }
        fill()
        NativeAudio.startOboe(output)
        playing = true
        if (!wakeLock.isHeld) wakeLock.acquire()
        emit(mapOf("token" to token, "event" to "active"))
        worker.removeCallbacks(pump)
        worker.post(pump)
    }
    private fun positionUs(): Long {
        if (needsSeek || output == 0L) return pausedUs
        val pcm = source ?: return pausedUs
        pausedUs = (baseUs + NativeAudio.framesOboe(output) * 1000000 / pcm.rate).coerceAtMost(pcm.durationUs)
        return pausedUs
    }
    private fun pause() {
        if (!needsSeek) pausedUs = runCatching { positionUs() }.getOrDefault(pausedUs)
        playing = false
        worker.removeCallbacks(pump)
        if (wakeLock.isHeld) wakeLock.release()
        if (output != 0L && !needsSeek) NativeAudio.flushOboe(output)
        needsSeek = true
    }
    private val pump = object : Runnable {
        override fun run() {
            if (!playing) return
            try {
                fill()
                val pcm = requireNotNull(source)
                if (pcm.ended && pending == null && NativeAudio.framesOboe(output) >= writtenFrames) {
                    pause()
                    emit(mapOf("token" to token, "event" to "complete"))
                } else worker.postDelayed(this, 5)
            } catch (error: Exception) { fail(error.message ?: "AAudio error") }
        }
    }
    private fun fail(reason: String) {
        android.util.Log.w("HiResPlayback", reason)
        runCatching { pause() }
        failed = true
        if (output != 0L) NativeAudio.closeOboe(output)
        output = 0
        emit(mapOf("token" to token, "event" to "paused", "reason" to "route_changed"))
    }
    private fun close() {
        runCatching { pause() }
        if (output != 0L) NativeAudio.closeOboe(output)
        output = 0
        source?.close()
        source = null
        pending = null
        failed = false
        needsSeek = false
        baseUs = 0
        pausedUs = 0
        writtenFrames = 0
    }
    fun dispose() {
        revision++
        manager.unregisterAudioDeviceCallback(route)
        worker.post { close(); thread.quitSafely() }
    }
}
