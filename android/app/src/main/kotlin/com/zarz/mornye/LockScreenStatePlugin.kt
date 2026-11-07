package com.zarz.mornye

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel

/**
 * Tells Dart whether the lock screen is showing: the screen is on and the
 * keyguard is up. Lyrics on the lock screen follow it, so the notification
 * keeps the song's title while the phone is unlocked or its screen is off.
 * The receiver is only registered while Dart listens.
 */
class LockScreenStatePlugin : FlutterPlugin, EventChannel.StreamHandler {
    private lateinit var channel: EventChannel
    private lateinit var context: Context
    private var sink: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null
    private var showing: Boolean? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = EventChannel(binding.binaryMessenger, "com.zarz.mornye/lock_screen")
        channel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setStreamHandler(null)
        onCancel(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        showing = null
        if (receiver == null) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    when (intent.action) {
                        // The keyguard can still report itself locked while
                        // it animates away, so an unlock is taken as given.
                        Intent.ACTION_USER_PRESENT, Intent.ACTION_SCREEN_OFF -> publish(false)
                        else -> publish()
                    }
                }
            }
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_USER_PRESENT)
            }
            if (Build.VERSION.SDK_INT >= 33) {
                // System UI sends USER_PRESENT from its own app uid, which a
                // not-exported receiver never gets. All three actions are
                // protected broadcasts that no other app can send.
                context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(receiver, filter)
            }
            this.receiver = receiver
        }
        publish()
    }

    override fun onCancel(arguments: Any?) {
        receiver?.let { runCatching { context.unregisterReceiver(it) } }
        receiver = null
        sink = null
    }

    private fun publish(now: Boolean = currentlyShowing()) {
        if (now == showing) return
        showing = now
        sink?.success(now)
    }

    private fun currentlyShowing(): Boolean {
        val power = context.getSystemService(PowerManager::class.java)
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        return power?.isInteractive == true && keyguard?.isKeyguardLocked == true
    }
}
