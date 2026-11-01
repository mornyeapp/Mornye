package com.zarz.mornye

import java.io.File
import java.security.MessageDigest

internal object AndroidLibraryCovers {
    @Synchronized
    fun cache(directory: File?, cached: File?, bytes: ByteArray, mime: String): File? {
        if (directory == null) return cached
        if (bytes.isEmpty() && cached != null && cached.length() > 24L * 1024 * 1024) return cached
        val data = if (bytes.isNotEmpty()) bytes else cached?.readBytes() ?: return null
        if (data.isEmpty()) return null
        val extension = if (data.size >= 4 && data[0] == 0x89.toByte() &&
            data[1] == 0x50.toByte() && data[2] == 0x4e.toByte() && data[3] == 0x47.toByte()
        ) {
            "png"
        } else if (data.size >= 2 && data[0] == 0xff.toByte() && data[1] == 0xd8.toByte()) {
            "jpg"
        } else if (bytes.isNotEmpty()) {
            if (mime.contains("png")) "png" else "jpg"
        } else if (cached?.extension == "png") "png" else "jpg"
        val hash = MessageDigest.getInstance("SHA-256").digest(data)
            .joinToString("") { "%02x".format(it) }
        val output = File(directory, "cover_content_$hash.$extension")
        if (output.exists()) {
            check(output.length() == data.size.toLong() && output.readBytes().contentEquals(data)) {
                "Content-addressed library artwork differs from its name"
            }
            return output
        }
        val staged = File.createTempFile("cover_", ".tmp", directory)
        try {
            staged.outputStream().use { stream ->
                stream.write(data)
            }
            check(staged.renameTo(output)) { "Could not publish library artwork" }
            return output
        } finally {
            staged.delete()
        }
    }
}
