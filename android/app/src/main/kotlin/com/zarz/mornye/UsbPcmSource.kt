package com.zarz.mornye

import android.media.AudioFormat
import android.media.MediaExtractor
import android.media.MediaFormat
import com.zarz.mornye.UsbCodecStream.Companion.integer
import java.io.Closeable
import java.io.FileInputStream
import java.nio.ByteBuffer

/**
 * A source for the direct driver; decoding never passes through AudioTrack.
 * FLAC files use libFLAC and WAV its integer PCM. With [decodeCompressed],
 * ALAC, FLAC in MP4/Ogg and lossy codecs decode through [UsbCodecStream],
 * primed before [deadline] (elapsedRealtime milliseconds).
 */
internal class UsbPcmSource(
    path: String,
    decodeCompressed: Boolean = false,
    deadline: Long = Long.MAX_VALUE,
) : Closeable {
    private var extractor: MediaExtractor? = null
    private var stream: UsbCodecStream? = null
    private var flac = 0L
    private val raw = ByteBuffer.allocateDirect(256 * 1024)
    private var converted: ByteBuffer? = null
    var ended = false
        private set
    private var inputBits = 0
    private var targetUs = 0L
    private var flacFrame = 0L
    var bufferTimeUs = 0L
        private set
    val rate: Int
    val channels: Int
    val bits: Int
    val durationUs: Long
    /** The source as the app describes it; a lossy codec has no bit depth. */
    val info: UsbSourceInfo

    init {
        try {
            val header = readHeader(path)
            if (BitPerfectPcm.flacFormat(header) != null) {
                // Some vendor extractors report FLAC as audio/raw and silently
                // truncate it to 16-bit. Open the original file with libFLAC.
                flac = NativeAudio.openFlac(path)
                val format = NativeAudio.infoFlac(flac)
                rate = format[0].toInt()
                channels = format[1].toInt()
                bits = format[2].toInt()
                durationUs = format[3] * 1000000 / rate
                info = UsbSourceInfo("FLAC", rate, bits, channels)
            } else {
                val media = MediaExtractor().also { extractor = it }
                FileInputStream(path).use { media.setDataSource(it.fd) }
                val index = audioTrack(media)
                media.selectTrack(index)
                val format = media.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME).orEmpty()
                durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0
                if (mime == "audio/raw") {
                    rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    val encoding = format.getInteger(MediaFormat.KEY_PCM_ENCODING)
                    bits = precision(encoding)
                    inputBits = bits
                    info = rawInfo(rate, channels, encoding)
                } else {
                    if (!decodeCompressed || !decodable(mime)) throw unsupported(format, mime)
                    val codec = UsbCodecStream(media, format, mime, deadline).also { stream = it }
                    rate = codec.rate
                    channels = codec.channels
                    bits = codec.containerBits
                    info = codec.info
                }
            }
            checkPcm(info, channels, bits)
        } catch (error: Exception) { close(); throw error }
    }

    companion object {
        private fun readHeader(path: String): ByteArray {
            val header = ByteArray(42)
            FileInputStream(path).use { input ->
                var n = 0
                while (n < header.size) {
                    val count = input.read(header, n, header.size - n)
                    if (count <= 0) break
                    n += count
                }
            }
            return header
        }

        private fun audioTrack(media: MediaExtractor): Int = (0 until media.trackCount).firstOrNull {
            media.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        } ?: throw UsbDirectException(UsbDirectFormats.FORMAT, "No audio stream")

        private fun decodable(mime: String) = mime in UsbDirectFormats.LOSSLESS_DECODE || mime in UsbDirectFormats.LOSSY_DECODE

        private fun precision(encoding: Int) = when (encoding) {
            AudioFormat.ENCODING_PCM_16BIT -> 16
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
            AudioFormat.ENCODING_PCM_32BIT -> 32
            else -> 0
        }

        private fun rawInfo(rate: Int, channels: Int, encoding: Int) = UsbSourceInfo(
            if (encoding == AudioFormat.ENCODING_PCM_FLOAT) "PCM float" else "PCM",
            rate, precision(encoding), channels,
        )

        private fun unsupported(format: MediaFormat, mime: String): UsbDirectException {
            val info = UsbSourceInfo(UsbDirectFormats.codecName(mime),
                format.integer(MediaFormat.KEY_SAMPLE_RATE), 0, format.integer(MediaFormat.KEY_CHANNEL_COUNT),
                mime in UsbDirectFormats.LOSSY_DECODE)
            return UsbDirectException(UsbDirectFormats.FORMAT, "Direct USB cannot decode ${info.codec}", info)
        }

        private fun checkPcm(info: UsbSourceInfo, channels: Int, bits: Int) {
            // Mono and stereo only; more channels are never downmixed.
            if (channels !in 1..2) {
                throw UsbDirectException(UsbDirectFormats.CHANNELS, "${info.describe()}: $channels channels", info)
            }
            if (bits !in listOf(16, 24, 32)) {
                throw UsbDirectException(UsbDirectFormats.FORMAT, "${info.describe()}: not 16, 24 or 32-bit integer PCM", info)
            }
        }

        /**
         * Checks a file before asking for USB permission. Reads headers and
         * the decoder list only; opens no decoder and no device. Throws
         * [UsbDirectException] when Direct USB cannot play it.
         */
        fun probe(path: String, decodeCompressed: Boolean): UsbSourceInfo {
            BitPerfectPcm.flacFormat(readHeader(path))?.let { (rate, channels, bits) ->
                return UsbSourceInfo("FLAC", rate, bits, channels).also { checkPcm(it, channels, bits) }
            }
            val media = MediaExtractor()
            try {
                FileInputStream(path).use { media.setDataSource(it.fd) }
                val format = media.getTrackFormat(audioTrack(media))
                val mime = format.getString(MediaFormat.KEY_MIME).orEmpty()
                if (mime == "audio/raw") {
                    val rate = format.integer(MediaFormat.KEY_SAMPLE_RATE)
                    val channels = format.integer(MediaFormat.KEY_CHANNEL_COUNT)
                    val encoding = format.integer(MediaFormat.KEY_PCM_ENCODING)
                    return rawInfo(rate, channels, encoding).also { checkPcm(it, channels, precision(encoding)) }
                }
                if (!decodeCompressed || !decodable(mime)) throw unsupported(format, mime)
                return UsbCodecStream.inspect(format, mime).first
            } finally { runCatching { media.release() } }
        }
    }

    private fun convert(buffer: ByteBuffer, timeUs: Long, outputBits: Int): ByteBuffer {
        val frame = channels * (inputBits / 8)
        require(frame > 0 && buffer.remaining() % frame == 0)
        val skip = if (timeUs < targetUs) ((targetUs - timeUs) * rate + 999999) / 1000000 else 0
        buffer.position(buffer.position() + minOf(skip, (buffer.remaining() / frame).toLong()).toInt() * frame)
        bufferTimeUs = maxOf(timeUs, targetUs)
        // The playback worker consumes this result before requesting another buffer.
        return BitPerfectPcm.convert(buffer, inputBits, bits, outputBits, false, converted)
            .also { converted = it }
    }

    fun read(outputBits: Int): ByteBuffer? {
        if (ended) return null
        stream?.let { codec ->
            val output = codec.read(outputBits)
            ended = codec.ended
            bufferTimeUs = codec.bufferTimeUs
            return output
        }
        if (flac != 0L) {
            raw.clear()
            val size = NativeAudio.readFlac(flac, raw, outputBits)
            if (size == 0) { ended = true; return null }
            raw.limit(size)
            bufferTimeUs = flacFrame * 1000000 / rate
            flacFrame += size / (channels * (outputBits / 8))
            return raw
        }
        val media = requireNotNull(extractor)
        raw.clear()
        val size = media.readSampleData(raw, 0)
        if (size < 0) { ended = true; return null }
        raw.limit(size)
        raw.position(0)
        val output = convert(raw, media.sampleTime, outputBits)
        media.advance()
        return output
    }

    fun seek(positionUs: Long) {
        targetUs = positionUs.coerceAtLeast(0)
        if (flac != 0L) {
            flacFrame = targetUs / 1000000 * rate + (targetUs % 1000000 * rate + 999999) / 1000000
            NativeAudio.seekFlac(flac, flacFrame)
        } else if (stream != null) requireNotNull(stream).seek(targetUs)
        else extractor?.seekTo(targetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        ended = false
    }

    override fun close() {
        runCatching { stream?.close() }
        stream = null
        if (flac != 0L) runCatching { NativeAudio.closeFlac(flac) }
        flac = 0
        converted = null
        runCatching { extractor?.release() }
        extractor = null
    }
}
