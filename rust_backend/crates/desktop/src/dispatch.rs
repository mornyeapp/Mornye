//! The desktop method table: the one place that lists every MethodChannel
//! method desktop implements. Anything not listed answers `unimplemented`.
//!
//! Ported from the mobile hosts with the same argument names and result
//! shapes (iOS wins where the hosts differ, because desktop follows the iOS
//! model):
//! - class (a) forwards: `ios/Runner/CoreBackend.swift` `invokeApplication`
//!   and Android `RustCoreBackendApplication.kt` `dispatchApplication`;
//! - Rust calls the hosts wrap for OS reasons: the `osMethods` of
//!   `ios/Runner/AppDelegate.swift` `handleMethodCall`, with plain paths;
//! - the Android extension callback inbox, fed by a desktop-only method.

use crate::backend::{CallbackRoute, complete_session_grant};
use crate::call::{Args, CallError, CallResult, CallState, OrFail, Reply};
use crate::ffmpeg::with_ffmpeg_commands;
use crate::paths::{self, media_path};
use crate::runtime::{self, Runtime};
use mornye_mobile::{ExtensionManager, LyricsRequest, RequestLease};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

/// What a handler sees of its call.
pub(crate) struct Ctx<'a> {
    rt: &'static Runtime,
    state: &'a CallState,
    /// Lets one handler serve several methods, like the hosts' `case a, b:`.
    method: &'static str,
}

impl Ctx<'_> {
    fn owner(&self) -> Result<Arc<ExtensionManager>, CallError> {
        self.rt.backend.owner()
    }

    /// Best-effort `mornye_cancel` support for this call.
    fn on_cancel(&self, hook: impl FnOnce(&'static Runtime) + Send + 'static) {
        let rt = self.rt;
        self.state.on_cancel(move || hook(rt));
    }
}

type Handler = fn(&Ctx<'_>, &Args) -> CallResult;

pub(crate) struct Entry {
    pub(crate) name: &'static str,
    /// Runs on the calling thread, before later calls are queued (iOS runs
    /// `cancelNativeDataJob` synchronously on the main thread).
    pub(crate) inline: bool,
    handler: Handler,
}

const fn pool(name: &'static str, handler: Handler) -> Entry {
    Entry {
        name,
        inline: false,
        handler,
    }
}

const fn inline(name: &'static str, handler: Handler) -> Entry {
    Entry {
        name,
        inline: true,
        handler,
    }
}

fn null(result: Result<(), CallError>) -> CallResult {
    result.map(|()| Reply::null())
}

fn text<E: std::fmt::Display>(result: Result<String, E>) -> CallResult {
    result.map(Reply::from).or_fail()
}

/// `ids(_:)`: a JSON array of strings.
fn ids(raw: &str) -> Result<Vec<String>, CallError> {
    serde_json::from_str::<Vec<String>>(raw)
        .map_err(|_| CallError::failure("Expected an array of extension IDs"))
}

fn limit(args: &Args) -> i64 {
    args.i64("limit").unwrap_or(20)
}

fn priority_kind(method_is_download: bool) -> &'static str {
    if method_is_download {
        "download"
    } else {
        "metadata"
    }
}

pub(crate) static METHODS: &[Entry] = &[
    // CoreBackend.swift invokeApplication: methods that do not need the owner.
    pool("runNativeDataJob", run_native_data_job),
    inline("cancelNativeDataJob", |c, a| {
        null(c.rt.backend.cancel_data_job(&a.string("request_id", "")))
    }),
    pool("cancelExtensionRequest", |c, a| {
        null(c.rt.backend.cancel_request(&a.string("request_id", "")))
    }),
    pool("customSearchWithExtension", extension_request),
    pool("getExtensionHomeFeed", extension_request),
    pool("getExtensionRelatedTracks", extension_request),
    pool("initExtensionSystem", |c, a| {
        null(c.rt.backend.initialize_owner(a))
    }),
    pool("setDownloadDirectory", |c, a| {
        null(c.rt.backend.set_download_directory(&a.string("path", "")))
    }),
    pool("acquireDownloadDirectory", |c, a| {
        c.rt.backend
            .acquire_download_directory(&a.string("path", ""))
            .map(Reply::from)
    }),
    pool("releaseDownloadDirectory", |c, a| {
        c.rt.backend
            .release_download_directory(&a.string("token", ""));
        Ok(Reply::null())
    }),
    pool("initExtensionRepo", |c, a| {
        null(
            c.rt.backend
                .initialize_repository(&a.string("cache_dir", "")),
        )
    }),
    pool("getRepoRegistryUrl", |c, _| {
        text(c.rt.backend.repository()?.registry_url())
    }),
    pool("setRepoRegistryUrl", |c, a| {
        null(
            c.rt.backend
                .repository()?
                .set_registry_url(a.string("registry_url", ""))
                .or_fail(),
        )
    }),
    pool("clearRepoRegistryUrl", |c, _| {
        null(c.rt.backend.repository()?.clear_registry_url().or_fail())
    }),
    pool("getRepoExtensions", |c, a| {
        text(
            c.rt.backend
                .repository()?
                .extensions(a.bool("force_refresh", false)),
        )
    }),
    pool("downloadRepoExtension", |c, a| {
        text(
            c.rt.backend
                .repository()?
                .download(a.string("extension_id", ""), a.string("dest_dir", "")),
        )
    }),
    pool("cleanupExtensions", |c, _| {
        c.rt.backend.shutdown_owner();
        Ok(Reply::null())
    }),
    pool("buildFilename", |_, a| {
        text(mornye_mobile::build_filename(
            a.string("template", ""),
            a.string("metadata", "{}"),
        ))
    }),
    pool("sanitizeFilename", |_, a| {
        Ok(mornye_mobile::sanitize_filename(a.string("filename", "")).into())
    }),
    pool("readFileMetadata", |_, a| {
        text(mornye_mobile::read_file_metadata(
            a.string("file_path", ""),
            a.string("display_name", ""),
            None,
        ))
    }),
    pool("editFileMetadata", edit_file_metadata),
    pool("getLogsSince", |c, a| {
        let index = a.i64("index").unwrap_or(0);
        match c.rt.backend.manager_snapshot() {
            Some(manager) => text(manager.environment().log_buffer().since(index)),
            None => Ok(r#"{"logs":[],"next_index":0}"#.into()),
        }
    }),
    pool("clearLogs", |c, _| {
        if let Some(manager) = c.rt.backend.manager_snapshot() {
            manager.environment().log_buffer().clear().or_fail()?;
        }
        Ok(Reply::null())
    }),
    pool("setLoggingEnabled", |c, a| {
        let enabled = a.bool("enabled", false);
        null(c.rt.backend.update_settings(|settings| {
            if let Some(manager) = settings.manager {
                manager
                    .environment()
                    .log_buffer()
                    .set_enabled(enabled)
                    .or_fail()?;
            }
            *settings.logging_enabled = enabled;
            Ok(())
        }))
    }),
    pool("setAllowPrivateNetwork", |c, a| {
        let allowed = a.bool("allowed", false);
        null(c.rt.backend.update_settings(|settings| {
            if let Some(manager) = settings.manager {
                manager
                    .environment()
                    .set_allow_private_network(allowed)
                    .or_fail()?;
            }
            *settings.allow_private_network = allowed;
            Ok(())
        }))
    }),
    pool("setNetworkCompatibilityOptions", |c, a| {
        let allowed = a.bool("allow_http", false);
        let insecure_tls = a.bool("insecure_tls", false);
        null(c.rt.backend.update_settings(|settings| {
            if let Some(manager) = settings.manager {
                manager
                    .environment()
                    .set_network_compatibility_options(allowed, insecure_tls)
                    .or_fail()?;
            }
            *settings.allow_http_fallback = allowed;
            Ok(())
        }))
    }),
    pool("setDownloadFallbackExtensionIds", |c, a| {
        let raw = a.string("extension_ids", "");
        let raw = raw.trim();
        let value = if raw.is_empty() || raw == "null" {
            None
        } else {
            Some(ids(raw)?)
        };
        null(c.rt.backend.update_settings(|settings| {
            if let Some(manager) = settings.manager {
                manager.set_fallback_providers(value.clone()).or_fail()?;
            }
            *settings.fallback_providers = value;
            Ok(())
        }))
    }),
    pool("setLyricsProviders", |c, a| {
        let raw = a.string("providers_json", "[]");
        c.rt.backend
            .update_settings(|settings| match settings.manager {
                Some(manager) => manager.set_lyrics_providers_json(raw).or_fail(),
                None => ids(&raw).map(drop),
            })?;
        Ok(r#"{"success":true}"#.into())
    }),
    pool("setLyricsFetchOptions", |c, a| {
        let raw = a.string("options_json", "{}");
        c.rt.backend
            .update_settings(|settings| match settings.manager {
                Some(manager) => manager.set_lyrics_fetch_options_json(raw).or_fail(),
                None => serde_json::from_str::<Value>(&raw).map(drop).or_fail(),
            })?;
        Ok(r#"{"success":true}"#.into())
    }),
    // CoreBackend.swift invokeApplication: methods that need the owner.
    pool("loadExtensionsFromDir", |c, a| {
        let manager = c.owner()?;
        let path = paths::resolve_string(&a.string("dir_path", ""));
        if c.rt.backend.source_directory().as_deref() != Some(path.as_str()) {
            return Err(CallError::failure(
                "Extension source directory does not match the initialized owner",
            ));
        }
        text(manager.load_all())
    }),
    pool("loadExtensionFromPath", |c, a| {
        text(c.owner()?.install(a.string("file_path", "")))
    }),
    pool("upgradeExtension", |c, a| {
        text(c.owner()?.upgrade(a.string("file_path", "")))
    }),
    pool("checkExtensionUpgrade", |c, a| {
        text(c.owner()?.check_upgrade(a.string("file_path", "")))
    }),
    pool("getInstalledExtensions", |c, _| {
        text(c.owner()?.installed())
    }),
    pool("setExtensionEnabled", |c, a| {
        null(
            c.owner()?
                .set_enabled(a.string("extension_id", ""), a.bool("enabled", false))
                .or_fail(),
        )
    }),
    pool("removeExtension", |c, a| {
        null(c.owner()?.remove(a.string("extension_id", "")).or_fail())
    }),
    pool("getExtensionSettings", |c, a| {
        text(
            c.owner()?
                .environment()
                .settings(a.string("extension_id", "")),
        )
    }),
    pool("setExtensionSettings", |c, a| {
        null(
            c.owner()?
                .update_settings(a.string("extension_id", ""), a.string("settings", "{}"))
                .or_fail(),
        )
    }),
    pool("invokeExtensionAction", |c, a| {
        let manager = c.owner()?;
        let id = a.string("extension_id", "");
        let action = a.string("action", "");
        if a.has("arguments_json") {
            // Transient form input bypasses persistent extension settings.
            return text(manager.call(id, action, a.string("arguments_json", "[]"), None, 120_000));
        }
        text(manager.invoke_action(id, action))
    }),
    pool("checkExtensionHealth", |c, a| {
        text(
            c.owner()?
                .check_extension_health_json(a.string("extension_id", "")),
        )
    }),
    pool("searchTracksWithMetadataProviders", |c, a| {
        text(c.owner()?.search_metadata_providers(
            a.string("query", ""),
            limit(a),
            a.bool("include_extensions", true),
            String::new(),
            30_000,
        ))
    }),
    pool("searchTracksWithMetadataProvider", |c, a| {
        text(c.owner()?.search_metadata_provider(
            a.string("extension_id", ""),
            a.string("query", ""),
            limit(a),
            30_000,
        ))
    }),
    pool("getProviderMetadata", |c, a| {
        text(c.owner()?.get_provider_metadata_json(
            a.string("provider_id", ""),
            a.string("resource_type", ""),
            a.string("resource_id", ""),
            None,
        ))
    }),
    pool("findCollectionAcrossExtensions", |c, a| {
        let request = a.as_string().unwrap_or("{}").to_owned();
        text(
            c.owner()?
                .find_collection_across_extensions_json(request, None),
        )
    }),
    pool("handleURLWithExtension", |c, a| {
        text(c.owner()?.handle_url_json(a.string("url", "")))
    }),
    pool("findURLHandler", |c, a| {
        let handler = c.owner()?.find_url_handler(a.string("url", "")).or_fail()?;
        Ok(handler.unwrap_or_default().into())
    }),
    pool("searchDeezerByISRC", |c, a| {
        text(c.owner()?.search_deezer_by_isrc_for_item_id(
            a.string("isrc", ""),
            a.string("item_id", ""),
            None,
        ))
    }),
    pool("getDeezerExtendedMetadata", |c, a| {
        text(
            c.owner()?
                .get_deezer_extended_metadata(a.string("track_id", ""), None),
        )
    }),
    pool("convertSpotifyToDeezer", |c, a| {
        text(c.owner()?.convert_spotify_to_deezer(
            a.string("resource_type", ""),
            a.string("spotify_id", ""),
            None,
        ))
    }),
    pool("getTrackPlatformLinks", |c, a| {
        text(c.owner()?.get_track_platform_links_json(
            a.string("spotify_id", ""),
            a.string("isrc", ""),
            None,
        ))
    }),
    pool("fetchMusicBrainzTags", |c, a| {
        let manager = c.owner()?;
        let isrc = a.string("isrc", "");
        let genre = manager
            .fetch_music_brainz_genre_by_isrc(isrc.clone(), None)
            .unwrap_or_default();
        let album_artist = manager
            .fetch_music_brainz_album_artist_by_isrc(isrc, a.string("album_name", ""), None)
            .unwrap_or_default();
        Ok(json!({"genre": genre, "album_artist": album_artist})
            .to_string()
            .into())
    }),
    pool("getTrackCacheSize", |c, _| {
        Ok(json!(c.owner()?.get_track_cache_size().or_fail()?).into())
    }),
    pool("readAudioMetadata", |c, a| {
        let path = a.string("file_path", "");
        c.rt.backend.with_media_files(&[&path], |manager| {
            text(manager.read_audio_metadata(media_path(&path), String::new(), String::new(), None))
        })
    }),
    pool("clearTrackCache", |c, _| {
        null(c.owner()?.clear_track_id_cache().or_fail())
    }),
    pool("setMetadataLanguage", |c, a| {
        null(
            c.owner()?
                .set_metadata_language(a.string("tag", ""))
                .or_fail(),
        )
    }),
    pool("downloadByStrategy", download_by_strategy),
    pool("getAllDownloadProgress", |c, _| {
        text(c.owner()?.environment().download_state().all_progress())
    }),
    pool("cleanupConnections", |c, _| {
        null(c.owner()?.environment().cleanup_connections().or_fail())
    }),
    pool("clearItemProgress", |c, a| {
        let state = c.owner()?.environment().download_state();
        null(state.clear_item_progress(a.string("item_id", "")).or_fail())
    }),
    pool("cancelDownload", |c, a| {
        let state = c.owner()?.environment().download_state();
        null(state.cancel_download(a.string("item_id", "")).or_fail())
    }),
    pool("resetDownloadCancel", |c, a| {
        let state = c.owner()?.environment().download_state();
        null(
            state
                .reset_download_cancel(a.string("item_id", ""))
                .or_fail(),
        )
    }),
    pool("resetDownloadCancels", |c, a| {
        let state = c.owner()?.environment().download_state();
        null(state.reset_download_cancels(item_ids(a)?).or_fail())
    }),
    pool("cancelDownloads", |c, a| {
        let state = c.owner()?.environment().download_state();
        null(state.cancel_downloads(item_ids(a)?).or_fail())
    }),
    pool("getExtensionPendingAuth", |c, a| {
        text(
            c.owner()?
                .get_extension_pending_auth_json(a.string("extension_id", "")),
        )
    }),
    pool("completeExtensionSessionGrant", |c, a| {
        let manager = c.owner()?;
        complete_session_grant(
            &manager,
            &a.string("extension_id", ""),
            &a.string("grant", ""),
        )?;
        Ok(true.into())
    }),
    pool("getLyricsLRC", lyrics),
    pool("getLyricsLRCWithSource", lyrics),
    pool("fetchAndSaveLyrics", lyrics),
    pool("getLyricsFromProvider", |c, a| {
        let request = LyricsRequest {
            spotify_id: a.string("spotify_id", ""),
            track: a.string("track_name", ""),
            artist: a.string("artist_name", ""),
            file_path: String::new(),
            duration_ms: a.i64("duration_ms").unwrap_or(0),
        };
        text(
            c.owner()?
                .get_lyrics_from_provider(a.string("provider", ""), request, None),
        )
    }),
    pool("getEnabledLyricsProviders", |c, _| {
        text(c.owner()?.get_enabled_lyrics_providers_json())
    }),
    pool("runPostProcessingV2", |c, a| {
        let manager = c.owner()?;
        let ffmpeg = c.rt.config.ffmpeg_path.clone();
        text(with_ffmpeg_commands(&manager, ffmpeg, || {
            manager.run_post_processing(a.string("input", ""), a.string("metadata", ""), 120_000)
        }))
    }),
    pool("embedLyricsToFile", |c, a| {
        let path = a.string("file_path", "");
        c.rt.backend.with_media_files(&[&path], |manager| {
            text(manager.embed_lyrics_to_file(media_path(&path), a.string("lyrics", ""), None))
        })
    }),
    pool("setProviderPriority", |c, a| set_priority(c, a, true)),
    pool("setMetadataProviderPriority", |c, a| {
        set_priority(c, a, false)
    }),
    pool("getProviderPriority", |c, _| get_priority(c, true)),
    pool("getMetadataProviderPriority", |c, _| get_priority(c, false)),
    // AppDelegate.swift osMethods backed by Rust, with plain paths.
    pool("getBackendImplementations", |_, _| {
        Ok(json!({
            "filename": "rust",
            "file_metadata": "rust",
            "extensions": "rust",
            "downloads": "rust",
        })
        .into())
    }),
    pool("rewriteSplitArtistTags", |c, a| {
        let path = a.string("file_path", "");
        c.rt.backend.with_media_files(&[&path], |manager| {
            text(manager.rewrite_split_artist_tags(
                media_path(&path),
                a.string("artist", ""),
                a.string("album_artist", ""),
                None,
            ))
        })
    }),
    pool("writeM4AFreeformTags", |c, a| {
        let path = a.string("file_path", "");
        c.rt.backend.with_media_files(&[&path], |manager| {
            text(manager.write_m4a_freeform_tags(
                media_path(&path),
                a.string("metadata_json", "{}"),
                None,
            ))
        })
    }),
    pool("ensureAC4Config", |c, a| {
        text(c.owner()?.ensure_ac4_config(
            media_path(&a.string("file_path", "")),
            media_path(&a.string("source_path", "")),
            None,
        ))
    }),
    pool("writeAC4Metadata", |c, a| {
        text(c.owner()?.write_ac4_metadata(
            media_path(&a.string("file_path", "")),
            a.string("metadata_json", "{}"),
            media_path(&a.string("cover_path", "")),
            None,
        ))
    }),
    pool("downloadCoverToFile", download_cover_to_file),
    pool("extractCoverToFile", |c, a| {
        let audio = a.string("audio_path", "");
        let output = a.string("output_path", "");
        c.rt.backend
            .with_media_files(&[&audio, &output], |manager| {
                manager
                    .extract_cover_to_file(media_path(&audio), media_path(&output), None)
                    .or_fail()
            })?;
        Ok(r#"{"success":true}"#.into())
    }),
    pool("reEnrichFile", re_enrich_file),
    pool("checkHiResAuthenticity", |_, a| {
        text(mornye_mobile::check_hires_authenticity(
            a.string("file_path", ""),
            a.string("options_json", ""),
            None,
        ))
    }),
    pool("releaseMemory", |c, _| {
        null(c.owner()?.release_memory(false).or_fail())
    }),
    pool("releaseMemoryUnderPressure", |c, _| {
        c.owner()?.release_memory(true).or_fail()?;
        runtime::log("info", "Backend memory pressure release completed");
        Ok(Reply::null())
    }),
    pool("setLibraryCoverCacheDir", |c, a| {
        null(
            c.rt.backend
                .set_library_cover_cache_directory(&a.string("cache_dir", "")),
        )
    }),
    pool(
        "scanLibraryFolderToNDJSONFile",
        scan_library_folder_to_ndjson_file,
    ),
    pool("scanLibraryFolderIncremental", |c, a| {
        let folder = a.string("folder_path", "");
        let existing = a.string("existing_files", "{}");
        c.on_cancel(cancel_library_scan);
        c.rt.backend
            .with_library_directories(std::slice::from_ref(&folder), |manager| {
                text(manager.scan_library_folder_incremental(
                    paths::resolve_string(&folder),
                    existing,
                    None,
                ))
            })
    }),
    pool("getLibraryScanProgress", |c, _| {
        Ok(parse_json_payload(c.rt.backend.library_scan_progress()?).into())
    }),
    pool("cancelLibraryScan", |c, _| {
        cancel_library_scan(c.rt);
        Ok(Reply::null())
    }),
    pool("pauseLibraryScan", |c, _| {
        if let Some(manager) = c.rt.backend.manager_snapshot() {
            manager.pause_library_scan().or_fail()?;
        }
        Ok(Reply::null())
    }),
    pool("resumeLibraryScan", |c, _| {
        if let Some(manager) = c.rt.backend.manager_snapshot() {
            manager.resume_library_scan().or_fail()?;
        }
        Ok(Reply::null())
    }),
    pool("parseCueSheet", |c, a| {
        c.rt.backend
            .parse_cue_sheet(&a.string("cue_path", ""), &a.string("audio_dir", ""))
            .map(Reply::from)
    }),
    // Android extension callback inbox (MainActivityExtensionIntents.kt).
    pool(
        "processPendingExtensionCallbacks",
        process_pending_extension_callbacks,
    ),
    // Desktop only: Dart forwards a `mornye://` URL it received from the OS.
    pool("queueExtensionCallbackUrl", |c, a| {
        let Some(route) = crate::callback_url::parse(&a.string("url", "")) else {
            return Ok(false.into());
        };
        if c.rt.backend.queue_callback(route) {
            // Keep the URL until Dart is initialized and drains the inbox.
            runtime::inbound("extensionAuthCallbackReceived", Value::Null);
        }
        Ok(true.into())
    }),
    // Desktop only: OS services (keep_awake.rs, discord.rs, watcher.rs).
    pool("beginKeepAwake", |c, a| {
        let reason = a.string("reason", "Downloading music");
        match c.rt.keep_awake.begin(&reason) {
            Ok(()) => Ok(true.into()),
            Err(error) => {
                runtime::log("warn", &format!("Keep awake unavailable: {error}"));
                Ok(false.into())
            }
        }
    }),
    pool("endKeepAwake", |c, _| Ok(c.rt.keep_awake.end().into())),
    pool("discordPresenceInitialize", |c, _| {
        Ok(c.rt.discord.initialize().into())
    }),
    pool("discordPresenceUpdate", |c, a| {
        c.rt.discord.update(a.value().clone());
        Ok(Reply::null())
    }),
    pool("discordPresenceClear", |c, _| {
        c.rt.discord.clear();
        Ok(Reply::null())
    }),
    pool("discordPresenceShutdown", |c, _| {
        c.rt.discord.shutdown();
        Ok(Reply::null())
    }),
    pool("watchLibraryFolders", |c, a| {
        let folders = match a.string_list("paths") {
            Some(Ok(folders)) => folders,
            Some(Err(())) => {
                return Err(CallError::invalid_arguments(
                    "paths must be a list of strings",
                ));
            }
            None => Vec::new(),
        };
        let watched = c.rt.watcher.watch(&folders).map_err(CallError::failure)?;
        Ok(json!(watched).into())
    }),
    pool("unwatchLibraryFolders", |c, _| {
        c.rt.watcher.stop();
        Ok(Reply::null())
    }),
    // Desktop only: the Mornye Link server (link.rs, LINK_CONTRACT.md 6).
    pool("linkStart", |c, a| c.rt.link.start(&c.rt.config, a)),
    pool("linkStop", |c, _| {
        c.rt.link.stop();
        Ok(Reply::null())
    }),
    pool("linkStatus", |c, _| {
        Ok(c.rt.link.status(&c.rt.config).into())
    }),
    pool("linkSetCatalog", |c, a| c.rt.link.set_catalog(a)),
    pool("linkBeginPairing", |c, _| c.rt.link.begin_pairing()),
    pool("linkEndPairing", |c, _| {
        c.rt.link.end_pairing();
        Ok(Reply::null())
    }),
    pool("linkDevices", |c, _| c.rt.link.devices(&c.rt.config)),
    pool("linkRevoke", |c, a| c.rt.link.revoke(&c.rt.config, a)),
    pool("linkCreateKey", |c, a| c.rt.link.create_key(a)),
    pool("linkReply", |c, a| c.rt.link.reply(a)),
    pool("linkSend", |c, a| c.rt.link.send(a)),
    pool("linkEmbeddedPictures", |c, a| {
        c.rt.link.embedded_pictures(a)
    }),
    // Desktop only: Google Cast output (cast.rs).
    pool("castCall", |c, a| c.rt.cast.call(a)),
];

fn table() -> &'static HashMap<&'static str, &'static Entry> {
    static TABLE: OnceLock<HashMap<&'static str, &'static Entry>> = OnceLock::new();
    TABLE.get_or_init(|| METHODS.iter().map(|entry| (entry.name, entry)).collect())
}

pub(crate) fn find(method: &str) -> Option<&'static Entry> {
    table().get(method).copied()
}

/// Work that must happen synchronously in `mornye_call`.
pub(crate) fn prepare(
    rt: &Runtime,
    method: &str,
    args: &Args,
    state: &CallState,
) -> Result<(), CallError> {
    if method != "runNativeDataJob" {
        return Ok(());
    }
    // Only acquire the cancellation lease here; the job itself runs on a
    // worker. This preserves cancellation of a queued job.
    let id = args
        .opt_string("request_id")
        .filter(|id| !id.is_empty())
        .ok_or_else(|| CallError::failure("Missing native data job ID"))?;
    let lease = rt.backend.acquire_data_job(id)?;
    *state.lease.lock().expect("call lease") = Some(lease);
    Ok(())
}

/// Releases what `prepare` acquired for a call that never ran.
pub(crate) fn abandon(rt: &Runtime, method: &str, args: &Args, state: &CallState) {
    if method == "runNativeDataJob"
        && let Some(lease) = state.lease.lock().expect("call lease").take()
    {
        rt.backend
            .finish_data_job(&args.string("request_id", ""), &lease);
    }
}

pub(crate) fn run(
    rt: &'static Runtime,
    entry: &Entry,
    args: &Args,
    state: &CallState,
) -> CallResult {
    let ctx = Ctx {
        rt,
        state,
        method: entry.name,
    };
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| (entry.handler)(&ctx, args)))
        .unwrap_or_else(|_| {
            Err(CallError::failure(format!(
                "Desktop backend panicked in {}",
                entry.name
            )))
        })
}

fn run_native_data_job(c: &Ctx<'_>, a: &Args) -> CallResult {
    struct Finish<'a>(&'static Runtime, &'a str, Arc<RequestLease>);
    impl Drop for Finish<'_> {
        fn drop(&mut self) {
            self.0.backend.finish_data_job(self.1, &self.2);
        }
    }
    let lease = c
        .state
        .lease
        .lock()
        .expect("call lease")
        .take()
        .ok_or_else(|| CallError::failure("Missing native data job lease"))?;
    let id = a.string("request_id", "");
    let _finish = Finish(c.rt, &id, Arc::clone(&lease));
    let cancel_id = id.clone();
    c.on_cancel(move |rt| {
        let _ = rt.backend.cancel_data_job(&cancel_id);
    });
    c.rt.backend.run_data_job(a, lease).map(Reply::from)
}

fn extension_request(c: &Ctx<'_>, a: &Args) -> CallResult {
    let id = a.string("request_id", "");
    let (manager, lease) = c.rt.backend.acquire_request(&id)?;
    struct Release(Arc<RequestLease>);
    impl Drop for Release {
        fn drop(&mut self) {
            self.0.release();
        }
    }
    let _release = Release(Arc::clone(&lease));
    let cancel_id = id.clone();
    c.on_cancel(move |rt| {
        let _ = rt.backend.cancel_request(&cancel_id);
    });
    let extension_id = a.string("extension_id", "");
    if c.method == "customSearchWithExtension" {
        return text(manager.custom_search_json(
            extension_id,
            a.string("query", ""),
            a.string("options", ""),
            Some(lease),
        ));
    }
    if c.method == "getExtensionRelatedTracks" {
        return text(manager.get_extension_related_tracks_json(
            extension_id,
            a.string("seeds", "[]"),
            a.string("options", ""),
            Some(lease),
        ));
    }
    text(manager.get_extension_home_feed_json(extension_id, Some(lease)))
}

fn edit_file_metadata(c: &Ctx<'_>, a: &Args) -> CallResult {
    let path = a.string("file_path", "");
    let metadata = a.string("metadata_json", "{}");
    let fields: Value = serde_json::from_str(&metadata).or_fail()?;
    let cover = fields["cover_path"].as_str().unwrap_or("").to_owned();
    c.rt.backend.with_media_files(&[&path, &cover], |manager| {
        text(manager.edit_file_metadata(media_path(&path), metadata.clone(), None))
    })
}

fn item_ids(a: &Args) -> Result<Vec<String>, CallError> {
    match a.string_list("item_ids") {
        Some(Ok(ids)) => Ok(ids),
        _ => Err(CallError::failure("Expected item_ids string list")),
    }
}

fn download_by_strategy(c: &Ctx<'_>, a: &Args) -> CallResult {
    let request = a
        .as_string()
        .ok_or_else(|| CallError::failure("Download request must be a JSON string"))?
        .to_owned();
    let manager = c.owner()?;
    let item_id = serde_json::from_str::<Value>(&request)
        .ok()
        .and_then(|value| value["item_id"].as_str().map(str::to_owned))
        .filter(|id| !id.is_empty());
    if let Some(item_id) = item_id {
        c.on_cancel(move |rt| {
            if let Ok(manager) = rt.backend.owner() {
                let _ = manager
                    .environment()
                    .download_state()
                    .cancel_download(item_id);
            }
        });
    }
    let ffmpeg = c.rt.config.ffmpeg_path.clone();
    text(with_ffmpeg_commands(&manager, ffmpeg, || {
        manager.download_by_strategy(request)
    }))
}

/// `getLyricsLRC`, `getLyricsLRCWithSource` and `fetchAndSaveLyrics`.
fn lyrics(c: &Ctx<'_>, a: &Args) -> CallResult {
    let save = c.method == "fetchAndSaveLyrics";
    let source = a.string(if save { "audio_file_path" } else { "file_path" }, "");
    let output = if save {
        a.string("output_path", "")
    } else {
        String::new()
    };
    c.rt.backend
        .with_media_files(&[&source, &output], |manager| {
            let request = LyricsRequest {
                spotify_id: a.string("spotify_id", ""),
                track: a.string("track_name", ""),
                artist: a.string("artist_name", ""),
                file_path: media_path(&source),
                duration_ms: a.i64("duration_ms").unwrap_or(0),
            };
            match c.method {
                "getLyricsLRC" => text(manager.get_lyrics_lrc(request, None)),
                "getLyricsLRCWithSource" => text(manager.get_lyrics_lrc_with_source(request, None)),
                _ => {
                    manager
                        .fetch_and_save_lyrics(request, media_path(&output), None)
                        .or_fail()?;
                    Ok(r#"{"success":true}"#.into())
                }
            }
        })
}

fn set_priority(c: &Ctx<'_>, a: &Args, download: bool) -> CallResult {
    let ids = ids(&a.string("priority", "[]"))?;
    null(
        c.owner()?
            .set_provider_priority(priority_kind(download).into(), ids)
            .or_fail(),
    )
}

fn get_priority(c: &Ctx<'_>, download: bool) -> CallResult {
    let priorities: Value =
        serde_json::from_str(&c.owner()?.provider_priorities().or_fail()?).or_fail()?;
    let value: Vec<String> = priorities[priority_kind(download)]
        .as_array()
        .map(|values| {
            values
                .iter()
                .filter_map(|value| value.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default();
    Ok(serde_json::to_string(&value).or_fail()?.into())
}

fn download_cover_to_file(c: &Ctx<'_>, a: &Args) -> CallResult {
    let url = a.string("cover_url", "");
    let output = a.string("output_path", "");
    let max_dimension = a.i64("max_dimension").unwrap_or(0).max(0);
    let temporary = if output.is_empty() {
        Some(c.rt.backend.create_temporary_media_file("cover_", ".jpg")?)
    } else {
        None
    };
    let destination = temporary
        .as_ref()
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or(output);
    let downloaded = c.owner().and_then(|manager| {
        manager
            .download_cover_to_file_sized(
                url,
                paths::resolve_string(&destination),
                max_dimension,
                None,
            )
            .or_fail()
    });
    if let Err(error) = downloaded {
        if let Some(temporary) = &temporary {
            let _ = std::fs::remove_file(temporary);
        }
        return Err(error);
    }
    Ok(match temporary {
        Some(temporary) => {
            json!({"success": true, "file_path": temporary.to_string_lossy()}).to_string()
        }
        None => r#"{"success":true}"#.to_owned(),
    }
    .into())
}

fn re_enrich_file(c: &Ctx<'_>, a: &Args) -> CallResult {
    let raw = a.string("request_json", "{}");
    let mut request: Value = serde_json::from_str(&raw).or_fail()?;
    if !request.is_object() {
        return Err(CallError::failure("Re-enrich request must be an object"));
    }
    let preview = request["preview_only"].as_bool() == Some(true);
    if !preview
        && let Some(path) = request["file_path"]
            .as_str()
            .filter(|path| path.starts_with('/'))
    {
        request["file_path"] = media_path(path).into();
    }
    let resolved = request.to_string();
    let path = request["file_path"].as_str().unwrap_or("").to_owned();
    if !preview && !path.is_empty() {
        return c.rt.backend.with_media_files(&[&path], |manager| {
            text(manager.reenrich_file(resolved, None))
        });
    }
    text(c.owner()?.reenrich_file(resolved, None))
}

fn cancel_library_scan(rt: &'static Runtime) {
    if let Some(manager) = rt.backend.manager_snapshot() {
        let _ = manager.cancel_library_scan();
    }
}

fn scan_library_folder_to_ndjson_file(c: &Ctx<'_>, a: &Args) -> CallResult {
    let invalid = |method: &str| CallError::failure(format!("Invalid arguments for {method}"));
    let folder = a
        .opt_string("folder_path")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| invalid("scanLibraryFolderToNDJSONFile"))?;
    let output = a
        .opt_string("output_path")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| invalid("scanLibraryFolderToNDJSONFile"))?;
    c.on_cancel(cancel_library_scan);
    let count =
        c.rt.backend
            .scan_library_folder_to_ndjson_file(folder, output)?;
    let progress: Value =
        serde_json::from_str(&c.rt.backend.library_scan_progress()?).unwrap_or(Value::Null);
    let error_count = progress["error_count"]
        .as_i64()
        .ok_or_else(|| invalid("scanLibraryFolderToNDJSONFile: missing scan summary"))?;
    Ok(json!({"path": output, "count": count, "error_count": error_count}).into())
}

/// `parseJsonPayload`: the decoded value, or the text when it is not JSON.
fn parse_json_payload(payload: String) -> Value {
    serde_json::from_str(&payload).unwrap_or(Value::String(payload))
}

/// Android `processPendingExtensionCallbacks` and `completeAuthCallback`.
fn process_pending_extension_callbacks(c: &Ctx<'_>, _: &Args) -> CallResult {
    for route in c.rt.backend.take_callbacks() {
        let mut extension_id = String::new();
        let result = complete_auth_callback(c, &route, &mut extension_id);
        match result {
            Ok(()) => {
                runtime::log("info", "Extension callback completed");
                if route.session_grant {
                    notify_session_grant_completed(&extension_id, true);
                }
            }
            Err(error) => {
                runtime::log(
                    "warn",
                    &format!("Extension callback failed: {}", error.message),
                );
                if route.session_grant && !extension_id.is_empty() {
                    notify_session_grant_completed(&extension_id, false);
                }
            }
        }
    }
    Ok(Reply::null())
}

fn complete_auth_callback(
    c: &Ctx<'_>,
    route: &CallbackRoute,
    extension_id: &mut String,
) -> Result<(), CallError> {
    let manager = c.owner()?;
    let environment = manager.environment();
    let state = route.state.clone();
    *extension_id = if route.session_grant {
        environment.resolve_callback_state(state)
    } else {
        environment.consume_callback_state(state)
    }
    .or_fail()?;
    if route.session_grant {
        return complete_session_grant(&manager, extension_id, &route.code);
    }
    environment
        .set_auth_code(extension_id.clone(), route.code.clone())
        .or_fail()?;
    manager
        .invoke_action(extension_id.clone(), "completeSpotifyLogin".into())
        .or_fail()?;
    Ok(())
}

fn notify_session_grant_completed(extension_id: &str, success: bool) {
    runtime::inbound(
        "extensionSessionGrantCompleted",
        json!({"extension_id": extension_id, "success": success}),
    );
}
