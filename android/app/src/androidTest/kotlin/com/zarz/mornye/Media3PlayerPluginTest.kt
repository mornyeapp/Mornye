package com.zarz.mornye

import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Drives the media3 channel the way the Dart deck does, with real audio. */
@RunWith(AndroidJUnit4::class)
class Media3PlayerPluginTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val codec = StandardMethodCodec.INSTANCE
    private val messenger = Messenger()
    private val plugin = Media3PlayerPlugin()
    private lateinit var binding: FlutterPluginBinding
    private val files = File(context.filesDir, "media3-test")

    private class Messenger : BinaryMessenger {
        val handlers = ConcurrentHashMap<String, BinaryMessenger.BinaryMessageHandler>()
        val events = LinkedBlockingQueue<Pair<String, Map<*, *>>>()
        @Volatile var offMain = false

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (Looper.myLooper() != Looper.getMainLooper()) offMain = true
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }

        override fun send(channel: String, message: ByteBuffer?) {
            if (Looper.myLooper() != Looper.getMainLooper()) offMain = true
            if (message == null) return
            val value = runCatching {
                StandardMethodCodec.INSTANCE.decodeEnvelope(message.duplicate().apply { flip() })
            }.getOrNull()
            if (value is Map<*, *>) events.add(channel to value)
        }

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            send(channel, message)
            callback?.reply(null)
        }
    }

    private inner class Reply : BinaryMessenger.BinaryReply {
        val done = CountDownLatch(1)
        var buffer: ByteBuffer? = null
        @Volatile var thread: Thread? = null

        override fun reply(buffer: ByteBuffer?) {
            thread = Thread.currentThread()
            this.buffer = buffer?.apply { flip() }
            done.countDown()
        }

        fun await(seconds: Long = 10): Reply {
            assertTrue("media3 command did not reply", done.await(seconds, TimeUnit.SECONDS))
            assertSame("Replies must arrive on the main thread", Looper.getMainLooper().thread, thread)
            return this
        }

        fun success(): Any? {
            await()
            return codec.decodeEnvelope(requireNotNull(buffer))
        }

        /** The error code, or a failure when the call succeeded. */
        fun failure(): Pair<String, Any?> {
            await()
            val error = runCatching { codec.decodeEnvelope(requireNotNull(buffer)) }.exceptionOrNull()
            val flutter = error as? io.flutter.plugin.common.FlutterException
                ?: throw AssertionError("Expected an error, got success")
            return flutter.code to flutter.details
        }
    }

    @Before fun attach() {
        files.deleteRecursively()
        files.mkdirs()
        binding = FlutterPluginBinding::class.java.constructors.single().newInstance(
            context, null, messenger, null, null, null, null,
        ) as FlutterPluginBinding
        instrumentation.runOnMainSync { plugin.onAttachedToEngine(binding) }
    }

    @After fun detach() {
        instrumentation.runOnMainSync { plugin.onDetachedFromEngine(binding) }
        files.deleteRecursively()
    }

    private fun call(method: String, arguments: Map<String, Any?> = emptyMap(), player: String = "a"): Reply {
        val reply = Reply()
        instrumentation.runOnMainSync { send(method, arguments, player, reply) }
        return reply
    }

    private fun send(method: String, arguments: Map<String, Any?>, player: String, reply: Reply) {
        val payload = codec.encodeMethodCall(MethodCall(method, mapOf("playerId" to player) + arguments))
        payload.flip()
        requireNotNull(messenger.handlers[CHANNEL]).onMessage(payload, reply)
    }

    private fun create(player: String = "a"): Int {
        val response = call("create", player = player).success() as Map<*, *>
        val listen = Reply()
        instrumentation.runOnMainSync {
            val handler = messenger.handlers["$CHANNEL/events/$player"]
            assertNotNull("create replied before its event channel was registered", handler)
            val payload = codec.encodeMethodCall(MethodCall("listen", null))
            payload.flip()
            handler!!.onMessage(payload, listen)
        }
        listen.await()
        return (response["audioSessionId"] as Number).toInt()
    }

    /** Waits for an event; [match] filters its fields. Other events are skipped. */
    private fun awaitEvent(name: String, player: String = "a", seconds: Long = 10, match: (Map<*, *>) -> Boolean = { true }): Map<*, *> {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds)
        while (true) {
            val remaining = deadline - System.nanoTime()
            if (remaining <= 0) fail("Missing media3 event $name")
            val polled = messenger.events.poll(remaining, TimeUnit.NANOSECONDS)
            assertNotNull("Missing media3 event $name", polled)
            val (channel, event) = polled!!
            Log.i(TAG, "event $channel $event")
            if (channel == "$CHANNEL/events/$player" && event["event"] == name && match(event)) return event
        }
    }

    private fun awaitState(state: String, player: String = "a") = awaitEvent("state", player) { it["state"] == state }

    private fun position(player: String = "a") = (call("getPosition", player = player).success() as Number).toLong()

    /** A quiet sine wave, as PCM WAV in app-private storage. */
    private fun wav(name: String, seconds: Double, rate: Int = 44100, bits: Int = 16): File {
        val channels = 2
        val frames = (seconds * rate).roundToInt()
        val bytesPerSample = bits / 8
        val data = frames * channels * bytesPerSample
        val buffer = ByteBuffer.allocate(44 + data).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray()).putInt(36 + data).put("WAVEfmt ".toByteArray())
        buffer.putInt(16).putShort(1).putShort(channels.toShort()).putInt(rate)
        buffer.putInt(rate * channels * bytesPerSample).putShort((channels * bytesPerSample).toShort())
        buffer.putShort(bits.toShort()).put("data".toByteArray()).putInt(data)
        val peak = (1 shl (bits - 1)) / 20
        for (frame in 0 until frames) {
            val sample = (peak * sin(2 * PI * 440 * frame / rate)).roundToInt()
            repeat(channels) {
                for (byte in 0 until bytesPerSample) buffer.put((sample shr (8 * byte)).toByte())
            }
        }
        return File(files, name).apply { writeBytes(buffer.array()) }
    }

    private fun setSource(file: File): Long? {
        val reply = call("setSource", mapOf("uri" to file.absolutePath, "isLocal" to true)).success() as Map<*, *>
        return (reply["durationMs"] as Number?)?.toLong()
    }

    @Test fun createRepliesWithASessionAndUnknownPlayersFail() {
        assertTrue(create() > 0)
        assertEquals("no_player", call("play", player = "missing").failure().first)
        assertFalse(messenger.offMain)
        call("dispose").success()
        call("dispose").success()
        assertEquals("no_player", call("play").failure().first)
    }

    @Test fun localFilePlaysSeeksPausesAndStops() {
        create()
        call("setVolume", mapOf("volume" to 0.2)).success()
        val duration = setSource(wav("local.wav", 3.0))
        assertEquals(3000.0, requireNotNull(duration).toDouble(), 30.0)
        assertEquals(duration, (call("getDuration").success() as Number).toLong())
        call("play").success()
        awaitState("playing")
        Thread.sleep(500)
        assertTrue("Position must advance", position() > 200)
        call("seek", mapOf("positionMs" to 2000)).success()
        assertEquals(2000.0, position().toDouble(), 100.0)
        call("pause").success()
        awaitState("paused")
        val paused = position()
        Thread.sleep(300)
        assertEquals(paused, position())
        call("play").success()
        awaitState("playing")
        call("stop").success()
        awaitState("stopped")
        assertEquals(0L, position())
        // The source stays loaded: play starts it again.
        call("play").success()
        awaitState("playing")
        awaitEvent("completed", seconds = 8)
        awaitState("completed")
        call("clearSource").success()
        assertNull(call("getDuration").success())
        assertFalse(messenger.offMain)
    }

    @Test fun descriptorLeasePlaysAndSeeksWithoutReopeningThePath() {
        create()
        call("setVolume", mapOf("volume" to 0.2)).success()
        val file = wav("lease.wav", 4.0, rate = 48000, bits = 24)
        val lease = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        val reply = call("setSource", mapOf("uri" to "/proc/self/fd/${lease.fd}", "isLocal" to true)).success()
        // Like the Dart caller: the lease closes once setSource replied.
        lease.close()
        assertEquals(4000.0, ((reply as Map<*, *>)["durationMs"] as Number).toDouble(), 30.0)
        call("play").success()
        awaitState("playing")
        Thread.sleep(1200)
        // Played samples are discarded, so a backward seek reopens the source.
        call("seek", mapOf("positionMs" to 100)).success()
        Thread.sleep(600)
        assertTrue("Playback must continue after reopening the descriptor", position() in 300..1500)
        call("seek", mapOf("positionMs" to 3000)).success()
        Thread.sleep(400)
        assertTrue(position() > 3100)
        call("seek", mapOf("positionMs" to 0)).success()
        Thread.sleep(400)
        assertTrue(position() in 100..1200)
        call("dispose").success()
    }

    @Test fun queuedItemPlaysGaplessly() {
        create()
        assertEquals(false, call("queueNext", mapOf("uri" to wav("orphan.wav", 0.5).absolutePath,
            "isLocal" to true, "volume" to 1.0)).success())
        call("setVolume", mapOf("volume" to 0.2)).success()
        setSource(wav("first.wav", 1.0))
        assertEquals(true, call("queueNext", mapOf("uri" to wav("unused.wav", 0.4).absolutePath,
            "isLocal" to true, "volume" to 0.1)).success())
        call("clearNext").success()
        val second = wav("second.wav", 1.5, rate = 48000)
        val lease = ParcelFileDescriptor.open(second, ParcelFileDescriptor.MODE_READ_ONLY)
        assertEquals(true, call("queueNext", mapOf("uri" to "/proc/self/fd/${lease.fd}",
            "isLocal" to true, "volume" to 0.15)).success())
        lease.close()
        call("play").success()
        awaitState("playing")
        awaitEvent("transition", seconds = 5)
        val duration = awaitEvent("duration", seconds = 5)
        assertEquals(1500.0, (duration["durationMs"] as Number).toDouble(), 30.0)
        assertTrue(position() < 1000)
        awaitEvent("completed", seconds = 5)
        awaitState("completed")
    }

    @Test fun brokenAndMissingSourcesFail() {
        create()
        val broken = File(files, "broken.flac").apply { writeBytes(ByteArray(64 * 1024) { (it * 31).toByte() }) }
        val (code, details) = call("setSource", mapOf("uri" to broken.absolutePath, "isLocal" to true)).failure()
        assertEquals("source_error", code)
        assertTrue(((details as Map<*, *>)["errorCode"] as String).startsWith("ERROR_CODE_"))
        Log.i(TAG, "broken file: $details")
        val missing = call("setSource", mapOf("uri" to File(files, "missing.flac").absolutePath, "isLocal" to true))
            .failure()
        assertEquals("source_error", missing.first)
        Log.i(TAG, "missing file: ${missing.second}")
        assertEquals("source_error", call("setSource", mapOf("uri" to "/proc/self/fd/99999", "isLocal" to true))
            .failure().first)
        // A good source still plays afterwards.
        setSource(wav("after.wav", 0.5))
        call("play").success()
        awaitState("playing")
    }

    @Test fun brokenQueuedItemFailsAfterTheCurrentOne() {
        create()
        call("setVolume", mapOf("volume" to 0.2)).success()
        setSource(wav("good.wav", 0.8))
        val broken = File(files, "broken.flac").apply { writeBytes(ByteArray(64 * 1024) { (it * 31).toByte() }) }
        assertEquals(true, call("queueNext", mapOf("uri" to broken.absolutePath, "isLocal" to true,
            "volume" to 0.2)).success())
        call("play").success()
        awaitState("playing")
        awaitEvent("transition", seconds = 5)
        val error = awaitEvent("error", seconds = 5)
        assertEquals(false, error["prepared"])
        assertEquals("Android could not open this audio source.", error["message"])
        assertEquals("ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED", error["errorCode"])
        awaitState("paused")
        assertNull(call("getDuration").success())
    }

    @Test fun newerSourceSupersedesAPreparingOne() {
        create()
        val first = Reply()
        val second = Reply()
        val firstFile = wav("one.wav", 1.0)
        val secondFile = wav("two.wav", 2.0)
        instrumentation.runOnMainSync {
            send("setSource", mapOf("uri" to firstFile.absolutePath, "isLocal" to true), "a", first)
            send("setSource", mapOf("uri" to secondFile.absolutePath, "isLocal" to true), "a", second)
        }
        assertEquals("superseded", first.failure().first)
        assertEquals(2000.0, ((second.success() as Map<*, *>)["durationMs"] as Number).toDouble(), 30.0)
        val third = Reply()
        val clear = Reply()
        instrumentation.runOnMainSync {
            send("setSource", mapOf("uri" to firstFile.absolutePath, "isLocal" to true), "a", third)
            send("clearSource", emptyMap(), "a", clear)
        }
        assertEquals("superseded", third.failure().first)
        clear.success()
    }

    @Test fun rateEqualizerAndHighResolutionOutput() {
        val session = create()
        call("setVolume", mapOf("volume" to 0.2)).success()
        setSource(wav("hires.wav", 6.0, rate = 96000, bits = 24))
        val equalizer = mapOf(
            "enabled" to true,
            "gains" to listOf(3.0, 0.0, -2.0, 0.0, 1.5),
            "frequencies" to listOf(60.0, 230.0, 910.0, 3600.0, 14000.0),
        )
        assertNull(call("setEqualizer", mapOf("configuration" to equalizer)).success())
        assertEquals("equalizer", call("setEqualizer", mapOf("configuration" to
            equalizer + ("gains" to listOf(0.0)))).failure().first)
        assertNull(call("setEqualizer", mapOf("configuration" to equalizer)).success())
        call("setPlaybackParameters", mapOf("speed" to 2.0, "pitch" to 1.0)).success()
        call("play").success()
        awaitState("playing")
        Thread.sleep(300)
        val start = position()
        val began = System.nanoTime()
        Thread.sleep(1500)
        val advanced = position() - start
        val elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - began)
        Log.i(TAG, "rate 2.0: advanced $advanced ms in $elapsed ms")
        assertEquals(2.0, advanced.toDouble() / elapsed, 0.25)
        val flinger = shell("dumpsys media.audio_flinger")
        val lines = flinger.lines().filter { line ->
            line.contains("Session") || line.contains(" $session ") || line.contains("Dynamics") ||
                line.contains("PCM_FLOAT") || line.contains("Format")
        }
        Log.i(TAG, "session $session audio_flinger:\n" + lines.joinToString("\n"))
        call("setPlaybackParameters", mapOf("speed" to 1.0, "pitch" to 1.0)).success()
        Thread.sleep(300)
        val again = position()
        Thread.sleep(1000)
        assertEquals(1000.0, (position() - again).toDouble(), 200.0)
        assertNull(call("setEqualizer", mapOf("configuration" to mapOf("enabled" to false))).success())
        assertEquals("invalid_argument", call("setPlaybackParameters", mapOf("speed" to 0.0)).failure().first)
    }

    @Test fun twentyFourBitFlacDecodes() {
        create()
        val flac = File(files, "pcm24.flac")
        InstrumentationRegistry.getInstrumentation().context.assets.open("pcm24-pattern.flac").use { input ->
            flac.outputStream().use { input.copyTo(it) }
        }
        val duration = requireNotNull(setSource(flac))
        assertEquals(100.0, duration.toDouble(), 20.0)
        call("setVolume", mapOf("volume" to 0.0)).success()
        call("play").success()
        awaitEvent("completed", seconds = 5)
    }

    private fun shell(command: String): String {
        val output = instrumentation.uiAutomation.executeShellCommand(command)
        return FileInputStream(output.fileDescriptor).use { it.readBytes().decodeToString() }.also { output.close() }
    }

    private companion object {
        const val TAG = "Media3Test"
        const val CHANNEL = "com.zarz.mornye/media3_player"
    }
}
