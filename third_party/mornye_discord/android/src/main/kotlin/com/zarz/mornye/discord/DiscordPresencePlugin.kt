package com.zarz.mornye.discord

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * The SDK reaches the Discord app through a service connection that it binds
 * with the activity it was given. Android releases that connection when the
 * activity is destroyed, while this plugin lives on with the shared Flutter
 * engine. A client therefore serves one activity: a new activity gets a new
 * client, and so does a client whose updates keep failing.
 */
class DiscordPresencePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private val handler = Handler(Looper.getMainLooper())
    private var activity: Activity? = null
    private var clientActivity = WeakReference<Activity>(null)
    private var clientStartedAt = 0L
    private var running = false
    private var loaded = false
    private var lastStatus = -1
    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            val status = nativeTick()
            if (status != lastStatus) {
                lastStatus = status
                channel.invokeMethod("status", when (status) {
                    1 -> "active"
                    2 -> "unavailable"
                    else -> "ready"
                })
            }
            handler.postDelayed(this, 100)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.zarz.mornye/discord")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "initialize" -> {
                    val host = activity
                    if (host == null) { result.success(false); return }
                    // Only load/start the SDK after the user enables presence.
                    if (!running) {
                        running = startClient(host)
                        lastStatus = -1
                        if (running) handler.post(tick)
                    }
                    result.success(running)
                }
                "update" -> {
                    renewFailedClient()
                    if (running) nativeUpdate(
                        call.argument<String>("title") ?: "",
                        call.argument<String>("state") ?: "",
                        call.argument<String>("album") ?: "",
                        call.argument<String>("artwork") ?: "",
                        call.argument<Number>("start")?.toLong() ?: 0L,
                        call.argument<Number>("end")?.toLong() ?: 0L,
                    )
                    result.success(null)
                }
                "clear" -> { if (running) nativeClear(); result.success(null) }
                "shutdown" -> { stop(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (_: ClassNotFoundException) {
            result.success(false)
        } catch (_: LinkageError) {
            result.error("sdk_unavailable", "Discord SDK is unavailable in this build.", null)
        } catch (_: Exception) {
            result.error("discord_unavailable", "Unable to connect to Discord.", null)
        }
    }

    /** Hands [host] to the SDK and creates the client that binds through it. */
    private fun startClient(host: Activity): Boolean {
        val init = Class.forName("com.discord.socialsdk.DiscordSocialSdkInit")
        init.getMethod("setEngineActivity", Activity::class.java).invoke(null, host)
        if (!loaded) { System.loadLibrary("mornye_discord"); loaded = true }
        clientActivity = WeakReference(host)
        clientStartedAt = SystemClock.elapsedRealtime()
        return nativeStart()
    }

    /** Replaces the client with one on [host]. False stops presence. */
    private fun renewClient(host: Activity): Boolean {
        try {
            nativeStop()
            running = startClient(host)
        } catch (_: Exception) {
            running = false
        } catch (_: LinkageError) {
            running = false
        }
        if (!running) {
            handler.removeCallbacks(tick)
            lastStatus = 2
            channel.invokeMethod("status", "unavailable")
        }
        return running
    }

    /**
     * Before an update that follows a failed one: a client whose connection
     * died for good (the Discord app was updated or force stopped) never
     * recovers, a new one does. Not more often than every two minutes, and
     * only while there is a Discord app to connect to.
     */
    private fun renewFailedClient() {
        val host = activity ?: return
        if (!running || lastStatus != 2) return
        if (SystemClock.elapsedRealtime() - clientStartedAt < CLIENT_RENEWAL_MS) return
        if (!discordInstalled(host)) return
        // The update that follows reports its own result; "ready" in between
        // would only make the app send the song twice.
        if (renewClient(host)) lastStatus = 0
    }

    private fun discordInstalled(host: Activity): Boolean = try {
        host.packageManager.getPackageInfo("com.discord", 0)
        true
    } catch (_: Exception) {
        false
    }

    private fun stop() {
        handler.removeCallbacks(tick)
        if (running) nativeStop()
        running = false
        lastStatus = -1
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        val host = binding.activity
        activity = host
        if (!running) {
            // Presence that was switched on while no activity existed (playback
            // started from a notification, a widget or a car) can start now.
            channel.invokeMethod("status", "available")
            return
        }
        if (clientActivity.get() === host) return
        // The connection of the previous activity is gone. "ready" makes the
        // app send the current song to the new client.
        if (renewClient(host)) lastStatus = -1
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onDetachedFromActivity() { activity = null }

    private external fun nativeStart(): Boolean
    private external fun nativeTick(): Int
    private external fun nativeUpdate(title: String, artist: String, album: String, artwork: String, start: Long, end: Long)
    private external fun nativeClear()
    private external fun nativeStop()

    private companion object {
        const val CLIENT_RENEWAL_MS = 120_000L
    }
}
