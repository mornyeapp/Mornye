package com.zarz.mornye

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.net.Uri
import android.util.Log
import java.io.File
import java.util.Locale

/** Background-safe history writes independent of audio finalization state. */
internal object NativeHistoryStore {
    private const val TAG = "NativeFinalizer"
    // Keep this schema contract in sync with Dart HistoryDatabase before bumping either side.
    const val HISTORY_SCHEMA_VERSION = 18

    // One guarded native writer prevents interleaved transactions. Flutter/sqflite
    // uses its own WAL connection, so configure the busy timeout once per connection.
    private val historyDatabaseLock = Any()
    private var historyDatabase: SQLiteDatabase? = null
    private var historyDatabasePath = ""
    private var historyDatabaseSchemaVersion = 0

    private val historyColumns = linkedMapOf(
        "id" to "TEXT PRIMARY KEY",
        "track_name" to "TEXT NOT NULL",
        "artist_name" to "TEXT NOT NULL",
        "album_name" to "TEXT NOT NULL",
        "album_artist" to "TEXT",
        "cover_url" to "TEXT",
        "file_path" to "TEXT NOT NULL",
        "origin_file_path" to "TEXT",
        "storage_mode" to "TEXT",
        "download_tree_uri" to "TEXT",
        "saf_relative_dir" to "TEXT",
        "saf_file_name" to "TEXT",
        "saf_repaired" to "INTEGER",
        "service" to "TEXT NOT NULL",
        "downloaded_at" to "TEXT NOT NULL",
        "isrc" to "TEXT",
        "spotify_id" to "TEXT",
        "track_number" to "INTEGER",
        "total_tracks" to "INTEGER",
        "disc_number" to "INTEGER",
        "total_discs" to "INTEGER",
        "duration" to "INTEGER",
        "release_date" to "TEXT",
        "quality" to "TEXT",
        "bit_depth" to "INTEGER",
        "sample_rate" to "INTEGER",
        "bitrate" to "INTEGER",
        "format" to "TEXT",
        "genre" to "TEXT",
        "composer" to "TEXT",
        "label" to "TEXT",
        "copyright" to "TEXT",
        "explicit" to "INTEGER NOT NULL DEFAULT 0",
        "has_lyrics" to "INTEGER NOT NULL DEFAULT 0",
        "lyrics_metadata_scan_version" to "INTEGER NOT NULL DEFAULT 0",
        "has_replaygain" to "INTEGER NOT NULL DEFAULT 0",
        "replaygain_metadata_scan_version" to "INTEGER NOT NULL DEFAULT 0",
        "spotify_id_norm" to "TEXT",
        "isrc_norm" to "TEXT",
        "match_key" to "TEXT",
        "album_key" to "TEXT",
        "search_text" to "TEXT",
        "sort_track" to "TEXT",
        "sort_artist" to "TEXT",
        "sort_album" to "TEXT",
        "sort_album_artist" to "TEXT",
        "sort_genre" to "TEXT",
        "sort_release" to "TEXT",
        "sort_added" to "INTEGER",
    )
    private val migratedHistoryColumns = listOf(
        "storage_mode", "download_tree_uri", "saf_relative_dir", "saf_file_name", "saf_repaired",
        "composer", "total_tracks", "total_discs", "bitrate", "format", "spotify_id_norm",
        "isrc_norm", "match_key", "album_key", "search_text", "sort_track", "sort_artist",
        "sort_album", "sort_album_artist", "sort_genre", "sort_release", "sort_added",
        "explicit", "has_lyrics", "lyrics_metadata_scan_version", "has_replaygain",
        "replaygain_metadata_scan_version",
        "origin_file_path",
    )
    private val unusedHistoryIndexes = listOf(
        "idx_downloaded_at", "idx_album", "idx_history_track_artist",
    )
    private val androidStoragePathAliases = listOf(
        "/storage/emulated/0",
        "/storage/emulated/legacy",
        "/storage/self/primary",
        "/sdcard",
        "/mnt/sdcard",
    )
    private val audioExtensions = listOf(
        ".flac", ".m4a", ".mp3", ".opus", ".ogg", ".wav", ".aac", ".mp4",
    )

    /** Adds lookup columns to [values] and writes the row and path keys in one transaction. */
    fun upsert(context: Context, values: ContentValues, deduplicateTrack: Boolean = true) {
        putNormalizedHistoryColumns(values)
        withHistoryDatabase(context) { db ->
            val initializeSchema = historyDatabaseSchemaVersion != HISTORY_SCHEMA_VERSION
            db.beginTransaction()
            try {
                if (initializeSchema) {
                    if (db.version > HISTORY_SCHEMA_VERSION) {
                        throw IllegalStateException(
                            "history schema v${db.version} is newer than native finalizer contract v$HISTORY_SCHEMA_VERSION"
                        )
                    }
                    // Only older schemas need metadata backfills. v15 adds
                    // tree-independent document identities to the path index.
                    val needsBackfill = db.version < 13
                    val needsPathBackfill = db.version < 15
                    val definitions = historyColumns.entries.joinToString(", ") { (name, type) ->
                        "$name $type"
                    }
                    db.execSQL("CREATE TABLE IF NOT EXISTS history ($definitions)")
                    for (column in migratedHistoryColumns) ensureHistoryColumn(db, column)
                    ensureHistoryPathKeyTable(db)
                    if (needsBackfill) backfillNormalizedHistoryColumns(db)
                    if (needsPathBackfill) backfillHistoryPathKeys(db)
                    validateHistorySchema(db)
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_spotify_id ON history(spotify_id)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_isrc ON history(isrc)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_history_origin ON history(origin_file_path)")
                    // v16 dropped these unused indexes; an older writer may have recreated them.
                    for (index in unusedHistoryIndexes) db.execSQL("DROP INDEX IF EXISTS $index")
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_history_spotify_id_norm ON history(spotify_id_norm)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_history_isrc_norm ON history(isrc_norm)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_history_match_key ON history(match_key)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_history_album_key ON history(album_key)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_history_queue_added ON history(sort_added DESC, sort_track, id)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_history_queue_track ON history(sort_track, sort_artist, id)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_history_queue_artist ON history(sort_artist, sort_track, id)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_history_queue_album ON history(sort_album, sort_track, id)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_history_queue_genre ON history(sort_genre, sort_track, id)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_history_queue_release ON history(sort_release, sort_track, id)")
                    db.execSQL("CREATE INDEX IF NOT EXISTS idx_history_sort_album_artist ON history(sort_album_artist)")
                    if (db.version < HISTORY_SCHEMA_VERSION) db.version = HISTORY_SCHEMA_VERSION
                }
                if (deduplicateTrack) deleteDuplicateHistoryRows(db, values)
                db.insertWithOnConflict("history", null, values, SQLiteDatabase.CONFLICT_REPLACE)
                replaceHistoryPathKeys(db, values.getAsString("id"), values.getAsString("file_path"))
                db.setTransactionSuccessful()
            } finally {
                db.endTransaction()
            }
            if (initializeSchema) historyDatabaseSchemaVersion = HISTORY_SCHEMA_VERSION
        }
    }

    private inline fun <T> withHistoryDatabase(context: Context, block: (SQLiteDatabase) -> T): T {
        synchronized(historyDatabaseLock) {
            val dbFile = File(File(context.applicationInfo.dataDir, "app_flutter"), "history.db")
            dbFile.parentFile?.mkdirs()
            val db = historyDatabase?.takeIf {
                it.isOpen && historyDatabasePath == dbFile.absolutePath
            } ?: run {
                historyDatabase?.close()
                val opened = SQLiteDatabase.openDatabase(
                    dbFile.absolutePath,
                    null,
                    SQLiteDatabase.OPEN_READWRITE or
                        SQLiteDatabase.CREATE_IF_NECESSARY or
                        SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING,
                )
                try {
                    configureHistoryDatabase(opened)
                } catch (e: Exception) {
                    opened.close()
                    throw e
                }
                historyDatabase = opened
                historyDatabasePath = dbFile.absolutePath
                historyDatabaseSchemaVersion = 0
                opened
            }
            return block(db)
        }
    }

    private fun configureHistoryDatabase(db: SQLiteDatabase) {
        runHistoryPragma(db, "PRAGMA busy_timeout = 5000")
        // CONFLICT_REPLACE must fire the history delete trigger so the
        // external-content FTS index does not retain the replaced rowid.
        runHistoryPragma(db, "PRAGMA recursive_triggers = ON")
        runHistoryPragma(db, "PRAGMA synchronous = NORMAL")
        runHistoryPragma(db, "PRAGMA journal_mode = WAL")
    }

    private fun runHistoryPragma(db: SQLiteDatabase, sql: String) {
        try {
            db.rawQuery(sql, null).use { cursor ->
                while (cursor.moveToNext()) {
                    // PRAGMA setters may return a row; consume it before closing the cursor.
                }
            }
        } catch (e: SQLiteException) {
            Log.w(TAG, "Unable to apply history database setting: $sql", e)
        }
    }

    private fun validateHistorySchema(db: SQLiteDatabase) {
        val columns = mutableSetOf<String>()
        db.rawQuery("PRAGMA table_info(history)", null).use { cursor ->
            val nameIndex = cursor.getColumnIndex("name")
            while (cursor.moveToNext()) {
                if (nameIndex >= 0) columns.add(cursor.getString(nameIndex).lowercase(Locale.ROOT))
            }
        }
        val missing = historyColumns.keys.filterNot { columns.contains(it) }
        if (missing.isNotEmpty()) {
            throw IllegalStateException("history schema missing columns for native finalizer: ${missing.joinToString()}")
        }
    }

    private fun deleteDuplicateHistoryRows(db: SQLiteDatabase, values: ContentValues) {
        val id = values.getAsString("id") ?: return
        val duplicateIds = linkedSetOf<String>()
        val spotifyId = values.getAsString("spotify_id")?.trim().orEmpty()
        val spotifyIdNorm = values.getAsString("spotify_id_norm")?.trim().orEmpty()
        if (spotifyId.isNotEmpty() || spotifyIdNorm.isNotEmpty()) {
            duplicateIds.addAll(
                historyIdsForWhere(
                    db,
                    "(spotify_id = ? OR spotify_id_norm = ?) AND id <> ?",
                    arrayOf(spotifyId, spotifyIdNorm, id),
                )
            )
        }

        val isrc = values.getAsString("isrc")?.trim().orEmpty()
        val isrcNorm = values.getAsString("isrc_norm")?.trim().orEmpty()
        if (isrc.isNotEmpty() || isrcNorm.isNotEmpty()) {
            duplicateIds.addAll(
                historyIdsForWhere(
                    db,
                    "(isrc = ? OR isrc_norm = ?) AND id <> ?",
                    arrayOf(isrc, isrcNorm, id),
                )
            )
        }

        if (spotifyIdNorm.isEmpty() && isrcNorm.isEmpty()) {
            val matchKey = values.getAsString("match_key")?.trim().orEmpty()
            if (matchKey.isNotEmpty()) {
                duplicateIds.addAll(
                    historyIdsForWhere(db, "match_key = ? AND id <> ?", arrayOf(matchKey, id))
                )
            }
        }
        if (duplicateIds.isEmpty()) return
        deleteHistoryPathKeys(db, duplicateIds)
        val placeholders = duplicateIds.joinToString(",") { "?" }
        db.delete("history", "id IN ($placeholders)", duplicateIds.toTypedArray())
    }

    private fun historyIdsForWhere(db: SQLiteDatabase, where: String, args: Array<String>): List<String> {
        val ids = mutableListOf<String>()
        db.query("history", arrayOf("id"), where, args, null, null, null).use { cursor ->
            val idIndex = cursor.getColumnIndex("id")
            while (cursor.moveToNext()) {
                if (idIndex >= 0) ids.add(cursor.getString(idIndex))
            }
        }
        return ids
    }

    private fun deleteHistoryPathKeys(db: SQLiteDatabase, ids: Collection<String>) {
        if (ids.isEmpty()) return
        val placeholders = ids.joinToString(",") { "?" }
        db.delete("history_path_keys", "item_id IN ($placeholders)", ids.toTypedArray())
    }

    private fun ensureHistoryPathKeyTable(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS history_path_keys (
              item_id TEXT NOT NULL,
              path_key TEXT NOT NULL,
              PRIMARY KEY (item_id, path_key)
            )
            """.trimIndent()
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS idx_history_path_keys_key ON history_path_keys(path_key)")
    }

    private fun backfillNormalizedHistoryColumns(db: SQLiteDatabase) {
        db.query(
            "history",
            arrayOf("id", "spotify_id", "isrc", "track_name", "artist_name", "album_name", "album_artist", "genre", "release_date", "downloaded_at"),
            "spotify_id_norm IS NULL OR isrc_norm IS NULL OR match_key IS NULL OR album_key IS NULL OR search_text IS NULL OR sort_track IS NULL OR sort_release IS NULL OR sort_added IS NULL",
            null,
            null,
            null,
            null,
        ).use { cursor ->
            val idIndex = cursor.getColumnIndex("id")
            val spotifyIndex = cursor.getColumnIndex("spotify_id")
            val isrcIndex = cursor.getColumnIndex("isrc")
            val trackIndex = cursor.getColumnIndex("track_name")
            val artistIndex = cursor.getColumnIndex("artist_name")
            val albumIndex = cursor.getColumnIndex("album_name")
            val albumArtistIndex = cursor.getColumnIndex("album_artist")
            val genreIndex = cursor.getColumnIndex("genre")
            val releaseDateIndex = cursor.getColumnIndex("release_date")
            val downloadedAtIndex = cursor.getColumnIndex("downloaded_at")
            while (cursor.moveToNext()) {
                if (idIndex < 0) continue
                val values = ContentValues()
                val spotifyId = cursor.getNullableString(spotifyIndex)
                val isrc = cursor.getNullableString(isrcIndex)
                val trackName = cursor.getNullableString(trackIndex)
                val artistName = cursor.getNullableString(artistIndex)
                val albumName = cursor.getNullableString(albumIndex)
                val albumArtist = cursor.getNullableString(albumArtistIndex)
                values.put("spotify_id_norm", normalizeLookupText(spotifyId))
                values.put("isrc_norm", normalizeIsrc(isrc))
                values.put("match_key", matchKeyFor(trackName, artistName))
                putAlbumSearchHistoryColumns(values, trackName, artistName, albumName, albumArtist)
                putQueueSortHistoryColumns(
                    values,
                    trackName = trackName,
                    artistName = artistName,
                    albumName = albumName,
                    albumArtist = albumArtist,
                    genre = cursor.getNullableString(genreIndex),
                    releaseDate = cursor.getNullableString(releaseDateIndex),
                    downloadedAt = cursor.getNullableString(downloadedAtIndex),
                )
                db.update("history", values, "id = ?", arrayOf(cursor.getString(idIndex)))
            }
        }
    }

    private fun backfillHistoryPathKeys(db: SQLiteDatabase) {
        db.query("history", arrayOf("id", "file_path"), null, null, null, null, null).use { cursor ->
            val idIndex = cursor.getColumnIndex("id")
            val pathIndex = cursor.getColumnIndex("file_path")
            while (cursor.moveToNext()) {
                if (idIndex >= 0) {
                    replaceHistoryPathKeys(db, cursor.getString(idIndex), cursor.getNullableString(pathIndex))
                }
            }
        }
    }

    private fun replaceHistoryPathKeys(db: SQLiteDatabase, itemId: String?, filePath: String?) {
        val id = itemId?.trim().orEmpty()
        if (id.isEmpty()) return
        db.delete("history_path_keys", "item_id = ?", arrayOf(id))
        for (key in buildPathMatchKeys(filePath)) {
            val values = ContentValues()
            values.put("item_id", id)
            values.put("path_key", key)
            db.insertWithOnConflict("history_path_keys", null, values, SQLiteDatabase.CONFLICT_IGNORE)
        }
    }

    private fun putNormalizedHistoryColumns(values: ContentValues) {
        values.put("spotify_id_norm", normalizeLookupText(values.getAsString("spotify_id")))
        values.put("isrc_norm", normalizeIsrc(values.getAsString("isrc")))
        values.put(
            "match_key",
            matchKeyFor(values.getAsString("track_name"), values.getAsString("artist_name")),
        )
        putAlbumSearchHistoryColumns(
            values,
            trackName = values.getAsString("track_name"),
            artistName = values.getAsString("artist_name"),
            albumName = values.getAsString("album_name"),
            albumArtist = values.getAsString("album_artist"),
        )
        putQueueSortHistoryColumns(
            values,
            trackName = values.getAsString("track_name"),
            artistName = values.getAsString("artist_name"),
            albumName = values.getAsString("album_name"),
            albumArtist = values.getAsString("album_artist"),
            genre = values.getAsString("genre"),
            releaseDate = values.getAsString("release_date"),
            downloadedAt = values.getAsString("downloaded_at"),
        )
    }

    private fun putQueueSortHistoryColumns(
        values: ContentValues,
        trackName: String?,
        artistName: String?,
        albumName: String?,
        albumArtist: String?,
        genre: String?,
        releaseDate: String?,
        downloadedAt: String?,
    ) {
        values.put("sort_track", normalizeLookupText(trackName))
        values.put("sort_artist", normalizeLookupText(artistName))
        values.put("sort_album", normalizeLookupText(albumName))
        values.put(
            "sort_album_artist",
            normalizeLookupText(albumArtist?.takeIf { it.trim().isNotEmpty() } ?: artistName),
        )
        values.put("sort_genre", normalizeLookupText(genre))
        values.put("sort_release", releaseDate?.trim().orEmpty())
        values.put("sort_added", parseHistoryTimestampMillis(downloadedAt))
    }

    private fun parseHistoryTimestampMillis(value: String?): Long {
        val timestamp = value?.trim().orEmpty()
        if (timestamp.isEmpty()) return 0L
        return try {
            java.time.Instant.parse(timestamp).toEpochMilli()
        } catch (_: Exception) {
            try {
                java.time.OffsetDateTime.parse(timestamp).toInstant().toEpochMilli()
            } catch (_: Exception) {
                try {
                    java.time.LocalDateTime.parse(timestamp)
                        .atZone(java.time.ZoneId.systemDefault())
                        .toInstant()
                        .toEpochMilli()
                } catch (_: Exception) {
                    0L
                }
            }
        }
    }

    private fun putAlbumSearchHistoryColumns(
        values: ContentValues,
        trackName: String?,
        artistName: String?,
        albumName: String?,
        albumArtist: String?,
    ) {
        val track = normalizeLookupText(trackName)
        val artist = normalizeLookupText(artistName)
        val album = normalizeLookupText(albumName)
        val resolvedAlbumArtist = normalizeLookupText(
            albumArtist?.takeIf { it.trim().isNotEmpty() } ?: artistName,
        )
        values.put("album_key", "$album|$resolvedAlbumArtist")
        values.put(
            "search_text",
            listOf(track, artist, album, resolvedAlbumArtist)
                .filter { it.isNotEmpty() }
                .joinToString(" "),
        )
    }

    private fun cleanMetadataString(value: String?): String {
        val trimmed = value?.trim().orEmpty()
        return if (trimmed.equals("null", ignoreCase = true)) "" else trimmed
    }

    private fun normalizeLookupText(value: String?): String =
        cleanMetadataString(value).lowercase(Locale.ROOT)

    private fun normalizeIsrc(value: String?): String =
        cleanMetadataString(value)
            .uppercase(Locale.ROOT)
            .replace(Regex("[-\\s]"), "")

    private fun matchKeyFor(trackName: String?, artistName: String?): String {
        val track = normalizeLookupText(trackName)
        if (track.isEmpty()) return ""
        return "$track|${normalizeLookupText(artistName)}"
    }

    private fun buildPathMatchKeys(filePath: String?): Set<String> {
        val raw = filePath?.trim().orEmpty()
        if (raw.isEmpty()) return emptySet()
        val cleaned = if (raw.startsWith("EXISTS:")) raw.substring(7).trim() else raw
        if (cleaned.isEmpty()) return emptySet()

        val keys = linkedSetOf<String>()
        val visited = linkedSetOf<String>()
        // Parse the original URI once; repeated percent decoding changes
        // opaque provider IDs containing literal percent escapes.
        try {
            val uri = Uri.parse(cleaned)
            safDocumentMatchKey(uri.scheme, uri.authority, uri.pathSegments)?.let(keys::add)
        } catch (_: IllegalArgumentException) {
        }

        fun addNormalized(value: String) {
            val trimmed = value.trim()
            if (trimmed.isEmpty()) return
            if (!visited.add(trimmed)) return
            keys.add(trimmed)
            keys.add(trimmed.lowercase(Locale.ROOT))
            if (trimmed.contains('\\')) {
                val slash = trimmed.replace('\\', '/')
                if (slash != trimmed) addNormalized(slash)
            }
            if (trimmed.contains('%')) {
                try {
                    val decoded = Uri.decode(trimmed)
                    if (decoded != trimmed) addNormalized(decoded)
                } catch (_: Throwable) {
                }
            }
            val parsed = try {
                Uri.parse(trimmed)
            } catch (_: Throwable) {
                null
            }
            if (parsed != null && !parsed.scheme.isNullOrEmpty()) {
                val stripped = stripUriQueryAndFragment(trimmed)
                keys.add(stripped)
                keys.add(stripped.lowercase(Locale.ROOT))
                if (parsed.scheme.equals("file", ignoreCase = true)) {
                    parsed.path?.let { addNormalized(it) }
                }
                for (alias in androidExternalStorageDocumentPaths(parsed)) addNormalized(alias)
            } else if (trimmed.startsWith("/")) {
                try {
                    val asFileUri = Uri.fromFile(File(trimmed)).toString()
                    keys.add(asFileUri)
                    keys.add(asFileUri.lowercase(Locale.ROOT))
                } catch (_: Throwable) {
                }
            }
            for (alias in androidEquivalentPaths(trimmed)) {
                if (alias != trimmed) addNormalized(alias)
            }
        }

        addNormalized(cleaned)
        val extensionStripped = linkedSetOf<String>()
        for (key in keys) {
            stripAudioExtension(key)?.let {
                if (it.isNotEmpty()) extensionStripped.add(it)
            }
        }
        keys.addAll(extensionStripped)
        return keys
    }

    private fun androidExternalStorageDocumentPaths(uri: Uri): List<String> {
        if (
            !uri.scheme.equals("content", ignoreCase = true) ||
            !uri.authority.equals("com.android.externalstorage.documents", ignoreCase = true)
        ) {
            return emptyList()
        }
        val segments = uri.pathSegments
        val documentIndex = segments.indexOfLast { it == "document" }
        val treeIndex = segments.indexOfLast { it == "tree" }
        val idIndex = if (documentIndex >= 0) documentIndex + 1 else treeIndex + 1
        if (idIndex <= 0 || idIndex >= segments.size) return emptyList()
        val documentId = segments.subList(idIndex, segments.size).joinToString("/")
        val separator = documentId.indexOf(':')
        if (separator < 0 || !documentId.substring(0, separator).equals("primary", ignoreCase = true)) {
            return emptyList()
        }
        val relativePath = documentId.substring(separator + 1).replace('\\', '/').trimStart('/')
        val suffix = if (relativePath.isEmpty()) "" else "/$relativePath"
        return androidStoragePathAliases.map { "$it$suffix" }
    }

    private fun stripUriQueryAndFragment(value: String): String {
        val queryIndex = value.indexOf('?').let { if (it >= 0) it else value.length }
        val fragmentIndex = value.indexOf('#').let { if (it >= 0) it else value.length }
        return value.substring(0, minOf(queryIndex, fragmentIndex))
    }

    private fun stripAudioExtension(path: String): String? {
        val lower = path.lowercase(Locale.ROOT)
        for (ext in audioExtensions) {
            if (lower.endsWith(ext)) return path.substring(0, path.length - ext.length)
        }
        return null
    }

    private fun androidEquivalentPaths(path: String): List<String> {
        val normalized = path.replace('\\', '/')
        val lower = normalized.lowercase(Locale.ROOT)
        var suffix: String? = null
        for (prefix in androidStoragePathAliases) {
            if (lower == prefix) {
                suffix = ""
                break
            }
            if (lower.startsWith("$prefix/")) {
                suffix = normalized.substring(prefix.length)
                break
            }
        }
        val resolvedSuffix = suffix ?: return emptyList()
        return androidStoragePathAliases.map { "$it$resolvedSuffix" }
    }

    private fun Cursor.getNullableString(index: Int): String? {
        if (index < 0 || isNull(index)) return null
        return getString(index)
    }

    private fun ensureHistoryColumn(db: SQLiteDatabase, column: String) {
        db.rawQuery("PRAGMA table_info(history)", null).use { cursor ->
            val nameIndex = cursor.getColumnIndex("name")
            while (cursor.moveToNext()) {
                if (nameIndex >= 0 && cursor.getString(nameIndex).equals(column, ignoreCase = true)) return
            }
        }
        db.execSQL("ALTER TABLE history ADD COLUMN $column ${historyColumns.getValue(column)}")
    }
}
