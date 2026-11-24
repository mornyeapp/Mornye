package com.zarz.mornye

import android.content.Context
import androidx.documentfile.provider.DocumentFile
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/**
 * Folder images (cover.jpg and the like) for the songs of one SAF scan that
 * have no embedded artwork. Each folder's image comes from the traversal's
 * own listing, and the first song that needs it makes the thumbnail for the
 * rest. Thumbnails are named by content, so a replaced image gets a new one
 * the next time its songs are read.
 */
internal class SafFolderCovers(
    private val context: Context,
    private val coreBackend: CoreBackend,
) {
    // Written by the traversal thread only: the image of each subfolder's
    // parent, for disc folders that leave the picture to it.
    private val parents = mutableMapOf<String, SafChildEntry>()
    private val thumbnails = ConcurrentHashMap<String, Lazy<String?>>()

    /** The image the files of [dir], at [path] below the tree, use. Call
     * once per listed folder, before its subfolders. */
    fun image(dir: DocumentFile, path: String, children: List<SafChildEntry>): SafChildEntry? {
        val files = children.filter { !it.isDirectory && it.name != null }
        val own = if (files.isEmpty()) null else {
            com.mornye.backend.libraryFolderImage(files.map { it.name!! })
                ?.let { name -> files.firstOrNull { it.name == name } }
        }
        val parent = parents.remove(dir.uri.toString())
        if (own != null) {
            for (child in children) {
                if (child.isDirectory) parents[child.doc.uri.toString()] = own
            }
        }
        return own ?: parent?.takeIf {
            com.mornye.backend.isLibraryDiscFolder(path.substringAfterLast('/'))
        }
    }

    fun fill(row: JSONObject, image: SafChildEntry?) {
        if (image == null || row.optString("coverPath", "").isNotEmpty()) return
        thumbnails.computeIfAbsent("${image.doc.uri}|${image.lastModified}") {
            lazy { thumbnail(image) }
        }.value?.let { row.put("coverPath", it) }
    }

    private fun thumbnail(image: SafChildEntry): String? = try {
        context.contentResolver.openFileDescriptor(image.doc.uri, "r")?.use {
            coreBackend.cacheLibraryFolderCover("/proc/self/fd/${it.fd}")
        }
    } catch (error: Exception) {
        // The songs keep their rows; only the folder artwork is missing.
        android.util.Log.w("Mornye", "Could not use folder image ${image.name}", error)
        null
    }
}
