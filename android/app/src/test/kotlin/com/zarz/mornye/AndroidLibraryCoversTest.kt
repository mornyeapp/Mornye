package com.zarz.mornye

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidLibraryCoversTest {
    @Test
    fun repeatedPicturesShareFilesWithoutRewritingOrRemovingLegacyNames() {
        val directory = Files.createTempDirectory("android-covers-").toFile()
        try {
            val first = AndroidLibraryCovers.cache(directory, null, "abc".toByteArray(), "image/jpeg")!!
            assertEquals(
                "cover_content_ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.jpg",
                first.name,
            )
            assertTrue(first.setLastModified(1000))
            repeat(100) {
                assertEquals(first, AndroidLibraryCovers.cache(directory, null, "abc".toByteArray(), "image/jpeg"))
            }
            assertEquals(1000, first.lastModified())
            assertEquals(1, directory.listFiles()!!.size)
            val legacy = File(directory, "cover_old.jpg").also { it.writeText("abc") }
            assertEquals(first, AndroidLibraryCovers.cache(directory, legacy, byteArrayOf(), ""))
            assertEquals("abc", legacy.readText())
            val replacement = AndroidLibraryCovers.cache(directory, null, "abd".toByteArray(), "image/jpeg")!!
            assertNotEquals(first, replacement)
            assertEquals("abc", first.readText())
            assertEquals("abc", legacy.readText())
            assertEquals(3, directory.listFiles()!!.size)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun inconsistentDestinationFailsWithoutReplacingAnotherCover() {
        val directory = Files.createTempDirectory("android-covers-").toFile()
        try {
            val bytes = byteArrayOf(137.toByte(), 80, 78, 71)
            val first = AndroidLibraryCovers.cache(directory, null, bytes, "image/jpeg")!!
            assertTrue(first.name.endsWith(".png"))
            assertArrayEquals(bytes, first.readBytes())
            first.writeText("different artwork")
            try {
                AndroidLibraryCovers.cache(directory, null, bytes, "image/png")
                throw AssertionError("Inconsistent destination must not be reused")
            } catch (_: IllegalStateException) {
            }
            assertEquals("different artwork", first.readText())
            assertNull(AndroidLibraryCovers.cache(directory, null, byteArrayOf(), ""))
            val empty = File(directory, "empty.jpg").also { it.writeBytes(byteArrayOf()) }
            assertNull(AndroidLibraryCovers.cache(directory, empty, byteArrayOf(), ""))
        } finally {
            directory.deleteRecursively()
        }
    }
}
