package com.zarz.mornye

/**
 * Pure parts of the media3 player channel (`com.zarz.mornye/media3_player`):
 * source classification, error payloads, transport state and the playlist
 * bookkeeping. Kept free of Android and media3 types for JVM tests.
 */
internal sealed interface Media3SourceKind {
    /** Scheme for logs. Paths and URLs can carry names or tokens. */
    val label: String

    /** An app-owned SAF lease: duplicate the descriptor, never reopen it. */
    data class Descriptor(val fd: Int) : Media3SourceKind {
        override val label get() = "fd"
    }

    data class File(val path: String) : Media3SourceKind {
        override val label get() = "file"
    }

    /** `file://` or `content://`; media3's default data source opens these. */
    data class Local(val uri: String, override val label: String) : Media3SourceKind

    data class Network(val url: String, override val label: String) : Media3SourceKind

    companion object {
        private const val PROC_FD = "/proc/self/fd/"

        /** Null when the URI is empty or uses a scheme media3 cannot open here. */
        fun classify(uri: String, isLocal: Boolean): Media3SourceKind? {
            if (uri.isBlank()) return null
            if (isLocal && uri.startsWith(PROC_FD)) {
                uri.removePrefix(PROC_FD).toIntOrNull()?.takeIf { it >= 0 }?.let { return Descriptor(it) }
            }
            if (uri.startsWith("/")) return File(uri)
            val scheme = uri.substringBefore("://", "").lowercase()
            return when (scheme) {
                "file", "content" -> Local(uri, scheme)
                "http", "https" -> Network(uri, scheme)
                else -> null
            }
        }
    }
}

internal object Media3Errors {
    const val NO_PLAYER = "no_player"
    const val SUPERSEDED = "superseded"
    const val SOURCE_ERROR = "source_error"
    const val EQUALIZER = "equalizer"
    const val INVALID_ARGUMENT = "invalid_argument"
    const val NATIVE_ERROR = "native_error"
    const val SOURCE_MESSAGE = "Android could not open this audio source."
    const val PLAYBACK_MESSAGE = "Android could not play this audio."
    const val SUPERSEDED_MESSAGE = "Another source replaced this one before it was ready."

    fun sourceDetails(errorCode: String): Map<String, Any?> = mapOf("errorCode" to errorCode)

    /** A failure after `setSource` replied; [prepared] picks the message. */
    fun errorEvent(errorCode: String, prepared: Boolean): Map<String, Any?> = mapOf(
        "event" to "error",
        "message" to if (prepared) PLAYBACK_MESSAGE else SOURCE_MESSAGE,
        "errorCode" to errorCode,
        "prepared" to prepared,
    )
}

/**
 * Which sample format a decoder is asked for. Float keeps the bits of a
 * high resolution file past 16; nothing else gains from it, and asking is
 * the one thing here that other players on the phone do not do, so a
 * vendor's decoder that handles the request badly would only show in this
 * engine. Songs that cannot hold more than 16 bits are therefore decoded as
 * every other player decodes them.
 */
internal object Media3Decoding {
    /** Codecs whose decoders have 16-bit samples to give at most. */
    private val lossy = setOf(
        "audio/mpeg",
        "audio/mpeg-l1",
        "audio/mpeg-l2",
        "audio/mp4a-latm",
        "audio/opus",
        "audio/vorbis",
        "audio/ac3",
        "audio/eac3",
        "audio/eac3-joc",
        "audio/ac4",
        "audio/3gpp",
        "audio/amr-wb",
    )

    /**
     * Whether to ask for 16-bit PCM. [bits] is the depth the file states,
     * null when it states none: a lossless file of unknown depth keeps
     * float. [skipSilence] needs 16-bit for every song.
     */
    fun sixteenBit(mime: String?, bits: Int?, skipSilence: Boolean): Boolean =
        skipSilence || (bits?.let { it <= 16 } ?: (mime?.lowercase() in lossy))

    /** A PCM encoding in words, for the log. */
    fun encodingName(bits: Int?, float: Boolean): String = when {
        float -> "float"
        bits != null -> "$bits-bit"
        else -> "unknown"
    }
}

internal object Media3Transport {
    const val PLAYING = "playing"
    const val PAUSED = "paused"
    const val STOPPED = "stopped"
    const val COMPLETED = "completed"

    /**
     * The state the Dart deck mirrors, or null to keep the last one while
     * the player waits to play (buffering or suppressed output).
     */
    fun state(
        hasItem: Boolean,
        idle: Boolean,
        ended: Boolean,
        playWhenReady: Boolean,
        isPlaying: Boolean,
        stopped: Boolean,
    ): String? = when {
        !hasItem -> STOPPED
        ended -> COMPLETED
        isPlaying -> PLAYING
        stopped -> STOPPED
        playWhenReady && !idle -> null
        else -> PAUSED
    }
}

/**
 * Mirrors the player's playlist: index 0 is the current item and index 1 the
 * one queued for gapless playback. Every change returns the entries that
 * left, so their resources can be released.
 */
internal class Media3Queue<T>(private val idOf: (T) -> String) {
    private val entries = ArrayList<T>(2)

    val current: T? get() = entries.firstOrNull()
    val next: T? get() = entries.getOrNull(1)
    val size: Int get() = entries.size

    fun replace(entry: T): List<T> = clear().also { entries.add(entry) }

    /** Null, and nothing changes, when there is no current item. */
    fun queueNext(entry: T): List<T>? {
        if (entries.isEmpty()) return null
        return clearNext().also { entries.add(entry) }
    }

    fun clearNext(): List<T> {
        if (entries.size <= 1) return emptyList()
        val removed = entries.subList(1, entries.size).toList()
        entries.subList(1, entries.size).clear()
        return removed
    }

    /**
     * Makes the entry with [id] current and returns the entries before it,
     * which left the playlist's front. Null when [id] is unknown.
     */
    fun advanceTo(id: String): List<T>? {
        val index = entries.indexOfFirst { idOf(it) == id }
        if (index < 0) return null
        val removed = entries.subList(0, index).toList()
        entries.subList(0, index).clear()
        return removed
    }

    fun clear(): List<T> = entries.toList().also { entries.clear() }
}
