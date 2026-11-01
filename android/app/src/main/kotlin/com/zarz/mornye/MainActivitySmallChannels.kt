package com.zarz.mornye

import android.content.Intent
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal fun MainActivity.registerConcertCalendarChannel(messenger: BinaryMessenger) {
    concertCalendarChannel = MethodChannel(messenger, "com.zarz.mornye/concert_calendar").also { channel ->
        channel.setMethodCallHandler { call, result ->
            if (call.method != "add") {
                result.notImplemented()
            } else {
                val start = call.argument<Number>("start")?.toLong()
                if (start == null) {
                    result.success(false)
                } else {
                    val suppliedEnd = call.argument<Number>("end")?.toLong()
                    val end = suppliedEnd?.takeIf { it > start } ?: (start + 3600000)
                    try {
                        startActivity(Intent(Intent.ACTION_INSERT).apply {
                            data = android.provider.CalendarContract.Events.CONTENT_URI
                            putExtra(android.provider.CalendarContract.Events.TITLE, call.argument<String>("title"))
                            putExtra(android.provider.CalendarContract.Events.EVENT_LOCATION, call.argument<String>("location"))
                            putExtra(android.provider.CalendarContract.Events.DESCRIPTION, call.argument<String>("url"))
                            putExtra(android.provider.CalendarContract.EXTRA_EVENT_BEGIN_TIME, start)
                            putExtra(android.provider.CalendarContract.EXTRA_EVENT_END_TIME, end)
                        })
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
            }
        }
    }
}

internal fun MainActivity.registerAudioOutputChannel(messenger: BinaryMessenger) {
    audioOutputChannel = MethodChannel(messenger, "com.zarz.mornye/audio_output").also { channel ->
        channel.setMethodCallHandler { call, result ->
            if (call.method != "show") {
                result.notImplemented()
            } else {
                try {
                    val shown = Build.VERSION.SDK_INT >= 34 && try {
                        android.media.MediaRouter2.getInstance(this).showSystemOutputSwitcher()
                    } catch (_: Exception) {
                        false
                    }
                    if (!shown) {
                        // Older releases and unavailable system pickers still offer Bluetooth settings.
                        startActivity(Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS))
                    }
                    result.success(true)
                } catch (_: Exception) {
                    result.success(false)
                }
            }
        }
    }
}
