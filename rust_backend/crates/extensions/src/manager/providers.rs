//! Extension manager provider selection: priorities, fallback providers, and URL handler lookup.

use super::*;
use mornye_core::matching::lowercase;
use std::collections::BTreeSet;
use std::sync::TryLockError;
use std::time::Duration;

#[derive(Default)]
pub(super) struct Priorities {
    download: Vec<String>,
    pub(super) metadata: Vec<String>,
    fallback: Option<Vec<String>>,
}

impl ExtensionManager {
    pub(crate) fn metadata_revision(&self) -> u64 {
        self.metadata_revision.load(Ordering::Acquire)
    }

    pub(crate) fn share_providers(
        &self,
        source_id: &str,
    ) -> Result<Vec<mornye_core::metadata::share::Provider>, ManagerError> {
        self.check()?;
        Ok(self
            .entries
            .lock()
            .expect("extension manager lock")
            .values()
            .filter(|entry| {
                let status = entry.status.read().expect("extension status lock");
                entry.manifest.name != source_id
                    && entry.manifest.has_type("metadata_provider")
                    && status.enabled
                    && status.error.is_empty()
            })
            .map(|entry| mornye_core::metadata::share::Provider {
                id: entry.manifest.name.clone(),
                display_name: entry.manifest.display_name.clone(),
                source_dir: entry.source.to_string_lossy().into_owned(),
                capabilities: json!(entry.manifest.capabilities),
            })
            .collect())
    }

    pub fn set_provider_priority(&self, kind: &str, ids: Vec<String>) -> Result<(), ManagerError> {
        self.check()?;
        let (provider_type, legacy): (&str, &[&str]) = match kind {
            "download" => ("download_provider", &["deezer", "qobuz", "tidal"]),
            "metadata" => (
                "metadata_provider",
                &["deezer", "spotify", "qobuz", "tidal"],
            ),
            _ => return Err(error("unknown provider priority kind")),
        };
        let enabled: BTreeSet<_> = self
            .provider_ids(provider_type)?
            .into_iter()
            .map(|id| lowercase(id.trim()))
            .collect();
        let mut seen = BTreeSet::new();
        let ids = ids
            .into_iter()
            .filter_map(|id| {
                let id = id.trim();
                let normalized = lowercase(id);
                if id.is_empty()
                    || (legacy.contains(&normalized.as_str()) && !enabled.contains(&normalized))
                {
                    return None;
                }
                let key = if kind == "download" {
                    normalized
                } else {
                    id.to_owned()
                };
                seen.insert(key).then(|| id.to_owned())
            })
            .collect();
        let mut priorities = self.priorities.lock().expect("provider priority lock");
        if kind == "download" {
            priorities.download = ids;
        } else {
            priorities.metadata = ids;
        }
        Ok(())
    }

    pub fn set_fallback_providers(&self, ids: Option<Vec<String>>) -> Result<(), ManagerError> {
        self.check()?;
        let mut seen = BTreeSet::new();
        self.priorities
            .lock()
            .expect("provider priority lock")
            .fallback = ids.map(|ids| {
            ids.into_iter()
                .filter_map(|id| {
                    let id = id.trim();
                    (!id.is_empty() && seen.insert(id.to_owned())).then(|| id.to_owned())
                })
                .collect()
        });
        Ok(())
    }

    pub fn provider_priorities(&self) -> Result<String, ManagerError> {
        self.check()?;
        let priorities = self.priorities.lock().expect("provider priority lock");
        Ok(json!({"download":priorities.download,"metadata":priorities.metadata,"fallback":priorities.fallback}).to_string())
    }

    pub fn fallback_allowed(&self, id: &str) -> Result<bool, ManagerError> {
        self.check()?;
        Ok(self
            .priorities
            .lock()
            .expect("provider priority lock")
            .fallback
            .as_ref()
            .is_none_or(|ids| ids.iter().any(|entry| entry == id)))
    }

    pub fn find_url_handler(&self, url: &str) -> Result<Option<String>, ManagerError> {
        self.check()?;
        let mut matches: Vec<_> = self
            .entries
            .lock()
            .expect("extension manager lock")
            .values()
            .filter(|entry| {
                let status = entry.status.read().expect("extension status lock");
                status.enabled && status.error.is_empty() && entry.manifest.matches_url(url)
            })
            .map(|entry| entry.manifest.name.clone())
            .collect();
        let priorities = self.priorities.lock().expect("provider priority lock");
        let ranks: BTreeMap<_, _> = priorities
            .metadata
            .iter()
            .enumerate()
            .map(|(index, id)| (lowercase(id.trim()), index))
            .collect();
        matches.sort_by_key(|id| {
            (
                ranks.get(&lowercase(id)).copied().unwrap_or(usize::MAX),
                id.clone(),
            )
        });
        Ok(matches.into_iter().next())
    }

    /// Validate the application metadata wrapper before checking its resource type.
    pub(crate) fn require_metadata_provider(&self, id: &str) -> Result<(), ManagerError> {
        let entry = self.get(id)?;
        if !entry.manifest.has_type("metadata_provider") {
            return Err(error(format!(
                "extension '{id}' is not a metadata provider"
            )));
        }
        if !entry.status.read().expect("extension status lock").enabled {
            return Err(error(format!("extension '{id}' is disabled")));
        }
        Ok(())
    }

    /// Typed metadata/lyrics results from installed providers. Download and
    /// post-processing orchestration use their separate runtime/file lifecycles.
    pub fn provider_call(
        &self,
        id: &str,
        method: &str,
        arguments: &str,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
    ) -> Result<String, ManagerError> {
        self.provider_operation(id, method, arguments, lease, timeout_ms, "")
    }

    /// Internal native callers keep the already validated provider value;
    /// only public string boundaries need to serialize it again.
    pub(crate) fn provider_call_value(
        &self,
        id: &str,
        method: &str,
        arguments: &str,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
    ) -> Result<Value, ManagerError> {
        self.provider_operation_value(id, method, arguments, lease, timeout_ms, "")
    }

    pub(super) fn provider_operation(
        &self,
        id: &str,
        method: &str,
        arguments: &str,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
        item_id: &str,
    ) -> Result<String, ManagerError> {
        self.provider_operation_value(id, method, arguments, lease, timeout_ms, item_id)
            .map(|value| value.to_string())
    }

    pub(super) fn provider_operation_value(
        &self,
        id: &str,
        method: &str,
        arguments: &str,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
        item_id: &str,
    ) -> Result<Value, ManagerError> {
        let entry = self.get(id)?;
        let manifest = &entry.manifest;
        let requirement =
            match method {
                "getTrack" | "getAlbum" | "getPlaylist" | "getArtist" | "getConcert"
                | "searchTracks" | "enrichTrack" => (!manifest.has_type("metadata_provider"))
                    .then_some("is not a metadata provider"),
                "checkAvailability" => (!manifest.has_type("download_provider"))
                    .then_some("is not a download provider"),
                "fetchLyrics" => {
                    (!manifest.has_type("lyrics_provider")).then_some("is not a lyrics provider")
                }
                "customSearch" => (!manifest
                    .search_behavior
                    .as_ref()
                    .is_some_and(|config| config.enabled))
                .then_some("does not support custom search"),
                "handleUrl" => (!manifest
                    .url_handler
                    .as_ref()
                    .is_some_and(|config| config.enabled && !config.patterns.is_empty()))
                .then_some("does not support URL handling"),
                "getHomeFeed" => None,
                "getRelatedTracks" => (!manifest.has_capability("relatedTracks"))
                    .then_some("does not suggest related tracks"),
                _ => return Err(error(format!("unsupported provider method: {method}"))),
            };
        if let Some(requirement) = requirement {
            return Err(error(format!("extension '{id}' {requirement}")));
        }
        if !entry.status.read().expect("extension status lock").enabled {
            return Err(error(format!("extension '{id}' is disabled")));
        }
        let mut engine = loop {
            self.check()?;
            if let Some(lease) = &lease {
                lease
                    .check_active()
                    .map_err(|failure| error(failure.to_string()))?;
            }
            match entry.engine.try_lock() {
                Ok(engine) => break engine,
                Err(TryLockError::WouldBlock) => std::thread::sleep(Duration::from_millis(5)),
                Err(TryLockError::Poisoned(_)) => {
                    return Err(error("extension engine lock poisoned"));
                }
            }
        };
        if !self.current(&entry) || !entry.status.read().expect("extension status lock").enabled {
            return Err(error("extension is disabled or no longer installed"));
        }
        let runtime = self
            .ready_with_lease(&entry, &mut engine, true, lease.clone())
            .inspect_err(|failure| {
                if lease
                    .as_ref()
                    .is_none_or(|lease| lease.check_active().is_ok())
                {
                    self.failed(&entry, failure);
                }
            })?;
        let mut arguments: Vec<Value> = serde_json::from_str(arguments)
            .map_err(|failure| cause("invalid provider arguments", failure))?;
        if method == "customSearch" {
            if arguments.len() < 2 {
                arguments.resize(2, Value::Null);
            }
            if arguments[1].is_null() {
                arguments[1] = json!({});
            }
        }
        if method == "checkAvailability" {
            runtime.take_verification_url();
        }
        let response = runtime
            .call_provider_operation(
                method,
                &json!(arguments).to_string(),
                lease,
                timeout_ms,
                item_id.into(),
            )
            .map_err(|failure| match failure {
                ExtensionError::Timeout => error(format!(
                    "{method} timeout: extension took too long to respond"
                )),
                ExtensionError::Cancelled(cause) => error(cause.to_string()),
                _ if method == "checkAvailability"
                    && !runtime.take_verification_url().is_empty() =>
                {
                    cause("checkAvailability failed", verification_error(id))
                }
                other => cause(&format!("{method} failed"), other),
            })?;
        let mut response: Value =
            serde_json::from_str(&response).map_err(|e| error(e.to_string()))?;
        if let Some(message) = response.get("parseError").and_then(Value::as_str) {
            if method == "getHomeFeed" {
                return Err(error(format!("failed to marshal result: {message}")));
            }
            let kind = match method {
                "searchTracks" | "customSearch" => "search result",
                "getRelatedTracks" => "related tracks",
                "getAlbum" => "album",
                "getPlaylist" => "playlist",
                "getArtist" => "artist",
                "getConcert" => "concert",
                "handleUrl" => "URL handle result",
                "fetchLyrics" => "lyrics result",
                "checkAvailability" => "availability result",
                _ => "track",
            };
            return Err(error(format!("failed to parse {kind}: {message}")));
        }
        let mut value = response["value"].take();
        if method == "checkAvailability" && (value.is_null() || value["available"] != true) {
            if !runtime.take_verification_url().is_empty() {
                return Err(verification_error(id));
            }
            if value.is_null() {
                return Ok(json!({"available":false,"reason":"not implemented"}));
            }
        }
        if value.is_null() {
            return if method == "customSearch" || method == "getRelatedTracks" {
                Ok(json!([]))
            } else if method == "handleUrl" {
                Err(error("handleUrl returned null - URL not recognized"))
            } else {
                Err(error(format!("{method} returned null")))
            };
        }
        match method {
            "getTrack" => stamp(&mut value, id),
            "getAlbum" | "getPlaylist" => stamp_album(&mut value, id),
            "searchTracks" => stamp_tracks(&mut value["tracks"], id),
            "customSearch" | "getRelatedTracks" => stamp_tracks(&mut value, id),
            "getArtist" => {
                // Go stamps releases here; albums/top tracks keep their supplied
                // provider fields until URL handling performs recursive stamping.
                stamp(&mut value, id);
                if let Some(releases) = value.get_mut("releases").and_then(Value::as_array_mut) {
                    for release in releases {
                        stamp_album(release, id);
                    }
                }
            }
            "handleUrl" => {
                if let Some(track) = value.get_mut("track") {
                    stamp(track, id);
                }
                if let Some(tracks) = value.get_mut("tracks") {
                    stamp_tracks(tracks, id);
                }
                if let Some(album) = value.get_mut("album") {
                    stamp_album(album, id);
                }
                if let Some(artist) = value.get_mut("artist") {
                    stamp(artist, id);
                    for key in ["albums", "releases"] {
                        if let Some(albums) = artist.get_mut(key).and_then(Value::as_array_mut) {
                            for album in albums {
                                stamp_album(album, id);
                            }
                        }
                    }
                    if let Some(tracks) = artist.get_mut("top_tracks") {
                        stamp_tracks(tracks, id);
                    }
                }
            }
            "fetchLyrics" => {
                value["source"] = format!("Extension: {id}").into();
                if value["provider"] == "" {
                    value["provider"] = manifest.display_name.clone().into();
                }
                if value["lines"].as_array().is_some_and(Vec::is_empty) {
                    let plain = value["plainLyrics"].as_str().unwrap_or("").to_owned();
                    value["lines"] = Value::Null;
                    if !plain.is_empty() && value["instrumental"] != true {
                        value["syncType"] = "UNSYNCED".into();
                        let lines: Vec<_> = plain
                            .split('\n')
                            .filter(|line| !line.trim().is_empty())
                            .map(|line| json!({"startTimeMs":0,"words":line,"endTimeMs":0}))
                            .collect();
                        if !lines.is_empty() {
                            value["lines"] = lines.into();
                        }
                    }
                }
            }
            _ => {}
        }
        Ok(value)
    }
}

fn verification_error(id: &str) -> ManagerError {
    error(format!(
        "verification_required: extension '{id}' needs signed-session verification"
    ))
}

fn stamp(value: &mut Value, id: &str) {
    value["provider_id"] = id.into();
}
fn stamp_tracks(value: &mut Value, id: &str) {
    if let Some(tracks) = value.as_array_mut() {
        for track in tracks {
            stamp(track, id);
        }
    }
}
fn stamp_album(value: &mut Value, id: &str) {
    stamp(value, id);
    stamp_tracks(&mut value["tracks"], id);
}
