package com.zarz.mornye

import android.app.Activity
import android.content.Context
import android.net.Uri
import android.net.wifi.WifiManager
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
import com.google.android.gms.common.images.WebImage
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** Belongs to the shared engine so a detached Activity does not stop TV playback. */
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

    private val progress = RemoteMediaClient.ProgressListener { _, _ -> publish() }
    private val volumeListener = object : Cast.Listener() {
        override fun onVolumeChanged() = publish()
    }
    private val mediaCallback = object : RemoteMediaClient.Callback() {
        override fun onStatusUpdated() = publish()
        override fun onMetadataUpdated() = publish()
        override fun onMediaError(error: com.google.android.gms.cast.MediaError) {
            sink?.success(snapshot() + mapOf("error" to "Cast receiver could not play this file"))
        }
    }
    private val sessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarted(session: CastSession, id: String) = attach(session)
        override fun onSessionResumed(session: CastSession, suspended: Boolean) = attach(session)
        override fun onSessionEnded(session: CastSession, error: Int) = detach()
        override fun onSessionStartFailed(session: CastSession, error: Int) = detach()
        override fun onSessionResumeFailed(session: CastSession, error: Int) = detach()
        override fun onSessionSuspended(session: CastSession, reason: Int) {
            sink?.success(snapshot() + mapOf("suspended" to true))
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
            when (call.method) {
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
                        else result.error("CAST_LOAD", "TV rejected audio (${reply.status.statusCode})", null)
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
        if (wifiLock == null) {
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
        publish()
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
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        sink?.success(mapOf("connected" to false))
    }

    private fun snapshot(): Map<String, Any?> {
        val session = cast?.sessionManager?.currentCastSession
        val status = client?.mediaStatus
        return mapOf(
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

    private fun publish() { sink?.success(snapshot()) }
    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        this.sink = sink
        publish()
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
    }
}
