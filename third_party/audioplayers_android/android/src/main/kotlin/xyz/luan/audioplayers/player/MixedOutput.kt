package xyz.luan.audioplayers.player

import android.media.audiofx.DynamicsProcessing
import android.os.Build

/**
 * Keeps a MediaPlayer's audio in the platform mixer while it plays.
 *
 * MediaPlayer may hand long local tracks to a compressed offload output, where
 * the audio DSP decodes them and the sound never reaches the mix. Features
 * that read the device's mixed output (playback capture, light effects synced
 * to music) then see silence. An enabled effect without offload support makes
 * the platform choose PCM through the mixer, as ExoPlayer players already do.
 * The effect has no processing stage in use, so it does not change the sound.
 */
internal class MixedOutput(private val wrappedPlayer: WrappedPlayer, private val session: Int) {
    private var effect: DynamicsProcessing? = null

    /** Call with true before the player starts, so offload is never chosen. */
    fun hold(active: Boolean) {
        if (Build.VERSION.SDK_INT < 28 || session <= 0) return
        try {
            val dsp = effect ?: if (active) create().also { effect = it } else return
            dsp.enabled = active
        } catch (error: Exception) {
            // Playback must not depend on it: the device may refuse the effect.
            close()
            wrappedPlayer.handleLog("Mixed output unavailable: ${error.message}")
        }
    }

    fun close() {
        if (Build.VERSION.SDK_INT >= 28) effect?.release()
        effect = null
    }

    private fun create(): DynamicsProcessing {
        val config = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION, 2,
            false, 1, false, 1, false, 1, false,
        ).build()
        return DynamicsProcessing(0, session, config)
    }
}
