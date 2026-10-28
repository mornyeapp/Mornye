package com.zarz.mornye

import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SafDocumentLookupTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val authority = "com.mornye.test.documents.lookup"
    private val controlUri = Uri.parse("content://$authority.control")
    private val treeUri = DocumentsContract.buildTreeDocumentUri(authority, "root")

    private fun reset(count: Int = 0, mode: String = "normal", failFinalRename: Boolean = false): DocumentFile {
        context.contentResolver.call(controlUri, "lookup.reset", null, Bundle().apply {
            putInt("count", count)
            putString("mode", mode)
            putBoolean("failFinalRename", failFinalRename)
            putString("targetPackage", context.packageName)
        })
        return requireNotNull(DocumentFile.fromTreeUri(context, treeUri))
    }

    private fun stats() = requireNotNull(context.contentResolver.call(controlUri, "lookup.stats", null, null))

    private fun clearCounters() {
        context.contentResolver.call(controlUri, "lookup.clearCounters", null, null)
    }

    @Test
    fun cueSiblingLookupBatchesCandidatesAndPreservesPriority() {
        val parent = reset(count = 2000)
        val declared = findSafCueAudioSibling(context, parent, "Song.cue", "Track 1999.flac")
        assertEquals("child:1999", DocumentsContract.getDocumentId(requireNotNull(declared).uri))
        assertEquals(1, stats().getInt("children"))
        assertEquals(0, stats().getInt("documents"))

        clearCounters()
        val fallback = findSafCueAudioSibling(context, parent, "Song.cue", "missing.flac")
        assertEquals("original", DocumentsContract.getDocumentId(requireNotNull(fallback).uri))
        assertEquals(1, stats().getInt("children"))
        assertEquals(0, stats().getInt("documents"))

        assertTrue(fallback.renameTo("Song.FLAC"))
        clearCounters()
        assertEquals(fallback.uri, findSafCueAudioSibling(context, parent, "Song.cue", null)?.uri)
        assertEquals(1, stats().getInt("children"))
        assertEquals(0, stats().getInt("documents"))

        clearCounters()
        assertNull(findSafCueAudioSibling(context, parent, "Missing.cue", null))
        assertEquals(1, stats().getInt("children"))
        assertEquals(0, stats().getInt("documents"))
    }

    @Test
    fun projectedBatchReplacesThousandsOfNameQueriesAndClosesItsCursor() {
        val parent = reset(count = 2000)
        assertNull(parent.findFile("missing.flac"))
        assertEquals(1, stats().getInt("children"))
        assertEquals(2002, stats().getInt("documents"))
        clearCounters()

        val found = findSafChildren(context, parent, setOf("Track 0.flac", "Track 1999.flac", "missing.flac"))
        assertEquals(setOf("Track 0.flac", "Track 1999.flac"), found.keys)
        assertEquals(1, stats().getInt("children"))
        assertEquals(0, stats().getInt("documents"))
        assertEquals(1, stats().getInt("closed"))
        clearCounters()
        assertNull(findSafChild(context, parent, "missing.flac"))
        assertEquals(1, stats().getInt("children"))
        assertEquals(0, stats().getInt("documents"))
        clearCounters()
        assertTrue(findSafChildren(context, parent, emptySet()).isEmpty())
        assertEquals(0, stats().getInt("children"))
    }

    @Test
    fun nestedOpaqueIdsUnicodeAndRenameKeepTheChildDocument() {
        val parent = reset()
        val directory = requireNotNull(findSafChild(context, parent, "音楽 🎵"))
        assertEquals("nested:音楽/opaque", DocumentsContract.getDocumentId(directory.uri))
        assertTrue(directory.isDirectory)
        val child = requireNotNull(findSafChild(context, directory, "歌 🎵.flac"))
        val oldUri = child.uri
        assertTrue(child.renameTo("Renamed.flac"))
        assertNotEquals(oldUri, child.uri)
        assertEquals("Renamed.flac", child.name)
        assertEquals(child.uri, findSafChild(context, directory, "Renamed.flac")?.uri)
        assertNull(findSafChild(context, parent, "Renamed.flac"))
        assertNotNull(directory.createDirectory("Created"))
    }

    @Test
    fun lyricsRefreshReplacesSidecarBesideOpaqueRootAndNestedDocuments() {
        val root = reset()
        val nested = requireNotNull(findSafChild(context, root, "音楽 🎵"))
        for ((parent, name) in listOf(root to "Song.flac", nested to "歌 🎵.flac")) {
            val audio = requireNotNull(findSafChild(context, parent, name))
            val sidecarName = name.substringBeforeLast('.') + ".lrc"
            val sidecar = requireNotNull(parent.createFile("text/plain", sidecarName))
            context.contentResolver.openOutputStream(sidecar.uri, "wt")!!.use {
                it.write("[00:01.00]Old lyrics that must be replaced completely".toByteArray())
            }
            context.contentResolver.openOutputStream(audio.uri, "wt")!!.use {
                it.write("unchanged audio".toByteArray())
            }
            val original = context.contentResolver.openInputStream(audio.uri)?.use { it.readBytes() }
            val replacement = "[00:01.00]<00:01.00>New <00:01.50>words<00:02.00>"
            assertEquals(parent.uri, context.safParentDir(audio.uri)?.uri)
            assertTrue(context.writeSafSidecarLrc(audio.uri, replacement))
            val saved = requireNotNull(findSafChild(context, parent, sidecarName))
            assertEquals(sidecar.uri, saved.uri)
            assertEquals(replacement, context.contentResolver.openInputStream(saved.uri)?.bufferedReader()?.use { it.readText() })
            assertArrayEquals(original, context.contentResolver.openInputStream(audio.uri)?.use { it.readBytes() })
            if (parent == nested) assertNull(findSafChild(context, root, sidecarName))
        }
        assertNull(context.safParentDir(root.uri))
    }

    @Test
    fun unavailableParentDoesNotWriteLyricsToTheGrantedRoot() {
        val root = reset(mode = "no-path")
        val nested = requireNotNull(findSafChild(context, root, "音楽 🎵"))
        val audio = requireNotNull(findSafChild(context, nested, "歌 🎵.flac"))
        assertTrue(!context.writeSafSidecarLrc(audio.uri, "[00:01.00]New lyrics"))
        assertNull(findSafChild(context, root, "歌 🎵.lrc"))
        assertNull(findSafChild(context, nested, "歌 🎵.lrc"))

        // Providers without findDocumentPath can still use verified path IDs.
        val legacy = requireNotNull(findSafChild(context, root, "Legacy"))
        val legacyAudio = requireNotNull(findSafChild(context, legacy, "Legacy.flac"))
        assertEquals(legacy.uri, context.safParentDir(legacyAudio.uri)?.uri)
        assertTrue(context.writeSafSidecarLrc(legacyAudio.uri, "[00:01.00]New lyrics"))
        assertNotNull(findSafChild(context, legacy, "Legacy.lrc"))
        assertNull(findSafChild(context, root, "Legacy.lrc"))
    }

    @Test
    fun importedDocumentsExportCoverAndLyricsBesideTheAudio() {
        val root = reset()
        val nested = requireNotNull(findSafChild(context, root, "音楽 🎵"))
        val staged = File(context.cacheDir, "sidecar-export-${System.nanoTime()}")
        try {
            for ((parent, name) in listOf(root to "Song.flac", nested to "歌 🎵.flac")) {
                val audio = requireNotNull(findSafChild(context, parent, name))
                context.contentResolver.openOutputStream(audio.uri, "wt")!!.use {
                    it.write("unchanged audio".toByteArray())
                }
                for ((extension, mime) in listOf("jpg" to "image/jpeg", "lrc" to "application/octet-stream")) {
                    val bytes = "exported $extension bytes".toByteArray()
                    staged.writeBytes(bytes)
                    val outputName = "Artist - $name.$extension"
                    val result = context.writeSafSidecarFromPath(audio.uri, outputName, mime, staged.path)
                    val output = requireNotNull(findSafChild(context, parent, outputName))
                    assertEquals(output.uri.toString(), result)
                    assertArrayEquals(bytes, context.contentResolver.openInputStream(output.uri)!!.use { it.readBytes() })
                    if (parent == nested) assertNull(findSafChild(context, root, outputName))
                }
                assertNull(context.writeSafSidecarFromPath(audio.uri, name, "image/jpeg", staged.path))
                assertNull(context.writeSafSidecarFromPath(audio.uri, "../escape.jpg", "image/jpeg", staged.path))
                assertEquals("unchanged audio", context.contentResolver.openInputStream(audio.uri)!!.bufferedReader().use { it.readText() })
            }
        } finally { staged.delete() }
    }

    @Test
    fun unsupportedProjectionNullCursorAndMissingColumnUseLegacyLookup() {
        for (mode in listOf("throw", "null", "missing")) {
            val parent = reset(count = 3, mode = mode)
            val found = requireNotNull(findSafChild(context, parent, "Song.flac"))
            assertEquals("original", DocumentsContract.getDocumentId(found.uri))
            assertEquals(2, stats().getInt("children"))
            assertEquals(5, stats().getInt("documents"))
            assertEquals(if (mode == "missing") 7 else 6, stats().getInt("closed"))
        }
    }

    @Test
    fun rawDocumentFileRetainsLegacyBehavior() {
        val directory = File(context.cacheDir, "lookup-raw").apply { mkdirs() }
        try {
            File(directory, "local.flac").writeText("audio")
            val found = findSafChild(context, DocumentFile.fromFile(directory), "local.flac")
            assertEquals("local.flac", found?.name)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun malformedTreeUriLeavesSourceIntact() {
        val source = File(context.cacheDir, "lookup-invalid.flac").apply { writeText("original audio") }
        try {
            assertNull(SafDownloadHandler.writeFileToSaf(
                context, "content://$authority/invalid", "", "Song.flac", "audio/flac", source.path,
            ))
            assertEquals("original audio", source.readText())
        } finally {
            source.delete()
        }
    }

    @Test
    fun failedPublicationRenameRestoresOriginalWhenProviderChangesDocumentIds() {
        val parent = reset(failFinalRename = true)
        val source = File(context.cacheDir, "lookup-source.flac").apply { writeText("replacement") }
        try {
            assertNull(SafDownloadHandler.writeFileToSaf(context, treeUri.toString(), "", "Song.flac", "audio/flac", source.path))
            val restored = requireNotNull(findSafChild(context, parent, "Song.flac"))
            val content = context.contentResolver.openInputStream(restored.uri)?.bufferedReader()?.use { it.readText() }
            assertEquals("original", content)
            assertEquals("replacement", source.readText())
            assertNull(findSafChild(context, parent, "Song.flac.replaced"))
            assertNull(findSafChild(context, parent, "Song.flac.partial"))
        } finally {
            source.delete()
        }
    }

    @Test
    fun publicationPreservesBytesReportsStagesAndDetectsLaterExistingFile() {
        val parent = reset(count = 2000)
        val bytes = ByteArray(262144) { (it % 251).toByte() }
        val source = File(context.cacheDir, "lookup-publish.flac").apply { writeBytes(bytes) }
        try {
            assertNull(findSafChild(context, parent, "Fresh.flac"))
            clearCounters()
            val result = requireNotNull(SafDownloadHandler.writeFileToSafIfAbsent(
                context, treeUri.toString(), "", "Fresh.flac", "audio/flac", source.path,
            ))
            assertTrue(!result.alreadyExists)
            assertEquals(4, stats().getInt("children"))
            assertEquals(1, stats().getInt("documents"))
            val expectedStages = setOf(
                "lock_wait", "directory", "existing_check", "cleanup", "create",
                "open", "copy", "sync", "close", "replace", "total",
            )
            assertTrue(result.publishTimingsMs.keys.containsAll(expectedStages))
            assertTrue(result.publishTimingsMs.values.all { it >= 0 })
            val actual = context.contentResolver.openInputStream(Uri.parse(result.uri))?.use { it.readBytes() }
            assertArrayEquals(bytes, actual)
            assertEquals(result.uri, findSafChild(context, parent, "Fresh.flac")?.uri.toString())
            assertNull(findSafChild(context, parent, "Fresh.flac.partial"))

            source.writeText("must not replace existing audio")
            val existing = requireNotNull(SafDownloadHandler.writeFileToSafIfAbsent(
                context, treeUri.toString(), "", "Fresh.flac", "audio/flac", source.path,
            ))
            assertTrue(existing.alreadyExists)
            assertEquals(result.uri, existing.uri)
            assertArrayEquals(bytes, context.contentResolver.openInputStream(Uri.parse(existing.uri))?.use { it.readBytes() })
        } finally {
            source.delete()
        }
    }
}
