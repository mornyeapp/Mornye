package com.zarz.mornye

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class CoverProviderFilesTest {
    private lateinit var app: File
    private lateinit var folders: Map<String, File>
    private val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0, 16)

    @Before
    fun createFolders() {
        app = Files.createTempDirectory("cover-provider-test").toFile().canonicalFile
        folders = CoverProviderFiles.folders(File(app, "files"), File(app, "cache"))
        folders.values.forEach { it.mkdirs() }
    }

    @After
    fun deleteFolders() {
        app.deleteRecursively()
    }

    private fun write(path: String, bytes: ByteArray = jpeg) =
        File(app, path).also {
            it.parentFile!!.mkdirs()
            it.writeBytes(bytes)
        }

    private fun resolve(vararg segments: String) = CoverProviderFiles.resolve(folders, segments.toList())

    @Test
    fun servesTheCoverFoldersBrowseListsName() {
        assertEquals(
            mapOf(
                "covers" to File(app, "files/covers"),
                "library_covers" to File(app, "files/library_covers"),
                "embedded_cover_previews" to File(app, "cache/embedded_cover_previews"),
            ),
            folders,
        )
        val stored = write("files/covers/0123_abcd.image")
        val thumbnail = write("files/library_covers/thumb.jpg")
        val embedded = write("cache/embedded_cover_previews/v1_hash_0.jpg")

        assertEquals(stored, resolve("covers", "0123_abcd.image"))
        assertEquals(thumbnail, resolve("library_covers", "thumb.jpg"))
        assertEquals(embedded, resolve("embedded_cover_previews", "v1_hash_0.jpg"))
    }

    @Test
    fun namesNothingOutsideItsFolders() {
        write("files/shared_prefs/settings.jpg")
        write("files/playlist_covers/list.jpg")
        write("files/library_covers/sub/nested.jpg")

        assertNull(resolve("playlist_covers", "list.jpg"))
        assertNull(resolve("files", "covers"))
        assertNull(resolve("library_covers"))
        assertNull(resolve("library_covers", "sub", "nested.jpg"))
        assertNull(resolve("library_covers", "sub/nested.jpg"))
        assertNull(resolve("library_covers", "../shared_prefs/settings.jpg"))
        assertNull(resolve("library_covers", ".."))
        assertNull(resolve("library_covers", "."))
        assertNull(resolve("library_covers", ""))
        assertNull(resolve("library_covers", "sub"))
        assertNull(resolve("library_covers", "missing.jpg"))
        assertNull(resolve("library_covers", "thumb.jpg\u0000.png"))
    }

    @Test
    fun followsNoLinkOutOfAFolder() {
        val secret = write("files/shared_prefs/settings.jpg")
        val thumbnail = write("files/library_covers/thumb.jpg")
        Files.createSymbolicLink(File(app, "files/library_covers/link.jpg").toPath(), secret.toPath())
        Files.createSymbolicLink(File(app, "files/covers/linked.jpg").toPath(), thumbnail.toPath())
        Files.createSymbolicLink(File(app, "files/library_covers/folder").toPath(), secret.parentFile!!.toPath())

        assertNull(resolve("library_covers", "link.jpg"))
        assertNull(resolve("covers", "linked.jpg"))
        assertNull(resolve("library_covers", "folder"))
    }

    @Test
    fun servesOnlyImagesThatAreNotHidden() {
        write("files/library_covers/.staged.jpg")
        write("files/library_covers/notes.txt", "not an image".toByteArray())
        write("files/library_covers/empty.jpg", ByteArray(0))
        write("files/library_covers/regenerate.marker", "2026-10-30T00:00:00".toByteArray())

        assertNull(resolve("library_covers", ".staged.jpg"))
        assertNull(resolve("library_covers", "notes.txt"))
        assertNull(resolve("library_covers", "empty.jpg"))
        assertNull(resolve("library_covers", "regenerate.marker"))
    }

    @Test
    fun aFolderReachedThroughALinkStillServesItsOwnFiles() {
        val real = File(app, "real").also { it.mkdirs() }
        val cover = File(real, "thumb.jpg").also { it.writeBytes(jpeg) }
        val linked = File(app, "linked_files")
        Files.createSymbolicLink(linked.toPath(), real.toPath())

        assertEquals(
            cover,
            CoverProviderFiles.resolve(mapOf("library_covers" to linked), listOf("library_covers", "thumb.jpg")),
        )
    }

    @Test
    fun recognizesTheImageFormatsTheCoverStoreKeeps() {
        fun type(vararg bytes: Int) = CoverProviderFiles.imageType(ByteArray(bytes.size) { bytes[it].toByte() })
        fun type(text: String) = CoverProviderFiles.imageType(text.toByteArray(Charsets.ISO_8859_1))

        assertEquals("image/jpeg", type(0xFF, 0xD8, 0xFF, 0xDB))
        assertEquals("image/png", type(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))
        assertEquals("image/gif", type("GIF89a"))
        assertEquals("image/webp", type("RIFF\u0000\u0000\u0000\u0000WEBP"))
        assertEquals("image/bmp", type("BM\u0000\u0000"))
        assertEquals("image/avif", type("\u0000\u0000\u0000 ftypavif"))
        assertEquals("image/heif", type("\u0000\u0000\u0000 ftypheic"))
        assertNull(type("\u0000\u0000\u0000 ftypisom"))
        assertNull(type("<svg"))
        assertNull(type(0xFF, 0xD8))
        assertNull(CoverProviderFiles.imageType(ByteArray(0)))
    }
}
