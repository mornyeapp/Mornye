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
    private lateinit var folders: Map<String, CoverProviderFiles.Folder>
    private val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0, 16)

    @Before
    fun createFolders() {
        app = Files.createTempDirectory("cover-provider-test").toFile().canonicalFile
        folders = CoverProviderFiles.folders(File(app, "files"), File(app, "cache"))
        folders.values.forEach { it.directory.mkdirs() }
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
            folders.mapValues { it.value.directory },
        )
        val stored = write("files/covers/0123_abcd.image")
        val thumbnail = write("files/library_covers/cover_0123.jpg")
        val png = write("files/library_covers/cover_4567.png")
        val subsonic = write("files/library_covers/subsonic_0123_89ab.image")
        val embedded = write("cache/embedded_cover_previews/v2_hash_0.jpg")

        assertEquals(stored, resolve("covers", "0123_abcd.image"))
        assertEquals(thumbnail, resolve("library_covers", "cover_0123.jpg"))
        assertEquals(png, resolve("library_covers", "cover_4567.png"))
        assertEquals(subsonic, resolve("library_covers", "subsonic_0123_89ab.image"))
        assertEquals(embedded, resolve("embedded_cover_previews", "v2_hash_0.jpg"))
    }

    @Test
    fun namesNothingOutsideItsFolders() {
        write("files/shared_prefs/settings.jpg")
        write("files/playlist_covers/list.jpg")
        write("files/library_covers/sub/nested.jpg")
        File(app, "files/library_covers/folder.jpg").mkdirs()

        assertNull(resolve("playlist_covers", "list.jpg"))
        assertNull(resolve("files", "covers"))
        assertNull(resolve("library_covers"))
        assertNull(resolve("library_covers", "sub", "nested.jpg"))
        assertNull(resolve("library_covers", "sub/nested.jpg"))
        assertNull(resolve("library_covers", "../shared_prefs/settings.jpg"))
        assertNull(resolve("library_covers", ".."))
        assertNull(resolve("library_covers", "."))
        assertNull(resolve("library_covers", ""))
        assertNull(resolve("library_covers", "folder.jpg"))
        assertNull(resolve("library_covers", "missing.jpg"))
        assertNull(resolve("library_covers", "thumb.jpg\u0000.png"))
    }

    @Test
    fun followsNoLinkOutOfAFolder() {
        val secret = write("files/shared_prefs/settings.jpg")
        val thumbnail = write("files/library_covers/thumb.jpg")
        Files.createSymbolicLink(File(app, "files/library_covers/link.jpg").toPath(), secret.toPath())
        Files.createSymbolicLink(File(app, "files/covers/0123_link.image").toPath(), thumbnail.toPath())
        Files.createSymbolicLink(File(app, "files/library_covers/folder.jpg").toPath(), secret.parentFile!!.toPath())

        assertNull(resolve("library_covers", "link.jpg"))
        assertNull(resolve("covers", "0123_link.image"))
        assertNull(resolve("library_covers", "folder.jpg"))
    }

    @Test
    fun refusesNamesThatAreNotCoversByName() {
        val names = mapOf(
            "covers" to listOf(
                "0123_abcd.image.0001.tmp",
                ".0123_abcd.image",
                "0123.jpg",
                ".image",
            ),
            "library_covers" to listOf(
                ".regenerate",
                "subsonic_0123.image.current",
                "subsonic_0123.image.0001.tmp",
                "cover_0123.jpg.tmp",
                "notes.txt",
                "cover_0123.webp",
                ".jpg",
            ),
            "embedded_cover_previews" to listOf(
                "v2_hash_0.jpg.source",
                "v2_hash_0.jpg.source.stage_1_2",
                ".v2_hash_0.stage_1.jpg",
                "v2_hash_0.png",
                "v2_hash_0.image",
            ),
        )
        for ((folder, files) in names) {
            for (name in files) {
                write("${folders.getValue(folder).directory.relativeTo(app).path}/$name")
                assertNull("$folder/$name", resolve(folder, name))
            }
        }
    }

    @Test
    fun aFolderReachedThroughALinkStillServesItsOwnFiles() {
        val real = File(app, "real").also { it.mkdirs() }
        val cover = File(real, "thumb.jpg").also { it.writeBytes(jpeg) }
        val linked = File(app, "linked_files")
        Files.createSymbolicLink(linked.toPath(), real.toPath())

        assertEquals(
            cover,
            CoverProviderFiles.resolve(
                mapOf("library_covers" to CoverProviderFiles.Folder(linked, listOf(".jpg"))),
                listOf("library_covers", "thumb.jpg"),
            ),
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
        assertNull(type(0x89, 0x50, 0x4E, 0x47))
        assertNull(CoverProviderFiles.imageType(ByteArray(0)))
    }
}
