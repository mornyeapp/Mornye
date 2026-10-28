//! Backend entry points for provider metadata: URL handling, custom search, home feeds, and lookups.

use super::{Backend, ManagerError};
use mornye_core::cancellation::{CancellationDomain, CancellationRegistry, RequestLease};
use mornye_core::matching::lowercase;
use mornye_providers::resolver::{Check, ResolverError};
use serde_json::{Map, Value, json};
use std::sync::{Arc, mpsc};
use std::time::Duration;

#[cfg(test)]
mod value_tests;

impl Backend {
    pub fn handle_url_json(&self, url: &str) -> Result<String, String> {
        let _operation = self.enter()?;
        let id = self
            .manager
            .find_url_handler(url)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| format!("no extension found to handle URL: {url}"))?;
        let value = self
            .manager
            .provider_call_value(&id, "handleUrl", &json!([url]).to_string(), None, 30_000)
            .map_err(|error| error.to_string())?;
        let mut result = strings(
            &value,
            &[
                "type",
                "id",
                "name",
                "cover_url",
                "header_image",
                "header_video",
            ],
        );
        result.insert("extension_id".into(), id.into());
        if let Some(value) = value.get("track").filter(|value| !value.is_null()) {
            result.insert("track".into(), track(value, "", 0));
        }
        let values = array(&value, "tracks");
        if !values.is_empty() {
            result.insert("tracks".into(), url_tracks(values));
        }
        if let Some(value) = value.get("album").filter(|value| !value.is_null()) {
            let mut info = strings(
                value,
                &[
                    "id",
                    "name",
                    "artists",
                    "cover_url",
                    "header_image",
                    "header_video",
                    "release_date",
                    "album_type",
                    "provider_id",
                ],
            );
            info.insert("audio_traits".into(), value["audio_traits"].clone());
            for key in ["editorial_notes", "description"] {
                if let Some(notes) = value.get(key) {
                    info.insert(key.into(), notes.clone());
                }
            }
            info.insert(
                "total_tracks".into(),
                json!(value["total_tracks"].as_i64().unwrap_or_default()),
            );
            result.insert("album".into(), info.into());
        }
        if let Some(value) = value.get("artist").filter(|value| !value.is_null()) {
            let mut info = strings(
                value,
                &[
                    "id",
                    "name",
                    "image_url",
                    "header_image",
                    "header_video",
                    "header_logo",
                    "albums_next",
                    "provider_id",
                ],
            );
            info.insert(
                "listeners".into(),
                json!(value["listeners"].as_i64().unwrap_or_default()),
            );
            info.insert("concerts".into(), array(value, "concerts").into());
            for key in ["albums", "releases"] {
                let values = array(value, key);
                if !values.is_empty() {
                    info.insert(
                        key.into(),
                        values
                            .iter()
                            .map(|value| {
                                let mut value = album(value, false);
                                if value["album_type"] == "" {
                                    value["album_type"] = "album".into();
                                }
                                value
                            })
                            .collect::<Vec<_>>()
                            .into(),
                    );
                }
            }
            let values = array(value, "top_tracks");
            if !values.is_empty() {
                info.insert("top_tracks".into(), url_tracks(values));
            }
            result.insert("artist".into(), info.into());
        }
        self.check()?;
        serde_json::to_string(&result).map_err(|error| error.to_string())
    }

    pub fn custom_search_json(
        &self,
        id: &str,
        query: &str,
        options_json: &str,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, String> {
        let _operation = self.enter()?;
        let options = serde_json::from_str::<Map<String, Value>>(options_json).unwrap_or_default();
        let values = self
            .manager
            .provider_call_value(
                id,
                "customSearch",
                &json!([query, options]).to_string(),
                lease.clone(),
                30_000,
            )
            .map_err(|error| error.to_string())?;
        let values = values.as_array().expect("validated custom search array");
        let normalized = values
            .iter()
            .map(|value| {
                self.check()?;
                if let Some(lease) = &lease {
                    lease.check_active().map_err(|error| error.to_string())?;
                }
                Ok(track(value, "", 0))
            })
            .collect::<Result<Vec<_>, String>>()?;
        serde_json::to_string(&normalized).map_err(|error| error.to_string())
    }

    /// Songs like the tracks in [seeds_json] (most important first) from an
    /// extension with the `relatedTracks` capability; [options_json] holds
    /// `limit` (1 to 50, 25 by default).
    pub fn get_extension_related_tracks_json(
        &self,
        id: &str,
        seeds_json: &str,
        options_json: &str,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, String> {
        let _operation = self.enter()?;
        let seeds = serde_json::from_str::<Vec<Value>>(seeds_json)
            .map_err(|error| format!("invalid related track seeds: {error}"))?;
        let options = serde_json::from_str::<Map<String, Value>>(options_json).unwrap_or_default();
        let limit = options
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(25)
            .clamp(1, 50);
        let values = self
            .manager
            .provider_call_value(
                id,
                "getRelatedTracks",
                &json!([seeds, {"limit": limit}]).to_string(),
                lease.clone(),
                30_000,
            )
            .map_err(|error| error.to_string())?;
        let values = values.as_array().expect("validated related tracks array");
        let normalized = values
            .iter()
            .map(|value| {
                self.check()?;
                if let Some(lease) = &lease {
                    lease.check_active().map_err(|error| error.to_string())?;
                }
                Ok(track(value, "", 0))
            })
            .collect::<Result<Vec<_>, String>>()?;
        serde_json::to_string(&normalized).map_err(|error| error.to_string())
    }

    pub fn get_extension_home_feed_json(
        &self,
        id: &str,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, String> {
        let _operation = self.enter()?;
        self.manager
            .provider_call(id, "getHomeFeed", "[]", lease, 60_000)
            .map_err(|error| error.to_string())
    }

    pub fn get_provider_metadata_json(
        &self,
        provider_id: &str,
        kind: &str,
        resource_id: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        self.metadata_operation(30, check, |check| {
            let id = provider_id.trim();
            if id.is_empty() {
                return Err(ResolverError::Failed("empty provider ID".into()));
            }
            let available = self.manager.require_metadata_provider(id);
            // Only built-in dispatch folds case; installed IDs retain their case.
            if lowercase(id) == "deezer" && available.is_err() {
                return self.deezer_metadata(kind, resource_id, check);
            }
            available.map_err(|error| ResolverError::Failed(error.to_string()))?;
            let method = match kind {
                "track" => "getTrack",
                "album" => "getAlbum",
                "playlist" => "getPlaylist",
                "artist" => "getArtist",
                "concert" => "getConcert",
                _ => {
                    return Err(ResolverError::Failed(format!(
                        "unsupported provider resource type: {kind}"
                    )));
                }
            };
            let arguments = json!([resource_id]).to_string();
            let result = self.metadata_provider_work_result(check, |lease| {
                self.manager
                    .provider_call_value(id, method, &arguments, Some(lease), 30_000)
            })?;
            let result = response(kind, &result, check)?;
            serde_json::to_string(&result).map_err(|error| ResolverError::Failed(error.to_string()))
        })
    }

    pub(super) fn provider_metadata_call(
        &self,
        id: &str,
        method: &str,
        arguments: &str,
        check: &Check<'_>,
    ) -> Result<Value, ResolverError> {
        self.metadata_provider_work_result(check, |lease| {
            self.manager
                .provider_call_value(id, method, arguments, Some(lease), 30_000)
        })
    }

    pub(super) fn metadata_provider_work(
        &self,
        check: &Check<'_>,
        work: impl FnOnce(Arc<RequestLease>) -> Result<String, ManagerError> + Send,
    ) -> Result<Value, ResolverError> {
        let result = self.metadata_provider_work_result(check, work)?;
        serde_json::from_str(&result).map_err(|error| ResolverError::Failed(error.to_string()))
    }

    pub(super) fn metadata_provider_work_result<T: Send>(
        &self,
        check: &Check<'_>,
        work: impl FnOnce(Arc<RequestLease>) -> Result<T, ManagerError> + Send,
    ) -> Result<T, ResolverError> {
        let cancellation = CancellationRegistry::new(CancellationDomain::ExtensionRequest);
        let lease = Arc::new(
            cancellation
                .acquire("")
                .expect("new metadata cancellation lease"),
        );
        std::thread::scope(|scope| {
            let (done, completion) = mpsc::channel::<()>();
            let worker_lease = &lease;
            let worker = std::thread::Builder::new()
                .name("provider-metadata".into())
                .spawn_scoped(scope, move || {
                    let _done = done;
                    work(worker_lease.clone())
                })
                .map_err(|error| ResolverError::Failed(error.to_string()))?;
            let mut cancelled = None;
            loop {
                if let Err(message) = check() {
                    cancelled = Some(message);
                    lease.release();
                    break;
                }
                if !matches!(
                    completion.recv_timeout(Duration::from_millis(5)),
                    Err(mpsc::RecvTimeoutError::Timeout)
                ) {
                    break;
                }
            }
            let result = worker
                .join()
                .map_err(|_| ResolverError::Failed("metadata provider panicked".into()))?;
            lease.release();
            if let Some(message) = cancelled {
                return Err(ResolverError::Cancelled(message));
            }
            check().map_err(ResolverError::Cancelled)?;
            result.map_err(|error| ResolverError::Failed(error.to_string()))
        })
    }
}

// Inputs have already passed the installed provider's typed decoder. Fill the
// fields that Go's internal omitempty serializer drops before the public map.
fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or_default()
}

fn strings(value: &Value, fields: &[&str]) -> Map<String, Value> {
    fields
        .iter()
        .map(|key| ((*key).into(), json!(text(value, key))))
        .collect()
}

fn array<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value[key].as_array().map(Vec::as_slice).unwrap_or_default()
}

fn url_tracks(values: &[Value]) -> Value {
    values.iter().map(|value| track(value, "", 0)).collect()
}

fn track(value: &Value, cover: &str, index: usize) -> Value {
    let mut result = strings(
        value,
        &[
            "id",
            "name",
            "artists",
            "album_name",
            "album_artist",
            "album_id",
            "album_url",
            "artist_id",
            "artist_url",
            "external_urls",
            "preview_url",
            "release_date",
            "isrc",
            "provider_id",
            "item_type",
            "album_type",
            "spotify_id",
            "genre",
            "label",
            "copyright",
            "composer",
            "comment",
            "audio_quality",
            "audio_modes",
            "upc",
        ],
    );
    let cover = [text(value, "cover_url"), text(value, "images"), cover]
        .into_iter()
        .find(|value| !value.is_empty())
        .unwrap_or_default();
    result.insert("images".into(), json!(cover));
    result.insert("cover_url".into(), json!(cover));
    for key in [
        "duration_ms",
        "track_number",
        "total_tracks",
        "disc_number",
        "total_discs",
    ] {
        result.insert(key.into(), json!(value[key].as_i64().unwrap_or_default()));
    }
    if result["track_number"] == 0 && index > 0 {
        result.insert("track_number".into(), json!(index));
    }
    result.insert(
        "explicit".into(),
        json!(value["explicit"].as_bool().unwrap_or(false)),
    );
    result.insert("external_links".into(), value["external_links"].clone());
    result.into()
}

fn tracks(values: &[Value], cover: &str, check: &Check<'_>) -> Result<Value, ResolverError> {
    values
        .iter()
        .enumerate()
        .map(|(index, value)| {
            check().map_err(ResolverError::Cancelled)?;
            Ok(track(value, cover, index + 1))
        })
        .collect::<Result<Vec<_>, _>>()
        .map(Value::Array)
}

fn album(value: &Value, full: bool) -> Value {
    let mut result = strings(
        value,
        &[
            "id",
            "name",
            "artists",
            "cover_url",
            "release_date",
            "album_type",
            "provider_id",
        ],
    );
    result.insert("images".into(), json!(text(value, "cover_url")));
    result.insert(
        "total_tracks".into(),
        json!(value["total_tracks"].as_i64().unwrap_or_default()),
    );
    if full {
        result.extend(strings(
            value,
            &["artist_id", "header_image", "header_video"],
        ));
        result.insert("audio_traits".into(), json!(array(value, "audio_traits")));
        for key in ["editorial_notes", "description"] {
            if let Some(notes) = value.get(key) {
                result.insert(key.into(), notes.clone());
            }
        }
    }
    result.into()
}

fn response(kind: &str, value: &Value, check: &Check<'_>) -> Result<Value, ResolverError> {
    check().map_err(ResolverError::Cancelled)?;
    let cover = text(value, "cover_url");
    Ok(match kind {
        "concert" => json!({"concert": value}),
        // Move normalized values into the envelope. json! serializes borrowed
        // expressions, duplicating every field of an already-built track list.
        "track" => Map::from_iter([("track".into(), track(value, "", 0))]).into(),
        "album" => Map::from_iter([
            ("album_info".into(), album(value, true)),
            (
                "track_list".into(),
                tracks(array(value, "tracks"), cover, check)?,
            ),
        ])
        .into(),
        "playlist" => {
            let mut info = strings(
                value,
                &[
                    "id",
                    "name",
                    "cover_url",
                    "header_image",
                    "header_video",
                    "provider_id",
                ],
            );
            info.insert("images".into(), json!(cover));
            info.insert(
                "owner".into(),
                json!({"name":text(value,"artists"),"images":cover}),
            );
            Map::from_iter([
                ("playlist_info".into(), info.into()),
                (
                    "track_list".into(),
                    tracks(array(value, "tracks"), cover, check)?,
                ),
            ])
            .into()
        }
        "artist" => {
            let cover = text(value, "image_url");
            let image = [text(value, "header_image"), cover]
                .into_iter()
                .map(str::trim)
                .find(|value| !value.is_empty())
                .unwrap_or_default();
            let mut info = strings(
                value,
                &[
                    "id",
                    "name",
                    "header_image",
                    "header_video",
                    "header_logo",
                    "albums_next",
                    "provider_id",
                ],
            );
            info.insert("images".into(), json!(image));
            info.insert("cover_url".into(), json!(cover));
            info.insert("concerts".into(), array(value, "concerts").into());
            if value["listeners"].as_i64().unwrap_or_default() > 0 {
                info.insert("listeners".into(), value["listeners"].clone());
            }
            let mut result = Value::Object(Map::from_iter([("artist_info".into(), info.into())]));
            for key in ["albums", "releases"] {
                let values = array(value, key);
                if key == "albums" || !values.is_empty() {
                    result[key] = values
                        .iter()
                        .map(|value| {
                            check().map_err(ResolverError::Cancelled)?;
                            Ok(album(value, false))
                        })
                        .collect::<Result<Vec<_>, ResolverError>>()?
                        .into();
                }
            }
            let top = array(value, "top_tracks");
            if !top.is_empty() {
                result["top_tracks"] = tracks(top, cover, check)?;
            }
            result
        }
        _ => unreachable!("validated provider resource type"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::RuntimeLimits;
    use std::path::Path;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Barrier};
    use std::thread;

    fn backend(root: &Path) -> Backend {
        Backend::new(
            &root.join("sources"),
            &root.join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            RuntimeLimits::default(),
        )
        .unwrap()
    }

    #[test]
    fn metadata_provider_work_returns_immediate_json() {
        let root = tempfile::tempdir().unwrap();
        let backend = backend(root.path());
        let result = backend
            .metadata_provider_work(&|| Ok(()), |_| Ok(r#"{"immediate":true}"#.into()))
            .unwrap();
        assert_eq!(result["immediate"], true);
    }

    #[test]
    fn metadata_provider_work_waits_for_delayed_worker_completion() {
        let root = tempfile::tempdir().unwrap();
        let backend = Arc::new(backend(root.path()));
        let started = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let worker_backend = Arc::clone(&backend);
        let worker_started = Arc::clone(&started);
        let worker_release = Arc::clone(&release);
        let worker = thread::spawn(move || {
            worker_backend.metadata_provider_work(&|| Ok(()), move |_| {
                worker_started.wait();
                worker_release.wait();
                Ok(r#"{"delayed":true}"#.into())
            })
        });
        started.wait();
        release.wait();
        assert_eq!(worker.join().unwrap().unwrap()["delayed"], true);
    }

    #[test]
    fn metadata_provider_work_reports_worker_panic() {
        let root = tempfile::tempdir().unwrap();
        let backend = backend(root.path());
        let result = backend
            .metadata_provider_work(&|| Ok(()), |_| -> Result<String, ManagerError> {
                panic!("metadata worker failed")
            });
        assert_eq!(
            result,
            Err(ResolverError::Failed("metadata provider panicked".into()))
        );
    }

    #[test]
    fn metadata_provider_work_releases_lease_and_joins_cancelled_worker() {
        let root = tempfile::tempdir().unwrap();
        let backend = backend(root.path());
        let started = Arc::new(AtomicBool::new(false));
        let joined = Arc::new(AtomicBool::new(false));
        let worker_started = Arc::clone(&started);
        let worker_joined = Arc::clone(&joined);
        let result = backend.metadata_provider_work(
            &|| {
                if started.load(Ordering::Acquire) {
                    Err("cancelled by test".into())
                } else {
                    Ok(())
                }
            },
            move |lease| {
                worker_started.store(true, Ordering::Release);
                assert!(lease.wait_cancelled(60_000).is_err());
                worker_joined.store(true, Ordering::Release);
                Ok("{}".into())
            },
        );
        assert_eq!(
            result,
            Err(ResolverError::Cancelled("cancelled by test".into()))
        );
        assert!(joined.load(Ordering::Acquire));
    }
}
