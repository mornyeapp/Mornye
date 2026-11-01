package com.zarz.mornye

import android.content.Context
import androidx.annotation.Keep
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.cast.framework.media.CastMediaOptions

@Keep
class MornyeCastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions = CastOptions.Builder()
        .setReceiverApplicationId(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID)
        // Mornye's audio_service session keeps the queue and notification controls.
        .setCastMediaOptions(CastMediaOptions.Builder()
            .setMediaSessionEnabled(false)
            .setNotificationOptions(null)
            .build())
        // A process restart cannot restore the temporary local media server.
        .setResumeSavedSession(false)
        .setStopReceiverApplicationWhenEndingSession(true)
        .build()

    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}
