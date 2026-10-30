package com.zarz.mornye

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileDescriptor
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InterruptedIOException

/**
 * Cover images for media browsers such as Android Auto, which run in
 * another process and load list artwork from the item's URI. A car cannot
 * hold a permission, so the provider is exported, and in exchange it only
 * reads: regular image files directly in the folders [CoverProviderFiles]
 * allows, named as `content://<authority>/<folder>/<file>`, with no
 * listing and no writes.
 */
class CoverContentProvider : ContentProvider() {
    private val folders: Map<String, CoverProviderFiles.Folder> by lazy { coverFolders(requireNotNull(context)) }

    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Covers are read-only")
        val (descriptor, _) = openCover(uri) ?: throw FileNotFoundException("No cover at this URI")
        try {
            return ParcelFileDescriptor.dup(descriptor)
        } catch (_: IOException) {
            throw FileNotFoundException("Could not open the cover")
        } finally {
            close(descriptor)
        }
    }

    override fun getType(uri: Uri): String? = openCover(uri)?.let { (descriptor, type) ->
        close(descriptor)
        type
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = readOnly()

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = readOnly()

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = readOnly()

    private fun readOnly(): Nothing = throw UnsupportedOperationException("Covers are read-only")

    private fun coverFile(uri: Uri): File? {
        val context = context ?: return null
        if (uri.scheme != ContentResolver.SCHEME_CONTENT || uri.authority != authority(context)) return null
        return CoverProviderFiles.resolve(folders, uri.pathSegments)
    }

    /**
     * The cover [uri] names, opened once without following a link, and its
     * image type, both checked on that descriptor: a regular file that
     * starts with an image signature. Null for anything else.
     */
    private fun openCover(uri: Uri): Pair<FileDescriptor, String>? {
        val file = coverFile(uri) ?: return null
        val descriptor = try {
            Os.open(file.path, openFlags, 0)
        } catch (_: ErrnoException) {
            return null
        }
        val type = try {
            if (OsConstants.S_ISREG(Os.fstat(descriptor).st_mode)) {
                val head = ByteArray(12)
                val count = Os.pread(descriptor, head, 0, head.size, 0)
                CoverProviderFiles.imageType(head.copyOf(count))
            } else {
                null
            }
        } catch (_: ErrnoException) {
            null
        } catch (_: InterruptedIOException) {
            null
        }
        if (type == null) close(descriptor)
        return type?.let { descriptor to it }
    }

    private fun close(descriptor: FileDescriptor) {
        try {
            Os.close(descriptor)
        } catch (_: ErrnoException) {
        }
    }

    companion object {
        private val openFlags = OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or
            if (Build.VERSION.SDK_INT >= 27) OsConstants.O_CLOEXEC else 0

        private fun authority(context: Context) = "${context.packageName}.covers"

        private fun coverFolders(context: Context) =
            CoverProviderFiles.folders(context.filesDir, context.cacheDir)

        /** The authority and folder paths Dart builds cover URIs from. */
        fun describe(context: Context): Map<String, Any> = mapOf(
            "authority" to authority(context),
            "folders" to coverFolders(context).mapValues { it.value.directory.path },
        )
    }
}
