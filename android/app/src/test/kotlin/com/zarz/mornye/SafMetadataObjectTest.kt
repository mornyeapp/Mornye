package com.zarz.mornye

import java.io.IOException
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Proxy
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SafMetadataObjectTest {
    private class CountingMetadata(raw: String) : JSONObject(raw) {
        var serializations = 0
        override fun toString(): String {
            serializations++
            return super.toString()
        }
    }

    private fun backend(metadata: JSONObject): CoreBackend = Proxy.newProxyInstance(
        CoreBackend::class.java.classLoader, arrayOf(CoreBackend::class.java),
    ) { _, method, _ ->
        when (method.name) {
            "readAudioMetadataObject" -> metadata
            "readAudioMetadata" -> metadata.toString()
            else -> error("Unexpected backend call ${method.name}")
        }
    } as CoreBackend

    @Test fun scanRetainsTheParsedObjectUntilFinalPublication() {
        val metadata = CountingMetadata("""{"trackName":"曲 Song","artistName":"Artist","duration":234,"explicit":true,"albumArtist":null,"coverPath":"/covers/art.jpg"}""")
        val result = readAudioMetadataForScan(backend(metadata), "/proc/self/fd/10", "Song.flac", "stable-key")
        assertSame(metadata, result)
        assertEquals(0, metadata.serializations)
        result.put("id", "library-id").put("filePath", "content://example.documents/song").put("fileModTime", 1234L)
        val published = JSONObject(result.toString())
        assertEquals(1, metadata.serializations)
        for (key in listOf("trackName", "artistName", "duration", "explicit", "coverPath", "id", "filePath")) {
            assertEquals(metadata.get(key), published.get(key))
        }
        assertTrue(published.isNull("albumArtist"))
        assertEquals(1234L, published.getLong("fileModTime"))
    }

    @Test fun errorsRetainTheirMessageWithoutAnotherJsonRoundTrip() {
        val metadata = CountingMetadata("""{"error":"No audio metadata"}""")
        val error = assertThrows(IOException::class.java) {
            readAudioMetadataForScan(backend(metadata), "/proc/self/fd/11", "Song.flac", "key")
        }
        assertEquals("No audio metadata", error.message)
        assertEquals(0, metadata.serializations)
    }

    @Test fun backendsWithOnlyTheStringApiKeepTheirExistingBehavior() {
        var reads = 0
        val raw = """{"trackName":"Song","artistName":"Artist","bitDepth":24}"""
        val invokeDefault = InvocationHandler::class.java.methods.single {
            it.name == "invokeDefault"
        }
        val backend = Proxy.newProxyInstance(
            CoreBackend::class.java.classLoader, arrayOf(CoreBackend::class.java),
        ) { proxy, method, arguments ->
            if (method.name == "readAudioMetadata") {
                reads++
                raw
            } else {
                invokeDefault.invoke(null, proxy, method, arguments ?: emptyArray<Any>())
            }
        } as CoreBackend
        val result = readAudioMetadataForScan(backend, "/music/Song.flac", "Song.flac", "key")
        assertEquals("Song", result.getString("trackName"))
        assertEquals("Artist", result.getString("artistName"))
        assertEquals(24, result.getInt("bitDepth"))
        assertEquals(1, reads)
    }
}
