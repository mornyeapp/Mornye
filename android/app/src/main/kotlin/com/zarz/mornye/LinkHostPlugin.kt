package com.zarz.mornye

import android.os.Handler
import android.os.Looper
import com.mornye.backend.LinkBridge
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Carries the `link*` calls and events of the phone's own Mornye Link server
 * (`LinkBridge`), used while "Share with other phones" is on. Belongs to the
 * shared engine, like Cast, so the server keeps answering while the app
 * plays without an Activity. Dart decides when it runs.
 */
internal class LinkHostPlugin : FlutterPlugin, EventChannel.StreamHandler {
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private val mainThread = Handler(Looper.getMainLooper())
    // A slow catalog load or server start must not hold back the replies
    // other phones are waiting for.
    private val workers = Executors.newFixedThreadPool(4) { Thread(it, "MornyeLinkHost") }
    private val bridge = lazy { LinkBridge() }
    @Volatile private var sink: EventChannel.EventSink? = null
    @Volatile private var pump: Thread? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods = MethodChannel(binding.binaryMessenger, "com.zarz.mornye/link")
        events = EventChannel(binding.binaryMessenger, "com.zarz.mornye/link/events")
        methods.setMethodCallHandler(::handle)
        events.setStreamHandler(this)
    }

    /** The method is the `link*` name; the arguments are its JSON text. */
    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? String ?: "{}"
        workers.execute {
            val reply = runCatching { bridge.value.call(call.method, arguments) }
            mainThread.post {
                reply.fold(
                    { result.success(it) },
                    { result.error("LINK_HOST", it.message, null) },
                )
            }
        }
    }

    /** Each event is the JSON text `{"method","arguments"}`. */
    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        this.sink = sink
        if (pump != null) return
        pump = Thread({
            val current = Thread.currentThread()
            while (pump === current) {
                val event = try {
                    bridge.value.nextEvent(1_000UL)
                } catch (error: Exception) {
                    // Only a closed bridge throws; the engine is going away.
                    break
                }
                if (event != null) mainThread.post { this.sink?.success(event) }
            }
        }, "MornyeLinkEvents").apply {
            isDaemon = true
            start()
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        pump = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        pump = null
        workers.execute {
            if (bridge.isInitialized()) {
                runCatching { bridge.value.call("linkStop", "{}") }
                bridge.value.close()
            }
        }
        workers.shutdown()
    }
}
