package com.zarz.mornye

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
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
import com.mornye.backend.UsbResampler
import io.flutter.plugin.common.MethodCall
import java.io.FileNotFoundException
import java.io.IOException
import java.nio.ByteBuffer

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
    // The level each DAC last played at once the user set one, and when the
    // app last let go of that DAC: a reopen right after is a track change.
    private val deviceVolumes = mutableMapOf<Int, Double>()
    private val deviceReleases = mutableMapOf<Int, Long>()
    // The level each DAC had before the app first lowered it, written back
    // when playback ends so other apps do not play through a lowered DAC.
    private val deviceOriginals = mutableMapOf<Int, Double>()
    // The rate each DAC played a song rate at, so a rate it refused once is
    // not asked of it again for every song.
    private val deviceRates = mutableMapOf<Int, MutableMap<Int, Int>>()
    // DACs whose access prompt the user declined this session, so later
    // tracks do not prompt again. Touched on the main thread only.
    private val declinedDevices = mutableSetOf<String>()
    // A mono source sent to a stereo-only DAC, each sample on both channels.
    private var upmixMono = false
    private var upmixBuffer: ByteBuffer? = null
    // Set while the DAC plays another rate than the song's, which it refused.
    private var resampler: UsbResampler? = null
    private var resamplerDrained = false
    private var resampleInput = ByteArray(0)

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            @Suppress("DEPRECATION")
            val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE) ?: return
            if (intent.action == UsbManager.ACTION_USB_DEVICE_DETACHED) {
                // Plugging the DAC in again asks for access again.
                declinedDevices.remove(device.declineKey())
                worker.post {
                    deviceVolumes.remove(device.deviceId)
                    deviceReleases.remove(device.deviceId)
                    deviceOriginals.remove(device.deviceId)
                    deviceRates.remove(device.deviceId)
                    if (device.deviceId == deviceId) fail("USB disconnected")
                }
            } else if (intent.action == permissionAction) {
                val request = permission ?: return
                if (request.device.deviceId != device.deviceId) return
                if (intent.getIntExtra("revision", -1) != request.revision) return
                permission = null
                if (request.revision != revision) { request.done(mapOf("reason" to "cancelled"), null); return }
                if (manager.hasPermission(device)) prepare(request)
                else {
                    declinedDevices += device.declineKey()
                    request.done(mapOf("reason" to "permission_declined"), null)
                }
            }
        }
    }

    init {
        val filter = IntentFilter(permissionAction).apply { addAction(UsbManager.ACTION_USB_DEVICE_DETACHED) }
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else { @Suppress("DEPRECATION") context.registerReceiver(receiver, filter) }
    }

    fun command(call: MethodCall, done: (Any?, String?) -> Unit) {
        if (call.method == "forgetPermissionDenial") {
            declinedDevices.clear()
            done(null, null)
            return
        }
        if (call.method == "prepare" || call.method == "stop" || call.method == "endSession") {
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
            else if (device.declineKey() in declinedDevices) {
                // Turning Direct USB off and on, or replugging, asks again.
                worker.post { done(mapOf("reason" to "permission_declined"), null) }
            }
            else worker.post {
                // A file Direct USB cannot play says why without a permission prompt.
                val failure = probeFailure(call.argument<String>("path"))
                main.post {
                    when {
                        request.revision != revision -> done(mapOf("reason" to "cancelled"), null)
                        failure != null -> done(failure, null)
                        else -> requestPermission(request)
                    }
                }
            }
            return
        }
        worker.post {
            try {
                val value: Any? = when (call.method) {
                    "endSession" -> { handBack(); null }
                    "resume" -> { resume(); null }
                    "pause" -> { pause(); null }
                    "seek" -> { seek((call.argument<Number>("position")?.toLong() ?: 0) * 1000); null }
                    "position" -> positionUs() / 1000
                    "status" -> mapOf("token" to token, "reason" to when {
                        failed -> "route_changed"
                        output == null -> "idle"
                        playing -> "active"
                        !requireNotNull(output).volume().available && !allowFixedVolume -> "volume_unavailable"
                        else -> "ready"
                    })
                    "volume" -> {
                        require(call.argument<Int>("token") == token) { "Stale volume request" }
                        val audio = requireNotNull(output)
                        val db = call.argument<Number>("db")?.toDouble()
                        val value = if (db == null) audio.volume() else audio.setVolume(db)
                        if (db != null && value.available) deviceId?.let { deviceVolumes[it] = value.currentDb }
                        volumeMap(value)
                    }
                    "stop" -> { closeSource(); null }
                    else -> error("Unknown USB command")
                }
                done(value, null)
            } catch (error: Exception) { done(null, error.message ?: "USB output failed") }
        }
    }

    private fun requestPermission(request: Permission) {
        permission = request
        val flags = PendingIntent.FLAG_CANCEL_CURRENT or if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val intent = PendingIntent.getBroadcast(context, request.revision, Intent(permissionAction).setPackage(context.packageName).putExtra("revision", request.revision), flags)
        try { manager.requestPermission(request.device, intent) }
        catch (error: Exception) { permission = null; request.done(mapOf("reason" to "permission_denied"), null) }
        main.postDelayed({
            if (permission === request) {
                permission = null
                declinedDevices += request.device.declineKey()
                request.done(mapOf("reason" to "permission_denied"), null)
            }
        }, 60000)
    }

    /** Stable across replugging, unlike the device id. */
    private fun UsbDevice.declineKey() = "$vendorId:$productId"

    /** The bConfigurationValue the kernel set (GET_CONFIGURATION), or null when the DAC does not answer. */
    private fun UsbDeviceConnection.activeConfiguration(): Int? {
        val value = ByteArray(1)
        val read = controlTransfer(UsbConstants.USB_DIR_IN or UsbConstants.USB_TYPE_STANDARD, 8, 0, 0, value, 1, 1000)
        return if (read == 1) (value[0].toInt() and 255).takeIf { it != 0 } else null
    }

    /** Reads headers only, never the device; null lets preparation decide. */
    private fun probeFailure(path: String?): Map<String, Any>? {
        if (path == null) return null
        return try {
            if (!DsdSource.isDsd(path)) UsbPcmSource.probe(path, decodeCompressed = true)
            null
        } catch (error: Exception) {
            if (error !is UsbDirectException && (error !is IOException || error is FileNotFoundException)) null
            else failure(error, isDsd = false, stage = Stage.SOURCE, info = null, bits = 0)
        }
    }

    private enum class Stage { SOURCE, DEVICE, DECODE }

    /** A specific reason for the app, with the source and the full error for the log. */
    private fun failure(error: Exception, isDsd: Boolean, stage: Stage, info: UsbSourceInfo?, bits: Int): Map<String, Any> {
        val typed = error as? UsbDirectException
        val source = typed?.info ?: info
        val reason = when {
            isDsd -> "dsd_unsupported"
            // Before playback starts, normal playback takes over instead of a pause.
            typed?.reason == UsbDirectFormats.DECODE_FAILED -> UsbDirectFormats.UNSUPPORTED
            typed != null -> typed.reason
            // An unreadable file is not a format problem.
            stage == Stage.SOURCE -> if (error is FileNotFoundException || error is SecurityException) {
                UsbDirectFormats.UNSUPPORTED
            } else UsbDirectFormats.FORMAT
            else -> UsbDirectFormats.classifyOutput(error.message)
        }
        val detail = listOfNotNull(source?.describe(), error.message ?: "USB preparation failed").joinToString(": ")
        android.util.Log.i("UsbDirect", "Direct output unavailable ($reason): $detail")
        return buildMap {
            source?.let { putAll(it.toMap()) }
            put("reason", reason)
            put("fatal", isDsd)
            put("detail", detail)
            if (reason == UsbDirectFormats.DAC_FORMAT && bits > 0) put("bitDepth", bits)
        }
    }

    private fun prepare(request: Permission) {
        worker.post {
            var isDsd = false
            var stage = Stage.SOURCE
            var info: UsbSourceInfo? = null
            var requestedBits = 0
            try {
                if (request.revision != revision) { request.done(mapOf("reason" to "cancelled"), null); return@post }
                closeSource()
                token = request.call.argument<Int>("token") ?: 0
                allowFixedVolume = request.call.argument<Boolean>("allowFixedVolume") == true
                val path = requireNotNull(request.call.argument<String>("path"))
                // Bounds priming a compressed decoder before the device opens.
                val deadline = android.os.SystemClock.elapsedRealtime() + 5000
                isDsd = DsdSource.isDsd(path)
                dsd = DsdSource.open(path)
                isDsd = isDsd || dsd != null
                if (isDsd) requireNotNull(dsd) { "DSD decoder unavailable" }
                if (!isDsd) pcm = UsbPcmSource(path, decodeCompressed = true, deadline = deadline)
                info = pcm?.info
                val rate = dsd?.rate ?: requireNotNull(pcm).rate
                val channels = dsd?.channels ?: requireNotNull(pcm).channels
                val bits = if (isDsd) 1 else requireNotNull(pcm).bits
                durationUs = dsd?.durationUs ?: requireNotNull(pcm).durationUs
                stage = Stage.DEVICE
                val usb = manager.openDevice(request.device) ?: error("Cannot open USB device")
                connection = usb
                deviceId = request.device.deviceId
                val allowDop = request.call.argument<Boolean>("allowDop") == true
                // A DAC with several configurations (UAC2 plus a UAC1 fallback)
                // is described by the one the kernel set.
                val raw = usb.rawDescriptors
                val activeConfiguration = usb.activeConfiguration()
                val descriptors = UsbDirectFormats.activeConfiguration(raw, activeConfiguration)
                if (descriptors.size != raw.size) {
                    android.util.Log.i("UsbDirect", "Using USB configuration ${activeConfiguration ?: "listed first"} of several")
                }
                requestedBits = bits
                // Fallbacks keep every sample exact: a mono sample goes to both
                // channels of a stereo-only DAC, and a lossy source, which has
                // no depth of its own, may go out at 16-bit.
                val attempts = buildList {
                    add(channels to bits)
                    if (!isDsd && channels == 1) add(2 to bits)
                    if (!isDsd && info?.lossy == true && bits > 16) {
                        add(channels to 16)
                        if (channels == 1) add(2 to 16)
                    }
                }
                var opened: UsbDirectOutput? = null
                var refused: Exception? = null
                // A DAC that refuses the song's rate, or a song above the rate
                // the user allows, is converted to a rate the DAC takes. DSD
                // is never converted.
                val maxRate = request.call.argument<Int>("maxSampleRate") ?: 0
                val playedRates = deviceRates.getOrPut(request.device.deviceId) { mutableMapOf() }
                val rates = if (isDsd) listOf(rate) else UsbDirectFormats.outputRates(rate, maxRate, playedRates[rate])
                var deviceRefusals = 0
                rates@ for (outRate in rates) {
                    for ((outChannels, outBits) in attempts) {
                        try {
                            opened = UsbDirectOutput.open(usb.fileDescriptor, descriptors, outRate.toUInt(), outChannels.toUByte(), outBits.toUByte(), isDsd, allowDop)
                            requestedBits = outBits
                            upmixMono = outChannels != channels
                            break@rates
                        } catch (error: Exception) {
                            if (UsbDirectFormats.classifyOutput(error.message) != UsbDirectFormats.DAC_FORMAT) throw error
                            if (refused == null) refused = error
                            val message = error.message.orEmpty()
                            // Refusals that never set anything on the DAC are
                            // free; one the DAC itself gave ends this rate.
                            if (message.startsWith("USB clock does not offer")) continue@rates
                            if (!message.startsWith("No compatible USB format") &&
                                !message.contains("bandwidth too small")) {
                                if (++deviceRefusals == 4) break@rates
                                continue@rates
                            }
                        }
                    }
                }
                // The first refusal names the format the song asked for.
                val audio = opened ?: throw requireNotNull(refused)
                output = audio
                format = audio.format()
                val outputRate = audio.format().sampleRate
                if (!isDsd) playedRates[rate] = outputRate.toInt()
                if (!isDsd && outputRate.toInt() != rate) {
                    resampler = UsbResampler.create(rate.toUInt(), outputRate, channels.toUByte(),
                        audio.format().subslot, audio.format().bits,
                        request.call.argument<Boolean>("ditherHighPass") ?: false)
                    android.util.Log.i("UsbDirect", "Converting $rate Hz to $outputRate Hz for the DAC")
                }
                // What the DAC read when it was opened, for the log: a level
                // that falls between tracks was set by something else.
                val connected = audio.volume()
                val volumeTrace = mutableMapOf<String, Any>("connectedDb" to connected.restoreLimitDb)
                if (connected.available) {
                    val id = request.device.deviceId
                    deviceOriginals.putIfAbsent(id, connected.restoreLimitDb)
                    val since = deviceReleases[id]?.let { android.os.SystemClock.elapsedRealtime() - it }
                    since?.let { volumeTrace["sinceReleaseMs"] = it }
                    deviceVolumes[id]?.let {
                        volumeTrace["rememberedDb"] = it
                        // What it plays at is what the next track keeps.
                        deviceVolumes[id] = audio.setVolume(
                            UsbDirectFormats.restoredVolumeDb(it, connected.restoreLimitDb, since),
                        ).currentDb
                    }
                }
                if (request.revision != revision) { closeSource(); request.done(mapOf("reason" to "cancelled"), null); return@post }
                stage = Stage.DECODE
                val firstBuffer = android.os.SystemClock.elapsedRealtime() + 5000
                while (pending == null && !ended) {
                    require(request.revision == revision) { "USB prepare cancelled" }
                    require(android.os.SystemClock.elapsedRealtime() < firstBuffer) { "Decoder timed out" }
                    decode()
                    if (pending == null) Thread.sleep(2)
                }
                val f = requireNotNull(format)
                val source = info ?: UsbSourceInfo("DSD", rate, 1, channels)
                request.done(mapOf("ready" to true, "device" to (request.device.productName ?: "USB audio"),
                    "sampleRate" to rate, "bitDepth" to f.bits.toInt(),
                    // A lossy source reports 0: its depth is the DAC's, not the file's.
                    "sourceBitDepth" to if (isDsd) 1 else source.bits,
                    "codec" to source.codec, "lossy" to source.lossy,
                    "duration" to durationUs / 1000,
                    "transport" to f.encoding, "carrierRate" to f.sampleRate.toLong(), "driver" to "usb_direct",
                    "resampled" to (resampler != null),
                    "volume" to volumeMap(audio.volume()), "volumeTrace" to volumeTrace,
                    "volumeBlocked" to (!audio.volume().available && !allowFixedVolume)), null)
            } catch (error: Exception) {
                closeSource()
                if (request.revision != revision) request.done(mapOf("reason" to "cancelled"), null)
                else request.done(failure(error, isDsd, stage, info, requestedBits), null)
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
            pending = try {
                val source = requireNotNull(pcm)
                val data = resampled(source.read(f.subslot.toInt() * 8), source.ended)
                if (upmixMono && data != null) {
                    BitPerfectPcm.duplicateMono(data, f.subslot.toInt(), upmixBuffer).also { upmixBuffer = it }
                } else data
            } catch (error: Exception) {
                // Separates a source that stopped decoding from a USB transfer failure.
                throw error as? UsbDirectException
                    ?: UsbDirectException(UsbDirectFormats.DECODE_FAILED, error.message ?: "Decoding failed", pcm?.info)
            }
            ended = requireNotNull(pcm).ended
        }
    }

    /**
     * [data] at the rate the DAC plays, when that is not the song's. With
     * [last], what the filter still holds follows. Null when the filter
     * needs more input before its next frame.
     */
    private fun resampled(data: ByteBuffer?, last: Boolean): ByteBuffer? {
        val converter = resampler ?: return data
        var output = ByteArray(0)
        if (data != null && data.hasRemaining()) {
            if (resampleInput.size != data.remaining()) resampleInput = ByteArray(data.remaining())
            data.duplicate().get(resampleInput)
            output = converter.process(resampleInput)
        }
        if (last && !resamplerDrained) {
            resamplerDrained = true
            output += converter.finish()
        }
        return if (output.isEmpty()) null else ByteBuffer.wrap(output)
    }

    private fun resume() {
        check(!failed) { "USB route changed; reopen track" }
        val audio = requireNotNull(output)
        check(audio.volume().available || allowFixedVolume) { "volume_unavailable" }
        if (needsSeek) resetSource(pausedPositionUs)
        fill()
        audio.start()
        playing = true
        if (!wakeLock.isHeld) wakeLock.acquire()
        emit(mapOf("token" to token, "event" to "active"))
        worker.removeCallbacks(pump)
        worker.post(pump)
    }

    private fun volumeMap(volume: UsbHardwareVolume): Map<String, Any> = mapOf(
        "available" to volume.available, "minDb" to volume.minDb,
        "maxDb" to volume.maxDb, "currentDb" to volume.currentDb, "token" to token,
    )

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
                } else {
                    val sampleRate = format?.sampleRate?.toLong()?.coerceAtLeast(1L) ?: 48000L
                    val bufferedMs = ((writtenFrames - frames).coerceAtLeast(0L) * 1000L) / sampleRate
                    val delayMs = if (!ended && pending == null && bufferedMs > 80L) {
                        (bufferedMs / 4L).coerceIn(15L, 40L)
                    } else {
                        5L
                    }
                    worker.postDelayed(this, delayMs)
                }
            } catch (error: Exception) {
                val reason = if (error is UsbDirectException) UsbDirectFormats.DECODE_FAILED else "route_changed"
                fail(listOfNotNull((error as? UsbDirectException)?.info?.describe(), error.message ?: "USB transfer failed")
                    .joinToString(": "), reason)
            }
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
        resampler?.reset()
        resamplerDrained = false
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

    private fun fail(message: String, reason: String = "route_changed") {
        android.util.Log.w("UsbDirect", "$reason: $message")
        runCatching { pause() }
        failed = true
        output?.shutdown()
        output?.destroy()
        output = null
        connection?.close()
        connection = null
        emit(mapOf("token" to token, "event" to "paused", "reason" to reason, "detail" to message))
    }

    private fun closeSource() {
        runCatching { pause() }
        output?.shutdown()
        output?.destroy()
        if (output != null) deviceId?.let { deviceReleases[it] = android.os.SystemClock.elapsedRealtime() }
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
        resampler?.destroy()
        resampler = null
        resamplerDrained = false
        upmixMono = false
        ended = false
        failed = false
        needsSeek = false
        baseUs = 0
        durationUs = 0
        pausedPositionUs = 0
        writtenFrames = 0
    }

    /**
     * The DAC goes back to the level it connected with and is let go, when
     * playback ends or has sat idle. Never between two songs, where the next
     * one could play through Android's mixer at that higher level.
     */
    private fun handBack() {
        val audio = output
        val original = deviceId?.let { deviceOriginals[it] }
        // A session that ends without the DAC open learns its level afresh.
        deviceOriginals.clear()
        if (audio != null && !failed) {
            runCatching {
                // Nothing is in flight when the level rises.
                pause()
                val now = audio.volume()
                val level = if (now.available) UsbDirectFormats.levelToHandBack(original, now.currentDb) else null
                if (level != null) {
                    val set = audio.setVolume(level)
                    android.util.Log.i("UsbDirect", "DAC handed back at ${set.currentDb} dB (played at ${now.currentDb} dB)")
                }
            }.onFailure { android.util.Log.w("UsbDirect", "DAC level not handed back: ${it.message}") }
        }
        closeSource()
    }

    fun dispose() {
        revision++
        permission?.done?.invoke(mapOf("reason" to "cancelled"), null)
        permission = null
        context.unregisterReceiver(receiver)
        worker.post { handBack(); writeBuffer = ByteArray(0); thread.quitSafely() }
    }
}
