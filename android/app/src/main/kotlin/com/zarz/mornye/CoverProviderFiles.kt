package com.zarz.mornye

import java.io.File
import java.io.IOException

/**
 * Which file a [CoverContentProvider] URI names. Its path is two segments:
 * the name of an allowed folder, then the name of a regular file directly
 * in that folder that is named as that folder names its covers. Anything
 * else names nothing, including a name that leaves the folder through
 * `..`, an encoded `/` or a symbolic link. The provider then checks the
 * opened file holds an image.
 */
internal object CoverProviderFiles {
    /** An allowed cover folder and the endings of its cover file names. */
    class Folder(val directory: File, private val suffixes: List<String>) {
        /**
         * Whether [name] is a cover's: not hidden or staged (`.tmp`), no
         * sidecar (`.source`), pointer (`.current`) or marker.
         */
        fun names(name: String) =
            !name.startsWith('.') &&
                name.none { it == '/' || it == '\u0000' } &&
                suffixes.any { name.length > it.length && name.endsWith(it) }
    }

    /**
     * The app's cover folders that media browser lists name: covers the
     * cover store fetched, Library thumbnails (scanned, Subsonic and other
     * network covers), and embedded artwork read from downloaded songs.
     */
    fun folders(files: File, cache: File): Map<String, Folder> = mapOf(
        "covers" to Folder(File(files, "covers"), listOf(".image")),
        "library_covers" to Folder(File(files, "library_covers"), listOf(".jpg", ".png", ".image")),
        "embedded_cover_previews" to Folder(File(cache, "embedded_cover_previews"), listOf(".jpg")),
    )

    /** The regular file [segments] name in [folders], or null. */
    fun resolve(folders: Map<String, Folder>, segments: List<String>): File? {
        if (segments.size != 2) return null
        val folder = folders[segments[0]] ?: return null
        val name = segments[1]
        if (!folder.names(name)) return null
        return try {
            val root = folder.directory.canonicalFile
            val file = File(root, name).canonicalFile
            file.takeIf { it.parentFile == root && it.isFile }
        } catch (_: IOException) {
            null
        } catch (_: SecurityException) {
            null
        }
    }

    /** The MIME type of the image whose first 12 bytes are [head], or null. */
    fun imageType(head: ByteArray): String? {
        fun has(offset: Int, vararg magic: Int) =
            head.size >= offset + magic.size &&
                magic.indices.all { head[offset + it] == magic[it].toByte() }
        fun has(offset: Int, magic: String) = has(offset, *IntArray(magic.length) { magic[it].code })
        return when {
            has(0, 0xFF, 0xD8, 0xFF) -> "image/jpeg"
            has(0, 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) -> "image/png"
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
