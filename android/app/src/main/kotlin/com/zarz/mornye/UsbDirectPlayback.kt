package com.zarz.mornye

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import com.mornye.backend.UsbDirectOutput
import com.mornye.backend.UsbOutputFormat
import com.mornye.backend.UsbHardwareVolume
import io.flutter.plugin.common.MethodCall
import java.nio.ByteBuffer
import kotlin.math.pow

/** Android owns permission/connection; the Rust worker owns isochronous I/O. */
internal class UsbDirectPlayback(private val context: Context, private val emit: (Map<String, Any>) -> Unit) {
    private val manager = context.getSystemService(UsbManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val thread = HandlerThread("Mornye-USB-source", android.os.Process.THREAD_PRIORITY_AUDIO).apply { start() }
    private val worker = Handler(thread.looper)
    private val wakeLock = context.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Mornye:UsbDirect")
    private val permissionAction = "${context.packageName}.USB_AUDIO_PERMISSION"
    private data class Permission(val device: UsbDevice, val call: MethodCall, val revision: Int, val done: (Any?, String?) -> Unit)
    private var permission: Permission? = null
    @Volatile private var revision = 0
    private var output: UsbDirectOutput? = null
    private var connection: UsbDeviceConnection? = null
    @Volatile private var deviceId: Int? = null
    private var format: UsbOutputFormat? = null
    private var pcm: UsbPcmSource? = null
    private var dsd: DsdSource? = null
    private var isDsd = false
    private var pending: ByteBuffer? = null
    private var writeBuffer = ByteArray(0)
    private var playing = false
    private var ended = false
    private var failed = false
    private var token = 0
    private var baseUs = 0L
    private var durationUs = 0L
    private var writtenFrames = 0L
    private var pausedPositionUs = 0L
    private var needsSeek = false
    private var allowFixedVolume = false
    private var forceSoftwareVolume = false
    private var currentSoftwareDb = 0.0
    private var softwareGain = 1.0f
    private val deviceVolumes = mutableMapOf<Int, Double>()
    private val deviceSoftwareVolumes = mutableMapOf<Int, Double>()

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            @Suppress("DEPRECATION")
            val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE) ?: return
            if (intent.action == UsbManager.ACTION_USB_DEVICE_DETACHED) {
                worker.post {
                    deviceVolumes.remove(device.deviceId)
                    deviceSoftwareVolumes.remove(device.deviceId)
                    if (device.deviceId == deviceId) fail("USB disconnected")
                }
            } else if (intent.action == permissionAction) {
                val request = permission ?: return
                if (request.device.deviceId != device.deviceId) return
                if (intent.getIntExtra("revision", -1) != request.revision) return
                permission = null
                if (request.revision != revision) { request.done(mapOf("reason" to "cancelled"), null); return }
                if (manager.hasPermission(device)) prepare(request)
                else request.done(mapOf("reason" to "permission_denied"), null)
            }
        }
    }

    init {
        val filter = IntentFilter(permissionAction).apply { addAction(UsbManager.ACTION_USB_DEVICE_DETACHED) }
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else { @Suppress("DEPRECATION") context.registerReceiver(receiver, filter) }
    }

    fun command(call: MethodCall, done: (Any?, String?) -> Unit) {
        if (call.method == "prepare" || call.method == "stop") {
            revision++
            permission?.done?.invoke(mapOf("reason" to "cancelled"), null)
            permission = null
        }
        if (call.method == "prepare") {
            worker.post { closeSource() }
            val device = manager.deviceList.values.sortedBy { it.deviceId }.firstOrNull { candidate ->
                (0 until candidate.interfaceCount).any {
                    candidate.getInterface(it).interfaceClass == 1 && candidate.getInterface(it).interfaceSubclass == 2
                }
            }
            if (device == null) {
                worker.post { done(mapOf("reason" to "no_usb"), null) }
                return
            }
            val request = Permission(device, call, revision, done)
            if (manager.hasPermission(device)) prepare(request)
            else {
                permission = request
                val flags = PendingIntent.FLAG_CANCEL_CURRENT or if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                val intent = PendingIntent.getBroadcast(context, revision, Intent(permissionAction).setPackage(context.packageName).putExtra("revision", revision), flags)
                try { manager.requestPermission(device, intent) }
                catch (error: Exception) { permission = null; done(mapOf("reason" to "permission_denied"), null) }
                main.postDelayed({
                    if (permission === request) { permission = null; done(mapOf("reason" to "permission_denied"), null) }
                }, 60000)
            }
            return
        }
        worker.post {
            try {
                val value: Any? = when (call.method) {
                    "resume" -> { resume(); null }
                    "pause" -> { pause(); null }
                    "seek" -> { seek((call.argument<Number>("position")?.toLong() ?: 0) * 1000); null }
                    "position" -> positionUs() / 1000
                    "volume" -> {
                        require(call.argument<Int>("token") == token) { "Stale volume request" }
                        val audio = requireNotNull(output)
                        val db = call.argument<Number>("db")?.toDouble()
                        if (forceSoftwareVolume) {
                            if (db != null) {
                                currentSoftwareDb = db.coerceIn(-62.0, 0.0)
                                updateSoftwareGain()
                                deviceId?.let { deviceSoftwareVolumes[it] = currentSoftwareDb }
                            }
                            volumeMap(audio.volume())
                        } else {
                            val value = if (db == null) audio.volume() else audio.setVolume(db)
                            if (db != null && value.available) deviceId?.let { deviceVolumes[it] = value.currentDb }
                            volumeMap(value)
                        }
                    }
                    "stop" -> { closeSource(); null }
                    else -> error("Unknown USB command")
                }
                done(value, null)
            } catch (error: Exception) { done(null, error.message ?: "USB output failed") }
        }
    }

    private fun prepare(request: Permission) {
        worker.post {
            isDsd = false
            try {
                if (request.revision != revision) { request.done(mapOf("reason" to "cancelled"), null); return@post }
                closeSource()
                token = request.call.argument<Int>("token") ?: 0
                allowFixedVolume = request.call.argument<Boolean>("allowFixedVolume") == true
                forceSoftwareVolume = request.call.argument<Boolean>("forceSoftwareVolume") == true
                val path = requireNotNull(request.call.argument<String>("path"))
                isDsd = DsdSource.isDsd(path)
                dsd = DsdSource.open(path)
                isDsd = isDsd || dsd != null
                if (isDsd) requireNotNull(dsd) { "DSD decoder unavailable" }
                if (forceSoftwareVolume && isDsd) {
                    android.util.Log.w("UsbDirect", "Software volume is not supported for native DSD")
                    closeSource()
                    request.done(mapOf("reason" to "dsd_software_volume", "fatal" to true), null)
                    return@post
                }
                if (!isDsd) pcm = UsbPcmSource(path)
                val rate = dsd?.rate ?: requireNotNull(pcm).rate
                val channels = dsd?.channels ?: requireNotNull(pcm).channels
                val bits = if (isDsd) 1 else requireNotNull(pcm).bits
                durationUs = dsd?.durationUs ?: requireNotNull(pcm).durationUs
                val usb = manager.openDevice(request.device) ?: error("Cannot open USB device")
                connection = usb
                deviceId = request.device.deviceId
                val audio = UsbDirectOutput.open(usb.fileDescriptor, usb.rawDescriptors, rate.toUInt(), channels.toUByte(), bits.toUByte(), isDsd, request.call.argument<Boolean>("allowDop") == true)
                output = audio
                format = audio.format()
                if (forceSoftwareVolume && audio.volume().available) {
                    runCatching { audio.setVolume(0.0) }
                } else if (audio.volume().available) {
                    deviceVolumes[request.device.deviceId]?.let {
                        audio.setVolume(minOf(it, audio.volume().restoreLimitDb))
                    }
                }
                if (forceSoftwareVolume) {
                    currentSoftwareDb = deviceId?.let { deviceSoftwareVolumes[it] } ?: 0.0
                    updateSoftwareGain()
                }
                if (request.revision != revision) { closeSource(); request.done(mapOf("reason" to "cancelled"), null); return@post }
                val deadline = android.os.SystemClock.elapsedRealtime() + 5000
                while (pending == null && !ended) {
                    require(request.revision == revision) { "USB prepare cancelled" }
                    require(android.os.SystemClock.elapsedRealtime() < deadline) { "Decoder timed out" }
                    decode()
                    if (pending == null) Thread.sleep(2)
                }
                val f = requireNotNull(format)
                request.done(mapOf("ready" to true, "device" to (request.device.productName ?: "USB audio"),
                    "sampleRate" to rate, "bitDepth" to f.bits.toInt(), "sourceBitDepth" to bits,
                    "duration" to durationUs / 1000,
                    "transport" to f.encoding, "carrierRate" to f.sampleRate.toLong(), "driver" to "usb_direct",
                    "volume" to volumeMap(audio.volume()),
                    "volumeBlocked" to (!audio.volume().available && !allowFixedVolume && !forceSoftwareVolume)), null)
            } catch (error: Exception) {
                android.util.Log.i("UsbDirect", "Direct output unavailable: ${error.message}")
                closeSource()
                request.done(mapOf("reason" to if (isDsd) "dsd_unsupported" else "unsupported", "fatal" to isDsd), null)
            }
        }
    }

    private fun decode() {
        if (pending != null || ended) return
        val f = requireNotNull(format)
        val dsdFile = dsd
        if (dsdFile != null) {
            val data = dsdFile.readFrames(f.encoding, f.subslot.toInt())
            if (data == null) ended = true else pending = ByteBuffer.wrap(data)
        } else {
            pending = requireNotNull(pcm).read(f.subslot.toInt() * 8)
            ended = requireNotNull(pcm).ended
        }
    }

    private fun resume() {
        check(!failed) { "USB route changed; reopen track" }
        val audio = requireNotNull(output)
        check(audio.volume().available || allowFixedVolume || forceSoftwareVolume) { "volume_unavailable" }
        if (needsSeek) resetSource(pausedPositionUs)
        fill()
        audio.start()
        playing = true
        if (!wakeLock.isHeld) wakeLock.acquire()
        emit(mapOf("token" to token, "event" to "active"))
        worker.removeCallbacks(pump)
        worker.post(pump)
    }

    private fun volumeMap(volume: UsbHardwareVolume): Map<String, Any> {
        if (forceSoftwareVolume) {
            return mapOf(
                "available" to true,
                "minDb" to -62.0,
                "maxDb" to 0.0,
                "currentDb" to currentSoftwareDb,
                "token" to token,
                "isSoftware" to true,
            )
        }
        return mapOf(
            "available" to volume.available,
            "minDb" to volume.minDb,
            "maxDb" to volume.maxDb,
            "currentDb" to volume.currentDb,
            "token" to token,
            "isSoftware" to false,
        )
    }

    private fun updateSoftwareGain() {
        if (!forceSoftwareVolume) {
            softwareGain = 1.0f
            return
        }
        if (currentSoftwareDb <= -61.5) {
            softwareGain = 0.0f
            return
        }
        if (currentSoftwareDb >= -0.01) {
            softwareGain = 1.0f
            return
        }
        softwareGain = 10.0.pow(currentSoftwareDb / 20.0).toFloat().coerceIn(0f, 1f)
    }

    private fun fill() {
        val f = requireNotNull(format)
        val frameBytes = f.subslot.toInt() * f.channels.toInt()
        repeat(8) {
            decode()
            val buffer = pending ?: return
            val count = minOf(buffer.remaining(), 65536) / frameBytes * frameBytes
            if (count == 0) { pending = null; return@repeat }
            val audio = requireNotNull(output)
            // There is one producer; the native consumer can only free more room
            // between this check and write. Wait rather than repeatedly copying
            // the same pending samples while the ring is full.
            if (audio.availableBytes().toInt() < count) return
            if (writeBuffer.size != count) writeBuffer = ByteArray(count)
            buffer.duplicate().get(writeBuffer)
            if (forceSoftwareVolume && !isDsd && (softwareGain < 0.9999f || softwareGain <= 0f)) {
                scalePcmBytes(writeBuffer, f.subslot.toInt() * 8, softwareGain)
            }
            val written = audio.write(writeBuffer).toInt()
            buffer.position(buffer.position() + written)
            writtenFrames += written / frameBytes
            if (buffer.hasRemaining()) return
            pending = null
        }
    }

    private val pump = object : Runnable {
        override fun run() {
            if (!playing) return
            try {
                fill()
                val frames = requireNotNull(output).frames().toLong()
                if (ended && pending == null && frames >= writtenFrames) {
                    pause()
                    emit(mapOf("token" to token, "event" to "complete"))
                } else worker.postDelayed(this, 5)
            } catch (error: Exception) { fail(error.message ?: "USB transfer failed") }
        }
    }

    private fun positionUs(): Long {
        if (needsSeek) return pausedPositionUs
        val f = format ?: return 0
        val position = baseUs + (output?.frames()?.toLong() ?: 0) * 1000000 / f.sampleRate.toLong()
        pausedPositionUs = if (durationUs > 0) position.coerceAtMost(durationUs) else position
        return pausedPositionUs
    }

    private fun pause() {
        if (output != null && !needsSeek) pausedPositionUs = runCatching { positionUs() }.getOrDefault(pausedPositionUs.coerceAtLeast(baseUs))
        playing = false
        worker.removeCallbacks(pump)
        if (wakeLock.isHeld) wakeLock.release()
        needsSeek = true
        output?.flush()
    }

    private fun resetSource(positionUs: Long) {
        val f = requireNotNull(format)
        val target = positionUs.coerceIn(0, durationUs.coerceAtLeast(0))
        baseUs = dsd?.seek(target, f.encoding) ?: target.also { pcm?.seek(it) }
        pending = null
        writtenFrames = 0
        ended = false
        needsSeek = false
    }

    private fun seek(positionUs: Long) {
        val wasPlaying = playing
        pause()
        resetSource(positionUs)
        pausedPositionUs = baseUs
        if (wasPlaying) resume()
    }

    private fun fail(reason: String) {
        android.util.Log.w("UsbDirect", reason)
        runCatching { pause() }
        failed = true
        output?.shutdown()
        output?.destroy()
        output = null
        connection?.close()
        connection = null
        emit(mapOf("token" to token, "event" to "paused", "reason" to "route_changed"))
    }

    private fun closeSource() {
        runCatching { pause() }
        output?.shutdown()
        output?.destroy()
        output = null
        connection?.close()
        connection = null
        deviceId = null
        pcm?.close()
        pcm = null
        dsd?.close()
        dsd = null
        format = null
        pending = null
        ended = false
        failed = false
        needsSeek = false
        baseUs = 0
        durationUs = 0
        pausedPositionUs = 0
        writtenFrames = 0
        isDsd = false
        forceSoftwareVolume = false
        softwareGain = 1.0f
    }

    fun dispose() {
        revision++
        permission?.done?.invoke(mapOf("reason" to "cancelled"), null)
        permission = null
        context.unregisterReceiver(receiver)
        worker.post { closeSource(); writeBuffer = ByteArray(0); thread.quitSafely() }
    }

    companion object {
        fun scalePcmBytes(bytes: ByteArray, bits: Int, gain: Float) {
            if (gain <= 0f) {
                bytes.fill(0)
                return
            }
            if (gain >= 0.9999f) return

            when (bits) {
                16 -> {
                    var i = 0
                    while (i + 1 < bytes.size) {
                        val sample = ((bytes[i].toInt() and 0xFF) or (bytes[i + 1].toInt() shl 8)).toShort().toInt()
                        val scaled = (sample * gain + if (sample >= 0) 0.5f else -0.5f).toInt()
                            .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                        bytes[i] = (scaled and 0xFF).toByte()
                        bytes[i + 1] = ((scaled shr 8) and 0xFF).toByte()
                        i += 2
                    }
                }
                24 -> {
                    var i = 0
                    while (i + 2 < bytes.size) {
                        val b0 = bytes[i].toInt() and 0xFF
                        val b1 = bytes[i + 1].toInt() and 0xFF
                        val b2 = bytes[i + 2].toInt() and 0xFF
                        var sample = (b2 shl 16) or (b1 shl 8) or b0
                        if ((sample and 0x800000) != 0) {
                            sample = (sample shl 8) shr 8
                        }
                        val scaled = (sample * gain.toDouble() + if (sample >= 0) 0.5 else -0.5).toInt()
                            .coerceIn(-0x800000, 0x7FFFFF)
                        bytes[i] = (scaled and 0xFF).toByte()
                        bytes[i + 1] = ((scaled shr 8) and 0xFF).toByte()
                        bytes[i + 2] = ((scaled shr 16) and 0xFF).toByte()
                        i += 3
                    }
                }
                32 -> {
                    var i = 0
                    while (i + 3 < bytes.size) {
                        val b0 = bytes[i].toInt() and 0xFF
                        val b1 = bytes[i + 1].toInt() and 0xFF
                        val b2 = bytes[i + 2].toInt() and 0xFF
                        val b3 = bytes[i + 3].toInt() and 0xFF
                        val sample = (b3 shl 24) or (b2 shl 16) or (b1 shl 8) or b0
                        val scaled = (sample.toDouble() * gain.toDouble()).toLong()
                            .coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()
                        bytes[i] = (scaled and 0xFF).toByte()
                        bytes[i + 1] = ((scaled shr 8) and 0xFF).toByte()
                        bytes[i + 2] = ((scaled shr 16) and 0xFF).toByte()
                        bytes[i + 3] = ((scaled shr 24) and 0xFF).toByte()
                        i += 4
                    }
                }
            }
        }
    }
}
