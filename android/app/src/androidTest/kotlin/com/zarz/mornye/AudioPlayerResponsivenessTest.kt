package com.zarz.mornye

import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import xyz.luan.audioplayers.AudioplayersPlugin
import xyz.luan.audioplayers.player.MediaPlayerWrapper
import xyz.luan.audioplayers.player.WrappedPlayer
import xyz.luan.audioplayers.source.UrlSource

@RunWith(AndroidJUnit4::class)
class AudioPlayerResponsivenessTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val codec = StandardMethodCodec.INSTANCE

    private class Messenger : BinaryMessenger {
        val handlers = ConcurrentHashMap<String, BinaryMessenger.BinaryMessageHandler>()
        val event = CountDownLatch(1)
        val messages = LinkedBlockingQueue<Map<*, *>>()
        var eventThread: Thread? = null

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            check(Looper.myLooper() == Looper.getMainLooper())
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }

        override fun send(channel: String, message: ByteBuffer?) {
            check(Looper.myLooper() == Looper.getMainLooper())
            eventThread = Thread.currentThread()
            if (message != null) {
                val value = StandardMethodCodec.INSTANCE.decodeEnvelope(message.duplicate().apply { flip() })
                if (value is Map<*, *>) messages.add(value)
            }
            event.countDown()
        }

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            send(channel, message)
            callback?.reply(null)
        }
    }

    private inner class Reply : BinaryMessenger.BinaryReply {
        val done = CountDownLatch(1)
        var result: Any? = null
        var failure: Throwable? = null
        override fun reply(buffer: ByteBuffer?) {
            try {
                result = codec.decodeEnvelope(requireNotNull(buffer).apply { flip() })
            } catch (error: Throwable) { failure = error }
            done.countDown()
        }
        fun success(): Any? {
            assertTrue("Audio command did not complete", done.await(5, TimeUnit.SECONDS))
            if (failure != null) throw AssertionError("Audio command failed", failure)
            return result
        }
    }

    private inner class Fixture {
        val messenger = Messenger()
        val plugin = AudioplayersPlugin()
        val binding = FlutterPluginBinding::class.java.constructors.single().newInstance(
            instrumentation.targetContext, null, messenger, null, null, null, null,
        ) as FlutterPluginBinding
        var detached = false

        init {
            instrumentation.runOnMainSync { plugin.onAttachedToEngine(binding) }
            call("create").success()
        }

        fun call(method: String, arguments: Map<String, Any?> = emptyMap(),
            channel: String = "xyz.luan/audioplayers"): Reply {
            val reply = Reply()
            instrumentation.runOnMainSync {
                val payload = codec.encodeMethodCall(MethodCall(method, mapOf("playerId" to "test") + arguments))
                payload.flip()
                requireNotNull(messenger.handlers[channel]).onMessage(payload, reply)
            }
            return reply
        }

        fun detach() {
            if (detached) return
            instrumentation.runOnMainSync { plugin.onDetachedFromEngine(binding) }
            detached = true
        }

        fun slowPlayer(): SlowPlayer {
            val ready = CountDownLatch(1)
            lateinit var native: SlowPlayer
            plugin.playbackDispatcher().invoke {
                @Suppress("UNCHECKED_CAST")
                val players = field(plugin, "players") as Map<String, WrappedPlayer>
                val player = requireNotNull(players["test"])
                native = SlowPlayer()
                setField(player, "player", MediaPlayerWrapper(player, native))
                // A source in preparation, the cancellation path from the ANR.
                setField(player, "source", UrlSource("https://example.invalid/audio", false))
                player.released = false
                ready.countDown()
            }
            assertTrue(ready.await(5, TimeUnit.SECONDS))
            return native
        }
    }

    private class SlowPlayer : MediaPlayer() {
        val owner: Thread = Thread.currentThread()
        val resetting = CountDownLatch(1)
        val resumeReset = CountDownLatch(1)
        var resetThread: Thread? = null
        var releaseThread: Thread? = null
        override fun reset() {
            resetThread = Thread.currentThread()
            resetting.countDown()
            check(resumeReset.await(5, TimeUnit.SECONDS)) { "Test reset was not released" }
            super.reset()
        }
        override fun release() {
            releaseThread = Thread.currentThread()
            super.release()
        }
    }

    private fun field(owner: Any, name: String): Any? =
        owner.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(owner)

    private fun setField(owner: Any, name: String, value: Any) {
        owner.javaClass.getDeclaredField(name).apply { isAccessible = true }.set(owner, value)
    }

    @Test fun slowResetKeepsInputResponsiveAndPlayerCommandsOrdered() {
        val fixture = Fixture()
        val native = fixture.slowPlayer()
        try {
            val release = fixture.call("release")
            assertTrue(native.resetting.await(2, TimeUnit.SECONDS))
            val position = fixture.call("getCurrentPosition")
            val heartbeat = CountDownLatch(1)
            Handler(Looper.getMainLooper()).post { heartbeat.countDown() }
            assertTrue("Input must keep running while reset waits on media service", heartbeat.await(1, TimeUnit.SECONDS))
            assertEquals(1L, release.done.count)
            assertEquals("Player commands must remain serialized", 1L, position.done.count)
            native.resumeReset.countDown()
            release.success()
            assertNull(position.success())
            assertNotSame(Looper.getMainLooper().thread, native.owner)
            assertSame(native.owner, native.resetThread)
            assertSame(native.owner, native.releaseThread)
        } finally {
            native.resumeReset.countDown()
            fixture.detach()
        }
    }

    @Test fun detachingDoesNotWaitForResetAndDiscardsOldFocusCallbacks() {
        val fixture = Fixture()
        val native = fixture.slowPlayer()
        val callback = fixture.plugin.playbackDispatcher()
        val late = CountDownLatch(1)
        try {
            val release = fixture.call("release")
            assertTrue(native.resetting.await(2, TimeUnit.SECONDS))
            fixture.detach()
            callback { late.countDown() }
            assertEquals(1L, release.done.count)
            native.resumeReset.countDown()
            release.success()
            native.owner.join(2000)
            assertFalse("Retired audio worker must terminate", native.owner.isAlive)
            assertEquals("Old engine callbacks must not run", 1L, late.count)
        } finally {
            native.resumeReset.countDown()
            fixture.detach()
        }
    }

    @Test fun createRepliesOnlyAfterItsEventChannelCanListen() {
        val fixture = Fixture()
        try {
            val reply = Reply()
            val eventChannel = "xyz.luan/audioplayers/events/second"
            instrumentation.runOnMainSync {
                val payload = codec.encodeMethodCall(MethodCall("create", mapOf("playerId" to "second")))
                payload.flip()
                requireNotNull(fixture.messenger.handlers["xyz.luan/audioplayers"]).onMessage(payload, reply)
                // Dart listens as soon as the reply lands. Holding the main
                // thread keeps the channel's registration waiting behind it.
                assertFalse(
                    "create replied before its event channel was registered",
                    reply.done.await(500, TimeUnit.MILLISECONDS),
                )
            }
            assertEquals(1, reply.success())
            assertNotNull(fixture.messenger.handlers[eventChannel])
        } finally { fixture.detach() }
    }

    @Test fun errorsAreSerializableAndEventsStayOnTheMainThread() {
        val fixture = Fixture()
        try {
            fixture.call("listen", channel = "xyz.luan/audioplayers/events/test").success()
            fixture.call("emitLog", mapOf("message" to "worker event")).success()
            assertTrue(fixture.messenger.event.await(2, TimeUnit.SECONDS))
            assertSame(Looper.getMainLooper().thread, fixture.messenger.eventThread)
            val failure = fixture.call("setSourceUrl")
            assertTrue(failure.done.await(2, TimeUnit.SECONDS))
            assertNotNull(failure.failure)
            assertEquals(1, fixture.call("setVolume", mapOf("volume" to 0.5)).success())
        } finally { fixture.detach() }
    }

    @Test fun nativePrepareSeekAndTransportWorkOnThePlaybackLooper() {
        val fixture = Fixture()
        try {
            fixture.call("listen", channel = "xyz.luan/audioplayers/events/test").success()
            fixture.call("setAudioContext", mapOf(
                "isSpeakerphoneOn" to false, "stayAwake" to false,
                "contentType" to 2, "usageType" to 1, "audioFocus" to 0, "audioMode" to 0,
            )).success()
            fixture.call("setReleaseMode", mapOf("releaseMode" to "ReleaseMode.stop")).success()
            fixture.call("setVolume", mapOf("volume" to 0.0)).success()
            val bytes = ByteBuffer.allocate(44 + 88200).order(ByteOrder.LITTLE_ENDIAN).apply {
                put("RIFF".toByteArray()); putInt(36 + 88200); put("WAVEfmt ".toByteArray())
                putInt(16); putShort(1); putShort(1); putInt(44100); putInt(88200)
                putShort(2); putShort(16); put("data".toByteArray()); putInt(88200)
            }.array()
            fixture.call("setSourceBytes", mapOf("bytes" to bytes)).success()
            awaitEvent(fixture, "audio.onPrepared")
            assertEquals(1000, fixture.call("getDuration").success())
            fixture.call("resume").success()
            fixture.call("seek", mapOf("position" to 400)).success()
            awaitEvent(fixture, "audio.onSeekComplete")
            fixture.call("pause").success()
            fixture.call("resume").success()
            fixture.call("stop").success()
            fixture.call("release").success()
            fixture.call("dispose").success()
        } finally { fixture.detach() }
    }

    private fun awaitEvent(fixture: Fixture, name: String) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (true) {
            val remaining = deadline - System.nanoTime()
            if (remaining <= 0) fail("Missing native event $name")
            val event = fixture.messenger.messages.poll(remaining, TimeUnit.NANOSECONDS)
            assertNotNull("Missing native event $name", event)
            if (event?.get("event") == name && event["value"] != false) return
        }
    }
}
