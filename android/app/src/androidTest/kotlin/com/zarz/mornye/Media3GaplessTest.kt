package com.zarz.mornye

import android.os.Handler
import android.os.SystemClock
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.audio.AudioSink
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Measures a gapless handoff through the media3 channel: how many audio
 * tracks the player opens, underruns, and how long the two items take
 * against their combined duration.
 */
@OptIn(UnstableApi::class)
@RunWith(AndroidJUnit4::class)
class Media3GaplessTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val codec = StandardMethodCodec.INSTANCE
    private val handlers = ConcurrentHashMap<String, BinaryMessenger.BinaryMessageHandler>()
    private val plugin = Media3PlayerPlugin()
    private lateinit var binding: FlutterPluginBinding
    private val files = File(context.filesDir, "media3-gapless")

    private val messenger = object : BinaryMessenger {
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }

        override fun send(channel: String, message: ByteBuffer?) {}

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            callback?.reply(null)
        }
    }

    private class Measurement : AnalyticsListener {
        val started = SystemClock.elapsedRealtime()
        val log: MutableList<String> = Collections.synchronizedList(mutableListOf())
        @Volatile var tracksOpened = 0
        @Volatile var tracksReleased = 0
        @Volatile var underruns = 0
        @Volatile var firstAudio = 0L
        @Volatile var transition = 0L
        val ended = CountDownLatch(1)
        @Volatile var endedAt = 0L

        fun mark(text: String) = note(text)

        private fun note(text: String) {
            log.add("${SystemClock.elapsedRealtime() - started} ms: $text")
        }

        override fun onAudioTrackInitialized(eventTime: AnalyticsListener.EventTime, audioTrackConfig: AudioSink.AudioTrackConfig) {
            tracksOpened++
            note("track opened encoding=${audioTrackConfig.encoding} rate=${audioTrackConfig.sampleRate} " +
                "channels=${audioTrackConfig.channelConfig} buffer=${audioTrackConfig.bufferSize} bytes")
        }

        override fun onAudioTrackReleased(eventTime: AnalyticsListener.EventTime, audioTrackConfig: AudioSink.AudioTrackConfig) {
            tracksReleased++
            note("track released")
        }

        override fun onAudioUnderrun(eventTime: AnalyticsListener.EventTime, bufferSize: Int, bufferSizeMs: Long, elapsedSinceLastFeedMs: Long) {
            underruns++
            note("underrun buffer=$bufferSizeMs ms since feed=$elapsedSinceLastFeedMs ms")
        }

        override fun onAudioPositionAdvancing(eventTime: AnalyticsListener.EventTime, playoutStartSystemTimeMs: Long) {
            if (firstAudio == 0L) firstAudio = SystemClock.elapsedRealtime()
            note("position advancing")
        }

        override fun onAudioInputFormatChanged(
            eventTime: AnalyticsListener.EventTime,
            format: androidx.media3.common.Format,
            decoderReuseEvaluation: androidx.media3.exoplayer.DecoderReuseEvaluation?,
        ) {
            note("input format ${format.sampleMimeType} pcm=${format.pcmEncoding} " +
                "reuse=${decoderReuseEvaluation?.result} discard=${decoderReuseEvaluation?.discardReasons}")
        }

        override fun onMediaItemTransition(eventTime: AnalyticsListener.EventTime, mediaItem: MediaItem?, reason: Int) {
            if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) {
                transition = SystemClock.elapsedRealtime()
                note("auto transition at media position ${eventTime.currentPlaybackPositionMs} ms")
            }
        }

        override fun onPlaybackStateChanged(eventTime: AnalyticsListener.EventTime, state: Int) {
            note("state $state")
            if (state == Player.STATE_ENDED) {
                endedAt = SystemClock.elapsedRealtime()
                ended.countDown()
            }
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

    private fun call(method: String, arguments: Map<String, Any?> = emptyMap()): Any? {
        val done = CountDownLatch(1)
        var buffer: ByteBuffer? = null
        instrumentation.runOnMainSync {
            val payload = codec.encodeMethodCall(MethodCall(method, mapOf("playerId" to "g") + arguments))
            payload.flip()
            requireNotNull(handlers[CHANNEL]).onMessage(payload) { reply ->
                buffer = reply?.apply { flip() }
                done.countDown()
            }
        }
        assertTrue("$method did not reply", done.await(10, TimeUnit.SECONDS))
        return codec.decodeEnvelope(requireNotNull(buffer))
    }

    /** The plugin's ExoPlayer, reached the way a debugger would. */
    private fun exo(): ExoPlayer {
        val players = Media3PlayerPlugin::class.java.getDeclaredField("players")
            .apply { isAccessible = true }.get(plugin) as Map<*, *>
        val player = requireNotNull(players["g"])
        return player.javaClass.getDeclaredField("exo").apply { isAccessible = true }.get(player) as ExoPlayer
    }

    private fun asset(name: String): File = File(files, name).apply {
        instrumentation.context.assets.open(name).use { input -> outputStream().use { input.copyTo(it) } }
    }

    private fun wav(name: String, seconds: Double, frequency: Double, channels: Int = 2): File {
        val rate = 44100
        val frames = (seconds * rate).roundToInt()
        val data = frames * channels * 2
        val buffer = ByteBuffer.allocate(44 + data).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray()).putInt(36 + data).put("WAVEfmt ".toByteArray())
        buffer.putInt(16).putShort(1).putShort(channels.toShort()).putInt(rate)
        buffer.putInt(rate * channels * 2).putShort((channels * 2).toShort())
        buffer.putShort(16).put("data".toByteArray()).putInt(data)
        for (frame in 0 until frames) {
            val sample = (3000 * sin(2 * PI * frequency * frame / rate)).roundToInt().toShort()
            repeat(channels) { buffer.putShort(sample) }
        }
        return File(files, name).apply { writeBytes(buffer.array()) }
    }

    private fun handoff(label: String, first: File, second: File, queueAtMs: Long = -1): Pair<Measurement, Long> {
        call("create")
        val measurement = Measurement()
        val player = exo()
        val added = CountDownLatch(1)
        Handler(player.applicationLooper).post {
            player.addAnalyticsListener(measurement)
            added.countDown()
        }
        assertTrue(added.await(5, TimeUnit.SECONDS))
        call("setVolume", mapOf("volume" to 0.2))
        val firstMs = ((call("setSource", mapOf("uri" to first.absolutePath, "isLocal" to true)) as Map<*, *>)
            ["durationMs"] as Number).toLong()
        val queue = { call("queueNext", mapOf("uri" to second.absolutePath, "isLocal" to true, "volume" to 0.2)) }
        if (queueAtMs < 0) assertEquals(true, queue())
        call("play")
        if (queueAtMs >= 0) {
            while ((call("getPosition") as Number).toLong() < queueAtMs) Thread.sleep(20)
            measurement.mark("queueNext at ${call("getPosition")} ms")
            assertEquals(true, queue())
        }
        assertTrue("$label never ended", measurement.ended.await(20, TimeUnit.SECONDS))
        val secondMs = 2000L
        val playedMs = measurement.endedAt - measurement.firstAudio
        val gapMs = playedMs - firstMs - secondMs
        Log.i(TAG, "$label: tracks opened=${measurement.tracksOpened} released=${measurement.tracksReleased} " +
            "underruns=${measurement.underruns} first item ${measurement.transition - measurement.firstAudio} ms " +
            "(duration $firstMs) total $playedMs ms for ${firstMs + secondMs} ms, extra $gapMs ms")
        measurement.log.forEach { Log.i(TAG, "$label: $it") }
        call("dispose")
        return measurement to gapMs
    }

    @Test fun monoFlacHandoffKeepsOneAudioTrack() {
        val (measurement, gapMs) = handoff("flac", asset("gapless-a.flac"), asset("gapless-b.flac"))
        assertEquals("A queued item must reuse the audio track", 1, measurement.tracksOpened)
        assertEquals(0, measurement.underruns)
        assertTrue("Handoff took $gapMs ms longer than the audio", gapMs < 80)
    }

    @Test fun pcmWavHandoffKeepsOneAudioTrack() {
        val (measurement, gapMs) = handoff("wav", wav("a.wav", 2.0, 440.0), wav("b.wav", 2.0, 660.0))
        assertEquals("A queued item must reuse the audio track", 1, measurement.tracksOpened)
        assertEquals(0, measurement.underruns)
        assertTrue("Handoff took $gapMs ms longer than the audio", gapMs < 80)
    }

    @Test fun lateQueuedItemKeepsOneAudioTrack() {
        // Queued once the whole first item is in the output buffer, as after
        // a seek into the last seconds of a song.
        val (measurement, gapMs) = handoff("late", wav("long.wav", 4.0, 440.0), wav("b.wav", 2.0, 660.0), 2500)
        assertEquals("A queued item must reuse the audio track", 1, measurement.tracksOpened)
        assertEquals(0, measurement.underruns)
        assertTrue("Handoff took $gapMs ms longer than the audio", gapMs < 80)
    }

    private companion object {
        const val TAG = "Media3Gapless"
        const val CHANNEL = "com.zarz.mornye/media3_player"
    }
}
