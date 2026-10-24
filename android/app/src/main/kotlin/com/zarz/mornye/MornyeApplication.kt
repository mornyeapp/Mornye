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
    }
}
