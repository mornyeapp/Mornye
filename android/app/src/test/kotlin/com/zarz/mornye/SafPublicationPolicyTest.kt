package com.zarz.mornye

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SafPublicationPolicyTest {
    @Test
    fun unfinishedNamesStayOutOfFullAndIncrementalScans() {
        for (name in listOf(
            "Track.flac.partial", "Track.partial.flac", "Track.partial.MP3",
            "Track.flac.replaced", ".Track.partial.flac", ".Track.flac.replaced",
        )) {
            assertTrue(name, isIncompleteSafFileName(name))
        }
        for (name in listOf("EjAj - Lej Mi Pół.flac", "Track.mp3", "Partial Eclipse.flac", "Track.partial-remix.flac")) {
            assertFalse(name, isIncompleteSafFileName(name))
        }
    }

    @Test
    fun stagingAndBackupNamesStayHiddenUntilAudioIsPublished() {
        for (extension in listOf("flac", "mp3", "m4a", "opus")) {
            val finalName = "Example track.$extension"
            assertEquals(
                ".Example track.partial.$extension",
                SafDownloadHandler.buildStagedSafFileName(finalName),
            )
            assertEquals(
                ".$finalName.replaced",
                SafDownloadHandler.buildReplacedSafFileName(finalName),
            )
            assertEquals(finalName, SafDownloadHandler.sanitizeFilename(finalName))
        }
    }

    @Test
    fun longTemporaryNamesKeepTheirHiddenMarkerAndAudioExtension() {
        for (fileName in listOf("Very long title ".repeat(20) + ".flac", "音乐🎵".repeat(60) + ".mp3")) {
            for (name in listOf(
                SafDownloadHandler.buildStagedSafFileName(fileName),
                SafDownloadHandler.buildReplacedSafFileName(fileName),
            )) {
                assertTrue(name, name.startsWith("."))
                assertTrue(name, name.toByteArray(Charsets.UTF_8).size <= 180)
                assertTrue(name, isIncompleteSafFileName(name))
            }
            assertTrue(
                SafDownloadHandler.buildStagedSafFileName(fileName)
                    .endsWith(".partial.${fileName.substringAfterLast('.')}"),
            )
        }
    }

    @Test
    fun longFinalNamesDoNotShareAStagingOrBackupDocument() {
        val first = "a".repeat(170) + "one.flac"
        val second = "a".repeat(170) + "two.flac"
        assertNotEquals(
            SafDownloadHandler.buildStagedSafFileName(first),
            SafDownloadHandler.buildStagedSafFileName(second),
        )
        assertNotEquals(
            SafDownloadHandler.buildReplacedSafFileName(first),
            SafDownloadHandler.buildReplacedSafFileName(second),
        )
    }
}
