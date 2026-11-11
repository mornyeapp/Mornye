package com.zarz.mornye

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.Closeable
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes a compressed track with MediaCodec for Direct USB, never through
 * AudioTrack. Lossless sources stay exact: up to 16 bits use the decoder's
 * integer output, deeper ones its float output, which [BitPerfectPcm]
 * checks sample by sample. Lossy sources are rounded to the DAC's precision
 * without dither. The constructor primes the decoder, so [rate] and
 * [channels] are the real output (HE-AAC doubles its rate after SBR).
 */
internal class UsbCodecStream(
    private val extractor: MediaExtractor,
    track: MediaFormat,
    mime: String,
    deadline: Long,
) : Closeable {
    val lossy = mime in UsbDirectFormats.LOSSY_DECODE
    val info: UsbSourceInfo
    /** The integer container for lossless output; lossy output asks the DAC for 24 bits. */
    val containerBits: Int
    var rate = 0
        private set
    var channels = 0
        private set
    var ended = false
        private set
    var bufferTimeUs = 0L
        private set
    private var encoding = AudioFormat.ENCODING_PCM_16BIT
    private val codec: MediaCodec
    private val buffer = MediaCodec.BufferInfo()
    private var inputDone = false
    private var outputEnded = false
    private var primed = false
    private var stash: ByteBuffer? = null
    private var stashUs = 0L
    private val delayFrames: Long
    private val paddingFrames: Int
    private var trimFrames = 0L
    private var targetUs = 0L
    private var firstSampleUs = 0L
    private var originUs = 0L
    private var tail: PcmTail? = null
    private var tailFrameBytes = 0
    private var converted: ByteBuffer? = null

    init {
        val (described, bits, name) = inspect(track, mime)
        containerBits = bits
        delayFrames = track.integer("encoder-delay").coerceIn(0, 1 shl 20).toLong()
        paddingFrames = track.integer("encoder-padding").coerceIn(0, 1 shl 20)
        // This stream trims delay and padding itself; a decoder told about them
        // would trim them too.
        track.setInteger("encoder-delay", 0)
        track.setInteger("encoder-padding", 0)
        // Float is exact for 24-bit integers; 16-bit sources keep the integer default.
        val wantFloat = lossy || containerBits > 16
        codec = try { MediaCodec.createByCodecName(name) }
            catch (error: Exception) { throw UsbDirectException(UsbDirectFormats.DECODER, "$name: ${error.message}", described) }
        try {
            configure(track, wantFloat, name, described)
            codec.start()
            // An edit list can start the timeline below zero; -1 means no sample.
            firstSampleUs = extractor.sampleTime.takeIf { it != -1L } ?: 0
            prime(deadline, described)
            // The decoder's output is what plays, not what the container claims.
            info = described.copy(rate = rate, channels = channels)
            checkChannels(channels, info)
            checkEncoding(info)
            originUs = firstSampleUs + delayFrames * 1000000 / rate
            trimFrames = delayFrames
        } catch (error: Exception) {
            runCatching { codec.release() }
            throw error
        }
    }

    private fun checkEncoding(described: UsbSourceInfo) {
        val exact = when (encoding) {
            AudioFormat.ENCODING_PCM_16BIT -> lossy || containerBits == 16
            AudioFormat.ENCODING_PCM_FLOAT -> true
            AudioFormat.ENCODING_PCM_24BIT_PACKED, AudioFormat.ENCODING_PCM_32BIT -> !lossy
            else -> false
        }
        if (!exact) throw UsbDirectException(UsbDirectFormats.FORMAT, "Decoder output encoding $encoding loses precision", described)
        // Reject a decoder that does not return the source's integers.
        if (!lossy) stash?.let {
            runCatching { BitPerfectPcm.convert(it.duplicate(), inputBits(), containerBits, 32, encoding == AudioFormat.ENCODING_PCM_FLOAT) }
                .getOrElse { throw UsbDirectException(UsbDirectFormats.FORMAT, "Decoder output is not exact ${containerBits}-bit PCM", described) }
        }
    }

    private fun configure(track: MediaFormat, wantFloat: Boolean, name: String, described: UsbSourceInfo) {
        if (wantFloat) {
            track.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_FLOAT)
            try { codec.configure(track, null, null, 0); return }
            catch (error: Exception) {
                // A deep lossless source needs float; a lossy one can still use 16-bit.
                if (!lossy) throw UsbDirectException(UsbDirectFormats.FORMAT, "$name has no float output: ${error.message}", described)
                codec.reset()
                track.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            }
        }
        try { codec.configure(track, null, null, 0) }
        catch (error: Exception) { throw UsbDirectException(UsbDirectFormats.DECODER, "$name: ${error.message}", described) }
    }

    /** Decodes until the first audio, which fixes the output format, and keeps it. */
    private fun prime(deadline: Long, described: UsbSourceInfo) {
        while (stash == null) {
            if (android.os.SystemClock.elapsedRealtime() > deadline) {
                throw UsbDirectException(UsbDirectFormats.TIMEOUT, "Decoder timed out before the first audio", described)
            }
            feed()
            val index = codec.dequeueOutputBuffer(buffer, 10000)
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) applyFormat(codec.outputFormat)
            if (index < 0) continue
            if (rate == 0) applyFormat(codec.getOutputFormat(index))
            if (buffer.size > 0) {
                val data = requireNotNull(codec.getOutputBuffer(index))
                data.position(buffer.offset)
                data.limit(buffer.offset + buffer.size)
                stash = ByteBuffer.allocateDirect(buffer.size).order(ByteOrder.LITTLE_ENDIAN).put(data).also { it.flip() }
                stashUs = buffer.presentationTimeUs
            }
            val end = buffer.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
            codec.releaseOutputBuffer(index, false)
            if (end && stash == null) throw UsbDirectException(UsbDirectFormats.FORMAT, "Decoder produced no audio", described)
            // A very short song can end in its first buffer.
            outputEnded = end
        }
        if (rate <= 0 || channels <= 0) throw UsbDirectException(UsbDirectFormats.FORMAT, "Decoder reported no output format", described)
        primed = true
    }

    /** Before the first audio the format may still change; afterwards a change stops playback. */
    private fun applyFormat(format: MediaFormat) {
        val newRate = format.integer(MediaFormat.KEY_SAMPLE_RATE)
        val newChannels = format.integer(MediaFormat.KEY_CHANNEL_COUNT)
        val newEncoding = format.integer(MediaFormat.KEY_PCM_ENCODING).takeIf { it != 0 } ?: AudioFormat.ENCODING_PCM_16BIT
        if (primed) {
            if (newRate != rate || newChannels != channels || newEncoding != encoding) {
                throw UsbDirectException(UsbDirectFormats.FORMAT, "Decoder output changed from $rate Hz ${channels}ch " +
                    "encoding $encoding to $newRate Hz ${newChannels}ch encoding $newEncoding", info)
            }
            return
        }
        rate = newRate
        channels = newChannels
        encoding = newEncoding
    }

    private fun feed() {
        repeat(4) {
            if (inputDone) return
            val index = codec.dequeueInputBuffer(0)
            if (index < 0) return
            val input = requireNotNull(codec.getInputBuffer(index))
            val size = extractor.readSampleData(input, 0)
            if (size < 0) {
                codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                inputDone = true
                return
            }
            codec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
            extractor.advance()
        }
    }

    private fun inputBits() = when (encoding) {
        AudioFormat.ENCODING_PCM_16BIT -> 16
        AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
        else -> 32
    }

    /** Returns the next PCM in [outputBits] containers, or null when none is ready yet. */
    fun read(outputBits: Int): ByteBuffer? {
        if (ended) return null
        stash?.let { data ->
            stash = null
            val result = emit(data, stashUs, outputBits)
            if (outputEnded) finish()
            if (result != null) return result
        }
        if (outputEnded) {
            finish()
            return null
        }
        repeat(16) {
            feed()
            // Short waits keep pause and seek responsive on the shared worker.
            val index = codec.dequeueOutputBuffer(buffer, 1000)
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) applyFormat(codec.outputFormat)
            if (index < 0) return@repeat
            val end = buffer.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
            val result = try {
                if (buffer.size > 0) {
                    val data = requireNotNull(codec.getOutputBuffer(index))
                    data.position(buffer.offset)
                    data.limit(buffer.offset + buffer.size)
                    emit(data, buffer.presentationTimeUs, outputBits)
                } else null
            } finally { codec.releaseOutputBuffer(index, false) }
            if (end) finish()
            if (result != null && result.hasRemaining()) return result
            if (end) return null
        }
        return null
    }

    private fun finish() {
        outputEnded = true
        ended = true
        // What the tail still holds is the encoder padding.
        tail?.clear()
    }

    private fun emit(data: ByteBuffer, timeUs: Long, outputBits: Int): ByteBuffer? {
        val frame = channels * inputBits() / 8
        require(frame > 0 && data.remaining() % frame == 0) { "Decoder returned a partial frame" }
        val frames = (data.remaining() / frame).toLong()
        val contentUs = timeUs - originUs
        val skip = if (trimFrames > 0) minOf(trimFrames, frames).also { trimFrames -= it }
            else minOf(UsbDirectFormats.skipFrames(contentUs, targetUs, rate), frames)
        data.position(data.position() + (skip * frame).toInt())
        bufferTimeUs = maxOf(contentUs + skip * 1000000 / rate, targetUs).coerceAtLeast(0)
        if (!data.hasRemaining()) return null
        val pcm = when {
            encoding == AudioFormat.ENCODING_PCM_FLOAT && lossy ->
                UsbDirectFormats.quantize(data, minOf(outputBits, 24), outputBits, converted)
            lossy -> BitPerfectPcm.convert(data, 16, 16, outputBits, false, converted)
            else -> BitPerfectPcm.convert(data, inputBits(), containerBits, outputBits,
                encoding == AudioFormat.ENCODING_PCM_FLOAT, converted)
        }.also { converted = it }
        if (paddingFrames == 0) return pcm
        val frameBytes = channels * outputBits / 8
        if (tail == null || tailFrameBytes != frameBytes) {
            tail = PcmTail(paddingFrames * frameBytes)
            tailFrameBytes = frameBytes
        }
        return requireNotNull(tail).push(pcm)
    }

    /** Flushes the decoder and drops frames before [positionUs], as the PCM path does. */
    fun seek(positionUs: Long) {
        targetUs = positionUs.coerceAtLeast(0)
        stash = null
        tail?.clear()
        codec.flush()
        inputDone = false
        outputEnded = false
        ended = false
        if (targetUs == 0L) {
            // Replays the start exactly, encoder delay trimmed by frame count.
            extractor.seekTo(firstSampleUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            trimFrames = delayFrames
        } else {
            // Decoders need a little audio before the target to settle (Opus asks for 80 ms).
            extractor.seekTo((originUs + targetUs - 100000).coerceAtLeast(firstSampleUs), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            trimFrames = 0
        }
    }

    override fun close() {
        stash = null
        converted = null
        tail = null
        runCatching { codec.stop() }
        runCatching { codec.release() }
    }

    companion object {
        fun MediaFormat.integer(key: String): Int =
            if (containsKey(key)) runCatching { getInteger(key) }.getOrDefault(0) else 0

        /**
         * Checks a compressed track without opening a decoder: channels, an
         * exact bit depth for lossless codecs, and an installed decoder.
         * Returns the description, the integer container and the decoder.
         */
        fun inspect(track: MediaFormat, mime: String): Triple<UsbSourceInfo, Int, String> {
            val lossy = mime in UsbDirectFormats.LOSSY_DECODE
            val codecName = UsbDirectFormats.codecName(mime)
            val channels = track.integer(MediaFormat.KEY_CHANNEL_COUNT)
            val sourceBits = if (lossy) 0 else losslessBits(track, mime)
            val described = UsbSourceInfo(codecName, track.integer(MediaFormat.KEY_SAMPLE_RATE), sourceBits, channels, lossy)
            checkChannels(channels, described)
            val containerBits = if (lossy) 24 else when {
                sourceBits <= 0 -> throw UsbDirectException(UsbDirectFormats.FORMAT, "$codecName bit depth is not reported", described)
                else -> UsbDirectFormats.losslessContainerBits(sourceBits)
                    ?: throw UsbDirectException(UsbDirectFormats.FORMAT, "$sourceBits-bit $codecName cannot be decoded exactly", described)
            }
            val name = decoderName(track, mime)
                ?: throw UsbDirectException(UsbDirectFormats.DECODER, "No $codecName decoder on this device", described)
            return Triple(described, containerBits, name)
        }

        private fun losslessBits(track: MediaFormat, mime: String): Int {
            track.integer("bits-per-sample").takeIf { it > 0 }?.let { return it }
            val csd = track.getByteBuffer("csd-0") ?: return 0
            val bytes = ByteArray(csd.remaining()).also { csd.duplicate().get(it) }
            return if (mime == "audio/alac") UsbDirectFormats.alacBitDepth(bytes) ?: 0
                else BitPerfectPcm.flacFormat(bytes.copyOf(maxOf(bytes.size, 42)))?.third ?: 0
        }

        private fun checkChannels(count: Int, described: UsbSourceInfo) {
            // The USB driver sends mono or stereo; more channels are never downmixed.
            if (count > 2) throw UsbDirectException(UsbDirectFormats.CHANNELS, "$count channels", described)
        }

        /** The decoder for [track], or null when this device has none. */
        private fun decoderName(track: MediaFormat, mime: String): String? {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            runCatching { list.findDecoderForFormat(track) }.getOrNull()?.let { return it }
            return list.codecInfos.firstOrNull { info ->
                !info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
            }?.name
        }
    }
}
