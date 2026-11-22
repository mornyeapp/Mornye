package com.zarz.mornye

import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import java.nio.ByteBuffer
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToLong
import kotlin.math.sin
import kotlin.math.sqrt

/** One filter of the `setEqualizer` configuration's `filters`. */
internal data class ParametricFilter(
    val type: String,
    val frequency: Double,
    val gain: Double,
    val q: Double,
) {
    /**
     * `b0, b1, b2, a1, a2` of the cookbook section
     * (https://www.w3.org/TR/audio-eq-cookbook/), the same on every platform.
     */
    fun coefficients(rate: Double): DoubleArray {
        val w = 2 * PI * min(frequency, rate * 0.45) / rate
        val a = 10.0.pow(gain / 40)
        val cosine = cos(w)
        val alpha = sin(w) / (2 * q)
        val slope = 2 * sqrt(a) * alpha
        val b: DoubleArray
        val a0: Double
        val a1: Double
        val a2: Double
        when (type) {
            LOW_SHELF -> {
                b = doubleArrayOf(
                    a * ((a + 1) - (a - 1) * cosine + slope),
                    2 * a * ((a - 1) - (a + 1) * cosine),
                    a * ((a + 1) - (a - 1) * cosine - slope),
                )
                a0 = (a + 1) + (a - 1) * cosine + slope
                a1 = -2 * ((a - 1) + (a + 1) * cosine)
                a2 = (a + 1) + (a - 1) * cosine - slope
            }
            HIGH_SHELF -> {
                b = doubleArrayOf(
                    a * ((a + 1) + (a - 1) * cosine + slope),
                    -2 * a * ((a - 1) + (a + 1) * cosine),
                    a * ((a + 1) + (a - 1) * cosine - slope),
                )
                a0 = (a + 1) - (a - 1) * cosine + slope
                a1 = 2 * ((a - 1) - (a + 1) * cosine)
                a2 = (a + 1) - (a - 1) * cosine - slope
            }
            else -> {
                b = doubleArrayOf(1 + alpha * a, -2 * cosine, 1 - alpha * a)
                a0 = 1 + alpha / a
                a1 = -2 * cosine
                a2 = 1 - alpha / a
            }
        }
        return doubleArrayOf(b[0] / a0, b[1] / a0, b[2] / a0, a1 / a0, a2 / a0)
    }

    companion object {
        const val PEAK = "peak"
        const val LOW_SHELF = "lowshelf"
        const val HIGH_SHELF = "highshelf"
        const val MAX_FILTERS = 20

        /**
         * The filters of a configuration, or null when it is off or plays
         * the graphic bands.
         */
        fun parse(data: Map<String, Any?>): List<ParametricFilter>? {
            if (data["enabled"] != true) return null
            val raw = data["filters"] as? List<*> ?: return null
            require(raw.size <= MAX_FILTERS) { "Too many equalizer filters" }
            return raw.map { entry ->
                val filter = entry as? Map<*, *> ?: error("Invalid equalizer filter")
                fun number(key: String): Double =
                    (filter[key] as? Number)?.toDouble()?.takeIf { it.isFinite() }
                        ?: error("Invalid equalizer filter")
                val type = filter["type"] as? String
                require(type == PEAK || type == LOW_SHELF || type == HIGH_SHELF) { "Unknown equalizer filter" }
                ParametricFilter(
                    type = type!!,
                    frequency = number("frequency").also { require(it in 10.0..24000.0) },
                    gain = number("gain").also { require(abs(it) <= 24) },
                    q = number("q").also { require(it in 0.05..40.0) },
                )
            }
        }
    }
}

/**
 * The parametric equalizer's own DSP on decoded PCM: input gain, then the
 * filters. The platform equalizer is a bank of fixed bands and cannot hold
 * a filter with its own frequency and width.
 *
 * [configure] is called from the platform thread, everything else from the
 * playback thread.
 */
internal class ParametricEqualizerDsp {
    private class Plan(val inputGain: Double, val filters: List<ParametricFilter>)

    @Volatile
    private var plan: Plan? = null

    /** The plan the sections were built for; playback thread only. */
    private var built: Plan? = null
    private var rate = 0.0
    private var channels = 0

    // Per section and channel: coefficients, their targets and the state.
    private var sections = 0
    private var coefficients = DoubleArray(0)
    private var targets = DoubleArray(0)
    private var state = DoubleArray(0)
    private var ramp = 0
    private var gain = 1.0
    private var targetGain = 1.0
    private var noise = 0x2545F491

    val active: Boolean get() = plan != null

    /** Takes the `setEqualizer` configuration; null filters turn it off. */
    fun configure(data: Map<String, Any?>) {
        val filters = ParametricFilter.parse(data)
        plan = filters?.let {
            val inputGain = ((data["inputGain"] as? Number)?.toDouble() ?: 0.0)
                .takeIf { it.isFinite() }?.coerceIn(-48.0, 12.0) ?: 0.0
            Plan(10.0.pow(inputGain / 20), it)
        }
    }

    fun disable() {
        plan = null
    }

    fun prepare(sampleRate: Int, channelCount: Int) {
        rate = sampleRate.toDouble()
        channels = channelCount
        built = null
    }

    /** Forgets the filters' memory, as after a seek. */
    fun reset() {
        state.fill(0.0)
    }

    private fun build(next: Plan) {
        val smooth = built != null && next.filters.size == sections
        if (!smooth) {
            sections = next.filters.size
            coefficients = DoubleArray(sections * 5)
            state = DoubleArray(sections * channels * 2)
        }
        targets = DoubleArray(sections * 5)
        next.filters.forEachIndexed { index, filter ->
            filter.coefficients(rate).copyInto(targets, index * 5)
        }
        targetGain = next.inputGain
        if (smooth) {
            // A change slides over 5 ms, so a slider does not click.
            ramp = max(1, (rate * 0.005).toInt())
        } else {
            targets.copyInto(coefficients)
            gain = targetGain
            ramp = 0
        }
        built = next
    }

    /**
     * Writes the processed frames of [input] to [output], which has room
     * for them. Returns false, with nothing read, when the equalizer is off
     * or cannot read [encoding].
     */
    fun process(input: ByteBuffer, output: ByteBuffer, encoding: Int): Boolean {
        val current = plan ?: return false
        val width = when (encoding) {
            C.ENCODING_PCM_16BIT -> 2
            C.ENCODING_PCM_24BIT -> 3
            C.ENCODING_PCM_32BIT, C.ENCODING_PCM_FLOAT -> 4
            else -> return false
        }
        if (channels <= 0 || rate <= 0) return false
        if (current !== built) build(current)
        val frames = input.remaining() / (width * channels)
        var position = input.position()
        for (frame in 0 until frames) {
            if (ramp > 0) {
                val step = 1.0 / ramp
                for (index in coefficients.indices) {
                    coefficients[index] += (targets[index] - coefficients[index]) * step
                }
                gain += (targetGain - gain) * step
                ramp--
            }
            for (channel in 0 until channels) {
                var value = when (encoding) {
                    C.ENCODING_PCM_16BIT -> input.getShort(position) / 32768.0
                    C.ENCODING_PCM_24BIT -> (
                        (input.get(position).toInt() and 0xFF) or
                            ((input.get(position + 1).toInt() and 0xFF) shl 8) or
                            (input.get(position + 2).toInt() shl 16)
                        ) / 8388608.0
                    C.ENCODING_PCM_32BIT -> input.getInt(position) / 2147483648.0
                    else -> input.getFloat(position).toDouble()
                }
                if (!value.isFinite()) value = 0.0
                value *= gain
                for (section in 0 until sections) {
                    val c = section * 5
                    val z = (section * channels + channel) * 2
                    val out = coefficients[c] * value + state[z]
                    state[z] = coefficients[c + 1] * value - coefficients[c + 3] * out + state[z + 1]
                    state[z + 1] = coefficients[c + 2] * value - coefficients[c + 4] * out
                    value = out
                }
                if (!value.isFinite()) {
                    // A filter that ran away starts over in silence.
                    state.fill(0.0)
                    value = 0.0
                }
                when (encoding) {
                    C.ENCODING_PCM_16BIT -> {
                        // Triangular dither of one step hides the rounding.
                        val dithered = value * 32768.0 + random() - random()
                        output.putShort(dithered.roundToLong().coerceIn(-32768, 32767).toShort())
                    }
                    C.ENCODING_PCM_24BIT -> {
                        val sample = (value * 8388608.0).roundToLong().coerceIn(-8388608, 8388607).toInt()
                        output.put(sample.toByte())
                        output.put((sample shr 8).toByte())
                        output.put((sample shr 16).toByte())
                    }
                    C.ENCODING_PCM_32BIT -> output.putInt(
                        (value * 2147483648.0).roundToLong().coerceIn(-2147483648L, 2147483647L).toInt(),
                    )
                    else -> output.putFloat(value.toFloat())
                }
                position += width
            }
        }
        input.position(position)
        return true
    }

    /** Uniform in 0 until 1; an xorshift is enough for dither. */
    private fun random(): Double {
        noise = noise xor (noise shl 13)
        noise = noise xor (noise ushr 17)
        noise = noise xor (noise shl 5)
        return (noise ushr 8) / 16777216.0
    }
}

/**
 * Runs [dsp] over the PCM on its way into [sink]. It sits in front of the
 * sink, not in its processor chain, which `DefaultAudioSink` skips for the
 * float PCM of high resolution songs.
 *
 * Its changes are heard once the audio already in the track's buffer has
 * played (about a second), unlike the platform equalizer behind it.
 */
@OptIn(UnstableApi::class)
internal class ParametricEqualizerSink(
    sink: AudioSink,
    private val dsp: ParametricEqualizerDsp,
) : ForwardingAudioSink(sink) {
    private var encoding = C.ENCODING_INVALID

    /** The decoder's buffer a processed copy is still being written for. */
    private var pending: ByteBuffer? = null
    private var processed: ByteBuffer = ByteBuffer.allocateDirect(0)

    /** Whether the last buffer went through the filters; logged on change. */
    private var playing: Boolean? = null

    override fun configure(config: AudioSink.AudioSinkConfig) {
        super.configure(config)
        val format = config.format
        encoding = if (format.sampleMimeType == MimeTypes.AUDIO_RAW) format.pcmEncoding else C.ENCODING_INVALID
        dsp.prepare(format.sampleRate, format.channelCount)
        playing = null
    }

    override fun handleBuffer(buffer: ByteBuffer, presentationTimeUs: Long, encodedAccessUnitCount: Int): Boolean {
        if (buffer !== pending) {
            pending = null
            if (!dsp.active || !buffer.hasRemaining()) {
                return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
            }
            // The decoder's buffer is not ours to write to.
            if (processed.capacity() < buffer.remaining()) {
                processed = ByteBuffer.allocateDirect(buffer.remaining())
            }
            processed.clear()
            processed.order(buffer.order())
            val start = buffer.position()
            val played = dsp.process(buffer, processed, encoding) && !buffer.hasRemaining()
            if (played != playing) {
                playing = played
                Log.i(TAG, "Parametric equalizer ${if (played) "plays" else "cannot play"} PCM encoding $encoding")
            }
            if (!played) {
                // Off since the check, an encoding it cannot read, or a
                // buffer that does not end on a frame: play it as it is.
                buffer.position(start)
                return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
            }
            processed.flip()
            pending = buffer
        }
        // The sink asks for the same buffer until it has taken all of it.
        val done = super.handleBuffer(processed, presentationTimeUs, encodedAccessUnitCount)
        if (done) pending = null
        return done
    }

    override fun flush() {
        pending = null
        dsp.reset()
        super.flush()
    }

    override fun reset() {
        pending = null
        dsp.reset()
        super.reset()
    }

    private companion object {
        const val TAG = "ParametricEqualizer"
    }
}
