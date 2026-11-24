//! Extension manager metadata operations: availability checks, track enrichment, and provider search.

use super::*;
use mornye_core::cancellation::RequestLease;
use mornye_core::matching::{lowercase, uppercase};
use serde::Deserialize;
use std::collections::BTreeSet;

#[derive(Default, Deserialize)]
#[serde(default)]
pub struct ProviderAvailabilityRequest {
    pub isrc: String,
    pub track_name: String,
    pub artist_name: String,
    pub spotify_id: String,
    pub deezer_id: String,
    pub tidal_id: String,
    pub qobuz_id: String,
    pub duration_ms: isize,
    pub item_id: String,
    pub track: Option<Map<String, Value>>,
}

impl ExtensionManager {
    fn item_lease(&self, id: &str) -> Result<Option<Arc<RequestLease>>, ManagerError> {
        if id.is_empty() {
            return Ok(None);
        }
        self.environment
            .download_state()
            .cancellation
            .acquire(id)
            .map(|lease| Some(Arc::new(lease)))
            .map_err(|failure| error(failure.to_string()))
    }

    pub(crate) fn check_availability_with_lease(
        &self,
        id: &str,
        request: ProviderAvailabilityRequest,
        timeout_ms: u64,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ManagerError> {
        let mut options = json!({"spotify_id":request.spotify_id,"deezer_id":request.deezer_id,
            "tidal_id":request.tidal_id,"qobuz_id":request.qobuz_id,"duration_ms":request.duration_ms});
        if let Some(track) = request.track.filter(|track| !track.is_empty()) {
            options["track"] = track.into();
        }
        self.provider_operation(
            id,
            "checkAvailability",
            &json!([
                request.isrc,
                request.track_name,
                request.artist_name,
                options
            ])
            .to_string(),
            lease,
            timeout_ms,
            &request.item_id,
        )
    }

    pub(crate) fn enrich_track_with_lease(
        &self,
        id: &str,
        track_json: &str,
        item_id: &str,
        timeout_ms: u64,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ManagerError> {
        let (original, input) = track_input(track_json)?;
        let entry = self.get(id)?;
        if !entry.manifest.has_type("metadata_provider")
            || !entry.status.read().expect("extension status lock").enabled
        {
            return Ok(original.to_string());
        }
        match self.provider_operation_value(
            id,
            "enrichTrack",
            &json!([input]).to_string(),
            lease,
            timeout_ms,
            item_id,
        ) {
            Ok(mut track) => {
                track["provider_id"] = original.get("provider_id").cloned().unwrap_or(json!(""));
                Ok(track.to_string())
            }
            Err(failure) if failure.0 == "download cancelled" => Err(failure),
            Err(failure) => {
                let _ = self.environment.log_buffer().backend(&format!(
                    "[Extension] EnrichTrack error for {id}: {failure}"
                ));
                Ok(original.to_string())
            }
        }
    }

    pub fn search_metadata_provider(
        &self,
        id: &str,
        query: &str,
        limit: isize,
        timeout_ms: u64,
    ) -> Result<String, ManagerError> {
        let id = id.trim();
        if id.is_empty() {
            return Err(error("metadata provider ID is required"));
        }
        let entry = self.get(id)?;
        if !entry.manifest.has_type("metadata_provider") {
            return Err(error(format!(
                "extension '{id}' is not a metadata provider"
            )));
        }
        {
            let status = entry.status.read().expect("extension status lock");
            if !status.enabled {
                return Err(error(format!("extension '{id}' is disabled")));
            }
            if !status.error.is_empty() {
                return Err(error(format!(
                    "extension '{id}' is unavailable: {}",
                    status.error
                )));
            }
        }
        let limit = search_limit(limit);
        let mut response = self.provider_call_value(
            id,
            "searchTracks",
            &json!([query, limit]).to_string(),
            None,
            timeout_ms,
        )?;
        let mut tracks = response["tracks"].take();
        if let Some(tracks) = tracks.as_array_mut() {
            tracks.truncate(limit);
        }
        Ok(tracks.to_string())
    }

    pub fn search_metadata_providers(
        &self,
        query: &str,
        limit: isize,
        include_extensions: bool,
        item_id: &str,
        timeout_ms: u64,
    ) -> Result<String, ManagerError> {
        self.search_metadata_providers_with_lease(
            query,
            limit,
            include_extensions,
            item_id,
            timeout_ms,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn search_metadata_providers_with_lease(
        &self,
        query: &str,
        limit: isize,
        include_extensions: bool,
        item_id: &str,
        timeout_ms: u64,
        request_lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ManagerError> {
        self.search_metadata_providers_value_with_lease(
            query,
            limit,
            include_extensions,
            item_id,
            timeout_ms,
            request_lease,
        )
        .map(|value| value.to_string())
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn search_metadata_providers_value_with_lease(
        &self,
        query: &str,
        limit: isize,
        include_extensions: bool,
        item_id: &str,
        timeout_ms: u64,
        request_lease: Option<Arc<RequestLease>>,
    ) -> Result<Value, ManagerError> {
        self.check()?;
        let mut ordered = self
            .priorities
            .lock()
            .expect("provider priority lock")
            .metadata
            .clone();
        let providers: BTreeSet<_> = if include_extensions {
            self.provider_ids("metadata_provider")?
                .into_iter()
                .collect()
        } else {
            BTreeSet::new()
        };
        let prioritized: BTreeSet<_> = ordered.iter().cloned().collect();
        ordered.extend(providers.difference(&prioritized).cloned());
        let limit = search_limit(limit);
        let mut tracks = Vec::new();
        let mut seen = BTreeSet::new();
        let mut verification = None;
        // Keep the same cancellation acquisition alive between providers.
        let lease = if request_lease.is_some() {
            request_lease
        } else if ordered.is_empty() {
            None
        } else {
            self.item_lease(item_id)?
        };
        for id in ordered {
            if let Some(lease) = &lease {
                lease.check_active().map_err(|e| error(e.to_string()))?;
            }
            if !providers.contains(&id) {
                continue;
            }
            let found = self.provider_search_tracks(
                &id,
                query,
                limit,
                lease.clone(),
                timeout_ms,
                item_id,
                &mut verification,
            )?;
            for track in found {
                if seen.insert(dedup_key(&track)) {
                    tracks.push(track);
                    if tracks.len() >= limit {
                        return Ok(tracks.into());
                    }
                }
            }
        }
        if tracks.is_empty()
            && let Some(failure) = verification
        {
            return Err(failure);
        }
        Ok(tracks.into())
    }

    /// Enabled metadata providers in the order a search asks them: `only`
    /// in its own order when given, otherwise the user's priority order.
    pub(crate) fn metadata_search_order(
        &self,
        only: &[String],
    ) -> Result<Vec<String>, ManagerError> {
        let providers: BTreeSet<_> = self
            .provider_ids("metadata_provider")?
            .into_iter()
            .collect();
        let mut ordered = if only.is_empty() {
            let mut ordered = self
                .priorities
                .lock()
                .expect("provider priority lock")
                .metadata
                .clone();
            let prioritized: BTreeSet<_> = ordered.iter().cloned().collect();
            ordered.extend(providers.difference(&prioritized).cloned());
            ordered
        } else {
            only.to_vec()
        };
        let mut seen = BTreeSet::new();
        ordered.retain(|id| providers.contains(id) && seen.insert(id.clone()));
        Ok(ordered)
    }

    /// Unlike `search_metadata_providers_value_with_lease`, every provider
    /// gets its own `limit`, so the first one cannot fill every slot and hide
    /// the others. `done` sees each provider's tracks and returns true to
    /// skip the remaining providers.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn search_each_metadata_provider_with_lease(
        &self,
        query: &str,
        limit: isize,
        order: &[String],
        item_id: &str,
        timeout_ms: u64,
        request_lease: Option<Arc<RequestLease>>,
        mut done: impl FnMut(&[Value]) -> bool,
    ) -> Result<Vec<Value>, ManagerError> {
        self.check()?;
        let limit = search_limit(limit);
        let mut tracks = Vec::new();
        let mut verification = None;
        let lease = if request_lease.is_some() {
            request_lease
        } else if order.is_empty() {
            None
        } else {
            self.item_lease(item_id)?
        };
        for id in order {
            if let Some(lease) = &lease {
                lease.check_active().map_err(|e| error(e.to_string()))?;
            }
            let mut found = self.provider_search_tracks(
                id,
                query,
                limit,
                lease.clone(),
                timeout_ms,
                item_id,
                &mut verification,
            )?;
            found.truncate(limit);
            let stop = done(&found);
            tracks.extend(found);
            if stop {
                break;
            }
        }
        if tracks.is_empty()
            && let Some(failure) = verification
        {
            return Err(failure);
        }
        Ok(tracks)
    }

    /// One provider's `searchTracks`. Failures other than cancellation are
    /// logged and skipped; the first one asking for verification is kept so
    /// an empty search can report it.
    #[allow(clippy::too_many_arguments)]
    fn provider_search_tracks(
        &self,
        id: &str,
        query: &str,
        limit: usize,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
        item_id: &str,
        verification: &mut Option<ManagerError>,
    ) -> Result<Vec<Value>, ManagerError> {
        let response = self.provider_operation_value(
            id,
            "searchTracks",
            &json!([query, limit]).to_string(),
            lease.clone(),
            timeout_ms,
            item_id,
        );
        if let Some(lease) = &lease {
            lease.check_active().map_err(|e| error(e.to_string()))?;
        }
        match response {
            Ok(mut response) => Ok(match response["tracks"].take() {
                Value::Array(found) => found,
                _ => Vec::new(),
            }),
            Err(failure) if failure.0 == "download cancelled" => Err(failure),
            Err(failure) => {
                let _ = self.environment.log_buffer().backend(&format!(
                    "[MetadataSearch] Search error from {id}: {failure}"
                ));
                if verification.is_none() && requires_verification(&failure.0) {
                    *verification = Some(error(format!(
                        "verification_required: extension '{id}' needs verification: {failure}"
                    )));
                }
                Ok(Vec::new())
            }
        }
    }
}

fn search_limit(limit: isize) -> usize {
    if limit <= 0 { 20 } else { limit as usize }
}

fn requires_verification(message: &str) -> bool {
    let message = lowercase(message);
    if ["isp blocking", "try using vpn", "change dns", "cancel"]
        .iter()
        .any(|part| message.contains(part))
    {
        return false;
    }
    [
        "verification_required",
        "session is not authenticated",
        "signed session is not authenticated",
        "signed session expired",
    ]
    .iter()
    .any(|part| message.contains(part))
}

fn dedup_key(track: &Value) -> String {
    let field = |name: &str| track[name].as_str().unwrap_or("").trim();
    if !field("isrc").is_empty() {
        format!("isrc:{}", uppercase(field("isrc")))
    } else if !field("spotify_id").is_empty() {
        format!("spotify:{}", field("spotify_id"))
    } else if !field("provider_id").is_empty() && !field("id").is_empty() {
        format!("{}:{}", field("provider_id"), field("id"))
    } else {
        format!("{}|{}", field("name"), field("artists"))
    }
}

// Native inputs use the canonical Go metadata JSON schema, not the aliases
// accepted when reading extension JavaScript results. Every input field is
// present, including zero values omitted from serialized metadata results.
fn track_input(text: &str) -> Result<(Value, Value), ManagerError> {
    let value: Value = serde_json::from_str(text).map_err(|e| cause("invalid track", e))?;
    if value.is_null() {
        return Ok((Value::Null, json!({})));
    }
    let Some(value) = value.as_object() else {
        return Err(error("invalid track: expected object or null"));
    };
    let mut input = Map::new();
    let mut original = Map::new();
    for key in [
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
        "cover_url",
        "preview_url",
        "images",
        "release_date",
        "isrc",
        "provider_id",
        "item_type",
        "album_type",
        "tidal_id",
        "qobuz_id",
        "deezer_id",
        "spotify_id",
        "label",
        "copyright",
        "genre",
        "composer",
        "comment",
        "audio_quality",
        "audio_modes",
        "upc",
    ] {
        let text = match value.get(key).filter(|v| !v.is_null()) {
            None => "",
            Some(value) => value
                .as_str()
                .ok_or_else(|| error(format!("invalid track: {key} must be a string")))?,
        };
        input.insert(key.into(), json!(text));
        if !text.is_empty() || ["id", "name", "artists", "album_name", "provider_id"].contains(&key)
        {
            original.insert(key.into(), json!(text));
        }
    }
    for key in [
        "duration_ms",
        "track_number",
        "total_tracks",
        "disc_number",
        "total_discs",
    ] {
        let integer = match value.get(key).filter(|v| !v.is_null()) {
            None => 0,
            Some(value) => value
                .as_i64()
                .and_then(|value| isize::try_from(value).ok())
                .ok_or_else(|| error(format!("invalid track: {key} must be a native integer")))?,
        };
        input.insert(key.into(), json!(integer));
        if integer != 0 || key == "duration_ms" {
            original.insert(key.into(), json!(integer));
        }
    }
    let explicit = match value.get("explicit").filter(|v| !v.is_null()) {
        None => false,
        Some(value) => value
            .as_bool()
            .ok_or_else(|| error("invalid track: explicit must be a boolean"))?,
    };
    input.insert("explicit".into(), json!(explicit));
    if explicit {
        original.insert("explicit".into(), json!(true));
    }
    let links = value.get("external_links").cloned().unwrap_or(Value::Null);
    if !links.is_null()
        && !links
            .as_object()
            .is_some_and(|links| links.values().all(Value::is_string))
    {
        return Err(error("invalid track: external_links must be a string map"));
    }
    if links.as_object().is_some_and(|links| !links.is_empty()) {
        original.insert("external_links".into(), links.clone());
    }
    // Go's argument adapter copies a typed nil map to an empty JS object.
    input.insert(
        "external_links".into(),
        if links.is_null() { json!({}) } else { links },
    );
    Ok((original.into(), input.into()))
}
