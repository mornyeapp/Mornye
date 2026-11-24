package com.zarz.mornye

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Lossless PCM representation changes only: no gain, dithering or resampling. */
internal object BitPerfectPcm {
    fun outputBits(sourceBits: Int, supported: List<Int>): Int? =
        supported.filter { it in listOf(16, 24, 32) && it >= sourceBits }.minOrNull()

    fun convert(input: ByteBuffer, inputBits: Int, sourceBits: Int, outputBits: Int, floating: Boolean, reuse: ByteBuffer? = null): ByteBuffer {
        require(sourceBits in listOf(16, 24, 32) && outputBits in listOf(16, 24, 32) && outputBits >= sourceBits)
        require(if (floating) inputBits == 32 && sourceBits <= 24 else inputBits >= sourceBits)
        val bytes = inputBits / 8
        require(input.remaining() % bytes == 0)
        input.order(ByteOrder.LITTLE_ENDIAN)
        val size = input.remaining() / bytes * (outputBits / 8)
        val output = (reuse?.takeIf { it.isDirect && !it.isReadOnly && it.capacity() >= size }
            ?: ByteBuffer.allocateDirect(size)).order(ByteOrder.LITTLE_ENDIAN)
        output.clear()
        output.limit(size)
        if (!floating && inputBits == sourceBits && outputBits == inputBits) {
            output.put(input)
            output.flip()
            return output
        }
        while (input.hasRemaining()) {
            val sample = if (floating) {
                val scaled = input.float.toDouble() * (1L shl (sourceBits - 1))
                require(scaled.isFinite() && scaled >= -(1L shl (sourceBits - 1)) &&
                    scaled < (1L shl (sourceBits - 1)) && scaled == scaled.toLong().toDouble())
                scaled.toInt() shl (32 - sourceBits)
            } else {
                when (inputBits) {
                    16 -> input.short.toInt() shl 16
                    24 -> ((input.get().toInt() and 255) or
                        ((input.get().toInt() and 255) shl 8) or
                        ((input.get().toInt() and 255) shl 16)) shl 8
                    32 -> input.int
                    else -> error("Unsupported PCM encoding")
                }
            }
            // Reject a decoder output containing more precision than the source contract.
            require(sourceBits == 32 || (sample shl sourceBits) == 0)
            when (outputBits) {
                16 -> output.putShort((sample shr 16).toShort())
                24 -> {
                    output.put((sample shr 8).toByte())
                    output.put((sample shr 16).toByte())
                    output.put((sample shr 24).toByte())
                }
                32 -> output.putInt(sample)
            }
        }
        output.flip()
        return output
    }

    /** Each mono sample twice, for a stereo-only output; no sample changes. */
    fun duplicateMono(input: ByteBuffer, sampleBytes: Int, reuse: ByteBuffer? = null): ByteBuffer {
        require(sampleBytes > 0 && input.remaining() % sampleBytes == 0)
        val size = input.remaining() * 2
        val output = (reuse?.takeIf { it.isDirect && !it.isReadOnly && it.capacity() >= size }
            ?: ByteBuffer.allocateDirect(size)).order(ByteOrder.LITTLE_ENDIAN)
        output.clear()
        output.limit(size)
        val sample = ByteArray(sampleBytes)
        while (input.hasRemaining()) {
            input.get(sample)
            output.put(sample)
            output.put(sample)
        }
        output.flip()
        return output
    }

    fun flacFormat(header: ByteArray): Triple<Int, Int, Int>? {
        if (header.size < 42 || header.take(4) != listOf<Byte>(102, 76, 97, 67) ||
            header[4].toInt() and 127 != 0 || header[5].toInt() != 0 ||
            header[6].toInt() != 0 || header[7].toInt() != 34) return null
        fun byte(i: Int) = header[i].toInt() and 255
        val rate = (byte(18) shl 12) or (byte(19) shl 4) or (byte(20) shr 4)
        val channels = ((byte(20) shr 1) and 7) + 1
        val bits = (((byte(20) and 1) shl 4) or (byte(21) shr 4)) + 1
        return Triple(rate, channels, bits)
    }
}
