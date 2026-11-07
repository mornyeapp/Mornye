package com.zarz.mornye

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Media3ContractTest {
    @Test
    fun classifiesEveryContractUriForm() {
        assertEquals(Media3SourceKind.Descriptor(42), Media3SourceKind.classify("/proc/self/fd/42", true))
        // Only local leases are duplicated; otherwise the path is a plain file.
        assertEquals(Media3SourceKind.File("/proc/self/fd/42"), Media3SourceKind.classify("/proc/self/fd/42", false))
        assertEquals(Media3SourceKind.File("/proc/self/fd/x"), Media3SourceKind.classify("/proc/self/fd/x", true))
        assertEquals(Media3SourceKind.File("/proc/self/fd/-1"), Media3SourceKind.classify("/proc/self/fd/-1", true))
        assertEquals(
            Media3SourceKind.File("/storage/emulated/0/Music/a b.flac"),
            Media3SourceKind.classify("/storage/emulated/0/Music/a b.flac", true),
        )
        assertEquals(
            Media3SourceKind.Local("content://media/external/audio/1", "content"),
            Media3SourceKind.classify("content://media/external/audio/1", true),
        )
        assertEquals(Media3SourceKind.Local("file:///a.mp3", "file"), Media3SourceKind.classify("file:///a.mp3", true))
        assertEquals(
            Media3SourceKind.Network("http://127.0.0.1:4000/token", "http"),
            Media3SourceKind.classify("http://127.0.0.1:4000/token", false),
        )
        assertEquals(
            Media3SourceKind.Network("HTTPS://example.com/a.flac", "https"),
            Media3SourceKind.classify("HTTPS://example.com/a.flac", false),
        )
        assertNull(Media3SourceKind.classify("", true))
        assertNull(Media3SourceKind.classify("ftp://example.com/a.mp3", false))
        assertNull(Media3SourceKind.classify("relative/a.mp3", true))
    }

    @Test
    fun logLabelsNeverCarryThePathOrUrl() {
        val sources = listOf(
            "/proc/self/fd/9" to true,
            "/storage/emulated/0/Music/secret.flac" to true,
            "content://provider/document/secret" to true,
            "https://example.com/stream?token=secret" to false,
        )
        val labels = sources.map { (uri, local) -> requireNotNull(Media3SourceKind.classify(uri, local)).label }
        assertEquals(listOf("fd", "file", "content", "https"), labels)
    }

    @Test
    fun errorPayloadsFollowTheContract() {
        assertEquals(mapOf("errorCode" to "ERROR_CODE_IO_FILE_NOT_FOUND"),
            Media3Errors.sourceDetails("ERROR_CODE_IO_FILE_NOT_FOUND"))
        assertEquals(
            mapOf(
                "event" to "error",
                "message" to "Android could not play this audio.",
                "errorCode" to "ERROR_CODE_DECODING_FAILED",
                "prepared" to true,
            ),
            Media3Errors.errorEvent("ERROR_CODE_DECODING_FAILED", true),
        )
        assertEquals(
            mapOf(
                "event" to "error",
                "message" to "Android could not open this audio source.",
                "errorCode" to "ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED",
                "prepared" to false,
            ),
            Media3Errors.errorEvent("ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED", false),
        )
        assertEquals("no_player", Media3Errors.NO_PLAYER)
        assertEquals("superseded", Media3Errors.SUPERSEDED)
        assertEquals("source_error", Media3Errors.SOURCE_ERROR)
        assertEquals("equalizer", Media3Errors.EQUALIZER)
    }

    private fun state(
        hasItem: Boolean = true,
        idle: Boolean = false,
        ended: Boolean = false,
        playWhenReady: Boolean = false,
        isPlaying: Boolean = false,
        stopped: Boolean = false,
    ) = Media3Transport.state(hasItem, idle, ended, playWhenReady, isPlaying, stopped)

    @Test
    fun transportStateMirrorsActualPlayback() {
        assertEquals("stopped", state(hasItem = false, playWhenReady = true))
        assertEquals("completed", state(ended = true, stopped = true))
        assertEquals("playing", state(playWhenReady = true, isPlaying = true))
        assertEquals("stopped", state(stopped = true))
        assertEquals("paused", state())
        // Error leaves the player idle and paused.
        assertEquals("paused", state(idle = true))
        assertEquals("paused", state(idle = true, playWhenReady = true))
        // Buffering or suppressed while asked to play: keep the last state.
        assertNull(state(playWhenReady = true))
    }

    @Test
    fun queueKeepsCurrentAndOneQueuedItem() {
        val queue = Media3Queue<String> { it }
        assertNull(queue.queueNext("orphan"))
        assertEquals(0, queue.size)
        assertEquals(emptyList<String>(), queue.replace("a"))
        assertEquals(emptyList<String>(), queue.queueNext("b"))
        assertEquals("a", queue.current)
        assertEquals("b", queue.next)
        // A newer queued item replaces the earlier one.
        assertEquals(listOf("b"), queue.queueNext("c"))
        assertEquals(listOf("a", "c"), listOf(queue.current, queue.next))
        assertNull(queue.advanceTo("unknown"))
        assertEquals(listOf("a"), queue.advanceTo("c"))
        assertEquals("c", queue.current)
        assertNull(queue.next)
        assertEquals(emptyList<String>(), queue.advanceTo("c"))
        assertEquals(emptyList<String>(), queue.clearNext())
        queue.queueNext("d")
        assertEquals(listOf("d"), queue.clearNext())
        queue.queueNext("e")
        assertEquals(listOf("c", "e"), queue.replace("f"))
        assertEquals(listOf("f"), queue.clear())
        assertNull(queue.current)
        assertTrue(queue.clear().isEmpty())
    }
}
