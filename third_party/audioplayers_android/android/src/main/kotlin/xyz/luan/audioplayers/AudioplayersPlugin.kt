package xyz.luan.audioplayers

import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import xyz.luan.audioplayers.player.SoundPoolManager
import xyz.luan.audioplayers.player.WrappedPlayer
import xyz.luan.audioplayers.source.BytesSource
import xyz.luan.audioplayers.source.UrlSource
import java.io.FileNotFoundException
import java.util.concurrent.ConcurrentHashMap

typealias FlutterHandler = (call: MethodCall, response: MethodChannel.Result) -> Unit

class AudioplayersPlugin : FlutterPlugin {
    private lateinit var methods: MethodChannel
    private lateinit var globalMethods: MethodChannel
    private lateinit var globalEvents: EventHandler
    private lateinit var context: Context
    private lateinit var binaryMessenger: BinaryMessenger
    private lateinit var soundPoolManager: SoundPoolManager

    private var players = ConcurrentHashMap<String, WrappedPlayer>()
    private var defaultAudioContext = AudioContextAndroid()
    private var playbackThread: HandlerThread? = null
    private var playbackHandler: Handler? = null
    @Volatile private var generation = 0

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        context = binding.applicationContext
        binaryMessenger = binding.binaryMessenger
        generation++
        players = ConcurrentHashMap()
        playbackThread = HandlerThread("mornye-audioplayers").apply { start() }
        playbackHandler = Handler(requireNotNull(playbackThread).looper)
        soundPoolManager = SoundPoolManager(this)
        methods = MethodChannel(binding.binaryMessenger, "xyz.luan/audioplayers")
        methods.setMethodCallHandler { call, response -> enqueue(call, response, ::methodHandler) }
        globalMethods = MethodChannel(binding.binaryMessenger, "xyz.luan/audioplayers.global")
        globalMethods.setMethodCallHandler { call, response -> enqueue(call, response, ::globalMethodHandler) }
        globalEvents = EventHandler(EventChannel(binding.binaryMessenger, "xyz.luan/audioplayers.global/events"))
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        generation++
        methods.setMethodCallHandler(null)
        globalMethods.setMethodCallHandler(null)
        val retiringPlayers = players
        val retiringPool = soundPoolManager
        val thread = playbackThread
        playbackHandler?.post {
            try {
                retiringPlayers.values.forEach { player ->
                    runCatching { player.dispose() }.onFailure {
                        Log.w("Audioplayers", "Could not release a retired player", it)
                    }
                }
                retiringPlayers.clear()
                runCatching { retiringPool.dispose() }.onFailure {
                    Log.w("Audioplayers", "Could not release a retired sound pool", it)
                }
            } finally {
                thread?.quitSafely()
            }
        }
        playbackHandler = null
        playbackThread = null
        globalEvents.dispose()
    }

    private fun enqueue(call: MethodCall, response: MethodChannel.Result, handler: FlutterHandler) {
        val epoch = generation
        val accepted = playbackHandler?.post {
            if (epoch == generation) safeCall(call, response, handler)
            else response.error("AndroidAudioError", "Audio engine was detached", null)
        } == true
        if (!accepted) response.error("AndroidAudioError", "Audio engine is not attached", null)
    }

    /** Capture the owner so late focus/load callbacks cannot enter a new engine. */
    fun playbackDispatcher(): (() -> Unit) -> Unit {
        val handler = playbackHandler ?: return { action -> action() }
        val epoch = generation
        return { action ->
            if (epoch == generation) {
                if (Looper.myLooper() == handler.looper) action()
                else handler.post { if (epoch == generation) action() }
            }
        }
    }

    private fun safeCall(
        call: MethodCall,
        response: MethodChannel.Result,
        handler: FlutterHandler,
    ) {
        try {
            handler(call, response)
        } catch (e: Throwable) {
            response.error("Unexpected AndroidAudioError", e.message, e.toString())
        }
    }

    private fun globalMethodHandler(call: MethodCall, response: MethodChannel.Result) {
        val currentPlayers = players
        when (call.method) {
            "init" -> {
                currentPlayers.values.forEach { it.dispose() }
                currentPlayers.clear()
            }

            "setAudioContext" -> {
                val audioContext = call.audioContext()
                val audioManager = getAudioManager()
                if (audioContext.audioMode != defaultAudioContext.audioMode) {
                    audioManager.mode = audioContext.audioMode
                }
                if (audioContext.isSpeakerphoneOn != defaultAudioContext.isSpeakerphoneOn) {
                    audioManager.isSpeakerphoneOn = audioContext.isSpeakerphoneOn
                }

                defaultAudioContext = audioContext
            }

            "emitLog" -> {
                val message = call.argument<String>("message") ?: error("message is required")
                handleGlobalLog(message)
            }

            "emitError" -> {
                val code = call.argument<String>("code") ?: error("code is required")
                val message = call.argument<String>("message") ?: error("message is required")
                handleGlobalError(code, message, null)
            }

            else -> {
                response.notImplemented()
                return
            }
        }

        response.success(1)
    }

    private fun methodHandler(call: MethodCall, response: MethodChannel.Result) {
        val currentPlayers = players
        val playerId = call.argument<String>("playerId") ?: return
        if (call.method == "create") {
            val eventHandler = EventHandler(EventChannel(binaryMessenger, "xyz.luan/audioplayers/events/$playerId"))
            currentPlayers[playerId] = WrappedPlayer(this, eventHandler, defaultAudioContext.copy(), soundPoolManager)
            // Dart listens as soon as this reply lands. Replying earlier leaves
            // the stream without a listener, and the prepared event never arrives.
            eventHandler.afterRegistration { response.success(1) }
            return
        }
        val player = getPlayer(playerId, currentPlayers)
        try {
            when (call.method) {
                "setEqualizer" -> {
                    val configuration = call.argument<Map<String, Any?>>("configuration")
                        ?: error("Equalizer configuration is required")
                    player.setEqualizer(configuration)
                }
                "setSourceUrl" -> {
                    val url = call.argument<String>("url") ?: error("url is required")
                    val isLocal = call.argument<Boolean>("isLocal") ?: false
                    try {
                        player.source = UrlSource(url, isLocal)
                    } catch (e: FileNotFoundException) {
                        response.error(
                            "AndroidAudioError",
                            "Failed to set source. For troubleshooting, see: " +
                                "https://github.com/bluefireteam/audioplayers/blob/main/troubleshooting.md",
                            e.toString(),
                        )
                        return
                    }
                }

                "setSourceBytes" -> {
                    val bytes = call.argument<ByteArray>("bytes") ?: error("bytes are required")
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                        error("BytesSource is not supported on Android <= M")
                    }
                    player.source = BytesSource(bytes)
                }

                "setNextPlayer" -> {
                    val nextId = call.argument<String>("nextPlayerId")
                    player.setNext(nextId?.let { getPlayer(it, currentPlayers) })
                }

                "resume" -> player.play()
                "pause" -> player.pause()
                "stop" -> player.stop()
                "release" -> player.release()
                "seek" -> {
                    val position = call.argument<Int>("position") ?: error("position is required")
                    player.seek(position)
                }

                "setVolume" -> {
                    val volume = call.argument<Double>("volume") ?: error("volume is required")
                    player.volume = volume.toFloat()
                }

                "setBalance" -> {
                    val balance = call.argument<Double>("balance") ?: error("balance is required")
                    player.balance = balance.toFloat()
                }

                "setPlaybackRate" -> {
                    val rate = call.argument<Double>("playbackRate") ?: error("playbackRate is required")
                    player.rate = rate.toFloat()
                }

                "getDuration" -> {
                    response.success(player.getDuration())
                    return
                }

                "getCurrentPosition" -> {
                    response.success(player.getCurrentPosition())
                    return
                }

                "setReleaseMode" -> {
                    val releaseMode = call.enumArgument<ReleaseMode>("releaseMode") ?: error("releaseMode is required")
                    player.releaseMode = releaseMode
                }

                "setPlayerMode" -> {
                    val playerMode = call.enumArgument<PlayerMode>("playerMode") ?: error("playerMode is required")
                    player.playerMode = playerMode
                }

                "setAudioContext" -> {
                    val audioContext = call.audioContext()
                    player.updateAudioContext(audioContext)
                }

                "emitLog" -> {
                    val message = call.argument<String>("message") ?: error("message is required")
                    player.handleLog(message)
                }

                "emitError" -> {
                    val code = call.argument<String>("code") ?: error("code is required")
                    val message = call.argument<String>("message") ?: error("message is required")
                    player.handleError(code, message, null)
                }

                "dispose" -> {
                    player.dispose()
                    currentPlayers.remove(playerId)
                }

                else -> {
                    response.notImplemented()
                    return
                }
            }
            response.success(1)
        } catch (e: Exception) {
            response.error("AndroidAudioError", e.message, e.toString())
        }
    }

    private fun getPlayer(playerId: String, currentPlayers: Map<String, WrappedPlayer>): WrappedPlayer {
        return currentPlayers[playerId] ?: error("Player has not yet been created or has already been disposed.")
    }

    fun getApplicationContext(): Context {
        return context.applicationContext
    }

    fun getAudioManager(): AudioManager {
        return context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    fun handleDuration(player: WrappedPlayer) {
        player.eventHandler.success(
            "audio.onDuration",
            hashMapOf("value" to (player.getDuration() ?: 0)),
        )
    }

    fun handleComplete(player: WrappedPlayer) {
        player.eventHandler.success("audio.onComplete")
    }

    fun handlePrepared(player: WrappedPlayer, isPrepared: Boolean) {
        player.eventHandler.success("audio.onPrepared", hashMapOf("value" to isPrepared))
    }

    fun handleLog(player: WrappedPlayer, message: String) {
        player.eventHandler.success("audio.onLog", hashMapOf("value" to message))
    }

    fun handleGlobalLog(message: String) {
        globalEvents.success("audio.onLog", hashMapOf("value" to message))
    }

    fun handleError(player: WrappedPlayer, errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        player.eventHandler.error(errorCode, errorMessage, errorDetails)
    }

    fun handleGlobalError(errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        globalEvents.error(errorCode, errorMessage, errorDetails)
    }

    fun handleSeekComplete(player: WrappedPlayer) {
        player.eventHandler.success("audio.onSeekComplete")
    }
}

private inline fun <reified T : Enum<T>> MethodCall.enumArgument(name: String): T? {
    val enumName = argument<String>(name) ?: return null
    return enumValueOf<T>(enumName.split('.').last().toConstantCase())
}

fun String.toConstantCase(): String {
    return replace(Regex("(.)(\\p{Upper})"), "$1_$2").replace(Regex("(.) (.)"), "$1_$2").uppercase()
}

private fun MethodCall.audioContext(): AudioContextAndroid {
    return AudioContextAndroid(
        isSpeakerphoneOn = argument<Boolean>("isSpeakerphoneOn") ?: error("isSpeakerphoneOn is required"),
        stayAwake = argument<Boolean>("stayAwake") ?: error("stayAwake is required"),
        contentType = argument<Int>("contentType") ?: error("contentType is required"),
        usageType = argument<Int>("usageType") ?: error("usageType is required"),
        audioFocus = argument<Int>("audioFocus") ?: error("audioFocus is required"),
        audioMode = argument<Int>("audioMode") ?: error("audioMode is required"),
    )
}

class EventHandler(private val eventChannel: EventChannel) : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == main.looper) action() else main.post { action() }
    }

    init {
        onMain { eventChannel.setStreamHandler(this) }
    }

    /** Runs [action] on the main thread, after the registration queued above. */
    fun afterRegistration(action: () -> Unit) = onMain(action)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun success(method: String, arguments: Map<String, Any> = HashMap()) {
        onMain { eventSink?.success(arguments + Pair("event", method)) }
    }

    fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        onMain { eventSink?.error(errorCode, errorMessage, errorDetails) }
    }

    fun dispose() {
        onMain {
            eventSink?.let {
                it.endOfStream()
                onCancel(null)
            }
            eventChannel.setStreamHandler(null)
        }
    }
}
