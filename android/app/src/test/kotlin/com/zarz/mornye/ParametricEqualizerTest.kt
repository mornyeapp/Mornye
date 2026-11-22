package com.zarz.mornye

import androidx.media3.common.C
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ParametricEqualizerTest {
    private fun configuration(
        filters: List<Map<String, Any?>>?,
        inputGain: Double = 0.0,
    ): Map<String, Any?> = mapOf("enabled" to true, "inputGain" to inputGain, "filters" to filters)

    private fun filter(type: String, frequency: Double, gain: Double, q: Double) =
        mapOf("type" to type, "frequency" to frequency, "gain" to gain, "q" to q)

    private fun floats(samples: FloatArray): ByteBuffer =
        ByteBuffer.allocateDirect(samples.size * 4).order(ByteOrder.nativeOrder()).apply {
            samples.forEach { putFloat(it) }
            flip()
        }

    /** Gain in dB of [dsp] for a mono sine at [hz], measured once it settled. */
    private fun gainAt(dsp: ParametricEqualizerDsp, hz: Double, rate: Int = 48000): Double {
        dsp.prepare(rate, 1)
        val input = FloatArray(rate) { (0.25 * sin(2 * PI * hz * it / rate)).toFloat() }
        val output = ByteBuffer.allocateDirect(input.size * 4).order(ByteOrder.nativeOrder())
        assertTrue(dsp.process(floats(input), output, C.ENCODING_PCM_FLOAT))
        output.flip()
        var sum = 0.0
        for (index in rate / 2 until rate) {
            val value = output.getFloat(index * 4).toDouble()
            sum += value * value
        }
        return 20 * log10(sqrt(sum / (rate / 2)) / (0.25 / sqrt(2.0)))
    }

    @Test
    fun graphicAndDisabledConfigurationsHaveNoFilters() {
        assertNull(ParametricFilter.parse(mapOf("enabled" to false, "filters" to emptyList<Any>())))
        assertNull(ParametricFilter.parse(mapOf("enabled" to true, "filters" to null)))
        assertNull(ParametricFilter.parse(mapOf("enabled" to true)))
        assertEquals(0, ParametricFilter.parse(configuration(emptyList()))!!.size)
    }

    @Test
    fun rejectsFiltersOutOfRange() {
        for (bad in listOf(
            filter("notch", 1000.0, 3.0, 1.0),
            filter("peak", 0.0, 3.0, 1.0),
            filter("peak", 1000.0, 30.0, 1.0),
            filter("peak", 1000.0, 3.0, 0.0),
            filter("peak", Double.NaN, 3.0, 1.0),
        )) {
            assertThrows(RuntimeException::class.java) { ParametricFilter.parse(configuration(listOf(bad))) }
        }
        assertThrows(RuntimeException::class.java) {
            ParametricFilter.parse(configuration(List(21) { filter("peak", 1000.0, 1.0, 1.0) }))
        }
    }

    @Test
    fun peakCoefficientsAreTheCookbookSection() {
        val rate = 48000.0
        val w = 2 * PI * 1000 / rate
        val a = Math.pow(10.0, 6.0 / 40)
        val alpha = sin(w) / (2 * 1.4)
        val a0 = 1 + alpha / a
        val got = ParametricFilter("peak", 1000.0, 6.0, 1.4).coefficients(rate)
        val want = doubleArrayOf(
            (1 + alpha * a) / a0, -2 * cos(w) / a0, (1 - alpha * a) / a0, -2 * cos(w) / a0, (1 - alpha / a) / a0,
        )
        for (index in want.indices) assertEquals(want[index], got[index], 1e-12)
    }

    @Test
    fun filtersReachTheirGainWhereTheyShould() {
        val dsp = ParametricEqualizerDsp()
        dsp.configure(configuration(listOf(filter("peak", 1000.0, 6.0, 1.4))))
        assertEquals(6.0, gainAt(dsp, 1000.0), 0.02)
        assertEquals(0.0, gainAt(dsp, 60.0), 0.05)
        assertEquals(0.0, gainAt(dsp, 15000.0), 0.05)

        dsp.configure(configuration(listOf(filter("lowshelf", 200.0, -5.0, 0.707))))
        assertEquals(-5.0, gainAt(dsp, 30.0), 0.05)
        assertEquals(-2.5, gainAt(dsp, 200.0), 0.05)
        assertEquals(0.0, gainAt(dsp, 5000.0), 0.02)

        dsp.configure(configuration(listOf(filter("highshelf", 4000.0, 4.0, 0.707))))
        assertEquals(0.0, gainAt(dsp, 100.0), 0.02)
        assertEquals(2.0, gainAt(dsp, 4000.0), 0.05)
        assertEquals(4.0, gainAt(dsp, 18000.0), 0.1)
    }

    @Test
    fun inputGainAndSeveralFiltersAddUp() {
        val dsp = ParametricEqualizerDsp()
        dsp.configure(
            configuration(
                listOf(filter("peak", 1000.0, 6.0, 1.0), filter("peak", 1000.0, -2.0, 1.0)),
                inputGain = -3.0,
            ),
        )
        // Two peaks of one width do not sum to a third exactly off centre,
        // but at the centre their gains add.
        assertEquals(6.0 - 2.0 - 3.0, gainAt(dsp, 1000.0), 0.02)
    }

    @Test
    fun offOrUnknownEncodingLeavesTheBufferUnread() {
        val dsp = ParametricEqualizerDsp()
        dsp.prepare(48000, 2)
        val input = floats(FloatArray(8) { 0.5f })
        val output = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder())
        assertFalse(dsp.active)
        assertFalse(dsp.process(input, output, C.ENCODING_PCM_FLOAT))
        assertEquals(0, input.position())
        dsp.configure(configuration(listOf(filter("peak", 1000.0, 6.0, 1.0))))
        assertTrue(dsp.active)
        assertFalse(dsp.process(input, output, C.ENCODING_PCM_16BIT_BIG_ENDIAN))
        assertEquals(0, input.position())
        dsp.configure(mapOf("enabled" to false))
        assertFalse(dsp.active)
    }

    @Test
    fun integerPcmKeepsItsWidthAndLevel() {
        for ((encoding, width) in listOf(
            C.ENCODING_PCM_16BIT to 2,
            C.ENCODING_PCM_24BIT to 3,
            C.ENCODING_PCM_32BIT to 4,
        )) {
            val dsp = ParametricEqualizerDsp()
            // No filter: the input gain alone, so each sample is checkable.
            dsp.configure(configuration(emptyList(), inputGain = -6.0206))
            dsp.prepare(44100, 2)
            val frames = 64
            val input = ByteBuffer.allocateDirect(frames * 2 * width).order(ByteOrder.LITTLE_ENDIAN)
            val full = 1L shl (width * 8 - 1)
            repeat(frames) { frame ->
                for (channel in 0 until 2) {
                    val sample = (if (channel == 0) full / 2 else -full / 4) + frame
                    for (byte in 0 until width) input.put((sample shr (8 * byte)).toByte())
                }
            }
            input.flip()
            val output = ByteBuffer.allocateDirect(input.remaining()).order(ByteOrder.LITTLE_ENDIAN)
            assertTrue(dsp.process(input, output, encoding))
            assertFalse(input.hasRemaining())
            output.flip()
            assertEquals(frames * 2 * width, output.remaining())
            repeat(frames) { frame ->
                for (channel in 0 until 2) {
                    var sample = 0L
                    for (byte in 0 until width) {
                        val value = output.get().toLong()
                        sample = sample or ((if (byte == width - 1) value else value and 0xFF) shl (8 * byte))
                    }
                    val want = ((if (channel == 0) full / 2 else -full / 4) + frame) / 2.0
                    // Half the level, within the dither of 16-bit output and
                    // the rounding of the gain written in dB.
                    val slack = (if (width == 2) 1.6 else 1.0) + abs(want) * 1e-6
                    assertTrue("$encoding $frame $channel", abs(sample - want) <= slack)
                }
            }
        }
    }

    @Test
    fun changingAFilterSlidesWithoutAJump() {
        val dsp = ParametricEqualizerDsp()
        dsp.configure(configuration(listOf(filter("peak", 1000.0, 0.5, 1.0))))
        dsp.prepare(48000, 1)
        val constant = FloatArray(4800) { 0.25f }
        val first = ByteBuffer.allocateDirect(constant.size * 4).order(ByteOrder.nativeOrder())
        assertTrue(dsp.process(floats(constant), first, C.ENCODING_PCM_FLOAT))
        dsp.configure(configuration(listOf(filter("peak", 1000.0, 12.0, 1.0)), inputGain = -12.0))
        val second = ByteBuffer.allocateDirect(constant.size * 4).order(ByteOrder.nativeOrder())
        assertTrue(dsp.process(floats(constant), second, C.ENCODING_PCM_FLOAT))
        second.flip()
        var previous = first.getFloat((constant.size - 1) * 4)
        var largest = 0f
        for (index in constant.indices) {
            val value = second.getFloat(index * 4)
            largest = maxOf(largest, abs(value - previous))
            previous = value
        }
        // The input gain falls by 12 dB over 5 ms (240 frames), not at once.
        assertTrue("step $largest", largest < 0.01f)
        assertEquals(0.25f * 0.2512f, previous, 0.002f)
    }
}
