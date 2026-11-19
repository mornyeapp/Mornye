package com.zarz.mornye

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.random.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class UsbDirectFormatsTest {
    private fun bytes(buffer: ByteBuffer): ByteArray = ByteArray(buffer.remaining()).also { buffer.get(it) }

    private fun floats(vararg values: Float): ByteBuffer =
        ByteBuffer.allocate(values.size * 4).order(ByteOrder.LITTLE_ENDIAN).apply {
            values.forEach { putFloat(it) }
            flip()
        }

    @Test
    fun classifiesTransportErrorsWithoutLosingUnknownOnes() {
        val cases = mapOf(
            "No compatible USB format for 1ch 16-bit 44100 Hz; DAC offers 2ch 16-bit" to UsbDirectFormats.DAC_FORMAT,
            "USB clock rate could not be verified" to UsbDirectFormats.DAC_FORMAT,
            "USB clock does not offer 96000 Hz" to UsbDirectFormats.DAC_FORMAT,
            "Variable USB clock has no rate control" to UsbDirectFormats.DAC_FORMAT,
            "USB error -9" to UsbDirectFormats.DAC_FORMAT,
            "USB error -6" to UsbDirectFormats.DAC_OPEN,
            "USB error -3" to UsbDirectFormats.DAC_OPEN,
            "Cannot open USB device" to UsbDirectFormats.DAC_OPEN,
            "Invalid USB device/configuration" to UsbDirectFormats.DAC_OPEN,
            "Implicit feedback is not supported" to UsbDirectFormats.DAC_UNSUPPORTED,
            "USB bus speed unavailable or unsupported" to UsbDirectFormats.DAC_UNSUPPORTED,
            "USB endpoint bandwidth too small" to UsbDirectFormats.DAC_FORMAT,
            "Multiple USB configurations are not supported" to UsbDirectFormats.DAC_UNSUPPORTED,
            "No supported USB endpoint" to UsbDirectFormats.DAC_UNSUPPORTED,
            "USB clock selector 40 reports input 3 of 2" to UsbDirectFormats.DAC_UNSUPPORTED,
            "USB clock topology loops" to UsbDirectFormats.DAC_UNSUPPORTED,
            "Decoder timed out" to UsbDirectFormats.TIMEOUT,
            "Something new" to UsbDirectFormats.UNSUPPORTED,
        )
        for ((message, reason) in cases) assertEquals(message, reason, UsbDirectFormats.classifyOutput(message))
        assertEquals(UsbDirectFormats.UNSUPPORTED, UsbDirectFormats.classifyOutput(null))
    }

    @Test
    fun opensTheDacAtTheSongRateUnlessALimitOrAnEarlierRefusalSaysOtherwise() {
        assertEquals(listOf(96000, 48000, 88200), UsbDirectFormats.outputRates(96000).take(3))
        // The user's limit: nothing above it is ever asked of the DAC.
        assertEquals(listOf(48000, 44100), UsbDirectFormats.outputRates(96000, limit = 48000))
        assertEquals(listOf(44100, 48000), UsbDirectFormats.outputRates(88200, limit = 48000))
        assertEquals(listOf(48000, 44100), UsbDirectFormats.outputRates(48000, limit = 48000))
        assertEquals(listOf(96000, 48000, 88200, 44100), UsbDirectFormats.outputRates(192000, limit = 96000))
        // The rate the DAC played this song rate at before comes first.
        assertEquals(listOf(48000, 96000, 88200), UsbDirectFormats.outputRates(96000, played = 48000).take(3))
        assertEquals(listOf(96000, 48000), UsbDirectFormats.outputRates(96000, played = 96000).take(2))
        // One remembered from before the limit was set does not pass it.
        assertEquals(listOf(48000, 44100), UsbDirectFormats.outputRates(96000, limit = 48000, played = 96000))
        // A limit below every rate leaves the list as it was.
        assertEquals(UsbDirectFormats.outputRates(96000), UsbDirectFormats.outputRates(96000, limit = 8000))
    }

    @Test
    fun convertsARefusedRateToTheNearestLowerRateOfItsFamilyFirst() {
        assertEquals(
            listOf(48000, 88200, 44100, 176400, 192000, 352800, 384000),
            UsbDirectFormats.resampleRates(96000),
        )
        assertEquals(listOf(44100, 48000), UsbDirectFormats.resampleRates(88200).take(2))
        assertEquals(listOf(96000, 48000, 176400), UsbDirectFormats.resampleRates(192000).take(3))
        // A DAC without 44.1 kHz nearly always has 48 kHz.
        assertEquals(listOf(48000, 88200), UsbDirectFormats.resampleRates(44100).take(2))
        assertEquals(listOf(44100, 88200), UsbDirectFormats.resampleRates(48000).take(2))
        assertEquals(listOf(44100, 48000), UsbDirectFormats.resampleRates(22050).take(2))
        assertEquals(listOf(44100, 48000), UsbDirectFormats.resampleRates(32000).take(2))
    }

    @Test
    fun namesCodecsAndDescribesSources() {
        assertEquals("ALAC", UsbDirectFormats.codecName("audio/alac"))
        assertEquals("AAC", UsbDirectFormats.codecName("audio/mp4a-latm"))
        assertEquals("MP3", UsbDirectFormats.codecName("audio/mpeg"))
        assertEquals("Opus", UsbDirectFormats.codecName("audio/opus"))
        assertEquals("WMA", UsbDirectFormats.codecName("audio/x-wma"))
        val info = UsbSourceInfo("ALAC", 96000, 24, 2)
        assertEquals("ALAC 24-bit 96000 Hz 2ch", info.describe())
        assertEquals(
            mapOf("codec" to "ALAC", "lossy" to false, "sampleRate" to 96000, "sourceBitDepth" to 24, "channels" to 2),
            info.toMap(),
        )
        // A lossy source reports no depth of its own.
        assertEquals(false, UsbSourceInfo("AAC", 44100, 0, 2, true).toMap().containsKey("sourceBitDepth"))
    }

    @Test
    fun losslessSourcesAbove24BitsCannotStayExact() {
        assertEquals(16, UsbDirectFormats.losslessContainerBits(8))
        assertEquals(16, UsbDirectFormats.losslessContainerBits(16))
        assertEquals(24, UsbDirectFormats.losslessContainerBits(20))
        assertEquals(24, UsbDirectFormats.losslessContainerBits(24))
        assertNull(UsbDirectFormats.losslessContainerBits(32))
        assertNull(UsbDirectFormats.losslessContainerBits(0))
        // Why: a 32-bit integer needs more than a float's 24 significant bits.
        val sample = 0x7fffff7f
        assertEquals(false, (sample.toFloat().toDouble()).toLong() == sample.toLong())
    }

    /** Decoders scale an n-bit integer by 2^-(n-1); every value must come back unchanged. */
    private fun assertFloatRoundTrip(bits: Int) {
        val count = 1 shl bits
        val chunk = minOf(count, 1 shl 20)
        val input = ByteBuffer.allocateDirect(chunk * 4).order(ByteOrder.LITTLE_ENDIAN)
        var reuse: ByteBuffer? = null
        var start = -(1 shl (bits - 1))
        val end = 1 shl (bits - 1)
        val scale = 1.0f / (1 shl (bits - 1))
        while (start < end) {
            val size = minOf(chunk, end - start)
            input.clear()
            for (i in 0 until size) input.putFloat((start + i) * scale)
            input.flip()
            val output = BitPerfectPcm.convert(input, 32, bits, 32, true, reuse).also { reuse = it }
            for (i in 0 until size) assertEquals(start + i, output.int shr (32 - bits))
            start += size
        }
    }

    @Test
    fun everySixteenBitValueSurvivesFloatDecoding() = assertFloatRoundTrip(16)

    @Test
    fun everyTwentyFourBitValueSurvivesFloatDecoding() = assertFloatRoundTrip(24)

    @Test
    fun floatOutputWithMorePrecisionThanTheSourceIsRejected() {
        val inexact = floats(0.5f + 1f / (1 shl 20))
        assertThrows(IllegalArgumentException::class.java) { BitPerfectPcm.convert(inexact, 32, 16, 24, true) }
    }

    @Test
    fun lossyFloatsRoundWithoutDitherAndClip() {
        val step = 1f / (1 shl 23)
        val input = floats(0f, 0.4f * step, 0.6f * step, -0.6f * step, 1.5f, -1.5f, Float.NaN, 0.5f)
        val output = UsbDirectFormats.quantize(input, 24, 32)
        val samples = IntArray(8) { output.int shr 8 }
        assertArrayEquals(intArrayOf(0, 0, 1, -1, (1 shl 23) - 1, -(1 shl 23), 0, 1 shl 22), samples)
        val sixteen = UsbDirectFormats.quantize(floats(0.5f, -1f), 16, 16)
        assertEquals(16384.toShort(), sixteen.short)
        assertEquals(Short.MIN_VALUE, sixteen.short)
        val packed = bytes(UsbDirectFormats.quantize(floats(-step), 24, 24))
        assertArrayEquals(byteArrayOf(-1, -1, -1), packed)
    }

    @Test
    fun tailHoldsBackExactlyThePadding() {
        val random = Random(7)
        val stream = ByteArray(10000) { random.nextInt().toByte() }
        for (hold in listOf(0, 1, 6, 4096, 20000)) {
            val tail = PcmTail(hold)
            val result = java.io.ByteArrayOutputStream()
            var offset = 0
            while (offset < stream.size) {
                val size = minOf(random.nextInt(1, 3000), stream.size - offset)
                result.write(bytes(tail.push(ByteBuffer.wrap(stream, offset, size))))
                offset += size
            }
            tail.clear()
            assertArrayEquals("hold $hold", stream.copyOf(maxOf(0, stream.size - hold)), result.toByteArray())
        }
    }

    @Test
    fun seekSkipMatchesThePcmPath() {
        assertEquals(0, UsbDirectFormats.skipFrames(1000000, 500000, 44100))
        assertEquals(44100, UsbDirectFormats.skipFrames(0, 1000000, 44100))
        // Rounds up so the first sent frame is never before the target.
        assertEquals(1, UsbDirectFormats.skipFrames(0, 1, 44100))
        assertEquals(4410, UsbDirectFormats.skipFrames(-100000, 0, 44100))
        assertEquals(48000 * 3, UsbDirectFormats.skipFrames(2000000, 5000000, 48000))
    }

    /** A configuration descriptor with [value] and one interface descriptor of [interfaceClass]. */
    private fun configuration(value: Int, interfaceClass: Int): ByteArray =
        byteArrayOf(9, 2, 18, 0, 1, value.toByte(), 0, 0x80.toByte(), 50) +
            byteArrayOf(9, 4, 0, 0, 0, interfaceClass.toByte(), 1, 0x20, 0)

    private val deviceDescriptor = ByteArray(18).also {
        it[0] = 18
        it[1] = 1
        it[17] = 2
    }

    @Test
    fun keepsOnlyTheActiveUsbConfiguration() {
        val first = configuration(1, 1)
        val second = configuration(2, 0xff)
        val raw = deviceDescriptor + first + second
        assertArrayEquals(deviceDescriptor + second, UsbDirectFormats.activeConfiguration(raw, 2))
        assertArrayEquals(deviceDescriptor + first, UsbDirectFormats.activeConfiguration(raw, 1))
        // Unknown or unlisted: the first configuration, as the kernel picks for UAC1/UAC2.
        assertArrayEquals(deviceDescriptor + first, UsbDirectFormats.activeConfiguration(raw, null))
        assertArrayEquals(deviceDescriptor + first, UsbDirectFormats.activeConfiguration(raw, 3))
    }

    @Test
    fun leavesSingleAndMalformedUsbConfigurationsUnchanged() {
        val single = deviceDescriptor + configuration(1, 1)
        assertArrayEquals(single, UsbDirectFormats.activeConfiguration(single, 1))
        assertArrayEquals(single, UsbDirectFormats.activeConfiguration(single, null))
        // wTotalLength runs past the end.
        val truncated = deviceDescriptor + configuration(1, 1) + configuration(2, 1).copyOf(12)
        assertArrayEquals(truncated, UsbDirectFormats.activeConfiguration(truncated, 2))
        // Something other than a configuration follows the device descriptor.
        val stray = deviceDescriptor + configuration(1, 1) + byteArrayOf(9, 4, 0, 0, 0, 1, 1, 0, 0)
        assertArrayEquals(stray, UsbDirectFormats.activeConfiguration(stray, 1))
        assertArrayEquals(ByteArray(0), UsbDirectFormats.activeConfiguration(ByteArray(0), 1))
    }

    @Test
    fun readsAlacBitDepthFromBareAndBoxedCookies() {
        val cookie = ByteArray(24).also {
            it[3] = 16 // frame length 4096
            it[4] = 0
            it[5] = 24
            it[9] = 2
        }
        assertEquals(24, UsbDirectFormats.alacBitDepth(cookie))
        val boxed = byteArrayOf(0, 0, 0, 36, 'a'.code.toByte(), 'l'.code.toByte(), 'a'.code.toByte(), 'c'.code.toByte(), 0, 0, 0, 0) + cookie
        assertEquals(24, UsbDirectFormats.alacBitDepth(boxed))
        assertNull(UsbDirectFormats.alacBitDepth(ByteArray(10)))
        assertNull(UsbDirectFormats.alacBitDepth(cookie.copyOf().also { it[4] = 1 }))
    }

    @Test
    fun keepsThePlayingLevelAcrossATrackChangeOnly() {
        // The system lowered the DAC while the app let go of it between tracks.
        assertEquals(-18.0, UsbDirectFormats.restoredVolumeDb(-18.0, -52.0, 40), 0.0)
        assertEquals(-18.0, UsbDirectFormats.restoredVolumeDb(-18.0, -52.0, UsbDirectFormats.TRACK_CHANGE_WINDOW_MS), 0.0)
        // A DAC opened later, or never held before, is not made louder than it connects.
        assertEquals(-52.0, UsbDirectFormats.restoredVolumeDb(-18.0, -52.0, UsbDirectFormats.TRACK_CHANGE_WINDOW_MS + 1), 0.0)
        assertEquals(-52.0, UsbDirectFormats.restoredVolumeDb(-18.0, -52.0, null), 0.0)
        assertEquals(-52.0, UsbDirectFormats.restoredVolumeDb(-18.0, -52.0, -5), 0.0)
        // A DAC that connects louder still gets the remembered level.
        assertEquals(-18.0, UsbDirectFormats.restoredVolumeDb(-18.0, 0.0, null), 0.0)
    }

    @Test
    fun handsADacBackAtTheLevelItConnectedWith() {
        // The app lowered it to play; other apps get the level they had.
        assertEquals(0.0, UsbDirectFormats.levelToHandBack(0.0, -40.0)!!, 0.0)
        // Never lower than it plays now, and nothing without a known level.
        assertNull(UsbDirectFormats.levelToHandBack(-52.0, -40.0))
        assertNull(UsbDirectFormats.levelToHandBack(-40.0, -40.0))
        assertNull(UsbDirectFormats.levelToHandBack(null, -40.0))
    }
}
