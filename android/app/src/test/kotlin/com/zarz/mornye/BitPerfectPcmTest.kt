package com.zarz.mornye

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.random.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertNotSame
import org.junit.Test

class BitPerfectPcmTest {
    private fun bytes(buffer: ByteBuffer): ByteArray = ByteArray(buffer.remaining()).also { buffer.get(it) }

    @Test
    fun selectsOnlyAnIntegerFormatWithEnoughPrecision() {
        assertEquals(24, BitPerfectPcm.outputBits(24, listOf(16, 32, 24)))
        assertEquals(32, BitPerfectPcm.outputBits(24, listOf(16, 32)))
        assertNull(BitPerfectPcm.outputBits(24, listOf(16)))
        assertNull(BitPerfectPcm.outputBits(32, listOf(16, 24)))
    }

    @Test
    fun preservesPacked24BitSamplesIncludingSignExtremes() {
        val samples = byteArrayOf(0, 0, -128, -1, -1, 127, -1, -1, -1, 1, 0, 0)
        val input = ByteBuffer.wrap(samples)
        assertArrayEquals(samples, bytes(BitPerfectPcm.convert(input, 24, 24, 24, false)))
    }

    @Test
    fun padsLeastSignificantBitsWithoutChangingSampleAmplitude() {
        val input = ByteBuffer.allocate(6).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(Short.MIN_VALUE).putShort(Short.MAX_VALUE).putShort(-1)
        input.flip()
        val result = BitPerfectPcm.convert(input, 16, 16, 32, false)
        assertEquals(Int.MIN_VALUE, result.int)
        assertEquals(0x7fff0000, result.int)
        assertEquals(-65536, result.int)
    }

    @Test
    fun reusesWritableDirectCapacityAndResetsBoundsForShorterChunks() {
        val reusable = ByteBuffer.allocateDirect(32)
        reusable.position(10)
        reusable.limit(12)
        val input = ByteBuffer.wrap(byteArrayOf(1, 0, -1, -1))
        val result = BitPerfectPcm.convert(input, 16, 16, 24, false, reusable)
        assertSame(reusable, result)
        assertArrayEquals(byteArrayOf(0, 1, 0, 0, -1, -1), bytes(result))
        val shorter = BitPerfectPcm.convert(ByteBuffer.wrap(byteArrayOf(2, 0)), 16, 16, 16, false, result)
        assertSame(result, shorter)
        assertArrayEquals(byteArrayOf(2, 0), bytes(shorter))
    }

    @Test
    fun growsCapacityAndRejectsReadOnlyOrHeapBuffersForReuse() {
        val small = ByteBuffer.allocateDirect(2)
        val grown = BitPerfectPcm.convert(ByteBuffer.wrap(byteArrayOf(1, 0)), 16, 16, 32, false, small)
        assertNotSame(small, grown)
        assertArrayEquals(byteArrayOf(0, 0, 1, 0), bytes(grown))
        for (invalid in listOf(ByteBuffer.allocate(8), ByteBuffer.allocateDirect(8).asReadOnlyBuffer())) {
            val result = BitPerfectPcm.convert(ByteBuffer.wrap(byteArrayOf(3, 0)), 16, 16, 16, false, invalid)
            assertNotSame(invalid, result)
            assertArrayEquals(byteArrayOf(3, 0), bytes(result))
        }
    }

    @Test
    fun decoderFloatRoundTripPreservesEveryBitOf24BitSamples() {
        val random = Random(17)
        val samples = listOf(-8388608, 8388607, -1, 0, 1) + List(10000) { random.nextInt(-8388608, 8388608) }
        val input = ByteBuffer.allocate(samples.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (sample in samples) input.putFloat(sample / 8388608f)
        input.flip()
        val result = BitPerfectPcm.convert(input, 32, 24, 32, true)
        for (sample in samples) assertEquals(sample shl 8, result.int)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsDecoderDownconversion() {
        BitPerfectPcm.convert(ByteBuffer.allocate(2), 16, 24, 24, false)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsFloatingPointFor32BitSource() {
        BitPerfectPcm.convert(ByteBuffer.allocate(4), 32, 32, 32, true)
    }

    @Test(expected = IllegalArgumentException::class)
    fun refusesRoundingOfNonRepresentableFloatSamples() {
        val input = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putFloat(0.00000001f)
        input.flip()
        BitPerfectPcm.convert(input, 32, 24, 24, true)
    }

    @Test
    fun readsFlacPrecisionFromStreaminfoInsteadOfLibraryTags() {
        val header = ByteArray(42)
        "fLaC".toByteArray().copyInto(header)
        header[4] = -128
        header[7] = 34
        val rate = 96000
        val packed = (rate.toLong() shl 44) or (1L shl 41) or (23L shl 36)
        for (i in 0..7) header[18 + i] = (packed ushr (56 - i * 8)).toByte()
        assertEquals(Triple(96000, 2, 24), BitPerfectPcm.flacFormat(header))
        header[7] = 33
        assertNull(BitPerfectPcm.flacFormat(header))
        assertNull(BitPerfectPcm.flacFormat(ByteArray(4)))
    }

    @Test
    fun duplicatesEachMonoSampleUnchangedOnBothChannels() {
        // 24-bit packed: two samples, the sign extremes.
        val mono = byteArrayOf(0, 0, -128, -1, -1, 127)
        assertArrayEquals(
            byteArrayOf(0, 0, -128, 0, 0, -128, -1, -1, 127, -1, -1, 127),
            bytes(BitPerfectPcm.duplicateMono(ByteBuffer.wrap(mono), 3)),
        )
        // 32-bit containers, reusing a buffer that is large enough.
        val wide = Random(7).nextBytes(64)
        val reuse = ByteBuffer.allocateDirect(256)
        val result = BitPerfectPcm.duplicateMono(ByteBuffer.wrap(wide), 4, reuse)
        assertSame(reuse, result)
        val stereo = bytes(result)
        assertEquals(128, stereo.size)
        for (frame in 0 until 16) {
            val sample = wide.copyOfRange(frame * 4, frame * 4 + 4)
            assertArrayEquals(sample, stereo.copyOfRange(frame * 8, frame * 8 + 4))
            assertArrayEquals(sample, stereo.copyOfRange(frame * 8 + 4, frame * 8 + 8))
        }
    }
}
