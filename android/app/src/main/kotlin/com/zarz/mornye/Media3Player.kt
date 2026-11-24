@file:OptIn(UnstableApi::class)

package com.zarz.mornye

import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionParameters.AudioOffloadPreferences
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.audio.MediaCodecAudioRenderer
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.MediaSource
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Audio-only renderers for the media3 engine.
 *
 * High resolution: float output is on, and speed goes through the platform
 * `AudioTrack.setPlaybackParams` (audio output playback parameters). In
 * media3 1.11.1 `DefaultAudioSink` sends 24/32-bit PCM to a float
 * `AudioTrack` only with float output enabled; otherwise the decoder is asked
 * for 16-bit PCM and the low bits are lost. With float output its audio
 * processor chain (Sonic) is skipped for that PCM, so Sonic speed changes
 * would silently not apply; the platform playback parameters change speed
 * and pitch for every format instead, the same time-stretch MediaPlayer
 * uses for `setPlaybackParams`. The `DynamicsProcessing` equalizer is an
 * effect on the session in the platform mixer and works with either PCM
 * format, since offload stays disabled. Only songs that can hold more than
 * 16 bits are decoded as float, and none while skip silence is on (see
 * [Media3AudioRenderer]).
 *
 * Buffer size: see [MAX_BUFFERED_SPEED].
 */
internal fun media3AudioRenderers(context: Context, skipSilence: () -> Boolean) =
    RenderersFactory { handler, _, audioListener, _, _ ->
        val sink = DefaultAudioSink.Builder(context)
            .setEnableFloatOutput(true)
            .setEnableAudioOutputPlaybackParameters(true)
            .setAudioTrackBufferSizeProvider(cappedSpeedBufferSize)
            .build()
        arrayOf(Media3AudioRenderer(context, handler, audioListener, sink, skipSilence))
    }

/**
 * media3 asks every decoder for float PCM once the sink takes float, the
 * phone vendor's MP3 and AAC decoders included. This renderer asks for
 * 16-bit PCM instead wherever float holds nothing more (see
 * [Media3Decoding]): lossy songs and files of 16 bits or fewer.
 *
 * Skip silence: `DefaultAudioSink` skips silence in its audio processor
 * chain, which it bypasses for float PCM (see [media3AudioRenderers]). So
 * while [skipSilence] holds, every decoder is asked for 16-bit PCM, which
 * the chain and its silence detection process.
 *
 * A decoder already running keeps its encoding; the mode applies from the
 * next decoder start (the next source, or a queued item whose decoder cannot
 * be reused, as when a 24-bit song follows a 16-bit one).
 */
private class Media3AudioRenderer(
    context: Context,
    handler: Handler?,
    listener: AudioRendererEventListener?,
    sink: AudioSink,
    private val skipSilence: () -> Boolean,
) : MediaCodecAudioRenderer(context, MediaCodecSelector.DEFAULT, handler, listener, sink) {
    /** The mode the running decoder was configured with; playback thread only. */
    private var decoding16Bit: Boolean? = null

    override fun getMediaFormat(
        format: Format,
        codecMimeType: String,
        codecMaxInputSize: Int,
        codecOperatingRate: Float,
    ): MediaFormat {
        val mediaFormat = super.getMediaFormat(format, codecMimeType, codecMaxInputSize, codecOperatingRate)
        val sixteen = decodes16Bit(format)
        if (sixteen && Build.VERSION.SDK_INT >= 24) {
            mediaFormat.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
        }
        decoding16Bit = sixteen
        return mediaFormat
    }

    override fun canReuseCodec(
        codecInfo: MediaCodecInfo,
        oldFormat: Format,
        newFormat: Format,
        isInitialization: Boolean,
    ): DecoderReuseEvaluation {
        val running = decoding16Bit
        if (running != null && running != decodes16Bit(newFormat)) {
            return DecoderReuseEvaluation(
                codecInfo.name,
                oldFormat,
                newFormat,
                DecoderReuseEvaluation.REUSE_RESULT_NO,
                DecoderReuseEvaluation.DISCARD_REASON_APP_OVERRIDE,
            )
        }
        return super.canReuseCodec(codecInfo, oldFormat, newFormat, isInitialization)
    }

    private fun decodes16Bit(format: Format): Boolean =
        Media3Decoding.sixteenBit(format.sampleMimeType, pcmBits(format.pcmEncoding), skipSilence())
}

/** The bit depth of a media3 PCM encoding, null when it names none. */
private fun pcmBits(encoding: Int): Int? = when (encoding) {
    C.ENCODING_PCM_8BIT -> 8
    C.ENCODING_PCM_16BIT, C.ENCODING_PCM_16BIT_BIG_ENDIAN -> 16
    C.ENCODING_PCM_24BIT, C.ENCODING_PCM_24BIT_BIG_ENDIAN -> 24
    C.ENCODING_PCM_32BIT, C.ENCODING_PCM_32BIT_BIG_ENDIAN, C.ENCODING_PCM_FLOAT -> 32
    else -> null
}

/**
 * The fastest speed the `AudioTrack` buffer is sized for. With platform
 * playback parameters media3 1.11.1 multiplies its PCM buffer (a fixed
 * 500 ms) by 8, the fastest `AudioTrack` speed, so it still holds that much
 * time at 8x. That makes 4 s at 1x. Once a song's end is in the buffer the
 * track is told to play out, so a song queued later than that opens a new
 * track at the handoff, and a short song before a queued one waits on the
 * buffer. The app plays at most 2x (the speed setting) times 1.2 (AutoMix),
 * so sizing for 2.5x keeps at least the 1x buffer's time up to 2.5x at
 * under a third of the size: 1.25 s at 1x. Volume
 * (`AudioTrack.setVolume`), speed, pitch and the session equalizer act after
 * this buffer, so its size does not delay them.
 */
private const val MAX_BUFFERED_SPEED = 2.5

/** `AudioTrack` playback parameter limits for speed and pitch. */
private const val MIN_PLAYBACK_SPEED = 0.125f
private const val MAX_PLAYBACK_SPEED = 8f
private const val MIN_PLAYBACK_PITCH = 0.25f
private const val MAX_PLAYBACK_PITCH = 4f

private val cappedSpeedBufferSize =
    DefaultAudioSink.AudioTrackBufferSizeProvider { minBuffer, encoding, outputMode, frameSize, rate, bitrate, speed ->
        DefaultAudioSink.AudioTrackBufferSizeProvider.DEFAULT.getBufferSizeInBytes(
            minBuffer, encoding, outputMode, frameSize, rate, bitrate, speed.coerceAtMost(MAX_BUFFERED_SPEED),
        )
    }

/**
 * Music attributes for the player. [spatialAudio] maps to the platform's
 * spatialization behavior on Android 12L and later: auto lets the system
 * spatialize what its spatializer supports, never keeps every song out of
 * it. Earlier releases ignore it.
 */
internal fun media3AudioAttributes(spatialAudio: Boolean): AudioAttributes =
    AudioAttributes.Builder()
        .setUsage(C.USAGE_MEDIA)
        .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
        .setSpatializationBehavior(
            if (spatialAudio) C.SPATIALIZATION_BEHAVIOR_AUTO else C.SPATIALIZATION_BEHAVIOR_NEVER,
        )
        .build()

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

    /** Read by the renderer on media3's playback thread. */
    @Volatile private var skipSilence = false

    /** Auto until Dart sends `setSpatialAudio`. */
    private var spatialAudio = true

    init {
        exo = ExoPlayer.Builder(appContext, media3AudioRenderers(appContext) { skipSilence })
            .setLooper(looper)
            // The app owns focus (audio_session) and becoming-noisy handling.
            .setAudioAttributes(media3AudioAttributes(spatialAudio), false)
            .setHandleAudioBecomingNoisy(false)
            // Off until Dart sends `setSkipSilence`.
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
        exo.addAnalyticsListener(OutputTrace())
    }

    /**
     * What the phone's decoder and audio output did with a song, for the
     * app's log: the decoder that ran, the output opened for it, and the
     * first times that output ran dry. Noise or stutter that only one brand
     * of phone has shows here. Never a path or a title.
     */
    private inner class OutputTrace : AnalyticsListener {
        private var underruns = 0

        override fun onAudioInputFormatChanged(
            eventTime: AnalyticsListener.EventTime,
            format: Format,
            decoderReuseEvaluation: DecoderReuseEvaluation?,
        ) {
            val encoding = format.pcmEncoding
            trace(
                "source ${format.sampleMimeType} " +
                    "${Media3Decoding.encodingName(pcmBits(encoding), encoding == C.ENCODING_PCM_FLOAT)} " +
                    "${format.sampleRate} Hz ${format.channelCount} ch",
            )
        }

        override fun onAudioDecoderInitialized(
            eventTime: AnalyticsListener.EventTime,
            decoderName: String,
            initializedTimestampMs: Long,
            initializationDurationMs: Long,
        ) = trace("decoder $decoderName")

        override fun onAudioTrackInitialized(
            eventTime: AnalyticsListener.EventTime,
            audioTrackConfig: AudioSink.AudioTrackConfig,
        ) {
            underruns = 0
            val encoding = audioTrackConfig.encoding
            trace(
                "output ${Media3Decoding.encodingName(pcmBits(encoding), encoding == C.ENCODING_PCM_FLOAT)} " +
                    "${audioTrackConfig.sampleRate} Hz, buffer ${audioTrackConfig.bufferSize} bytes",
            )
        }

        override fun onAudioUnderrun(
            eventTime: AnalyticsListener.EventTime,
            bufferSize: Int,
            bufferSizeMs: Long,
            elapsedSinceLastFeedMs: Long,
        ) {
            if (++underruns > UNDERRUNS_TRACED) return
            trace("output ran dry: buffer $bufferSizeMs ms, $elapsedSinceLastFeedMs ms since the last write")
        }

        override fun onAudioSinkError(eventTime: AnalyticsListener.EventTime, audioSinkError: Exception) =
            trace("output error ${audioSinkError.javaClass.simpleName}")

        override fun onAudioCodecError(eventTime: AnalyticsListener.EventTime, audioCodecError: Exception) =
            trace("decoder error ${audioCodecError.javaClass.simpleName}")

        private fun trace(message: String) {
            Log.i(TAG, message)
            if (!released) emit(mapOf("event" to "trace", "message" to message))
        }
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
            "setPlaybackParameters" -> {
                val speed = call.argument<Number>("speed")?.toFloat()
                if (speed == null || !speed.isFinite() || speed <= 0f) return invalid(result, "speed must be above 0")
                val pitch = call.argument<Number>("pitch")?.toFloat() ?: 1f
                if (!pitch.isFinite() || pitch <= 0f) return invalid(result, "pitch must be above 0")
                // Applied through AudioTrack.setPlaybackParams, which takes
                // a pitch from 0.25 to 4 (see media3AudioRenderers).
                exo.playbackParameters = PlaybackParameters(
                    speed.coerceIn(MIN_PLAYBACK_SPEED, MAX_PLAYBACK_SPEED),
                    pitch.coerceIn(MIN_PLAYBACK_PITCH, MAX_PLAYBACK_PITCH),
                )
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
            "setSkipSilence" -> {
                val enabled = call.argument<Boolean>("enabled")
                    ?: return invalid(result, "enabled is required")
                // Live where the running decoder already gives 16-bit PCM;
                // otherwise from its next start (see Media3AudioRenderer).
                skipSilence = enabled
                exo.skipSilenceEnabled = enabled
                result.success(null)
            }
            "setSpatialAudio" -> {
                val enabled = call.argument<Boolean>("enabled")
                    ?: return invalid(result, "enabled is required")
                setSpatialAudio(enabled)
                result.success(null)
            }
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

    /**
     * Applies live. New attributes make the sink reopen its `AudioTrack`,
     * which the platform attaches to the spatializer or not as it opens, and
     * drop the audio it had buffered (up to 1.25 s, see [MAX_BUFFERED_SPEED]).
     * Seeking to the current position decodes that audio again instead of
     * skipping it, for a short pause rather than a jump.
     */
    private fun setSpatialAudio(enabled: Boolean) {
        if (enabled == spatialAudio) return
        spatialAudio = enabled
        exo.setAudioAttributes(media3AudioAttributes(enabled), false)
        val state = exo.playbackState
        if (queue.current != null && pending == null && state != Player.STATE_IDLE && state != Player.STATE_ENDED) {
            exo.seekTo(exo.currentPosition)
        }
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

        /** Dry runs logged for one output; a broken one would flood the log. */
        const val UNDERRUNS_TRACED = 5
    }
}
