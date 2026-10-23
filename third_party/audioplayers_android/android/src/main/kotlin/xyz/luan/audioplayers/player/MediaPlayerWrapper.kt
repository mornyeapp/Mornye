package xyz.luan.audioplayers.player

import android.media.MediaPlayer
import android.os.Build
import android.os.PowerManager
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.source.Source

class MediaPlayerWrapper(
    private val wrappedPlayer: WrappedPlayer,
) : PlayerWrapper {
    private val mediaPlayer = createMediaPlayer(wrappedPlayer)
    private var equalizer: PlaybackEqualizer? = null
    private var playbackParamsApplied = false

    fun setEqualizer(configuration: Map<String, Any?>) {
        if (Build.VERSION.SDK_INT < 28) {
            check(configuration["enabled"] != true) { "Equalizer requires Android 9 or later" }
            return
        }
        if (configuration["enabled"] == true && equalizer == null) {
            equalizer = PlaybackEqualizer(mediaPlayer.audioSessionId)
        }
        try {
            equalizer?.configure(configuration)
        } catch (error: Exception) {
            equalizer?.close()
            equalizer = null
            throw error
        }
    }

    private fun createMediaPlayer(wrappedPlayer: WrappedPlayer): MediaPlayer {
        val mediaPlayer = MediaPlayer().apply {
            setOnPreparedListener { wrappedPlayer.onPrepared() }
            setOnCompletionListener { wrappedPlayer.onCompletion() }
            setOnSeekCompleteListener { wrappedPlayer.onSeekComplete() }
            setOnErrorListener { _, what, extra -> wrappedPlayer.onError(what, extra) }
            setOnBufferingUpdateListener { _, percent -> wrappedPlayer.onBuffering(percent) }
        }
        wrappedPlayer.context.setAttributesOnPlayer(mediaPlayer)
        if (wrappedPlayer.context.stayAwake) {
            mediaPlayer.setWakeMode(wrappedPlayer.applicationContext, PowerManager.PARTIAL_WAKE_LOCK)
        }
        return mediaPlayer
    }

    override fun getDuration(): Int? {
        // media player returns -1 if the duration is unknown
        return mediaPlayer.duration.takeUnless { it == -1 }
    }

    override fun getCurrentPosition(): Int {
        return mediaPlayer.currentPosition
    }

    override fun setVolume(leftVolume: Float, rightVolume: Float) {
        mediaPlayer.setVolume(leftVolume, rightVolume)
    }

    override fun setRate(rate: Float) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            // Normal playback does not need the platform's time-stretch path.
            // Once changed, still apply 1.0 to restore the original speed.
            if (rate == 1.0f && !playbackParamsApplied) return
            mediaPlayer.playbackParams = mediaPlayer.playbackParams.setSpeed(rate)
            playbackParamsApplied = true
        } else if (rate != 1.0f) {
            error("Changing the playback rate is only available for Android M/23+ or using LOW_LATENCY mode.")
        }
    }

    override fun setSource(source: Source) {
        reset()
        source.setForMediaPlayer(mediaPlayer)
    }

    override fun setLooping(looping: Boolean) {
        mediaPlayer.isLooping = looping
    }

    override fun start() {
        setRate(wrappedPlayer.rate)
        // Do not depend on setPlaybackParams implicitly starting the output.
        mediaPlayer.start()
    }

    override fun pause() {
        mediaPlayer.pause()
    }

    override fun stop() {
        mediaPlayer.stop()
    }

    override fun release() {
        if (Build.VERSION.SDK_INT >= 28) equalizer?.close()
        equalizer = null
        mediaPlayer.reset()
        mediaPlayer.release()
    }

    override fun seekTo(position: Int) {
        mediaPlayer.seekTo(position)
    }

    override fun updateContext(context: AudioContextAndroid) {
        context.setAttributesOnPlayer(mediaPlayer)
        if (context.stayAwake) {
            mediaPlayer.setWakeMode(wrappedPlayer.applicationContext, PowerManager.PARTIAL_WAKE_LOCK)
        }
    }

    override fun prepare() {
        mediaPlayer.prepareAsync()
    }

    override fun reset() {
        if (Build.VERSION.SDK_INT >= 28) equalizer?.close()
        equalizer = null
        mediaPlayer.reset()
    }

    override fun isLiveStream(): Boolean {
        val duration = getDuration()
        return duration == null || duration == 0
    }
}
