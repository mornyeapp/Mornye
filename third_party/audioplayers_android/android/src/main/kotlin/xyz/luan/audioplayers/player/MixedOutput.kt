package xyz.luan.audioplayers.player

import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.audiofx.DynamicsProcessing
import android.os.Build
import androidx.annotation.RequiresApi

/**
 * Keeps a MediaPlayer's audio in the platform mixer for Nothing's Glyph sync.
 *
 * MediaPlayer may hand long local tracks to a compressed offload output, where
 * the audio DSP decodes them and the sound never reaches the mix. Features
 * that read the device's mixed output (playback capture, light effects synced
 * to music) then see silence. An enabled effect without offload support makes
 * the platform choose PCM through the mixer, as ExoPlayer players already do.
 * Keep this workaround scoped to Nothing phones. Even with no processing stage,
 * the effect participates in volume handling on other manufacturers' audio
 * stacks, so those devices keep the platform's normal output path. For the
 * same reason it stays off while a USB audio output is attached.
 */
internal class MixedOutput(private val wrappedPlayer: WrappedPlayer, private val session: Int) {
    private var effect: DynamicsProcessing? = null

    /** Call with true before the player starts, so offload is never chosen. */
    fun hold(active: Boolean) {
        if (Build.VERSION.SDK_INT < 28 || session <= 0 ||
            !Build.MANUFACTURER.equals("Nothing", ignoreCase = true)
        ) return
        try {
            // The effect takes over the player's volume. On a USB DAC that
            // left songs at full volume after every track change, and USB
            // output is not offloaded anyway (Mornye issue 864).
            if (active && usbOutputAttached()) {
                close()
                return
            }
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

    private fun usbOutputAttached(): Boolean =
        wrappedPlayer.audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
            it.type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                it.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                it.type == AudioDeviceInfo.TYPE_USB_ACCESSORY
        }

    @RequiresApi(28)
    private fun create(): DynamicsProcessing {
        val config = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION, 2,
            false, 1, false, 1, false, 1, false,
        ).build()
        return DynamicsProcessing(0, session, config)
    }
}
