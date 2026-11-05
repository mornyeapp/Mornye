package xyz.luan.audioplayers.player

import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import androidx.annotation.RequiresApi
import xyz.luan.audioplayers.AudioContextAndroid

abstract class FocusManager {
    abstract val player: WrappedPlayer
    abstract val onGranted: () -> Unit
    abstract val onLoss: (isTransient: Boolean) -> Unit
    abstract var context: AudioContextAndroid

    companion object {
        fun create(
            player: WrappedPlayer,
            onGranted: () -> Unit,
            onLoss: (isTransient: Boolean) -> Unit,
        ): FocusManager {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ModernFocusManager(player, onGranted, onLoss)
            } else {
                LegacyFocusManager(player, onGranted, onLoss)
            }
        }
    }

    protected abstract fun hasAudioFocusRequest(): Boolean

    protected abstract fun updateAudioFocusRequest()

    protected val audioManager: AudioManager
        get() = player.audioManager

    fun maybeRequestAudioFocus() {
        if (context != player.context) {
            context = player.context
            updateAudioFocusRequest()
        }
        if (hasAudioFocusRequest()) {
            requestAudioFocus()
        } else {
            // Grant without requesting focus, if it is AudioManager.AUDIOFOCUS_NONE
            onGranted()
        }
    }

    protected abstract fun requestAudioFocus()

    abstract fun handleStop()

    protected fun handleFocusResult(result: Int) {
        when (result) {
            AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> {
                onGranted()
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                onLoss(true)
            }

            AudioManager.AUDIOFOCUS_LOSS -> {
                onLoss(false)
            }
        }
        // Keep playing source on `AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK` as sound is ducked.
    }
}

private class LegacyFocusManager(
    override val player: WrappedPlayer,
    override val onGranted: () -> Unit,
    override val onLoss: (isTransient: Boolean) -> Unit,
) : FocusManager() {
    override var context: AudioContextAndroid = player.context

    // Deprecated variant of listening to focus changes
    private var audioFocusChangeListener: AudioManager.OnAudioFocusChangeListener? = null

    init {
        updateAudioFocusRequest()
    }

    override fun hasAudioFocusRequest(): Boolean {
        return audioFocusChangeListener != null
    }

    override fun updateAudioFocusRequest() {
        audioFocusChangeListener = if (context.audioFocus == AudioManager.AUDIOFOCUS_NONE) {
            // Mix sound with others
            null
        } else {
            AudioManager.OnAudioFocusChangeListener { focus ->
                player.onPlaybackThread { handleFocusResult(focus) }
            }
        }
    }

    override fun handleStop() {
        if (hasAudioFocusRequest()) {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(audioFocusChangeListener)
        }
    }

    override fun requestAudioFocus() {
        @Suppress("DEPRECATION")
        val result = audioManager.requestAudioFocus(
            audioFocusChangeListener,
            AudioManager.STREAM_MUSIC,
            context.audioFocus,
        )
        handleFocusResult(result)
    }
}

@RequiresApi(Build.VERSION_CODES.O)
private class ModernFocusManager(
    override val player: WrappedPlayer,
    override val onGranted: () -> Unit,
    override val onLoss: (isTransient: Boolean) -> Unit,
) : FocusManager() {
    override var context: AudioContextAndroid = player.context

    // Listen also for focus changes, e.g. if interrupt playing with a phone call and resume afterward.
    private var audioFocusRequest: AudioFocusRequest? = null

    init {
        updateAudioFocusRequest()
    }

    override fun hasAudioFocusRequest(): Boolean {
        return audioFocusRequest != null
    }

    override fun updateAudioFocusRequest() {
        audioFocusRequest = if (context.audioFocus == AudioManager.AUDIOFOCUS_NONE) {
            // Mix sound with others
            null
        } else {
            AudioFocusRequest.Builder(context.audioFocus).setAudioAttributes(context.buildAttributes())
                .setOnAudioFocusChangeListener { focus ->
                    player.onPlaybackThread { handleFocusResult(focus) }
                }.build()
        }
    }

    override fun handleStop() {
        if (hasAudioFocusRequest()) {
            audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        }
    }

    override fun requestAudioFocus() {
        val result = audioManager.requestAudioFocus(audioFocusRequest!!)
        handleFocusResult(result)
    }
}
