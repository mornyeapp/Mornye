package com.zarz.mornye

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.round

/** What Direct USB knows about a source; [bits] is 0 for a lossy codec. */
internal data class UsbSourceInfo(
    val codec: String,
    val rate: Int = 0,
    val bits: Int = 0,
    val channels: Int = 0,
    val lossy: Boolean = false,
) {
    fun describe(): String = listOfNotNull(
        codec,
        bits.takeIf { it > 0 }?.let { "$it-bit" },
        rate.takeIf { it > 0 }?.let { "$it Hz" },
        channels.takeIf { it > 0 }?.let { "${it}ch" },
    ).joinToString(" ")

    fun toMap(): Map<String, Any> = buildMap {
        put("codec", codec)
        put("lossy", lossy)
        if (rate > 0) put("sampleRate", rate)
        if (bits > 0) put("sourceBitDepth", bits)
        if (channels > 0) put("channels", channels)
    }
}

/** A failure the app can explain; [info] names the source when it is known. */
internal class UsbDirectException(val reason: String, message: String, val info: UsbSourceInfo? = null) :
    Exception(message)

/** Pure Direct USB policy: failure reasons, codec names and PCM arithmetic. */
internal object UsbDirectFormats {
    const val FORMAT = "format_unsupported"
    const val DECODER = "decoder_unavailable"
    const val CHANNELS = "channels_unsupported"
    const val DAC_FORMAT = "dac_format_rejected"
    const val DAC_UNSUPPORTED = "dac_unsupported"
    const val DAC_OPEN = "dac_open_failed"
    const val TIMEOUT = "timeout"
    const val UNSUPPORTED = "unsupported"

    /** Playback paused because the source stopped decoding exactly. */
    const val DECODE_FAILED = "decode_failed"

    /** Decoded through MediaCodec without losing a bit. */
    val LOSSLESS_DECODE = setOf("audio/flac", "audio/alac")

    /** Decoded through MediaCodec and rounded to the DAC's precision. */
    val LOSSY_DECODE = setOf("audio/mp4a-latm", "audio/mpeg", "audio/opus", "audio/vorbis")

    private val usbErrorCode = Regex("^USB error (-?\\d+)$")

    fun codecName(mime: String): String = when (val type = mime.lowercase()) {
        "audio/raw" -> "PCM"
        "audio/flac" -> "FLAC"
        "audio/alac" -> "ALAC"
        "audio/mp4a-latm" -> "AAC"
        "audio/mpeg" -> "MP3"
        "audio/opus" -> "Opus"
        "audio/vorbis" -> "Vorbis"
        "audio/ac3" -> "AC-3"
        "audio/eac3" -> "E-AC-3"
        "audio/ac4" -> "AC-4"
        "audio/3gpp" -> "AMR-NB"
        "audio/amr-wb" -> "AMR-WB"
        else -> type.removePrefix("audio/").removePrefix("x-").uppercase()
    }

    /**
     * Maps a Rust transport or Android device error to a reason. Unknown
     * messages stay [UNSUPPORTED]; the log keeps the original text.
     */
    fun classifyOutput(message: String?): String {
        val text = message.orEmpty()
        usbErrorCode.find(text)?.let {
            // LIBUSB_ERROR_PIPE: the DAC stalled a format or clock request.
            return if (it.groupValues[1] == "-9") DAC_FORMAT else DAC_OPEN
        }
        return when {
            text.startsWith("No compatible USB format") ||
                text.contains("clock rate could not be verified") ||
                text.contains("Variable USB clock has no rate control") -> DAC_FORMAT
            text.startsWith("Cannot open USB device") ||
                text.startsWith("Invalid USB device/configuration") ||
                text.startsWith("USB disconnected") -> DAC_OPEN
            listOf(
                "Implicit feedback", "bus speed", "packet interval", "interval/packet size",
                "bandwidth too small", "feedback endpoint", "Multiple USB configurations",
                "malformed USB descriptor", "No supported USB endpoint", "Short USB control response",
                "USB transfer allocation failed", "USB clock selector", "USB clock topology",
            ).any { text.contains(it) } -> DAC_UNSUPPORTED
            text.startsWith("Decoder timed out") -> TIMEOUT
            else -> UNSUPPORTED
        }
    }

    /** The integer container a lossless source decodes into, or null when it cannot stay exact. */
    fun losslessContainerBits(bits: Int): Int? = when (bits) {
        in 1..16 -> 16
        // A float sample carries 24 significant bits, so 17 to 24-bit sources stay exact.
        in 17..24 -> 24
        else -> null
    }

    /** The bit depth in an ALAC magic cookie, bare or inside its 'alac' box. */
    fun alacBitDepth(cookie: ByteArray): Int? {
        val offset = if (cookie.size >= 36 && String(cookie, 4, 4, Charsets.US_ASCII) == "alac") 12 else 0
        // frameLength(4), compatibleVersion(1) = 0, bitDepth(1), ...
        if (cookie.size < offset + 24 || cookie[offset + 4].toInt() != 0) return null
        return (cookie[offset + 5].toInt() and 255).takeIf { it in 1..32 }
    }

    /**
     * Android's raw descriptors (the device descriptor, then every
     * configuration in full) cut down to the configuration whose
     * bConfigurationValue is [active]. The first configuration stands in
     * when [active] is unknown or not listed, as the kernel picks it for a
     * UAC1/UAC2 device. A malformed list comes back unchanged for the parser
     * to reject.
     */
    fun activeConfiguration(raw: ByteArray, active: Int?): ByteArray {
        if (raw.size < 2 || raw[1].toInt() != 1) return raw
        val head = raw[0].toInt() and 255
        if (head < 2 || head > raw.size) return raw
        val blocks = mutableListOf<Pair<Int, Int>>()
        var offset = head
        while (offset < raw.size) {
            if (offset + 9 > raw.size || (raw[offset].toInt() and 255) < 9 || raw[offset + 1].toInt() != 2) return raw
            val total = (raw[offset + 2].toInt() and 255) or ((raw[offset + 3].toInt() and 255) shl 8)
            if (total < 9 || offset + total > raw.size) return raw
            blocks += offset to offset + total
            offset += total
        }
        if (blocks.size < 2) return raw
        val (start, end) = blocks.firstOrNull { (start, _) -> (raw[start + 5].toInt() and 255) == active }
            ?: blocks.first()
        return raw.copyOfRange(0, head) + raw.copyOfRange(start, end)
    }

    /** Frames before [targetUs] in a buffer starting at [timeUs], rounded up like the PCM path. */
    fun skipFrames(timeUs: Long, targetUs: Long, rate: Int): Long =
        if (timeUs < targetUs) ((targetUs - timeUs) * rate + 999999) / 1000000 else 0

    /**
     * Rounds decoder floats to [precision] bits inside [outputBits]
     * little-endian containers. Overs clip; there is no dither.
     */
    fun quantize(input: ByteBuffer, precision: Int, outputBits: Int, reuse: ByteBuffer? = null): ByteBuffer {
        require(precision in 16..24 && outputBits in listOf(16, 24, 32) && precision <= outputBits)
        input.order(ByteOrder.LITTLE_ENDIAN)
        require(input.remaining() % 4 == 0)
        val size = input.remaining() / 4 * (outputBits / 8)
        val output = (reuse?.takeIf { it.isDirect && !it.isReadOnly && it.capacity() >= size }
            ?: ByteBuffer.allocateDirect(size)).order(ByteOrder.LITTLE_ENDIAN)
        output.clear()
        output.limit(size)
        val scale = (1L shl (precision - 1)).toDouble()
        val high = (1L shl (precision - 1)) - 1
        val low = -(1L shl (precision - 1))
        while (input.hasRemaining()) {
            val value = input.float.toDouble()
            val level = if (value.isNaN()) 0L else round(value * scale).toLong().coerceIn(low, high)
            val sample = level.toInt() shl (32 - precision)
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

    /** A new track reopens the DAC within this long of closing the last one. */
    const val TRACK_CHANGE_WINDOW_MS = 10_000L

    /**
     * The level to give a DAC that was playing at [remembered] dB and read
     * [limit] dB when it was opened, [sinceReleaseMs] after this app let go
     * of it (null if it never held it).
     *
     * A DAC is never made louder than it connects. Between two tracks the app
     * lets go of the DAC for a moment, though, and the system's own USB audio
     * driver takes it back and may set its volume; a lower level read then is
     * not the listener's, and following it made every track quieter than the
     * last. So across a track change the level that was playing stands.
     */
    fun restoredVolumeDb(remembered: Double, limit: Double, sinceReleaseMs: Long?): Double =
        if (sinceReleaseMs != null && sinceReleaseMs in 0..TRACK_CHANGE_WINDOW_MS) remembered
        else minOf(remembered, limit)
}

/**
 * Holds back the last [holdBytes] of a stream so encoder padding can be
 * dropped at the end. Memory stays at one held block plus one output buffer.
 */
internal class PcmTail(private val holdBytes: Int) {
    private val held = ByteArray(holdBytes)
    private var heldSize = 0
    private var output: ByteBuffer? = null

    /** Returns the bytes that are certainly not padding; valid until the next call. */
    fun push(input: ByteBuffer): ByteBuffer {
        val total = heldSize + input.remaining()
        val emit = maxOf(0, total - holdBytes)
        val out = (output?.takeIf { it.capacity() >= emit } ?: ByteBuffer.allocateDirect(maxOf(emit, 4096)))
            .also { output = it }
        out.clear()
        val fromHeld = minOf(heldSize, emit)
        out.put(held, 0, fromHeld)
        val fromInput = emit - fromHeld
        val slice = input.duplicate()
        slice.limit(slice.position() + fromInput)
        out.put(slice)
        input.position(input.position() + fromInput)
        System.arraycopy(held, fromHeld, held, 0, heldSize - fromHeld)
        heldSize -= fromHeld
        val rest = input.remaining()
        input.get(held, heldSize, rest)
        heldSize += rest
        out.flip()
        return out.order(ByteOrder.LITTLE_ENDIAN)
    }

    /** Drops what is held: the padding at the end, or stale audio after a seek. */
    fun clear() {
        heldSize = 0
    }
}
