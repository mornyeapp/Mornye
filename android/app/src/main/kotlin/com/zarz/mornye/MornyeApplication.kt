package com.zarz.mornye

import android.app.Application
import com.ryanheise.audioservice.AudioServicePlugin

class MornyeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AppCrashReporter.initialize(this)
        // audio_service creates the cached engine before a FlutterFragment can
        // supply shell args, including when playback starts without an Activity.
        AudioServicePlugin.setFlutterEngineArguments(flutterRendererShellArgs())
        AudioServicePlugin.setFlutterEngineConfigurator(SharedEngineChannels::configure)
        AudioServicePlugin.setQueueArtResolver(CoverContentProvider.queueArtResolver(this))
        AudioServicePlugin.setResourceResolver { resource ->
            when (resource) {
                "mipmap/ic_launcher" -> R.mipmap.ic_launcher
                "drawable/ic_launcher_monochrome" -> R.drawable.ic_launcher_monochrome
                "drawable/ic_notification_mornye" -> R.drawable.ic_notification_mornye
                "drawable/ic_notification_airplay" -> R.drawable.ic_notification_airplay
                "drawable/ic_notification_star" -> R.drawable.ic_notification_star
                "drawable/ic_notification_star_filled" -> R.drawable.ic_notification_star_filled
                "drawable/ic_notification_shuffle" -> R.drawable.ic_notification_shuffle
                "drawable/ic_notification_shuffle_on" -> R.drawable.ic_notification_shuffle_on
                "drawable/ic_widget_previous" -> R.drawable.ic_widget_previous
                "drawable/ic_widget_next" -> R.drawable.ic_widget_next
                "drawable/ic_widget_play" -> R.drawable.ic_widget_play
                "drawable/ic_widget_pause" -> R.drawable.ic_widget_pause
                else -> 0
            }
        }
    }
}
