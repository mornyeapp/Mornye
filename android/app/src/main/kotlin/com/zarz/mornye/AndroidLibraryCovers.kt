package com.zarz.mornye

import java.io.File
import java.security.MessageDigest

internal object AndroidLibraryCovers {
    private val HEX_CHARS = "0123456789abcdef".toCharArray()
    // ThreadLocal.withInitial needs API 26; subclasses work on every version.
    private val COMPARE_BUFFER = object : ThreadLocal<ByteArray>() {
        override fun initialValue() = ByteArray(8192)
    }
    private val SHA256_DIGEST = object : ThreadLocal<MessageDigest>() {
        override fun initialValue(): MessageDigest = MessageDigest.getInstance("SHA-256")
    }

    private fun sha256Hex(data: ByteArray): String {
        val digest = SHA256_DIGEST.get()!!.apply { reset() }.digest(data)
        val out = CharArray(digest.size * 2)
        for (i in digest.indices) {
            val v = digest[i].toInt() and 0xff
            out[i * 2] = HEX_CHARS[v ushr 4]
            out[i * 2 + 1] = HEX_CHARS[v and 0x0f]
        }
        return String(out)
    }

    private fun fileEqualsBytes(file: File, expected: ByteArray): Boolean {
        if (file.length() != expected.size.toLong()) return false
        val buffer = COMPARE_BUFFER.get()!!
        var offset = 0
        file.inputStream().use { input ->
            while (offset < expected.size) {
                val read = input.read(buffer, 0, minOf(buffer.size, expected.size - offset))
                if (read <= 0) return false
                for (i in 0 until read) {
                    if (buffer[i] != expected[offset + i]) return false
                }
                offset += read
            }
            return input.read() == -1
        }
    }

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
        val hash = sha256Hex(data)
        val output = File(directory, "cover_content_$hash.$extension")
        if (output.exists()) {
            check(fileEqualsBytes(output, data)) {
                "Content-addressed library artwork differs from its name"
            }
            return output
        }
        val staged = File.createTempFile("cover_", ".tmp", directory)
        try {
            staged.outputStream().use { stream ->
                stream.write(data)
            }
            synchronized(this) {
                if (output.exists()) {
                    check(fileEqualsBytes(output, data)) {
                        "Content-addressed library artwork differs from its name"
                    }
                    return output
                }
                check(staged.renameTo(output)) { "Could not publish library artwork" }
                return output
            }
        } finally {
            staged.delete()
        }
    }
}
