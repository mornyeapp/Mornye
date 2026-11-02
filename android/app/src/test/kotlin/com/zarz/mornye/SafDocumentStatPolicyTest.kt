package com.zarz.mornye

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SafDocumentStatPolicyTest {
    @Test fun nullCursorAndLoadingResultsNeverBecomeMissing() {
        assertThrows(IOException::class.java) { safDocumentStatResult(hasRow = null) }
        for (hasRow in listOf(false, true)) {
            assertThrows(IOException::class.java) { safDocumentStatResult(hasRow, loading = true) }
        }
    }

    @Test fun onlyCompletedEmptyQueryIsMissing() {
        val result = safDocumentStatResult(hasRow = false)
        assertFalse(result.getBoolean("exists"))
        assertTrue(result.isNull("size"))
        assertTrue(result.isNull("modified"))
        assertTrue(result.isNull("mime_type"))
    }

    @Test fun presentDocumentRetainsUnknownMetadata() {
        val result = safDocumentStatResult(hasRow = true)
        assertTrue(result.getBoolean("exists"))
        assertTrue(result.isNull("size"))
        assertTrue(result.isNull("modified"))
        assertTrue(result.isNull("mime_type"))
    }

    @Test fun knownMetadataIncludesZeroLengthDocuments() {
        val result = safDocumentStatResult(true, size = 0L, modified = 123L, mimeType = "audio/flac")
        assertTrue(result.getBoolean("exists"))
        assertEquals(0L, result.getLong("size"))
        assertEquals(123L, result.getLong("modified"))
        assertEquals("audio/flac", result.getString("mime_type"))
    }

    @Test fun displayNameIsPreservedOnlyForExistingDocuments() {
        val name = "Song: Live 100%.flac"
        assertEquals(name, safDocumentStatResult(true, displayName = name).getString("display_name"))
        assertTrue(safDocumentStatResult(false, displayName = name).isNull("display_name"))
    }
}
