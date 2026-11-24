package com.zarz.mornye

import android.media.audiofx.DynamicsProcessing
import androidx.annotation.RequiresApi
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * The `setEqualizer` configuration, validated the same way as the
 * audioplayers fork's `PlaybackEqualizer` (third_party/audioplayers_android).
 */
internal data class EqualizerSettings(
    val gains: List<Float>,
    val frequencies: List<Float>,
    val inputGain: Float,
    val balance: Float,
    val compressor: Boolean,
    val attack: Float,
    val release: Float,
    val threshold: Float,
    val ratio: Float,
    val limiter: Boolean,
) {
    /** Cutoff of each pre-EQ band: the geometric middle to the next band. */
    fun cutoffs(): List<Float> = gains.indices.map { index ->
        if (index == gains.lastIndex) 24000f else sqrt(frequencies[index] * frequencies[index + 1])
    }

    /** Input gain per channel, with the balance folded in. */
    fun channelGain(channel: Int): Float {
        val amplitude = when (channel) {
            0 -> if (balance > 0) 1f - balance else 1f
            1 -> if (balance < 0) 1f + balance else 1f
            else -> 1f
        }
        return inputGain + 20f * log10(amplitude.coerceAtLeast(0.000001f))
    }

    companion object {
        /** Null when the configuration turns the equalizer off. */
        fun parse(data: Map<String, Any?>): EqualizerSettings? {
            if (data["enabled"] != true) return null
            val gains = (data["gains"] as? List<*>)?.map { (it as Number).toFloat() }
                ?: error("Missing equalizer bands")
            val frequencies = (data["frequencies"] as? List<*>)?.map { (it as Number).toFloat() }
                ?: error("Missing equalizer frequencies")
            require(gains.size in listOf(5, 10, 15, 31) && gains.size == frequencies.size)
            require(gains.all { it.isFinite() && it in -24f..24f })
            require(frequencies.all { it.isFinite() && it > 0f })
            require(frequencies.zipWithNext().all { (left, right) -> left < right })
            fun number(key: String, fallback: Float, min: Float, max: Float): Float =
                ((data[key] as? Number)?.toFloat() ?: fallback).let {
                    require(it.isFinite())
                    it.coerceIn(min, max)
                }
            return EqualizerSettings(
                gains = gains,
                frequencies = frequencies,
                inputGain = number("inputGain", 0f, -48f, 12f),
                balance = number("balance", 0f, -1f, 1f),
                compressor = data["compressor"] == true,
                attack = number("attack", 10f, 1f, 100f),
                release = number("release", 150f, 20f, 1000f),
                threshold = number("threshold", -18f, -60f, 0f),
                ratio = number("ratio", 3f, 1f, 20f),
                limiter = data["limiter"] != false,
            )
        }
    }
}

/**
 * Per-player effect, copied from the audioplayers fork: never attaches to
 * session zero or other apps' audio.
 */
@RequiresApi(28)
internal class PlaybackEqualizer(private val session: Int) {
    private var effect: DynamicsProcessing? = null
    private var bandCount = 0

    fun configure(data: Map<String, Any?>) {
        val settings = EqualizerSettings.parse(data) ?: run { close(); return }
        check(session > 0) { "No active audio session for equalizer" }
        val gains = settings.gains
        if (effect == null || bandCount != gains.size) {
            close()
            val config = DynamicsProcessing.Config.Builder(
                DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION, 2,
                true, gains.size, true, 1, false, 0, true,
            ).build()
            effect = DynamicsProcessing(0, session, config)
            bandCount = gains.size
        }
        val dsp = requireNotNull(effect)
        for (channel in 0 until dsp.channelCount) {
            dsp.setInputGainbyChannel(channel, settings.channelGain(channel))
        }
        settings.cutoffs().forEachIndexed { index, cutoff ->
            dsp.setPreEqBandAllChannelsTo(index, DynamicsProcessing.EqBand(true, cutoff, gains[index]))
        }
        val compressor = dsp.getMbcBandByChannelIndex(0, 0).apply {
            isEnabled = settings.compressor
            cutoffFrequency = 24000f
            attackTime = settings.attack
            releaseTime = settings.release
            threshold = settings.threshold
            ratio = settings.ratio
            kneeWidth = 6f
            noiseGateThreshold = -120f
            expanderRatio = 1f
            preGain = 0f
            postGain = 0f
        }
        dsp.setMbcBandAllChannelsTo(0, compressor)
        dsp.setLimiterAllChannelsTo(DynamicsProcessing.Limiter(
            true, settings.limiter, 0, 1f, 60f, 20f, -0.5f, 0f,
        ))
        check(dsp.setEnabled(true) == 0) { "Device rejected the equalizer" }
    }

    fun close() {
        effect?.release()
        effect = null
        bandCount = 0
    }
}
