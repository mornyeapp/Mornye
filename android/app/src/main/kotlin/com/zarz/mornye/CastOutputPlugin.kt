package com.zarz.mornye

import android.app.Activity
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import android.view.ViewGroup
import androidx.appcompat.view.ContextThemeWrapper
import androidx.fragment.app.FragmentActivity
import androidx.mediarouter.app.MediaRouteButton
import com.google.android.gms.cast.Cast
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaSeekOptions
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastButtonFactory
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.images.WebImage
import com.mornye.backend.CastBridge
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Belongs to the shared engine so a detached Activity does not stop TV playback.
 * Google Cast runs on Google's SDK; the other kinds and the media server run on
 * the Rust sender (`CastBridge`). One session lives at a time, and its snapshots
 * are the only ones Dart sees. State below is touched on the main thread only.
 */
internal class CastOutputPlugin : FlutterPlugin, ActivityAware, EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var activity: Activity? = null
    private var sink: EventChannel.EventSink? = null
    private var cast: CastContext? = null
    private var client: RemoteMediaClient? = null
    private var boundSession: CastSession? = null
    private var revision = 0
    private var wifiLock: WifiManager.WifiLock? = null
    private var handoverLock: PowerManager.WakeLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val mainThread = Handler(Looper.getMainLooper())
    private val mediaWorker = Executors.newSingleThreadExecutor { Thread(it, "MornyeCastMedia") }
    // Session calls wait for the receiver; they must not hold back media requests.
    private val sessionWorker = Executors.newSingleThreadExecutor { Thread(it, "MornyeCastSession") }
    private val bridge = lazy { CastBridge() }
    @Volatile private var pump: Thread? = null
    /** From a Rust connect until that session ends or Google's starts. */
    private var rustOwns = false
    private var rustConnecting = 0
    private var rustConnected = false

    private val progress = RemoteMediaClient.ProgressListener { _, _ -> publish() }
    private val volumeListener = object : Cast.Listener() {
        override fun onVolumeChanged() = publish()
    }
    private val mediaCallback = object : RemoteMediaClient.Callback() {
        override fun onStatusUpdated() {
            val status = client?.mediaStatus
            if (status?.playerState == MediaStatus.PLAYER_STATE_IDLE &&
                status.idleReason == MediaStatus.IDLE_REASON_FINISHED
            ) {
                holdForHandover()
            }
            publish()
        }
        override fun onMetadataUpdated() = publish()
        override fun onMediaError(error: com.google.android.gms.cast.MediaError) {
            // Reported for the logs only: a receiver that really stopped says so
            // with its idle reason, which the snapshot carries as "failed".
            if (!rustOwns) sink?.success(
                snapshot() + mapOf("mediaError" to "reason=${error.reason} code=${error.detailedErrorCode}"),
            )
        }
    }
    private val sessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarted(session: CastSession, id: String) = attach(session)
        override fun onSessionResumed(session: CastSession, suspended: Boolean) = attach(session)
        override fun onSessionEnded(session: CastSession, error: Int) = detach()
        override fun onSessionStartFailed(session: CastSession, error: Int) = detach()
        override fun onSessionResumeFailed(session: CastSession, error: Int) = detach()
        override fun onSessionSuspended(session: CastSession, reason: Int) {
            if (!rustOwns) sink?.success(snapshot() + mapOf("suspended" to true))
        }
        override fun onSessionStarting(session: CastSession) {}
        override fun onSessionEnding(session: CastSession) {}
        override fun onSessionResuming(session: CastSession, id: String) {}
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "com.zarz.mornye/cast")
        events = EventChannel(binding.binaryMessenger, "com.zarz.mornye/cast/events")
        methods.setMethodCallHandler(::handle)
        events.setStreamHandler(this)
    }

    private fun initialize(): CastContext {
        cast?.let { return it }
        val instance = CastContext.getSharedInstance(context)
        cast = instance
        instance.sessionManager.addSessionManagerListener(sessionListener, CastSession::class.java)
        instance.sessionManager.currentCastSession?.takeIf { it.isConnected }?.let(::attach)
        return instance
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            if (rustOwns && call.method in RUST_SESSION_METHODS) {
                rustSession(call, result)
                return
            }
            when (call.method) {
                "discover" -> discover(call, result)
                "devices" -> rust("devices", "{}", sessionWorker, result, ::withoutGoogleCast)
                "connect" -> connectRust(call, result)
                "state" -> result.success(snapshot())
                "show" -> {
                    val host = activity as? FragmentActivity
                        ?: throw IllegalStateException("Open Mornye to choose a TV")
                    initialize()
                    val button = MediaRouteButton(ContextThemeWrapper(
                        host, androidx.appcompat.R.style.Theme_AppCompat_DayNight))
                    button.dialogFactory = MornyeCastDialogs
                    CastButtonFactory.setUpMediaRouteButton(host, button)
                    // MediaRouteButton refuses to show a dialog until attached to a window.
                    val root = host.window.decorView as ViewGroup
                    root.addView(button, ViewGroup.LayoutParams(0, 0))
                    try {
                        result.success(button.showDialog())
                    } finally {
                        root.removeView(button)
                    }
                }
                "disconnect" -> {
                    cast?.sessionManager?.endCurrentSession(true)
                    result.success(null)
                }
                "load" -> {
                    val remote = connectedClient()
                    holdForHandover()
                    val metadata = MediaMetadata(MediaMetadata.MEDIA_TYPE_MUSIC_TRACK).apply {
                        putString(MediaMetadata.KEY_TITLE, call.argument<String>("title") ?: "")
                        putString(MediaMetadata.KEY_ARTIST, call.argument<String>("artist") ?: "")
                        putString(MediaMetadata.KEY_ALBUM_TITLE, call.argument<String>("album") ?: "")
                        call.argument<String>("artwork")?.let { addImage(WebImage(Uri.parse(it))) }
                    }
                    val media = MediaInfo.Builder(requireNotNull(call.argument<String>("url")))
                        .setContentType(requireNotNull(call.argument<String>("mime")))
                        .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
                        .setMetadata(metadata)
                        .setCustomData(JSONObject().put("mornyeToken", call.argument<Number>("token")))
                    call.argument<Number>("duration")?.toLong()?.takeIf { it > 0 }?.let {
                        media.setStreamDuration(it)
                    }
                    remote.load(MediaLoadRequestData.Builder().setMediaInfo(media.build())
                        .setAutoplay(false).build()).setResultCallback { reply ->
                        if (reply.status.isSuccess) result.success(null)
                        else result.error("CAST_LOAD", loadFailure(reply.status.statusCode), null)
                    }
                }
                "play", "pause", "stop", "seek" -> {
                    val remote = connectedClient()
                    val pending = when (call.method) {
                        "play" -> remote.play()
                        "pause" -> remote.pause()
                        "stop" -> remote.stop()
                        else -> remote.seek(MediaSeekOptions.Builder()
                            .setPosition(call.argument<Number>("position")?.toLong() ?: 0).build())
                    }
                    pending.setResultCallback { reply ->
                        if (reply.status.isSuccess) result.success(null)
                        else result.error("CAST_TRANSPORT", "TV command failed (${reply.status.statusCode})", null)
                    }
                }
                "serve", "register", "clearMedia", "closeMedia" -> media(call, result)
                "position" -> result.success(client?.approximateStreamPosition ?: 0)
                "volume" -> {
                    val session = cast?.sessionManager?.currentCastSession
                        ?: throw IllegalStateException("TV is disconnected")
                    session.volume = (call.argument<Number>("volume")?.toDouble() ?: 0.0).coerceIn(0.0, 1.0)
                    publish()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("CAST_UNAVAILABLE", error.message, null)
        }
    }

    /** The TV streams from the Rust media server (`mornye-cast`), off the UI isolate. */
    private fun media(call: MethodCall, result: MethodChannel.Result) =
        rust(call.method, arguments(call), mediaWorker, result, code = "CAST_MEDIA")

    /** Runs a Rust method on [worker]; [done] and [result] run on the main thread. */
    private fun rust(
        method: String,
        arguments: String,
        worker: ExecutorService,
        result: MethodChannel.Result?,
        transform: (Any?) -> Any? = { it },
        code: String = "CAST_UNAVAILABLE",
        done: (Result<Any?>) -> Unit = {},
    ) {
        worker.execute {
            val reply = runCatching {
                plain(JSONObject("{\"v\":${bridge.value.call(method, arguments)}}").opt("v"))
            }
            mainThread.post {
                done(reply)
                reply.fold(
                    { result?.success(transform(it)) },
                    { result?.error(code, it.message, null) },
                )
            }
        }
    }

    private fun arguments(call: MethodCall): String =
        JSONObject((call.arguments as? Map<*, *>) ?: emptyMap<String, Any?>()).toString()

    /** Looks for the kinds Google's dialog does not offer; Dart filters by kind too. */
    private fun discover(call: MethodCall, result: MethodChannel.Result) {
        val on = call.argument<Boolean>("on") == true
        setMulticast(on)
        if (!on && !bridge.isInitialized()) {
            result.success(null)
            return
        }
        val kinds = (call.argument<List<Any?>>("kinds") ?: RUST_KINDS).filter { it != "cast" }
        if (on && kinds.isEmpty()) {
            result.success(null)
            return
        }
        val request = JSONObject().put("on", on)
        if (on) {
            request.put("kinds", JSONArray(kinds))
            listenToRust()
        }
        rust("discover", request.toString(), sessionWorker, result)
    }

    /** Ends a Google Cast session first: Dart sees the switch as a disconnect. */
    private fun connectRust(call: MethodCall, result: MethodChannel.Result) {
        val google = cast?.sessionManager?.currentCastSession
        rustOwns = true
        rustConnecting++
        if (google != null) {
            sink?.success(mapOf("connected" to false))
            cast?.sessionManager?.endCurrentSession(true)
        }
        listenToRust()
        rust("connect", arguments(call), sessionWorker, result) { reply ->
            val connected = reply.isSuccess
            rustConnecting--
            if (!rustOwns) {
                // Google's session started meanwhile and owns the output.
                if (connected) rust("disconnect", "{}", sessionWorker, null)
            } else if (!connected && rustConnecting == 0 && !rustConnected) {
                rustOwns = false
                publish()
            }
        }
    }

    private fun rustSession(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> holdForHandover()
            "disconnect" -> {
                rust("disconnect", "{}", sessionWorker, result) {
                    // Rust's last snapshot may come after this; Dart hears the end now.
                    if (rustOwns && rustConnecting == 0) {
                        rustOwns = false
                        publish()
                    }
                }
                return
            }
        }
        rust(call.method, arguments(call), sessionWorker, result)
    }

    /** Pulls Rust's events on a daemon thread until the engine goes away. */
    private fun listenToRust() {
        if (pump != null) return
        pump = Thread({
            val current = Thread.currentThread()
            while (pump === current) {
                val text = try {
                    bridge.value.nextEvent(1_000UL)
                } catch (error: Exception) {
                    // A bridge that failed to start or was closed.
                    Log.w("MornyeCast", "Cast events stopped", error)
                    break
                }
                if (text == null) continue
                val event = runCatching { JSONObject(text) }.getOrNull() ?: continue
                val payload = plain(event.opt("payload")) as? Map<*, *> ?: continue
                val name = event.optString("event")
                mainThread.post { receiveRust(name, payload) }
            }
            mainThread.post { if (pump === current) pump = null }
        }, "MornyeCastEvents").apply {
            isDaemon = true
            start()
        }
    }

    private fun receiveRust(event: String, payload: Map<*, *>) {
        when (event) {
            "castDevices" -> sink?.success(mapOf("devices" to withoutGoogleCast(payload["devices"])))
            "castStatus" -> {
                val live = payload["connected"] == true
                rustConnected = live
                updateWifiLock()
                if (!live && boundSession == null) handoverLock?.let { if (it.isHeld) it.release() }
                if (!rustOwns) return
                if (live && payload["finished"] == true) holdForHandover()
                if (!live && rustConnecting == 0) rustOwns = false
                sink?.success(payload)
            }
        }
    }

    /** Google's dialog lists Google Cast; a device without a kind is one. */
    private fun withoutGoogleCast(devices: Any?): List<Any?> =
        (devices as? List<*>).orEmpty().filter {
            val kind = (it as? Map<*, *>)?.get("kind")
            kind != null && kind != "cast"
        }

    /** Many Wi-Fi drivers drop multicast, where SSDP and mDNS answers arrive, without it. */
    private fun setMulticast(on: Boolean) {
        try {
            if (on) {
                val lock = multicastLock
                    ?: (context.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                        .createMulticastLock("Mornye:CastDiscovery")
                        .apply { setReferenceCounted(false) }
                        .also { multicastLock = it }
                if (!lock.isHeld) lock.acquire()
            } else {
                multicastLock?.let { if (it.isHeld) it.release() }
            }
        } catch (error: RuntimeException) {
            Log.w("MornyeCast", "Could not change the multicast lock", error)
        }
    }

    /**
     * A TV that cannot fetch the audio from this device keeps trying and never
     * answers the load, which Google Cast reports as a timeout.
     */
    private fun loadFailure(code: Int): String {
        if (code != CommonStatusCodes.TIMEOUT) return "TV rejected audio ($code)"
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val vpn = try {
            connectivity?.getNetworkCapabilities(connectivity.activeNetwork)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        } catch (_: RuntimeException) {
            false
        }
        return "The TV could not reach this device. " + if (vpn) {
            "Allow local network devices in your VPN app, or turn the VPN off."
        } else {
            "Check that both are on the same Wi-Fi network."
        }
    }

    private fun connectedClient(): RemoteMediaClient =
        cast?.sessionManager?.currentCastSession?.takeIf { it.isConnected }?.remoteMediaClient
            ?: throw IllegalStateException("TV is disconnected")

    private fun attach(session: CastSession) {
        clearClient()
        revision++
        boundSession = session
        session.addCastListener(volumeListener)
        client = session.remoteMediaClient
        client?.registerCallback(mediaCallback)
        client?.addProgressListener(progress, 500)
        if (rustOwns || rustConnected) {
            // A Google Cast device chosen in Google's dialog ends the Rust session.
            rustOwns = false
            rust("disconnect", "{}", sessionWorker, null)
        }
        updateWifiLock()
        publish()
    }

    /** Held while either kind of session is connected. */
    private fun updateWifiLock() {
        val live = boundSession != null || rustConnected
        if (!live) {
            wifiLock?.let { if (it.isHeld) it.release() }
            wifiLock = null
            return
        }
        if (wifiLock != null) return
        try {
            val wifi = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "Mornye:Cast").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (error: RuntimeException) {
            Log.w("MornyeCast", "Could not keep Wi-Fi active for Cast", error)
        }
    }

    /**
     * Keeps the CPU awake while the next song loads. The playback wake lock is
     * released when a song ends, and the TV needs seconds to fetch the next one
     * from this device.
     */
    private fun holdForHandover() {
        try {
            val lock = handoverLock
                ?: (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Mornye:CastHandover")
                    .apply { setReferenceCounted(false) }
                    .also { handoverLock = it }
            lock.acquire(HANDOVER_WAKE_MS)
        } catch (error: RuntimeException) {
            Log.w("MornyeCast", "Could not stay awake for the next song", error)
        }
    }

    private fun clearClient() {
        boundSession?.removeCastListener(volumeListener)
        boundSession = null
        client?.unregisterCallback(mediaCallback)
        client?.removeProgressListener(progress)
        client = null
    }

    private fun detach() {
        clearClient()
        updateWifiLock()
        if (!rustConnected) handoverLock?.let { if (it.isHeld) it.release() }
        if (!rustOwns) sink?.success(mapOf("connected" to false))
    }

    private fun snapshot(): Map<String, Any?> {
        val session = cast?.sessionManager?.currentCastSession
        val status = client?.mediaStatus
        return mapOf(
            "kind" to "cast",
            "connected" to (session?.isConnected == true || session?.isSuspended == true),
            "deviceId" to session?.castDevice?.deviceId,
            "revision" to revision,
            "deviceName" to session?.castDevice?.friendlyName,
            "host" to session?.castDevice?.inetAddress?.hostAddress,
            "volume" to session?.volume,
            "token" to status?.mediaInfo?.customData?.optLong("mornyeToken"),
            "position" to (client?.approximateStreamPosition ?: 0),
            "duration" to (client?.streamDuration ?: 0),
            "state" to status?.playerState,
            "finished" to (status?.idleReason == MediaStatus.IDLE_REASON_FINISHED),
            "failed" to (status?.idleReason == MediaStatus.IDLE_REASON_ERROR),
        )
    }

    /** Google's snapshot, unless the Rust session owns the output. */
    private fun publish() {
        if (!rustOwns) sink?.success(snapshot())
    }

    /** JSON from Rust as the maps, lists and values the event channel sends. */
    private fun plain(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { plain(value.opt(it)) }
        is JSONArray -> List(value.length()) { plain(value.opt(it)) }
        JSONObject.NULL -> null
        else -> value
    }

    private companion object {
        /** Longer than the app's own limit for a load. */
        const val HANDOVER_WAKE_MS = 60_000L

        /** What Rust looks for on Android when Dart names no kinds. */
        val RUST_KINDS = listOf("dlna", "fcast", "roku")

        /** Calls that go to the Rust session while it owns the output. */
        val RUST_SESSION_METHODS = setOf(
            "state", "position", "load", "play", "pause", "stop", "seek", "volume", "disconnect",
        )
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        this.sink = sink
        if (!rustOwns) {
            publish()
            return
        }
        rust("state", "{}", sessionWorker, null) { reply ->
            val state = reply.getOrNull()
            if (rustOwns && state is Map<*, *>) this.sink?.success(state)
        }
    }
    override fun onCancel(arguments: Any?) { sink = null }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onDetachedFromActivity() { activity = null }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        cast?.sessionManager?.removeSessionManagerListener(sessionListener, CastSession::class.java)
        cast?.sessionManager?.endCurrentSession(true)
        detach()
        sink = null
        cast = null
        pump = null
        setMulticast(false)
        // Closing the bridge ends its session and media server.
        mediaWorker.shutdown()
        sessionWorker.execute { if (bridge.isInitialized()) bridge.value.close() }
        sessionWorker.shutdown()
    }
}
