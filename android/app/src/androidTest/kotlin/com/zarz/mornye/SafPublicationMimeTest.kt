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
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SafPublicationMimeTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val authority = "com.mornye.test.documents.lookup"
    private val treeUri = DocumentsContract.buildTreeDocumentUri(authority, "root")

    private fun reset(): DocumentFile {
        context.contentResolver.call(Uri.parse("content://$authority.control"), "lookup.reset", null, Bundle().apply {
            putString("targetPackage", context.packageName)
        })
        return requireNotNull(DocumentFile.fromTreeUri(context, treeUri))
    }

    @Test
    fun everyPublicationPathRetainsAudioMimeAndBytesAfterOpaqueRename() {
        val bytes = ByteArray(16384) { (it % 251).toByte() }
        val source = File(context.cacheDir, "publish-mime-${System.nanoTime()}.tmp").apply { writeBytes(bytes) }
        try {
            for ((extension, mime) in listOf("flac" to "audio/flac", "mp3" to "audio/mpeg", "m4a" to "audio/mp4", "opus" to "audio/opus")) {
                for (mode in 0..3) {
                    val parent = reset()
                    val name = "EjAj - Lej Mi Pół.$extension"
                    val uri = requireNotNull(when (mode) {
                        0 -> SafDownloadHandler.writeFileToSaf(context, treeUri.toString(), "", name, mime, source.path)
                        1 -> SafDownloadHandler.writeFileToSafUnique(context, treeUri.toString(), "", name, mime, source.path)?.uri
                        2 -> SafDownloadHandler.writeFileToSafCollisionAware(context, treeUri.toString(), "", name, "Variant.$extension", mime, source.path)?.uri
                        else -> SafDownloadHandler.writeFileToSafIfAbsent(context, treeUri.toString(), "", name, mime, source.path)?.uri
                    })
                    val published = Uri.parse(uri)
                    assertEquals("$extension/$mode", mime, context.contentResolver.getType(published))
                    assertEquals(name, findSafChild(context, parent, name)?.name)
                    assertArrayEquals(bytes, context.contentResolver.openInputStream(published)?.use { it.readBytes() })
                    assertNull(findSafChild(context, parent, "$name.partial"))
                    assertNull(findSafChild(context, parent, name.removeSuffix(".$extension") + ".partial.$extension"))
                    assertNull(findSafChild(context, parent, SafDownloadHandler.buildStagedSafFileName(name)))
                    val stats = requireNotNull(context.contentResolver.call(
                        Uri.parse("content://$authority.control"), "lookup.stats", null, null,
                    ))
                    val created = requireNotNull(stats.getStringArrayList("createdNames"))
                    assertTrue(
                        "$extension/$mode: $created",
                        created.isNotEmpty() && created.all { it.startsWith(".") },
                    )
                    assertNotNull(source.takeIf { it.exists() })
                }
            }
        } finally { source.delete() }
    }

    @Test
    fun replacementHidesBackupAndRemovesLegacyTemporaryFiles() {
        val parent = reset()
        val legacy = listOf("Song.partial.flac", "Song.flac.partial", "Song.flac.replaced")
        for (name in legacy) requireNotNull(parent.createFile("audio/flac", name))
        context.contentResolver.call(
            Uri.parse("content://$authority.control"), "lookup.clearCounters", null, null,
        )
        val bytes = ByteArray(16384) { (it % 251).toByte() }
        val source = File(context.cacheDir, "publish-replacement-${System.nanoTime()}.tmp")
            .apply { writeBytes(bytes) }
        try {
            val uri = requireNotNull(SafDownloadHandler.writeFileToSaf(
                context, treeUri.toString(), "", "Song.flac", "audio/flac", source.path,
            ))
            assertArrayEquals(bytes, context.contentResolver.openInputStream(Uri.parse(uri))?.use { it.readBytes() })
            assertEquals("audio/flac", context.contentResolver.getType(Uri.parse(uri)))
            for (name in legacy + listOf(".Song.partial.flac", ".Song.flac.replaced")) {
                assertNull(name, findSafChild(context, parent, name))
            }
            val stats = requireNotNull(context.contentResolver.call(
                Uri.parse("content://$authority.control"), "lookup.stats", null, null,
            ))
            assertEquals(listOf(".Song.partial.flac"), stats.getStringArrayList("createdNames"))
            assertEquals(
                listOf(".Song.flac.replaced", "Song.flac"),
                stats.getStringArrayList("renamedNames"),
            )
        } finally { source.delete() }
    }
}
