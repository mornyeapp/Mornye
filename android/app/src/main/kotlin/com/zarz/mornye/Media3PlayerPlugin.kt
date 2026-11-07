package com.zarz.mornye

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The media3 ExoPlayer engine for ordinary (mixer) playback. Engine-owned
 * (not Activity-owned), so playback survives backgrounding.
 *
 * Every player and every method runs on one owned [HandlerThread] looper;
 * method results and events are delivered on the main thread. `create`
 * replies only after the player's event channel has its stream handler:
 * Dart listens as soon as the reply lands, and a stream without a handler
 * loses events.
 */
class Media3PlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var messenger: BinaryMessenger
    private lateinit var methods: MethodChannel
    private val main = Handler(Looper.getMainLooper())
    private var thread: HandlerThread? = null
    private var worker: Handler? = null
    @Volatile private var generation = 0

    /** Playback looper only. */
    private var players = HashMap<String, Media3Player>()

    /** Main thread only. */
    private val events = HashMap<String, PlayerEvents>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        messenger = binding.binaryMessenger
        generation++
        players = HashMap()
        thread = HandlerThread("Mornye-Media3").apply { start() }
        worker = Handler(requireNotNull(thread).looper)
        methods = MethodChannel(messenger, CHANNEL)
        methods.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        generation++
        methods.setMethodCallHandler(null)
        events.values.forEach { it.dispose() }
        events.clear()
        val retiring = players
        val retiringThread = thread
        worker?.post {
            try {
                retiring.values.forEach { player ->
                    runCatching { player.dispose() }.onFailure { Log.w(TAG, "Could not release a retired player", it) }
                }
                retiring.clear()
            } finally {
                retiringThread?.quitSafely()
            }
        }
        worker = null
        thread = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val reply = MainResult(result, main)
        val epoch = generation
        val currentPlayers = players
        val accepted = worker?.post {
            if (epoch != generation) {
                reply.error(Media3Errors.NO_PLAYER, "Playback engine was detached", null)
            } else {
                try {
                    handle(call, reply, currentPlayers)
                } catch (error: Exception) {
                    Log.w(TAG, "${call.method} failed: ${error.javaClass.simpleName}")
                    reply.error(Media3Errors.NATIVE_ERROR, error.message, null)
                }
            }
        } == true
        if (!accepted) result.error(Media3Errors.NO_PLAYER, "Playback engine is not attached", null)
    }

    private fun handle(call: MethodCall, reply: MethodChannel.Result, players: HashMap<String, Media3Player>) {
        val id = call.argument<String>("playerId")
            ?: return reply.error(Media3Errors.NO_PLAYER, "playerId is required", null)
        when (call.method) {
            "create" -> {
                players[id]?.let { return reply.success(mapOf("audioSessionId" to it.sessionId)) }
                val channel = PlayerEvents(EventChannel(messenger, "$CHANNEL/events/$id"), main)
                val player = Media3Player(context, requireNotNull(Looper.myLooper()), channel::send)
                players[id] = player
                main.post {
                    events.remove(id)?.dispose()
                    events[id] = channel
                    channel.register()
                    reply.success(mapOf("audioSessionId" to player.sessionId))
                }
            }
            "dispose" -> {
                players.remove(id)?.dispose()
                main.post {
                    events.remove(id)?.dispose()
                    reply.success(null)
                }
            }
            else -> {
                val player = players[id] ?: return reply.error(Media3Errors.NO_PLAYER, "Unknown player", null)
                player.handle(call, reply)
            }
        }
    }

    /** One player's event channel; events from the looper reach Dart on main. */
    private class PlayerEvents(private val channel: EventChannel, private val main: Handler) :
        EventChannel.StreamHandler {
        private var sink: EventChannel.EventSink? = null
        private var disposed = false

        fun register() = channel.setStreamHandler(this)

        fun send(event: Map<String, Any?>) {
            main.post { if (!disposed) sink?.success(event) }
        }

        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
        override fun onCancel(arguments: Any?) { sink = null }

        fun dispose() {
            if (disposed) return
            disposed = true
            sink?.endOfStream()
            sink = null
            channel.setStreamHandler(null)
        }
    }

    /** Replies once, on the main thread. */
    private class MainResult(private val result: MethodChannel.Result, private val main: Handler) :
        MethodChannel.Result {
        private val replied = AtomicBoolean(false)

        private fun deliver(action: () -> Unit) {
            if (!replied.compareAndSet(false, true)) return
            if (Looper.myLooper() == main.looper) action() else main.post(action)
        }

        override fun success(value: Any?) = deliver { result.success(value) }
        override fun error(code: String, message: String?, details: Any?) =
            deliver { result.error(code, message, details) }
        override fun notImplemented() = deliver { result.notImplemented() }
    }

    private companion object {
        const val TAG = "Media3"
        const val CHANNEL = "com.zarz.mornye/media3_player"
    }
}
