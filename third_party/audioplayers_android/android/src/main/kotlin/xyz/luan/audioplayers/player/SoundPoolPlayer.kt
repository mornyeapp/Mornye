package xyz.luan.audioplayers.player

import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.os.Build
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.AudioplayersPlugin
import xyz.luan.audioplayers.source.Source
import xyz.luan.audioplayers.source.UrlSource
import java.util.Collections.synchronizedMap

/** Value should not exceed 32 */
// TODO(luan): make this configurable
private const val MAX_STREAMS = 32

class SoundPoolPlayer(
    val wrappedPlayer: WrappedPlayer,
    private val soundPoolManager: SoundPoolManager,
) : PlayerWrapper {
    private val mainScope = CoroutineScope(Dispatchers.Main)

    /** The id of the sound of source which will be played */
    var soundId: Int? = null

    /** The id of the stream / player */
    private var streamId: Int? = null

    private var audioContext = wrappedPlayer.context
        set(value) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                // AudioAttributes are compared by its property values.
                if (field.buildAttributes() != value.buildAttributes()) {
                    release()
                    soundPoolManager.createSoundPoolWrapper(MAX_STREAMS, value)
                    soundPoolWrapper = soundPoolManager.getSoundPoolWrapper(value)
                        ?: error("Could not create SoundPool $value")
                }
            }
            field = value
        }

    private var soundPoolWrapper: SoundPoolWrapper

    private val soundPool: SoundPool
        get() = soundPoolWrapper.soundPool

    init {
        soundPoolManager.createSoundPoolWrapper(MAX_STREAMS, audioContext)
        soundPoolWrapper = soundPoolManager.getSoundPoolWrapper(audioContext)
            ?: error("Could not create SoundPool $audioContext")
    }

    override fun stop() {
        streamId?.let {
            soundPool.stop(it)
            streamId = null
        }
    }

    override fun release() {
        stop()
        val soundId = this.soundId ?: return
        val urlSource = this.urlSource ?: return

        synchronized(soundPoolWrapper.urlToPlayers) {
            val playersForSoundId = soundPoolWrapper.urlToPlayers[urlSource] ?: return
            if (playersForSoundId.singleOrNull() === this) {
                soundPoolWrapper.urlToPlayers.remove(urlSource)
                soundPool.unload(soundId)
                soundPoolWrapper.soundIdToPlayer.remove(soundId)
                wrappedPlayer.handleLog("unloaded soundId $soundId")
            } else {
                // This is not the last player using the soundId, just remove it from the list.
                playersForSoundId.remove(this)
            }
            this.soundId = null
            this.urlSource = null
        }
    }

    override fun pause() {
        streamId?.let { soundPool.pause(it) }
    }

    override fun updateContext(context: AudioContextAndroid) {
        audioContext = context
    }

    override fun setSource(source: Source) {
        source.setForSoundPool(this)
    }

    var urlSource: UrlSource? = null
        set(value) {
            if (value != null) {
                synchronized(soundPoolWrapper.urlToPlayers) {
                    val urlPlayers = soundPoolWrapper.urlToPlayers.getOrPut(value) { mutableListOf() }
                    val originalPlayer = urlPlayers.firstOrNull()

                    if (originalPlayer != null) {
                        // Sound has already been loaded - reuse the soundId.
                        val prepared = originalPlayer.wrappedPlayer.prepared
                        wrappedPlayer.prepared = prepared
                        soundId = originalPlayer.soundId
                        wrappedPlayer.handleLog("Reusing soundId $soundId for $value is prepared=$prepared $this")
                    } else {
                        // First one for this URL - load it.
                        val start = System.currentTimeMillis()

                        wrappedPlayer.prepared = false
                        val soundPoolPlayer = this
                        wrappedPlayer.handleLog("Fetching actual URL for $value")

                        // Need to load sound on another thread than main to avoid `NetworkOnMainThreadException`
                        mainScope.launch(Dispatchers.IO) {
                            val actualUrl = value.getAudioPathForSoundPool()
                            wrappedPlayer.onPlaybackThread {
                                if (urlSource != value) return@onPlaybackThread
                                wrappedPlayer.handleLog("Now loading $actualUrl")
                                val intSoundId = soundPool.load(actualUrl, 1)
                                soundPoolWrapper.soundIdToPlayer[intSoundId] = soundPoolPlayer
                                soundId = intSoundId

                                wrappedPlayer.handleLog(
                                    "time to call load() for $value: " +
                                        "${System.currentTimeMillis() - start} player=$this",
                                )
                            }
                        }
                    }
                    urlPlayers.add(this)
                }
            }
            field = value
        }

    override fun setVolume(leftVolume: Float, rightVolume: Float) {
        streamId?.let { soundPool.setVolume(it, leftVolume, rightVolume) }
    }

    override fun setRate(rate: Float) {
        streamId?.let { soundPool.setRate(it, rate) }
    }

    override fun setLooping(looping: Boolean) {
        streamId?.let { soundPool.setLoop(it, looping.loopModeInteger()) }
    }

    // Cannot get duration for Sound Pool
    override fun getDuration() = null

    // Cannot get current position for Sound Pool
    override fun getCurrentPosition() = null

    override fun seekTo(position: Int) {
        if (position == 0) {
            streamId?.let {
                stop()
                if (wrappedPlayer.playing) {
                    soundPool.resume(it)
                }
            }
        } else {
            unsupportedOperation("seek")
        }
    }

    override fun start() {
        val streamId = streamId
        val soundId = soundId

        if (streamId != null) {
            soundPool.resume(streamId)
        } else if (soundId != null) {
            this.streamId = soundPool.play(
                soundId,
                wrappedPlayer.volume,
                wrappedPlayer.volume,
                0,
                wrappedPlayer.isLooping.loopModeInteger(),
                wrappedPlayer.rate,
            )
        }
    }

    override fun prepare() {
        // sound pool automatically prepares when source URL is set
    }

    override fun reset() {
        // TODO(luan): what do I do here?
    }

    override fun isLiveStream() = false

    /** Integer representation of the loop mode used by Android */
    private fun Boolean.loopModeInteger(): Int = if (this) -1 else 0

    private fun unsupportedOperation(message: String): Nothing {
        throw UnsupportedOperationException("LOW_LATENCY mode does not support: $message")
    }
}

class SoundPoolManager(
    private val ref: AudioplayersPlugin,
) {
    private val dispatch = ref.playbackDispatcher()

    // Only needed for legacy apps with SDK < 21
    private var legacySoundPoolWrapper: SoundPoolWrapper? = null

    /**
     * Lazy store one [SoundPoolWrapper] for each [AudioAttributes] configuration.
     * [AudioAttributes] are compared by its property values, so it can be used as key.
     */
    private val soundPoolWrappers = HashMap<AudioAttributes, SoundPoolWrapper>()

    /**
     * Create a SoundPoolWrapper with the given [maxStreams] and the according [audioContext] and save it to be
     * globally accessible for every player.
     *
     * @param maxStreams the maximum number of simultaneous streams for this
     *                   SoundPool object, see [SoundPool.Builder.setMaxStreams]
     */
    fun createSoundPoolWrapper(maxStreams: Int, audioContext: AudioContextAndroid) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val attrs = audioContext.buildAttributes()
            if (!soundPoolWrappers.containsKey(attrs)) {
                val soundPool = SoundPool.Builder()
                    .setAudioAttributes(attrs)
                    .setMaxStreams(maxStreams)
                    .build()
                ref.handleGlobalLog("Create SoundPool with $attrs")
                val soundPoolWrapper = SoundPoolWrapper(soundPool)
                soundPoolWrapper.soundPool.setOnLoadCompleteListener { _, sampleId, _ ->
                    dispatch {
                        ref.handleGlobalLog("Loaded $sampleId")
                        val loadingPlayer = soundPoolWrapper.soundIdToPlayer[sampleId]
                        val urlSource = loadingPlayer?.urlSource
                        if (urlSource != null) {
                            soundPoolWrapper.soundIdToPlayer.remove(loadingPlayer.soundId)
                            // Mark all owners loaded on their playback thread.
                            synchronized(soundPoolWrapper.urlToPlayers) {
                                val urlPlayers = soundPoolWrapper.urlToPlayers[urlSource] ?: listOf()
                                for (player in urlPlayers) {
                                    player.wrappedPlayer.handleLog("Marking $player as loaded")
                                    player.wrappedPlayer.prepared = true
                                    if (player.wrappedPlayer.playing) {
                                        player.wrappedPlayer.handleLog("Delayed start of $player")
                                        player.start()
                                    }
                                }
                            }
                        }
                    }
                }
                soundPoolWrappers[attrs] = soundPoolWrapper
            }
        } else if (legacySoundPoolWrapper == null) {
            @Suppress("DEPRECATION")
            val soundPool = SoundPool(maxStreams, AudioManager.STREAM_MUSIC, 0)
            ref.handleGlobalLog("Create legacy SoundPool")
            legacySoundPoolWrapper = SoundPoolWrapper(soundPool)
        }
    }

    /**
     * Get the [SoundPoolWrapper] with the given [audioContext].
     */
    fun getSoundPoolWrapper(audioContext: AudioContextAndroid): SoundPoolWrapper? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val attrs = audioContext.buildAttributes()
            soundPoolWrappers[attrs]
        } else {
            legacySoundPoolWrapper
        }
    }

    fun dispose() {
        for (soundPoolEntry in soundPoolWrappers) {
            soundPoolEntry.value.dispose()
        }
        soundPoolWrappers.clear()
    }
}

class SoundPoolWrapper(val soundPool: SoundPool) {

    /** For the onLoadComplete listener, track which sound id is associated with which player. An entry only exists until
     * it has been loaded.
     */
    val soundIdToPlayer: MutableMap<Int, SoundPoolPlayer> = synchronizedMap(mutableMapOf<Int, SoundPoolPlayer>())

    /** This is to keep track of the players which share the same sound id, referenced by url. When a player release()s, it
     * is removed from the associated player list. The last player to be removed actually unloads() the sound id and then
     * the url is removed from this map.
     */
    val urlToPlayers: MutableMap<UrlSource, MutableList<SoundPoolPlayer>> =
        synchronizedMap(mutableMapOf<UrlSource, MutableList<SoundPoolPlayer>>())

    fun dispose() {
        soundPool.release()
        soundIdToPlayer.clear()
        urlToPlayers.clear()
    }
}
