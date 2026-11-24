package com.zarz.mornye

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SafSiblingsTest {
    @Test
    fun sidecarsUseTheSongsBaseName() {
        val wanted = safSiblingWanted("Song.flac", listOf("mlrc", "lrc"), listOf("cover.mp4"))
        assertEquals(mapOf("mlrc" to "Song.mlrc", "lrc" to "Song.lrc"), wanted.sidecars)
        assertEquals(setOf("cover.mp4"), wanted.files)
        assertEquals(setOf("Song.mlrc", "Song.lrc", "cover.mp4"), wanted.names)
    }

    @Test
    fun onlyTheLastExtensionIsReplaced() {
        assertEquals(
            mapOf("lrc" to "Artist - Song.v2.lrc"),
            safSiblingWanted("Artist - Song.v2.flac", listOf("lrc"), emptyList()).sidecars,
        )
        assertEquals(
            mapOf("lrc" to "Song.lrc"),
            safSiblingWanted("Song", listOf("lrc"), emptyList()).sidecars,
        )
    }

    @Test
    fun namesKeepTheirCase() {
        val wanted = safSiblingWanted("SONG.FLAC", listOf("lrc"), listOf("cover.mp4"))
        assertEquals(setOf("SONG.lrc", "cover.mp4"), wanted.names)
    }

    @Test
    fun sidecarsNeedTheSongsName() {
        val wanted = safSiblingWanted(null, listOf("mlrc", "lrc"), listOf("cover.mp4"))
        assertTrue(wanted.sidecars.isEmpty())
        assertEquals(setOf("cover.mp4"), wanted.names)
    }

    @Test
    fun invalidExtensionsAndNamesAreLeftOut() {
        val wanted = safSiblingWanted(
            "Song.flac",
            listOf("LRC", "", "toolongext", "l/c", "lrc"),
            listOf("", " ", "../cover.mp4", "a/cover.mp4", ".cover.mp4", "cover.mp4"),
        )
        assertEquals(mapOf("lrc" to "Song.lrc"), wanted.sidecars)
        assertEquals(setOf("cover.mp4"), wanted.files)
    }

    @Test
    fun plainSiblingNames() {
        assertTrue(isPlainSiblingName("cover.mp4"))
        assertFalse(isPlainSiblingName(""))
        assertFalse(isPlainSiblingName("dir/cover.mp4"))
        assertFalse(isPlainSiblingName(".hidden"))
    }
}
