package com.zarz.mornye

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document.MIME_TYPE_DIR
import androidx.documentfile.provider.DocumentFile
import java.io.IOException
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

// Provider round trips dominate on SD cards, USB drives and network shares.
private const val SAF_LIST_CONCURRENCY = 4
private const val SAF_READ_WORKERS = 6
private const val SAF_READ_CANCEL_POLL_MS = 100L

/**
 * Prefetches the listings of directories already waiting in a breadth-first
 * queue. The caller still dequeues, deduplicates and records errors serially,
 * so traversal order and results match a one-directory-at-a-time walk.
 * Idle daemon threads exit on their own, so abandoned walks leak nothing.
 */
internal class SafTreeLister(private val context: Context) {
    private val executor = ThreadPoolExecutor(
        SAF_LIST_CONCURRENCY,
        SAF_LIST_CONCURRENCY,
        1,
        TimeUnit.SECONDS,
        LinkedBlockingQueue(),
    ) { runnable -> Thread(runnable, "saf-scan-list").apply { isDaemon = true } }
        .apply { allowCoreThreadTimeOut(true) }
    private val prefetched = mutableMapOf<String, Future<Result<List<SafChildEntry>>>>()

    private fun submit(dir: DocumentFile) = executor.submit<Result<List<SafChildEntry>>> {
        try {
            Result.success(context.listSafChildrenOrThrow(dir))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun list(
        dir: DocumentFile,
        queue: Collection<Pair<DocumentFile, String>>,
        visited: Set<String>,
    ): Result<List<SafChildEntry>> {
        val uri = dir.uri.toString()
        val current = prefetched.remove(uri) ?: submit(dir)
        for ((next, _) in queue) {
            if (prefetched.size >= SAF_LIST_CONCURRENCY * 2) break
            val nextUri = next.uri.toString()
            if (nextUri == uri || nextUri in visited || nextUri in prefetched) continue
            prefetched[nextUri] = submit(next)
        }
        return try {
            current.get()
        } catch (e: ExecutionException) {
            throw e.cause ?: e
        }
    }
}

/**
 * Runs [task] on a bounded pool and passes each result to [consume] in input
 * order. A sliding window keeps workers busy past one slow file. Returns
 * false when cancelled.
 */
internal fun <T, R> runSafReadsInOrder(
    items: List<T>,
    cancelled: () -> Boolean,
    task: (T) -> R,
    consume: (T, Result<R>) -> Unit,
): Boolean {
    if (items.isEmpty()) return true
    val workers = minOf(SAF_READ_WORKERS, items.size)
    val executor = Executors.newFixedThreadPool(workers)
    try {
        val window = workers * 4
        val inFlight = ArrayDeque<Pair<T, Future<R>>>(window)
        var next = 0
        while (next < items.size || inFlight.isNotEmpty()) {
            if (cancelled()) {
                inFlight.forEach { it.second.cancel(true) }
                return false
            }
            while (inFlight.size < window && next < items.size) {
                val item = items[next++]
                inFlight.addLast(item to executor.submit<R> { task(item) })
            }
            val (item, future) = inFlight.removeFirst()
            var result: Result<R>? = null
            while (result == null) {
                if (cancelled()) {
                    future.cancel(true)
                    inFlight.forEach { it.second.cancel(true) }
                    return false
                }
                result = try {
                    Result.success(future.get(SAF_READ_CANCEL_POLL_MS, TimeUnit.MILLISECONDS))
                } catch (_: TimeoutException) {
                    // A provider read can block while the scan is cancelled or
                    // paused. Keep checking without submitting more work.
                    null
                } catch (e: ExecutionException) {
                    Result.failure(e.cause ?: e)
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw e
                } catch (e: Exception) {
                    Result.failure(e)
                }
            }
            if (cancelled()) return false
            consume(item, result)
        }
        return true
    } finally {
        executor.shutdownNow()
    }
}

internal data class SafChildEntry(
    val doc: DocumentFile,
    val name: String?,
    val isDirectory: Boolean,
    val lastModified: Long,
    val isFile: Boolean,
)

internal fun Context.listSafChildrenOrThrow(
    dir: DocumentFile,
    includeLastModified: Boolean = true,
): List<SafChildEntry> {
    for (attempt in 0..2) {
        try {
            return querySafChildrenOrThrow(dir, includeLastModified)
        } catch (error: SafProviderLoadingException) {
            if (attempt == 2) throw error
            Thread.sleep(300L * (attempt + 1))
        }
    }
    throw IOException("SAF directory listing did not complete")
}

private class SafProviderLoadingException(uri: Uri) :
    IOException("SAF provider is still loading $uri; retry the scan when it is ready")

private fun Context.querySafChildrenOrThrow(
    dir: DocumentFile,
    includeLastModified: Boolean,
): List<SafChildEntry> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            dir.uri,
            DocumentsContract.getDocumentId(dir.uri),
        )
        val projection = mutableListOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        if (includeLastModified) projection.add(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        val cursor = try {
            contentResolver.query(childrenUri, projection.toTypedArray(), null, null, null)
        } catch (_: Exception) {
            // A few older providers reject the richer projection; retry with IDs.
            contentResolver.query(
                childrenUri,
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                null,
                null,
                null,
            )
        } ?: throw IOException("SAF provider returned no cursor for ${dir.uri}")
        return cursor.use {
            // Network DocumentsProviders may return cached/partial rows while
            // fetching a directory. Never commit that as an empty/full scan.
            if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false)) {
                throw SafProviderLoadingException(dir.uri)
            }
            val documentIdIndex = it.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            )
            val displayNameIndex = it.getColumnIndex(
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            )
            val mimeTypeIndex = it.getColumnIndex(
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            )
            val lastModifiedIndex = it.getColumnIndex(
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            )
            buildList {
                while (it.moveToNext()) {
                    val childUri = DocumentsContract.buildDocumentUriUsingTree(
                        dir.uri,
                        it.getString(documentIdIndex),
                    )
                    val child = DocumentFile.fromTreeUri(this@querySafChildrenOrThrow, childUri)
                        ?: throw IOException("Invalid SAF child URI: $childUri")
                    val name = if (displayNameIndex >= 0 && !it.isNull(displayNameIndex)) {
                        it.getString(displayNameIndex)
                    } else {
                        try { child.name } catch (_: Exception) { null }
                    }
                    val mimeType = if (mimeTypeIndex >= 0 && !it.isNull(mimeTypeIndex)) {
                        it.getString(mimeTypeIndex)
                    } else {
                        null
                    }
                    val isDirectory = if (mimeType != null) {
                        mimeType == MIME_TYPE_DIR
                    } else {
                        try { child.isDirectory } catch (_: Exception) { false }
                    }
                    val isFile = if (mimeType != null) {
                        mimeType.isNotEmpty() && !isDirectory
                    } else {
                        !isDirectory && try { child.isFile } catch (_: Exception) { false }
                    }
                    val lastModified = if (!includeLastModified) {
                        0L
                    } else if (
                        lastModifiedIndex >= 0 && !it.isNull(lastModifiedIndex)
                    ) {
                        it.getLong(lastModifiedIndex)
                    } else {
                        try { child.lastModified() } catch (_: Exception) { 0L }
                    }
                    add(SafChildEntry(child, name, isDirectory, lastModified, isFile))
                }
            }
        }
    }

internal fun Context.resolveReadableSafTreeOrThrow(
        treeUriStr: String,
    ): Triple<Uri, DocumentFile, List<SafChildEntry>> {
        if (treeUriStr.isBlank()) {
            throw IllegalArgumentException("SAF tree URI is empty")
        }
        val treeUri = Uri.parse(treeUriStr)
        val root = DocumentFile.fromTreeUri(this, treeUri)
            ?: throw IOException("Unable to resolve SAF tree")
        val hasReadPermission = contentResolver.persistedUriPermissions.any {
            it.uri == treeUri && it.isReadPermission
        } || checkUriPermission(
            root.uri,
            android.os.Process.myPid(),
            android.os.Process.myUid(),
            Intent.FLAG_GRANT_READ_URI_PERMISSION,
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasReadPermission) {
            throw SecurityException("Read access to the SAF tree has been revoked")
        }
        // canRead() also requires a non-empty MIME type from queryDocument.
        // Remote providers can omit that metadata after reconnecting even
        // though queryChildDocuments can read the folder. The real listing is
        // authoritative; reuse it in the scan instead of another round trip.
        for (attempt in 0..2) {
            val children = listSafChildrenOrThrow(root)
            if (children.isNotEmpty() || root.exists()) {
                return Triple(treeUri, root, children)
            }
            // An empty listing without a confirmed root is inconclusive,
            // never evidence that previously indexed songs were deleted.
            if (attempt < 2) Thread.sleep(300L * (attempt + 1))
        }
        throw IOException("SAF provider could not confirm the library folder; reconnect it and retry")
    }
