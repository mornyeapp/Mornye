@file:OptIn(UnstableApi::class)

package com.zarz.mornye

import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionParameters.AudioOffloadPreferences
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.audio.MediaCodecAudioRenderer
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.MediaSource
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Audio-only renderers for the media3 engine.
 *
 * High resolution: float output is on, and speed goes through the platform
 * `AudioTrack.setPlaybackParams` (audio output playback parameters). In
 * media3 1.9.2 `DefaultAudioSink` sends 24/32-bit PCM to a float
 * `AudioTrack` only with float output enabled; otherwise the decoder is asked
 * for 16-bit PCM and the low bits are lost. With float output its audio
 * processor chain (Sonic) is skipped for that PCM, so Sonic speed changes
 * would silently not apply; the platform playback parameters change speed
 * for every format instead, the same time-stretch MediaPlayer uses for
 * `setPlaybackParams(setSpeed)`. The `DynamicsProcessing` equalizer is an
 * effect on the session in the platform mixer and works with either PCM
 * format, since offload stays disabled.
 */
internal fun media3AudioRenderers(context: Context) = RenderersFactory { handler, _, audioListener, _, _ ->
    val sink = DefaultAudioSink.Builder(context)
        .setEnableFloatOutput(true)
        .setEnableAudioOutputPlaybackParameters(true)
        .build()
    arrayOf(MediaCodecAudioRenderer(context, MediaCodecSelector.DEFAULT, handler, audioListener, sink))
}

/**
 * One media3 player of the `com.zarz.mornye/media3_player` channel. Every
 * method runs on the plugin's playback looper, which also owns the player.
 * [emit] delivers events to Dart; [MethodChannel.Result] calls are expected
 * to reach the main thread on their own.
 */
internal class Media3Player(
    context: Context,
    looper: Looper,
    private val emit: (Map<String, Any?>) -> Unit,
) : Player.Listener {
    private class Item(val id: String, val descriptor: DescriptorSource?, val volume: Double?) {
        var prepared = false

        /** The queued item's load failed for good: a [PlaybackException] code. */
        var failedCode: Int? = null
    }

    private val appContext = context.applicationContext
    private val handler = Handler(looper)
    private val sources = Media3SourceFactory(appContext)
    private val queue = Media3Queue<Item> { it.id }
    private val exo: ExoPlayer
    val sessionId: Int
    private var pending: MethodChannel.Result? = null
    private var stopped = false
    private var lastState: String? = null
    private var lastDurationMs: Long? = null
    private var nextItem = 0L
    private var equalizer: PlaybackEqualizer? = null
    private var released = false

    init {
        exo = ExoPlayer.Builder(appContext, media3AudioRenderers(appContext))
            .setLooper(looper)
            // The app owns focus (audio_session) and becoming-noisy handling.
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                false,
            )
            .setHandleAudioBecomingNoisy(false)
            .setSkipSilenceEnabled(false)
            .setWakeMode(C.WAKE_MODE_NONE)
            .build()
        exo.trackSelectionParameters = exo.trackSelectionParameters.buildUpon()
            .setAudioOffloadPreferences(
                AudioOffloadPreferences.Builder()
                    .setAudioOffloadMode(AudioOffloadPreferences.AUDIO_OFFLOAD_MODE_DISABLED)
                    .build(),
            )
            .build()
        exo.repeatMode = Player.REPEAT_MODE_OFF
        exo.shuffleModeEnabled = false
        // Set before any source, so the equalizer can attach before playback.
        val generated = appContext.getSystemService(AudioManager::class.java)?.generateAudioSessionId()
            ?: AudioManager.ERROR
        if (generated != AudioManager.ERROR) exo.audioSessionId = generated
        sessionId = exo.audioSessionId
        exo.addListener(this)
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setSource" -> setSource(
                call.argument<String>("uri") ?: return invalid(result, "uri is required"),
                call.argument<Boolean>("isLocal") ?: false,
                result,
            )
            "play" -> { play(); result.success(null) }
            "pause" -> { exo.pause(); refreshState(); result.success(null) }
            "stop" -> { stop(); result.success(null) }
            "clearSource" -> { clearSource(); result.success(null) }
            "seek" -> {
                val position = call.argument<Number>("positionMs")?.toLong()
                    ?: return invalid(result, "positionMs is required")
                exo.seekTo(position.coerceAtLeast(0))
                result.success(null)
            }
            "setVolume" -> {
                val volume = call.argument<Number>("volume")?.toDouble()
                    ?: return invalid(result, "volume is required")
                applyVolume(volume)
                result.success(null)
            }
            "setRate" -> {
                val rate = call.argument<Number>("rate")?.toFloat()
                if (rate == null || !rate.isFinite() || rate <= 0f) return invalid(result, "rate must be above 0")
                exo.setPlaybackSpeed(rate)
                result.success(null)
            }
            "getPosition" -> result.success(if (queue.current == null) 0L else exo.currentPosition.coerceAtLeast(0))
            "getDuration" -> result.success(if (queue.current == null) null else knownDuration())
            "queueNext" -> result.success(queueNext(
                call.argument<String>("uri") ?: return invalid(result, "uri is required"),
                call.argument<Boolean>("isLocal") ?: false,
                call.argument<Number>("volume")?.toDouble(),
            ))
            "clearNext" -> { clearNext(); result.success(null) }
            "setEqualizer" -> {
                val configuration = call.argument<Map<String, Any?>>("configuration")
                    ?: return invalid(result, "configuration is required")
                try {
                    setEqualizer(configuration)
                    result.success(null)
                } catch (error: Exception) {
                    result.error(Media3Errors.EQUALIZER, error.message ?: "Equalizer failed", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        if (released) return
        released = true
        supersede()
        if (Build.VERSION.SDK_INT >= 28) equalizer?.close()
        equalizer = null
        exo.removeListener(this)
        exo.release()
        retire(queue.clear())
    }

    private fun invalid(result: MethodChannel.Result, message: String) =
        result.error(Media3Errors.INVALID_ARGUMENT, message, null)

    private fun setSource(uri: String, isLocal: Boolean, result: MethodChannel.Result) {
        supersede()
        stopped = false
        lastDurationMs = null
        val kind = Media3SourceKind.classify(uri, isLocal)
        val built = kind?.let { build(it) }
        if (built == null) {
            exo.stop()
            exo.clearMediaItems()
            retire(queue.clear())
            refreshState()
            result.error(
                Media3Errors.SOURCE_ERROR,
                Media3Errors.SOURCE_MESSAGE,
                Media3Errors.sourceDetails(PlaybackException.getErrorCodeName(
                    if (kind == null) PlaybackException.ERROR_CODE_IO_UNSPECIFIED
                    else PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND,
                )),
            )
            return
        }
        val (item, source) = built
        exo.setWakeMode(if (kind is Media3SourceKind.Network) C.WAKE_MODE_NETWORK else C.WAKE_MODE_LOCAL)
        exo.playWhenReady = false
        exo.setMediaSource(source, true)
        retire(queue.replace(item))
        pending = result
        exo.prepare()
    }

    private fun play() {
        stopped = false
        if (exo.playbackState == Player.STATE_ENDED) exo.seekToDefaultPosition()
        exo.play()
        refreshState()
    }

    private fun stop() {
        supersede()
        exo.pause()
        exo.seekTo(0)
        stopped = true
        refreshState()
    }

    private fun clearSource() {
        supersede()
        exo.stop()
        exo.clearMediaItems()
        retire(queue.clear())
        stopped = true
        lastDurationMs = null
        refreshState()
    }

    private fun queueNext(uri: String, isLocal: Boolean, volume: Double?): Boolean {
        if (queue.current == null) return false
        val kind = Media3SourceKind.classify(uri, isLocal) ?: return false
        val (item, source) = build(kind, volume) ?: return false
        removeAfterCurrent()
        retire(requireNotNull(queue.queueNext(item)))
        exo.addMediaSource(source)
        return true
    }

    private fun clearNext() {
        removeAfterCurrent()
        retire(queue.clearNext())
    }

    private fun removeAfterCurrent() {
        if (exo.mediaItemCount > 1) exo.removeMediaItems(1, exo.mediaItemCount)
    }

    private fun build(kind: Media3SourceKind, volume: Double? = null): Pair<Item, MediaSource>? {
        val id = "media3-${++nextItem}"
        return try {
            val built = sources.build(kind, id) { error ->
                val code = loadErrorCode(error)
                handler.post { onLoadFailed(id, code) }
            }
            Item(id, built.descriptor, volume) to built.source
        } catch (error: Exception) {
            Log.w(TAG, "Could not open a ${kind.label} source: ${error.javaClass.simpleName}")
            null
        }
    }

    private fun setEqualizer(configuration: Map<String, Any?>) {
        if (Build.VERSION.SDK_INT < 28) {
            check(configuration["enabled"] != true) { "Equalizer requires Android 9 or later" }
            return
        }
        if (configuration["enabled"] == true && equalizer == null) {
            equalizer = PlaybackEqualizer(sessionId)
        }
        try {
            equalizer?.configure(configuration)
        } catch (error: Exception) {
            equalizer?.close()
            equalizer = null
            throw error
        }
        if (configuration["enabled"] != true) equalizer = null
    }

    private fun applyVolume(volume: Double) {
        exo.volume = volume.toFloat().coerceIn(0f, 1f)
    }

    private fun supersede() {
        val superseded = pending ?: return
        pending = null
        superseded.error(Media3Errors.SUPERSEDED, Media3Errors.SUPERSEDED_MESSAGE, null)
    }

    private fun retire(items: List<Item>) {
        items.forEach { it.descriptor?.retire() }
    }

    private fun knownDuration(): Long? = exo.duration.takeIf { it != C.TIME_UNSET && it >= 0 }

    private fun refreshState() {
        if (released) return
        val state = Media3Transport.state(
            hasItem = queue.current != null,
            idle = exo.playbackState == Player.STATE_IDLE,
            ended = exo.playbackState == Player.STATE_ENDED,
            playWhenReady = exo.playWhenReady,
            isPlaying = exo.isPlaying,
            stopped = stopped,
        ) ?: return
        if (state == lastState) return
        lastState = state
        emit(mapOf("event" to "state", "state" to state))
    }

    private fun refreshDuration() {
        if (pending != null || queue.current == null) return
        val duration = knownDuration() ?: return
        if (duration == lastDurationMs) return
        lastDurationMs = duration
        emit(mapOf("event" to "duration", "durationMs" to duration))
    }

    override fun onPlaybackStateChanged(playbackState: Int) {
        when (playbackState) {
            Player.STATE_READY -> {
                queue.current?.prepared = true
                val prepared = pending ?: return
                pending = null
                lastDurationMs = knownDuration()
                prepared.success(mapOf("durationMs" to lastDurationMs))
            }
            Player.STATE_ENDED -> {
                if (queue.current == null) return
                // Like MediaPlayer: a later seek must not restart playback.
                exo.playWhenReady = false
                val failed = queue.next?.takeIf { it.failedCode != null }
                if (failed != null) failQueued(failed) else emit(mapOf("event" to "completed"))
            }
        }
    }

    /**
     * The queued item's load failed for good while the current one played.
     * It leaves the media3 playlist at once, so the current item plays to
     * its end (and a short one starts at all); the end then reports it.
     */
    private fun onLoadFailed(id: String, code: Int) {
        val next = queue.next ?: return
        if (released || next.id != id || next.failedCode != null) return
        Log.w(TAG, "Queued source failed: ${PlaybackException.getErrorCodeName(code)}")
        next.failedCode = code
        removeAfterCurrent()
    }

    /** The current item ended before a failed queued one: report that one. */
    private fun failQueued(item: Item) {
        retire(requireNotNull(queue.advanceTo(item.id)))
        exo.stop()
        exo.clearMediaItems()
        item.volume?.let(::applyVolume)
        lastDurationMs = null
        emit(mapOf("event" to "transition"))
        emit(Media3Errors.errorEvent(PlaybackException.getErrorCodeName(requireNotNull(item.failedCode)), false))
    }

    override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
        if (reason != Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) return
        advanceTo(mediaItem?.mediaId ?: return)
    }

    /** The queued item became current; drop the finished one before it. */
    private fun advanceTo(id: String) {
        val removed = queue.advanceTo(id) ?: return
        if (removed.isNotEmpty()) exo.removeMediaItems(0, removed.size)
        retire(removed)
        val item = requireNotNull(queue.current)
        item.prepared = true
        item.volume?.let(::applyVolume)
        lastDurationMs = null
        emit(mapOf("event" to "transition"))
    }

    override fun onPlayerError(error: PlaybackException) {
        val code = error.errorCodeName
        Log.w(TAG, "Playback failed: $code")
        val waiting = pending
        if (waiting != null) {
            pending = null
            queue.current?.prepared = false
            exo.playWhenReady = false
            waiting.error(Media3Errors.SOURCE_ERROR, Media3Errors.SOURCE_MESSAGE, Media3Errors.sourceDetails(code))
            return
        }
        val current = queue.current
        emit(Media3Errors.errorEvent(code, current?.prepared == true))
        current?.prepared = false
        exo.playWhenReady = false
    }

    override fun onEvents(player: Player, events: Player.Events) {
        if (events.containsAny(
                Player.EVENT_TIMELINE_CHANGED,
                Player.EVENT_MEDIA_ITEM_TRANSITION,
                Player.EVENT_PLAYBACK_STATE_CHANGED,
            )
        ) {
            refreshDuration()
        }
        refreshState()
    }

    private companion object {
        const val TAG = "Media3"
    }
}
