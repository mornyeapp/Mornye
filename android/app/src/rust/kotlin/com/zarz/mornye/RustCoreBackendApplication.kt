package com.zarz.mornye

import com.mornye.backend.LyricsRequest
import java.io.File
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

internal fun RustCoreBackend.dispatchApplication(method: String, arguments: Any?): Any? {
    val args = arguments as? Map<*, *> ?: emptyMap<Any, Any>()
    fun string(key: String, default: String = "") = args[key] as? String ?: default
    fun lyricsRequest(fileKey: String) = LyricsRequest(
        string("spotify_id"),
        string("track_name"),
        string("artist_name"),
        mediaPath(string(fileKey)),
        (args["duration_ms"] as? Number)?.toLong() ?: 0L,
    )
    fun ids(raw: String): List<String> {
        val values = JSONArray(raw)
        return (0 until values.length()).map { values.getString(it) }
    }
    when (method) {
        "cancelExtensionRequest" -> synchronized(this) {
            requestRegistry().cancel(string("request_id"))
            return null
        }
        "customSearchWithExtension", "getExtensionHomeFeed", "getExtensionRelatedTracks" -> {
            val (current, lease) = acquireRequest(string("request_id"))
            return lease.use {
                try {
                    when (method) {
                        "customSearchWithExtension" ->
                            current.customSearchJson(string("extension_id"), string("query"), string("options"), it)
                        "getExtensionRelatedTracks" ->
                            current.getExtensionRelatedTracksJson(string("extension_id"), string("seeds"), string("options"), it)
                        else -> current.getExtensionHomeFeedJson(string("extension_id"), it)
                    }
                } finally {
                    it.release()
                }
            }
        }
        "prepareRuntimeState" -> synchronized(this) {
            val directory = File(string("data_dir"))
            require(directory.isAbsolute) { "Extension data directory must be absolute" }
            val data = directory.canonicalPath
            check(manager == null || identity?.second == data) {
                "Runtime state directory does not match the initialized owner"
            }
            val raw = string("runtime_state")
            manager?.environment()?.use { it.setRuntimeState(raw) }
            runtimeState = data to raw
            return null
        }
        "initExtensionSystem" -> {
            initializeOwner(args)
            return null
        }
        "setDownloadDirectory" -> {
            setDownloadDirectory(string("path"))
            return null
        }
        "acquireDownloadDirectory" -> synchronized(this) {
            val scope = openDownloadDirectory(string("path"))
            val token = UUID.randomUUID().toString()
            directoryScopes[token] = scope
            return token
        }
        "releaseDownloadDirectory" -> synchronized(this) {
            directoryScopes.remove(string("token"))?.close()
            return null
        }
        "cleanupExtensions" -> {
            shutdownOwner()
            return null
        }
        "buildFilename" -> return buildFilename(string("template"), string("metadata", "{}"))
        "sanitizeFilename" -> return sanitizeFilename(string("filename"))
        "getLogsSince" -> return synchronized(this) {
            manager?.environment()?.use { environment ->
                environment.logBuffer().use { it.since((args["index"] as? Number)?.toLong() ?: 0L) }
            } ?: """{"logs":[],"next_index":0}"""
        }
        "clearLogs" -> return synchronized(this) {
            manager?.environment()?.use { environment -> environment.logBuffer().use { it.clear() } }
            null
        }
        "setLoggingEnabled", "setAllowPrivateNetwork", "setDownloadFallbackExtensionIds",
        "setNetworkCompatibilityOptions",
        "setLyricsProviders", "setLyricsFetchOptions" -> synchronized(this) {
            when (method) {
                "setLoggingEnabled" -> {
                    val enabled = args["enabled"] as? Boolean ?: false
                    manager?.environment()?.use { environment ->
                        environment.logBuffer().use { it.setEnabled(enabled) }
                    }
                    loggingEnabled = enabled
                }
                "setAllowPrivateNetwork" -> {
                    val allowed = args["allowed"] as? Boolean ?: false
                    manager?.environment()?.use { it.setAllowPrivateNetwork(allowed) }
                    allowPrivateNetwork = allowed
                }
                "setNetworkCompatibilityOptions" -> {
                    val allowed = args["allow_http"] as? Boolean ?: false
                    val insecureTls = args["insecure_tls"] as? Boolean ?: false
                    manager?.environment()?.use { it.setNetworkCompatibilityOptions(allowed, insecureTls) }
                    allowHttpFallback = allowed
                }
                "setDownloadFallbackExtensionIds" -> {
                    val raw = string("extension_ids")
                    val value = if (raw.isBlank() || raw.trim() == "null") null else ids(raw)
                    manager?.setFallbackProviders(value)
                    fallbackProviders = value
                }
                "setLyricsProviders" -> {
                    val raw = string("providers_json", "[]")
                    if (manager != null) manager!!.setLyricsProvidersJson(raw) else ids(raw)
                    return """{"success":true}"""
                }
                "setLyricsFetchOptions" -> {
                    val raw = string("options_json", "{}")
                    if (manager != null) manager!!.setLyricsFetchOptionsJson(raw) else JSONObject(raw)
                    return """{"success":true}"""
                }
            }
            return null
        }
        "initExtensionRepo" -> {
            initializeRepository(string("cache_dir"))
            return null
        }
        "setRepoRegistryUrl" -> {
            repositoryOwner().setRegistryUrl(string("registry_url"))
            return null
        }
        "getRepoRegistryUrl" -> return repositoryOwner().registryUrl()
        "clearRepoRegistryUrl" -> {
            repositoryOwner().clearRegistryUrl()
            return null
        }
        "getRepoExtensions" -> return repositoryOwner().extensions(
            args["force_refresh"] as? Boolean ?: false,
        )
        "downloadRepoExtension" -> return repositoryOwner().download(
            string("extension_id"),
            string("dest_dir"),
        )
    }
    val current = owner()
    return when (method) {
        "loadExtensionsFromDir" -> {
            synchronized(this) {
                check(File(string("dir_path")).canonicalPath == identity?.first) { "Extension source directory does not match the initialized owner" }
            }
            current.loadAll()
        }
        "loadExtensionFromPath" -> current.install(string("file_path"))
        "upgradeExtension" -> current.upgrade(string("file_path"))
        "checkExtensionUpgrade" -> current.checkUpgrade(string("file_path"))
        "getInstalledExtensions" -> current.installed()
        "setExtensionEnabled" -> {
            current.setEnabled(string("extension_id"), args["enabled"] as? Boolean ?: false)
            null
        }
        "removeExtension" -> {
            current.remove(string("extension_id"))
            null
        }
        "getExtensionSettings" -> current.environment().use { it.settings(string("extension_id")) }
        "setExtensionSettings" -> {
            current.updateSettings(string("extension_id"), string("settings", "{}"))
            null
        }
        "invokeExtensionAction" -> if (args.containsKey("arguments_json")) {
            // Transient form input bypasses persistent extension settings.
            current.call(string("extension_id"), string("action"), string("arguments_json", "[]"), null, 120_000uL)
        } else current.invokeAction(string("extension_id"), string("action"))
        "checkExtensionHealth" -> current.checkExtensionHealthJson(string("extension_id"))
        "setProviderPriority", "setMetadataProviderPriority" -> {
            current.setProviderPriority(if (method == "setProviderPriority") "download" else "metadata", ids(string("priority", "[]")))
            null
        }
        "getProviderPriority", "getMetadataProviderPriority" -> {
            JSONObject(current.providerPriorities()).optJSONArray(if (method == "getProviderPriority") "download" else "metadata")?.toString() ?: "[]"
        }
        "searchTracksWithMetadataProviders" -> current.searchMetadataProviders(
            string("query"),
            (args["limit"] as? Number)?.toLong() ?: 20L,
            args["include_extensions"] as? Boolean ?: true,
            "",
            30_000uL,
        )
        "searchTracksWithMetadataProvider" -> current.searchMetadataProvider(
            string("extension_id"),
            string("query"),
            (args["limit"] as? Number)?.toLong() ?: 20L,
            30_000uL,
        )
        "getProviderMetadata" -> current.getProviderMetadataJson(
            string("provider_id"),
            string("resource_type"),
            string("resource_id"),
            null,
        )
        "searchDeezerByISRC" -> current.searchDeezerByIsrcForItemId(
            string("isrc"),
            string("item_id"),
            null,
        )
        "getDeezerExtendedMetadata" -> current.getDeezerExtendedMetadata(
            string("track_id"),
            null,
        )
        "convertSpotifyToDeezer" -> current.convertSpotifyToDeezer(
            string("resource_type"),
            string("spotify_id"),
            null,
        )
        "getTrackPlatformLinks" -> current.getTrackPlatformLinksJson(
            string("spotify_id"),
            string("isrc"),
            null,
        )
        "fetchMusicBrainzTags" -> {
            val genre = try {
                current.fetchMusicBrainzGenreByIsrc(string("isrc"), null)
            } catch (_: Exception) {
                ""
            }
            val albumArtist = try {
                current.fetchMusicBrainzAlbumArtistByIsrc(
                    string("isrc"),
                    string("album_name"),
                    null,
                )
            } catch (_: Exception) {
                ""
            }
            JSONObject()
                .put("genre", genre)
                .put("album_artist", albumArtist)
                .toString()
        }
        "getTrackCacheSize" -> current.getTrackCacheSize().toInt()
        "clearTrackCache" -> {
            current.clearTrackIdCache()
            null
        }
        "setMetadataLanguage" -> {
            current.setMetadataLanguage(string("tag"))
            null
        }
        "findURLHandler" -> current.findUrlHandler(string("url")) ?: ""
        "handleURLWithExtension" -> current.handleUrlJson(string("url"))
        "getExtensionPendingAuth" -> current.getExtensionPendingAuthJson(string("extension_id")).ifEmpty { null }
        "getLyricsFromProvider" -> current.getLyricsFromProvider(
            string("provider"),
            LyricsRequest(
                string("spotify_id"),
                string("track_name"),
                string("artist_name"),
                "",
                (args["duration_ms"] as? Number)?.toLong() ?: 0L,
            ),
            null,
        )
        "getEnabledLyricsProviders" -> current.getEnabledLyricsProvidersJson()
        "completeExtensionSessionGrant" -> {
            completeSessionGrant(current, string("extension_id"), string("grant"))
            true
        }
        "getAllDownloadProgress" -> current.withDownloadState { state -> state.allProgress() }
        "cleanupConnections" -> current.environment().use { it.cleanupConnections(); null }
        "resetDownloadCancels", "cancelDownloads" -> {
            val values = args["item_ids"] as? List<*> ?: error("Expected item_ids list")
            val itemIds = values.map { it as? String ?: error("Expected string item ID") }
            current.withDownloadState { state ->
                if (method == "cancelDownloads") state.cancelDownloads(itemIds)
                else state.resetDownloadCancels(itemIds)
            }
            null
        }
        "clearItemProgress", "cancelDownload", "resetDownloadCancel" -> current.withDownloadState { state ->
            when (method) {
                "clearItemProgress" -> state.clearItemProgress(string("item_id"))
                "cancelDownload" -> state.cancelDownload(string("item_id"))
                else -> state.resetDownloadCancel(string("item_id"))
            }
            null
        }
        "getLyricsLRC", "getLyricsLRCWithSource" -> withMediaFiles(listOf(string("file_path"))) {
            val request = lyricsRequest("file_path")
            if (method == "getLyricsLRC") it.getLyricsLrc(request, null)
            else it.getLyricsLrcWithSource(request, null)
        }
        "embedLyricsToFile" -> withMediaFiles(listOf(string("file_path"))) {
            it.embedLyricsToFile(mediaPath(string("file_path")), string("lyrics"), null)
        }
        "fetchAndSaveLyrics" -> try {
            withMediaFiles(listOf(string("audio_file_path"), string("output_path"))) {
                it.fetchAndSaveLyrics(lyricsRequest("audio_file_path"), mediaPath(string("output_path")), null)
                """{"success":true}"""
            }
        } catch (error: Exception) {
            JSONObject().put("success", false).put("error", error.message ?: "Lyrics operation failed").toString()
        }
        "findCollectionAcrossExtensions" -> current.findCollectionAcrossExtensionsJson(
            arguments as? String ?: "{}",
            null,
        )
        else -> error("Rust application method is not connected yet: $method")
    }
}
