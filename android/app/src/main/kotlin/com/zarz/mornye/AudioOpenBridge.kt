package com.zarz.mornye

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/** Imports audio grants off the UI thread, without converting SAF URIs to raw paths. */
internal object AudioOpenBridge {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var messenger: BinaryMessenger? = null
    private var channel: MethodChannel? = null
    private var ready = false
    private val pending = ArrayDeque<List<Map<String, String>>>()
    private const val CONSUMED = "com.zarz.mornye.audio_open_consumed"

    fun attach(value: BinaryMessenger) {
        if (messenger === value) return
        messenger = value
        ready = false
        channel = MethodChannel(value, "com.zarz.mornye/open_audio").also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                if (call.method == "takePending") {
                    ready = true
                    result.success(pending.toList())
                    pending.clear()
                } else {
                    result.notImplemented()
                }
            }
            bridge.invokeMethod("ready", null)
        }
    }

    @Suppress("DEPRECATION")
    fun consume(context: Context, intent: Intent) {
        if (intent.getBooleanExtra(CONSUMED, false)) {
            intent.action = null
            return
        }
        val mime = intent.type?.lowercase().orEmpty()
        if (!mime.startsWith("audio/") && mime != "application/ogg" && mime != "application/x-flac") return
        val uris = when (intent.action) {
            Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
            else -> return
        }.filter { it.scheme == "content" || it.scheme == "file" }.distinct()
        if (uris.isEmpty()) return
        // Do not let receive_sharing_intent resolve the same documents to
        // inaccessible /storage paths or copy them synchronously on the UI thread.
        intent.putExtra(CONSUMED, true)
        intent.action = null
        val app = context.applicationContext
        worker.execute {
            val files = uris.take(10000).map { uri -> importAudio(app, uri, mime) }
            main.post {
                if (ready) channel?.invokeMethod("open", files)
                else {
                    if (pending.size >= 32) pending.removeFirst()
                    pending.add(files)
                }
            }
        }
    }

    private fun importAudio(context: Context, uri: Uri, mime: String): Map<String, String> {
        val directory = File(context.cacheDir, "open_audio/${UUID.randomUUID()}")
        var name = uri.lastPathSegment?.substringAfterLast('/').orEmpty()
        try {
            if (uri.scheme == "content") {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) name = cursor.getString(0).orEmpty()
                }
            }
        } catch (_: Exception) {
            // Providers without a display-name column can still expose audio.
        }
        name = File(name).name.replace('\u0000', '_')
            .takeUnless { it.isBlank() || it == "." || it == ".." } ?: "Audio"
        if (!name.contains('.')) {
            val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
            if (extension != null) name += ".$extension"
        }
        val target = File(directory, name)
        try {
            check(directory.mkdirs()) { "Could not create audio import directory" }
            val input = context.contentResolver.openInputStream(uri)
                ?: error("The audio document is unavailable")
            input.use { source -> target.outputStream().use { source.copyTo(it) } }
        } catch (error: Exception) {
            target.delete()
            android.util.Log.w("Mornye", "Could not import audio document", error)
        }
        // Missing targets reach Flutter's normal cannot-open feedback as well.
        return mapOf("source" to target.path, "name" to name)
    }
}
