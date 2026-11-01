package com.zarz.mornye

import java.io.IOException
import java.io.Reader
import java.io.StringReader
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SafCueScanTest {
    private class CountingReader(private val text: String) : Reader() {
        var consumed = 0
        var largestRead = 0
        var closed = false

        override fun read(buffer: CharArray, offset: Int, length: Int): Int {
            largestRead = maxOf(largestRead, length)
            if (consumed == text.length) return -1
            val count = minOf(length, text.length - consumed)
            text.toCharArray(buffer, offset, consumed, consumed + count)
            consumed += count
            return count
        }

        override fun close() { closed = true }
    }

    @Test fun keepsBomQuotesWhitespaceAndFilenameSemantics() {
        for ((cue, expected) in listOf(
            "FILE \"Album Name.flac\" WAVE" to "Album Name.flac",
            "\uFEFF  file \"Music/曲 name.flac\" WAVE\r\nTRACK 01 AUDIO" to "曲 name.flac",
            " \t\uFEFF FILE \"C:\\Music\\Album.flac\" WAVE\n" to "Album.flac",
            "REM comment\rFILE Music/Some   Album.flac WAVE\r" to "Some Album.flac",
            "FILE song.flac" to "song.flac",
            "FILE \"\" WAVE" to "",
            "FILE \"unfinished.flac WAVE" to "\"unfinished.flac WAVE",
            "FILE first.flac WAVE\nFILE second.flac WAVE" to "first.flac",
            "FILE\t\"not-a-file-directive.flac\" WAVE" to null,
            "REM FILE ignored.flac WAVE" to null,
            "" to null,
        )) {
            assertEquals(cue, expected, extractCueAudioFileName(StringReader(cue)))
        }
    }

    @Test fun readsOneBufferedPrefixInsteadOfTheWholeSheet() {
        val source = CountingReader("FILE \"Album.flac\" WAVE\n" + "REM trailing data\n".repeat(100000))
        val result = readCueAudioReference({ source }, retryOnDenied = false)
        assertEquals("Album.flac", result?.filename)
        assertTrue(source.consumed <= 8192)
        assertTrue(source.largestRead <= 8192)
        assertTrue(source.closed)
    }

    @Test fun doesNotRejectALateFileDirectiveOrALargeHeader() {
        val cue = "REM comment\n".repeat(100000) + "FILE \"Late.flac\" WAVE"
        assertEquals("Late.flac", extractCueAudioFileName(StringReader(cue)))
    }

    @Test fun distinguishesAnUnreadableDocumentFromAMissingFileDirective() {
        var opens = 0
        assertNull(readCueAudioReference({ opens++; null }, retryOnDenied = true))
        assertEquals(1, opens)
        val source = CountingReader("TITLE \"A sheet using its basename\"")
        val read = readCueAudioReference({ source }, retryOnDenied = false)
        assertEquals(CueAudioReference(null), read)
        assertTrue(source.closed)
    }

    @Test fun mediaStoreSecurityRetryClosesBothReadersAndRetriesOnlyOnce() {
        var opened = 0
        var closed = false
        val second = CountingReader("FILE \"Recovered.flac\" WAVE")
        val reference = readCueAudioReference(open = {
            if (++opened == 1) object : StringReader("") {
                override fun read(buffer: CharArray, offset: Int, length: Int): Int =
                    throw SecurityException("Provider permission changed")
                override fun close() { closed = true; super.close() }
            } else second
        }, retryOnDenied = true)
        assertEquals("Recovered.flac", reference?.filename)
        assertEquals(2, opened)
        assertTrue(closed)
        assertTrue(second.closed)
        opened = 0
        assertThrows(SecurityException::class.java) {
            readCueAudioReference({ opened++; throw SecurityException("Denied") }, retryOnDenied = true)
        }
        assertEquals(2, opened)
    }

    @Test fun otherReadFailuresCloseTheStreamWithoutRetrying() {
        var opened = 0
        var closed = false
        assertThrows(IOException::class.java) {
            readCueAudioReference(open = {
                opened++
                object : StringReader("") {
                    override fun read(buffer: CharArray, offset: Int, length: Int): Int =
                        throw IOException("Read failed")
                    override fun close() { closed = true; super.close() }
                }
            }, retryOnDenied = true)
        }
        assertEquals(1, opened)
        assertTrue(closed)
        opened = 0
        assertThrows(SecurityException::class.java) {
            readCueAudioReference({ opened++; throw SecurityException("Denied") }, retryOnDenied = false)
        }
        assertEquals(1, opened)
    }
}
