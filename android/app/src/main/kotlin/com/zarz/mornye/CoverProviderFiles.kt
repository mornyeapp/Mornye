package com.zarz.mornye

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile

/**
 * Which file a [CoverContentProvider] URI names. Its path is two segments:
 * the name of an allowed folder, then the name of a regular image file
 * directly in that folder. Anything else names nothing, including a name
 * that leaves the folder through `..`, an encoded `/` or a symbolic link.
 */
internal object CoverProviderFiles {
    /**
     * The app's cover folders that media browser lists name: covers the
     * cover store fetched, Library thumbnails, and embedded artwork read
     * from downloaded songs.
     */
    fun folders(files: File, cache: File): Map<String, File> = mapOf(
        "covers" to File(files, "covers"),
        "library_covers" to File(files, "library_covers"),
        "embedded_cover_previews" to File(cache, "embedded_cover_previews"),
    )

    /** The image file [segments] name in [folders], or null. */
    fun resolve(folders: Map<String, File>, segments: List<String>): File? {
        if (segments.size != 2) return null
        val folder = folders[segments[0]] ?: return null
        val name = segments[1]
        if (name.isEmpty() || name.startsWith('.') || name.any { it == '/' || it == '\u0000' }) {
            return null
        }
        return try {
            val root = folder.canonicalFile
            val file = File(root, name).canonicalFile
            file.takeIf { it.parentFile == root && it.isFile && imageType(it) != null }
        } catch (_: IOException) {
            null
        } catch (_: SecurityException) {
            null
        }
    }

    /** The MIME type of the image [file] holds, or null when it holds none. */
    fun imageType(file: File): String? = try {
        RandomAccessFile(file, "r").use { input ->
            val head = ByteArray(12)
            val count = input.read(head)
            imageType(if (count > 0) head.copyOf(count) else ByteArray(0))
        }
    } catch (_: IOException) {
        null
    }

    /** The MIME type of the image whose first 12 bytes are [head], or null. */
    fun imageType(head: ByteArray): String? {
        fun has(offset: Int, magic: String) =
            head.size >= offset + magic.length &&
                magic.indices.all { head[offset + it] == magic[it].code.toByte() }
        return when {
            has(0, "ÿØÿ") -> "image/jpeg"
            has(0, "\u0089PNG\r\n\u001A\n") -> "image/png"
            has(0, "GIF8") -> "image/gif"
            has(0, "RIFF") && has(8, "WEBP") -> "image/webp"
            has(0, "BM") -> "image/bmp"
            has(4, "ftyp") && head.size >= 12 -> when (String(head, 8, 4, Charsets.ISO_8859_1)) {
                "avif", "avis" -> "image/avif"
                in heifBrands -> "image/heif"
                else -> null
            }
            else -> null
        }
    }

    private val heifBrands = setOf(
        "heic", "heim", "heis", "heix", "hevc", "hevm", "hevs", "hevx", "mif1", "msf1",
    )
}
