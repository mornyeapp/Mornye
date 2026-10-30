package com.zarz.mornye

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException

/**
 * Cover images for media browsers such as Android Auto, which run in
 * another process and load list artwork from the item's URI. A car cannot
 * hold a permission, so the provider is exported, and in exchange it only
 * reads: regular image files directly in the folders [CoverProviderFiles]
 * allows, named as `content://<authority>/<folder>/<file>`, with no
 * listing and no writes.
 */
class CoverContentProvider : ContentProvider() {
    private val folders: Map<String, File> by lazy { coverFolders(requireNotNull(context)) }

    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Covers are read-only")
        val file = coverFile(uri) ?: throw FileNotFoundException("No cover at this URI")
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String? = coverFile(uri)?.let(CoverProviderFiles::imageType)

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

    companion object {
        private fun authority(context: Context) = "${context.packageName}.covers"

        private fun coverFolders(context: Context) =
            CoverProviderFiles.folders(context.filesDir, context.cacheDir)

        /** The authority and folder paths Dart builds cover URIs from. */
        fun describe(context: Context): Map<String, Any> = mapOf(
            "authority" to authority(context),
            "folders" to coverFolders(context).mapValues { it.value.path },
        )
    }
}
