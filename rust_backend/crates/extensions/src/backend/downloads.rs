//! Application download planning. The installed manager owns VMs/transfers;
//! this root owns request lifetime, fallback and publication of regular files.

#[cfg(test)]
mod account_tests;
#[cfg(test)]
mod container_tests;
mod matching;
mod metadata;
mod paths;
mod prepared;
mod result;
#[cfg(test)]
mod tests;

use super::Backend;
use crate::download::native_error_response;
use crate::manager::{ProviderAvailabilityRequest, ProviderDownloadRequest};
use crate::manifest::ExtensionManifest;
use cap_std::fs::OpenOptions;
use mornye_core::cancellation::RequestLease;
use mornye_core::downloads::DownloadRequest;
use mornye_core::metadata::reenrich::text;
use mornye_core::tags::{embed_flac_metadata, extract_cover};
use mornye_providers::resolver::Check;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, VecDeque};
use std::io::{Read, Write};
use std::path::Path;
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

use matching::{matches_track, probe_result};
use metadata::{
    apply_metadata, download_metadata_fields, host_track, preferred_track_id,
    select_download_metadata,
};
use paths::{album_folder, filename, output_path};
use prepared::preparation_key;
use result::{compact, failure, stopped, storage_failure, success};

pub(super) type PreparedDownloads = BTreeMap<String, Prepared>;

pub(super) struct Prepared {
    key: String,
    request: DownloadRequest,
    metadata_ready: bool,
    created: Instant,
}

enum DownloadOutcome {
    Retry(Value),
    // Successful downloads and host finalization failures are both terminal.
    Final(Value),
}

impl Backend {
    /// Go's strategy facade returns a JSON failure, including transport errors
    /// from the extension facade. The latter retains its Result error boundary.
    pub fn download_by_strategy(&self, raw: &str, check: &Check<'_>) -> Result<String, String> {
        let _operation = self.enter()?;
        let request = match DownloadRequest::parse(raw) {
            Ok(request) => request,
            Err(error) => {
                return Ok(native_error_response(&format!("Invalid request: {error}")).to_string());
            }
        };
        if !request.use_extensions {
            return Ok(native_error_response(
                "Extension providers are disabled; built-in download providers have been retired",
            )
            .to_string());
        }
        Ok(self
            .download_request(request, check)
            .unwrap_or_else(|error| native_error_response(&error).to_string()))
    }

    fn download_request(
        &self,
        mut request: DownloadRequest,
        check: &Check<'_>,
    ) -> Result<String, String> {
        request.normalize();
        self.check()?;
        check()?;
        // Descriptor adoption is an application-owner operation. Do not claim
        // a successful regular-file download has written the caller's FD.
        if request.output_fd > 0 {
            return Err(
                "output descriptor ownership is not yet connected to the Rust download planner"
                    .into(),
            );
        }
        self.set_song_link_region(&request.songlink_region)?;
        let state = self.environment().download_state();
        let lease = Arc::new(
            state
                .acquire(&request.item_id)
                .map_err(|error| error.to_string())?,
        );
        lease.check_active().map_err(|error| error.to_string())?;
        let item_id = request.item_id.clone();
        if !item_id.is_empty() {
            state
                .progress
                .start(&item_id)
                .map_err(|error| error.to_string())?;
            state
                .progress
                .preparing(&item_id, "checking_session")
                .map_err(|error| error.to_string())?;
        }
        // One lease reaches availability, auth, VM and file finalization,
        // including requests without an item ID. Join the VM before returning.
        let result = std::thread::scope(|scope| {
            let (finished, completion) = mpsc::sync_channel(1);
            let request_lease = lease.clone();
            let worker = std::thread::Builder::new()
                .name("download-planner".into())
                .spawn_scoped(scope, move || {
                    let result = self.plan_download(request, request_lease);
                    let _ = finished.send(());
                    result
                })
                .map_err(|error| error.to_string())?;
            let mut cancelled = None;
            while !worker.is_finished() {
                if let Err(error) = self.check().and_then(|()| check()) {
                    cancelled = Some(error);
                    lease.release();
                    break;
                }
                // Completion wakes the caller immediately; timeouts retain the
                // owner/caller cancellation heartbeat while work is active.
                if !matches!(
                    completion.recv_timeout(Duration::from_millis(5)),
                    Err(mpsc::RecvTimeoutError::Timeout)
                ) {
                    break;
                }
            }
            let result = worker
                .join()
                .map_err(|_| "download planner panicked".to_owned())?;
            if let Some(error) = cancelled {
                return Err(error);
            }
            self.check()?;
            check()?;
            lease.check_active().map_err(|error| error.to_string())?;
            result
        });
        if !item_id.is_empty() {
            if result
                .as_ref()
                .is_ok_and(|result| result["success"] == true)
            {
                let _ = state.progress.complete(&item_id);
            } else {
                let _ = state.progress.remove(&item_id);
            }
        }
        result.map(|value| compact(value).to_string())
    }

    fn plan_download(
        &self,
        mut request: DownloadRequest,
        lease: Arc<RequestLease>,
    ) -> Result<Value, String> {
        let check = || {
            self.check()
                .and_then(|()| lease.check_active().map_err(|error| error.to_string()))
        };
        let key = preparation_key(&request);
        let session_provider = if request.service.trim().is_empty() {
            request.source.trim()
        } else {
            request.service.trim()
        }
        .to_owned();
        let preflight = self.preflight_download(&session_provider, lease.clone());
        check()?;
        match preflight {
            Ok(true) => {
                self.cache_prepared(&key, &request, false);
                return Ok(failure(
                    &session_provider,
                    "Verification required before download",
                    "verification_required",
                    0,
                ));
            }
            Err(error) => {
                return Ok(failure(
                    &session_provider,
                    &format!("Could not start verification for {session_provider}: {error}"),
                    "",
                    0,
                ));
            }
            Ok(false) => {}
        }
        let prepared = self.take_prepared(&key, &mut request);
        if !request.item_id.is_empty() {
            let _ = self
                .environment()
                .download_state()
                .progress
                .preparing(&request.item_id, "resolving_metadata");
        }
        let mut selected = request.service.trim().to_owned();
        let priorities: Value = serde_json::from_str(
            &self
                .provider_priorities()
                .map_err(|error| error.to_string())?,
        )
        .map_err(|error| error.to_string())?;
        let mut priority: Vec<String> = serde_json::from_value(priorities["download"].clone())
            .map_err(|error| error.to_string())?;
        if !request.use_fallback {
            if selected.is_empty() {
                selected = request.source.trim().to_owned();
            }
            if !selected.is_empty() {
                priority = vec![selected.clone()];
            }
        } else if !request.service.is_empty() {
            priority.retain(|id| !id.eq_ignore_ascii_case(&request.service));
            priority.insert(0, request.service.clone());
        }

        if prepared == Some(false)
            && let Some(response) =
                self.download_verified_retry(&request, &selected, lease.clone())?
        {
            return Ok(response);
        }

        // A source catalog can explicitly prohibit replacing its recording.
        let mut source_availability = None;
        if !request.source.is_empty()
            && selected != request.source
            && self
                .download_manifest(&request.source)
                .is_ok_and(|m| m.has_type("download_provider"))
        {
            let availability = self.download_availability(&request.source, &request, lease.clone());
            check()?;
            if let Ok(availability) = availability
                && availability["skip_fallback"] == true
            {
                selected = request.source.clone();
                source_availability = Some(availability);
            }
        }
        if prepared != Some(true) {
            self.enrich_download_source(&mut request, lease.clone())?;
        }

        let mut last = None;
        let mut attempts = VecDeque::new();
        if !request.source.is_empty() && selected == request.source {
            attempts.push_back((request.source.clone(), true));
        }
        let mut fallback = Some(priority);
        loop {
            if attempts.is_empty() {
                let Some(priority) = fallback.take() else {
                    break;
                };
                let protected = if selected.is_empty() {
                    &request.source
                } else {
                    &selected
                };
                let priority = self.prioritize_healthy_downloads(priority, protected, &selected)?;
                attempts.extend(priority.into_iter().map(|id| (id, false)));
            }
            let Some((id, direct)) = attempts.pop_front() else {
                break;
            };
            check()?;
            if id.is_empty()
                || (!direct && id == request.source && request.source != selected)
                || (!direct
                    && id != selected
                    && !self
                        .fallback_allowed(&id)
                        .map_err(|error| error.to_string())?)
            {
                continue;
            }
            let Ok(manifest) = self.download_manifest(&id) else {
                continue;
            };
            if !manifest.has_type("download_provider") {
                continue;
            }
            let account_mode = self
                .account_download_enabled(&id)
                .map_err(|error| error.to_string())?;
            let availability = if direct {
                source_availability
                    .clone()
                    .unwrap_or_else(|| json!({"available":true}))
            } else {
                let available = self.preflight_download(&id, lease.clone()).map_err(|error| error.to_string())
                    .and_then(|verification| {
                        if verification { Err(format!("verification_required: extension '{id}' needs signed-session verification")) }
                        else { self.download_availability(&id, &request, lease.clone()) }
                    });
                check()?;
                match available {
                    Ok(value) => value,
                    Err(error) => {
                        let response = failure(&id, &error, "", 0);
                        if account_mode {
                            return Ok(response);
                        }
                        if response["error_type"] == "verification_required" {
                            self.cache_prepared(&key, &request, true);
                            return Ok(failure(
                                &id,
                                &format!("Download failed: {error}"),
                                "verification_required",
                                0,
                            ));
                        }
                        last = Some(response);
                        continue;
                    }
                }
            };
            let stop = availability["skip_fallback"] == true || account_mode;
            if availability["available"] != true {
                if stop {
                    return Ok(stopped(&id, &availability, ""));
                }
                continue;
            }
            let track_id = if direct {
                preferred_track_id(&request, &manifest, text(&availability, "track_id"))
            } else {
                text(&availability, "track_id").to_owned()
            };
            let mut attempt = request.clone();
            attempt.download_provider = id.clone();
            attempt.provider_track_id = track_id;
            if !direct {
                attempt.output_ext.clear();
            }
            let outcome =
                self.download_resolved(&attempt, &manifest, &availability, lease.clone())?;
            check()?;
            let response = match outcome {
                DownloadOutcome::Final(response) => return Ok(response),
                DownloadOutcome::Retry(response) => response,
            };
            let message = text(&response, "error");
            let kind = text(&response, "error_type");
            let retry = response["retry_after_seconds"].as_i64().unwrap_or_default();
            if account_mode
                || self
                    .account_download_enabled(&id)
                    .map_err(|error| error.to_string())?
            {
                return Ok(failure(
                    &id,
                    &format!("Download failed: {message}"),
                    kind,
                    retry,
                ));
            }
            if kind == "verification_required" {
                self.cache_prepared(&key, &request, true);
                return Ok(failure(
                    &id,
                    &format!("Download failed: {message}"),
                    kind,
                    retry,
                ));
            }
            if storage_failure(kind, message) {
                return Ok(failure(
                    &id,
                    &format!("Download failed: {message}"),
                    "permission",
                    retry,
                ));
            }
            if stop {
                return Ok(stopped(&id, &availability, message));
            }
            if direct && manifest.stops_provider_fallback() {
                return Ok(failure(
                    &id,
                    &format!("Download failed: {message}"),
                    kind,
                    retry,
                ));
            }
            last = Some(response);
        }
        check()?;
        Ok(match last {
            Some(last) => failure(
                text(&last, "service"),
                &format!("All providers failed. Last error: {}", text(&last, "error")),
                if text(&last, "error_type") == "unknown" {
                    "not_found"
                } else {
                    text(&last, "error_type")
                },
                last["retry_after_seconds"].as_i64().unwrap_or_default(),
            ),
            None => failure(
                "",
                "No extension download providers available",
                "not_found",
                0,
            ),
        })
    }

    /// A preflight challenge can be satisfied without consulting optional
    /// metadata providers again. A different download source still gets its
    /// normal opportunity to prohibit fallback before any selected download.
    fn download_verified_retry(
        &self,
        request: &DownloadRequest,
        selected: &str,
        lease: Arc<RequestLease>,
    ) -> Result<Option<Value>, String> {
        if selected.is_empty()
            || (!request.source.is_empty()
                && !request.source.eq_ignore_ascii_case(selected)
                && self
                    .download_manifest(&request.source)
                    .is_ok_and(|manifest| manifest.has_type("download_provider")))
        {
            return Ok(None);
        }
        let Ok(manifest) = self.download_manifest(selected) else {
            return Ok(None);
        };
        if !manifest.has_type("download_provider") {
            return Ok(None);
        }
        let direct = request.source.eq_ignore_ascii_case(selected);
        let availability = if direct {
            json!({"available":true})
        } else {
            let result = self.download_availability(selected, request, lease.clone());
            lease.check_active().map_err(|error| error.to_string())?;
            match result {
                Ok(value) => value,
                Err(error) => {
                    let response = failure(selected, &format!("Download failed: {error}"), "", 0);
                    return Ok(
                        (response["error_type"] == "verification_required").then_some(response)
                    );
                }
            }
        };
        if availability["available"] != true {
            return Ok((availability["skip_fallback"] == true)
                .then(|| stopped(selected, &availability, "")));
        }
        let mut attempt = request.clone();
        attempt.download_provider = selected.into();
        attempt.provider_track_id =
            preferred_track_id(request, &manifest, text(&availability, "track_id"));
        if !direct {
            attempt.output_ext.clear();
        }
        let outcome = self.download_resolved(&attempt, &manifest, &availability, lease.clone())?;
        lease.check_active().map_err(|error| error.to_string())?;
        let response = match outcome {
            DownloadOutcome::Final(response) => return Ok(Some(response)),
            DownloadOutcome::Retry(response) => response,
        };
        let message = text(&response, "error");
        let kind = text(&response, "error_type");
        let retry = response["retry_after_seconds"].as_i64().unwrap_or_default();
        if kind == "verification_required" || storage_failure(kind, message) {
            return Ok(Some(failure(
                selected,
                &format!("Download failed: {message}"),
                if kind == "verification_required" {
                    kind
                } else {
                    "permission"
                },
                retry,
            )));
        }
        // Ordinary failures may recover after source enrichment supplies a
        // better native track ID. Preserve the normal strict/fallback path.
        Ok(None)
    }

    fn download_resolved(
        &self,
        request: &DownloadRequest,
        manifest: &ExtensionManifest,
        availability: &Value,
        lease: Arc<RequestLease>,
    ) -> Result<DownloadOutcome, String> {
        let source = [&request.service, &request.source]
            .into_iter()
            .filter_map(|id| self.download_manifest(id.trim()).ok())
            .find(|manifest| manifest.find_quality(request.quality.trim()).is_some());
        let quality = match manifest.resolve_download_quality(&request.quality, source.as_ref()) {
            Ok(quality) => quality,
            Err(error) => {
                self.log_provider_failure(&request.download_provider, "quality selection", &error);
                return Ok(DownloadOutcome::Retry(failure(
                    &request.download_provider,
                    &error,
                    "quality_unavailable",
                    0,
                )));
            }
        };
        let mut attempt = request.clone();
        attempt.quality = quality;
        let outcome = self.download_attempt(&attempt, manifest, availability, lease)?;
        if let DownloadOutcome::Retry(response) = &outcome {
            self.log_provider_failure(
                &request.download_provider,
                "download",
                text(response, "error"),
            );
        }
        Ok(outcome)
    }

    fn download_availability(
        &self,
        id: &str,
        request: &DownloadRequest,
        lease: Arc<RequestLease>,
    ) -> Result<Value, String> {
        let input = ProviderAvailabilityRequest {
            isrc: request.isrc.clone(),
            track_name: request.track_name.clone(),
            artist_name: request.artist_name.clone(),
            spotify_id: request.spotify_id.clone(),
            deezer_id: request.deezer_id.clone(),
            tidal_id: request.tidal_id.clone(),
            qobuz_id: request.qobuz_id.clone(),
            duration_ms: request.duration_ms as isize,
            item_id: request.item_id.clone(),
            track: host_track(request).as_object().cloned(),
        };
        let result = self
            .check_availability_with_lease(id, input, 30_000, Some(lease))
            .map_err(|error| error.to_string())
            .and_then(|raw| serde_json::from_str::<Value>(&raw).map_err(|error| error.to_string()));
        match &result {
            Ok(value) if value["available"] != true => {
                self.log_provider_failure(id, "availability", text(value, "reason"));
            }
            Err(error) => self.log_provider_failure(id, "availability", error),
            _ => {}
        }
        result
    }

    fn log_provider_failure(&self, id: &str, stage: &str, reason: &str) {
        let reason = if reason.trim().is_empty() {
            "no reason supplied"
        } else {
            reason
        };
        let _ = self.environment().log_buffer().add(
            "WARN",
            "DownloadPlanner",
            &format!("Provider {id} failed during {stage}: {reason}"),
        );
    }

    fn enrich_download_source(
        &self,
        request: &mut DownloadRequest,
        lease: Arc<RequestLease>,
    ) -> Result<(), String> {
        if request.source.is_empty() {
            return Ok(());
        }
        if self
            .download_manifest(&request.source)
            .is_ok_and(|manifest| manifest.has_type("metadata_provider"))
        {
            let mut input = host_track(request);
            input["id"] = request.spotify_id.clone().into();
            for (key, value) in [
                ("provider_id", &request.source),
                ("spotify_id", &request.spotify_id),
                ("tidal_id", &request.tidal_id),
                ("qobuz_id", &request.qobuz_id),
                ("deezer_id", &request.deezer_id),
            ] {
                input[key] = value.clone().into();
            }
            let result = self.enrich_track_with_lease(
                &request.source,
                &input.to_string(),
                &request.item_id,
                30_000,
                Some(lease.clone()),
            );
            lease.check_active().map_err(|error| error.to_string())?;
            if let Ok(raw) = result
                && let Ok(track) = serde_json::from_str::<Value>(&raw)
            {
                apply_metadata(request, &track, true);
            }
        }
        if !request.track_name.is_empty()
            && !request.artist_name.is_empty()
            && (request.album_name.is_empty()
                || request.release_date.is_empty()
                || request.isrc.is_empty())
        {
            let result = self.search_metadata_providers_with_lease(
                &format!("{} {}", request.track_name, request.artist_name),
                5,
                true,
                &request.item_id,
                30_000,
                Some(lease.clone()),
            );
            lease.check_active().map_err(|error| error.to_string())?;
            if let Ok(raw) = result
                && let Ok(tracks) = serde_json::from_str::<Vec<Value>>(&raw)
                && let Some(track) = select_download_metadata(request, &tracks)
            {
                apply_metadata(request, track, false);
            }
        }
        Ok(())
    }

    fn download_attempt(
        &self,
        request: &DownloadRequest,
        manifest: &ExtensionManifest,
        availability: &Value,
        lease: Arc<RequestLease>,
    ) -> Result<DownloadOutcome, String> {
        let check = || {
            self.check()
                .and_then(|()| lease.check_active().map_err(|error| error.to_string()))
        };
        let environment = self.environment();
        let files = environment.native_files()?;
        let directory = environment
            .data_directory()
            .join(&manifest.name)
            .join("downloads");
        let path = output_path(request, &directory, &request.album_name, &check)?;
        let output = files.resolve_legacy(&path)?;
        output.native_display()?;
        let guard = files.lock(&output, &check)?;
        // The output lock also owns this destination's attempt directories.
        // Reclaim only that namespace after a process restart, including when
        // a complete file already exists but its finalizer still needs to run.
        let staging_prefix = format!(
            ".mornye-download-{}-",
            crate::binary::encode(
                &Sha256::digest(output.display().to_lowercase().as_bytes()),
                "hex"
            )
            .expect("hex encoding")
        );
        if directory.exists() {
            for entry in directory.read_dir().map_err(|error| error.to_string())? {
                check()?;
                let entry = entry.map_err(|error| error.to_string())?;
                if entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(&staging_prefix)
                    && entry
                        .file_type()
                        .map_err(|error| error.to_string())?
                        .is_dir()
                {
                    std::fs::remove_dir_all(entry.path()).map_err(|error| error.to_string())?;
                }
            }
        }
        if !request.allow_quality_variant
            && (request.album_folder_template.is_empty()
                || !album_folder(request, &request.album_name).is_empty())
            && output
                .metadata()
                .is_ok_and(|metadata| metadata.is_file() && metadata.len() > 0)
        {
            let mut result = json!({"file_path":path});
            probe_result(&files, &mut result, false, &check)?;
            let mut response = success(request, &result, &path, true, manifest, &check)?;
            response
                .as_object_mut()
                .unwrap()
                .remove("skip_metadata_enrichment");
            return Ok(DownloadOutcome::Final(response));
        }
        // Give the extension its own temporary directory. A mismatched track,
        // failed provider or cancellation can never overwrite an old library file.
        let temporary_parent =
            files.resolve_legacy(&directory.join(".parent").to_string_lossy())?;
        temporary_parent.native_display()?;
        temporary_parent
            .mkdir_parent()
            .map_err(|error| format!("failed to create directory: {error}"))?;
        let temporary = tempfile::Builder::new()
            .prefix(&staging_prefix)
            .tempdir_in(&directory)
            .map_err(|error| format!("failed to create directory: {error}"))?;
        let _grant = environment.grant_temporary_download_directory(temporary.path())?;
        let name = filename(request, &request.output_ext, &check)?;
        let staging_path = temporary.path().join(name).to_string_lossy().into_owned();
        let mut prepared = availability["prepared_context"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        prepared.insert("host_track".into(), host_track(request));
        if !request.item_id.is_empty() {
            let _ = environment
                .download_state()
                .progress
                .preparing(&request.item_id, "resolving_stream");
        }
        let response = self.download_with_lease(
            &manifest.name,
            ProviderDownloadRequest {
                track_id: request.provider_track_id.clone(),
                quality: request.quality.clone(),
                output_path: staging_path,
                item_id: request.item_id.clone(),
                prepared_context: Some(prepared),
            },
            60_000,
            Some(lease.clone()),
        );
        check()?;
        let mut result: Value = match response {
            Ok(raw) => serde_json::from_str(&raw).map_err(|error| error.to_string())?,
            Err(error) => {
                return Ok(DownloadOutcome::Retry(failure(
                    &manifest.name,
                    &error.to_string(),
                    "",
                    0,
                )));
            }
        };
        if result["success"] != true {
            let message = if text(&result, "error_message").is_empty() {
                "extension download failed without an error message"
            } else {
                text(&result, "error_message")
            };
            let kind = text(&result, "error_type").trim();
            let classified = native_error_response(message);
            let kind = if matches!(
                kind.to_ascii_lowercase().as_str(),
                "" | "unknown"
                    | "runtime_error"
                    | "api_error"
                    | "download_error"
                    | "extension_error"
            ) && classified["error_type"] != "unknown"
            {
                text(&classified, "error_type")
            } else if kind.is_empty() {
                "extension_error"
            } else {
                kind
            };
            return Ok(DownloadOutcome::Retry(failure(
                &manifest.name,
                message,
                kind,
                result["retry_after_seconds"].as_i64().unwrap_or_default(),
            )));
        }
        let skip_names = request.source.trim().eq_ignore_ascii_case(&manifest.name)
            || manifest
                .track_matching
                .as_ref()
                .is_some_and(|matching| matching.custom_matching);
        if !matches_track(request, &result, skip_names) {
            return Ok(DownloadOutcome::Retry(failure(
                &manifest.name,
                &format!("provider {} returned a different track", manifest.name),
                "not_found",
                0,
            )));
        }
        let returned = text(&result, "file_path").trim();
        let already_exists = result["already_exists"] == true || returned.starts_with("EXISTS:");
        let returned = returned
            .strip_prefix("EXISTS:")
            .unwrap_or(returned)
            .to_owned();
        let input = files.resolve_legacy(&returned)?;
        input.native_display()?;
        if !already_exists
            && !crate::files::clean(Path::new(&returned)).starts_with(temporary.path())
        {
            return Ok(DownloadOutcome::Retry(failure(
                &manifest.name,
                "provider output is outside its download staging directory",
                "file_error",
                0,
            )));
        }
        if !input
            .metadata()
            .is_ok_and(|metadata| metadata.is_file() && metadata.len() > 0)
        {
            return Ok(DownloadOutcome::Retry(failure(
                &manifest.name,
                "provider returned no audio file",
                "file_error",
                0,
            )));
        }
        result["file_path"] = returned.clone().into();
        let mut enriched = request.clone();
        if !manifest.skip_metadata_enrichment {
            self.enrich_download_extended(&mut enriched, &check)?;
        }
        let request = &enriched;
        let container = probe_result(
            &files,
            &mut result,
            request.album_name.trim().is_empty()
                && request.album_folder_template.contains("{album}"),
            &check,
        )?;
        if already_exists {
            return success(request, &result, &returned, true, manifest, &check)
                .map(DownloadOutcome::Final);
        }
        let mut response = success(request, &result, &path, false, manifest, &check)?;
        if text(&response, "actual_extension") == ".flac" && container != "flac" {
            // Unrecognized bytes behind a FLAC label, such as an error page,
            // cannot take FLAC tags. Another provider may return real audio.
            return Ok(DownloadOutcome::Retry(failure(
                &manifest.name,
                &format!(
                    "provider {} returned a file that is not FLAC audio",
                    manifest.name
                ),
                "file_error",
                0,
            )));
        }
        if !request.item_id.is_empty() {
            let _ = environment
                .download_state()
                .progress
                .finalizing(&request.item_id);
        }

        let mut resolved = request.clone();
        resolved.output_ext = text(&response, "actual_extension").to_owned();
        if !request.output_path.is_empty() {
            // SAF uses a local working path too. Keep its directory and stem,
            // but use the provider's actual container before final publication.
            resolved.output_path = Path::new(&request.output_path)
                .with_extension(resolved.output_ext.trim_start_matches('.'))
                .to_string_lossy()
                .into_owned();
        }
        let final_path = output_path(&resolved, &directory, text(&response, "album"), &check)?;
        // Keep the original lock for an unchanged destination. Release it
        // before acquiring a different path lock to avoid lock-order cycles.
        let destination = files.resolve_legacy(&final_path)?;
        destination.native_display()?;
        let _guard = if final_path == path {
            guard
        } else {
            drop(guard);
            files.lock(&destination, &check)?
        };
        if final_path != path && destination.metadata().is_ok() {
            return Ok(DownloadOutcome::Final(failure(
                &manifest.name,
                &format!("resolve album folder: open {final_path}: file exists"),
                "file_error",
                0,
            )));
        }
        let mut source = input
            .open(OpenOptions::new().read(true))
            .map_err(|error| error.to_string())?;
        let info = source.metadata().map_err(|error| error.to_string())?;
        if !info.is_file() || info.len() == 0 {
            return Err("provider returned no audio file".into());
        }
        // ReplayGain, decryption/conversion, external LRC and extension hooks
        // are executed by the existing Android/Dart finalizers. This is the
        // Go backend's local FLAC embed step; provider lyrics are reused.
        let embed = request.embed_metadata && resolved.output_ext == ".flac";
        let cover = if embed {
            let url = [request.cover_url.as_str(), text(&response, "cover_url")]
                .into_iter()
                .map(str::trim)
                .find(|url| !url.is_empty())
                .unwrap_or_default();
            if url.is_empty() {
                None
            } else {
                self.cover
                    .download(url, request.cover_max_dimension, &check)
                    .ok()
            }
        } else {
            None
        };
        check()?;
        let (mut staged, promoted) = if embed {
            destination.stage().map(|stage| (stage, false))
        } else {
            destination.stage_from(&input, &source)
        }
        .map_err(|error| format!("failed to create file: {error}"))?;
        if embed {
            let cover = cover.as_deref().filter(|bytes| !bytes.is_empty());
            embed_flac_metadata(
                &mut source,
                &mut staged.file,
                &download_metadata_fields(request, &response),
                &request.artist_tag_mode,
                cover,
                &check,
            )?;
            if cover.is_some()
                && extract_cover(&mut staged.file, "flac", &check)?
                    .data
                    .is_empty()
            {
                return Err(
                    "metadata embedded but cover verification failed: empty embedded cover".into(),
                );
            }
        } else if !promoted {
            let mut buffer = [0_u8; 65536];
            loop {
                check()?;
                let size = source
                    .read(&mut buffer)
                    .map_err(|error| error.to_string())?;
                if size == 0 {
                    break;
                }
                staged
                    .file
                    .write_all(&buffer[..size])
                    .map_err(|error| error.to_string())?;
            }
        }
        if final_path != path {
            if let Err(error) = staged.publish_new(&check) {
                check()?;
                let message = if error.kind() == std::io::ErrorKind::AlreadyExists {
                    format!("resolve album folder: open {final_path}: file exists")
                } else {
                    format!("resolve album folder: {error}")
                };
                return Ok(DownloadOutcome::Final(failure(
                    &manifest.name,
                    &message,
                    "file_error",
                    0,
                )));
            }
        } else {
            staged.publish(&check)?;
        }
        response["file_path"] = final_path.clone().into();
        if !request.output_dir.is_empty() && !text(&response, "isrc").trim().is_empty() {
            // Shared index only; never build a planner-specific cache.
            environment
                .invalidate_isrc_cache(&request.output_dir)
                .map_err(|error| error.to_string())?;
            environment
                .add_to_isrc_index(
                    destination
                        .absolute
                        .parent()
                        .unwrap_or(Path::new("."))
                        .to_string_lossy()
                        .as_ref(),
                    text(&response, "isrc").trim(),
                    &final_path,
                    &check,
                )
                .map_err(|error| error.to_string())?;
        }
        Ok(DownloadOutcome::Final(response))
    }

    fn enrich_download_extended(
        &self,
        request: &mut DownloadRequest,
        check: &Check<'_>,
    ) -> Result<(), String> {
        if request.isrc.is_empty() {
            return Ok(());
        }
        let needs_artist = request.album_artist.trim().is_empty();
        let needs_tags =
            request.genre.is_empty() || request.label.is_empty() || request.copyright.is_empty();
        let artist = || {
            self.fetch_music_brainz_album_artist_by_isrc(&request.isrc, &request.album_name, check)
        };
        let tags = || {
            self.metadata_operation(10, check, |check| {
                self.deezer
                    .get_extended_metadata_by_isrc(request.isrc.trim(), check)
            })
        };
        // These lookups are independent. Join the extra worker before returning
        // so cancellation and owner shutdown still cover both requests.
        let (artist, metadata) = if needs_artist && needs_tags && !request.isrc.trim().is_empty() {
            std::thread::scope(|scope| {
                let worker = std::thread::Builder::new()
                    .name("download-album-artist".into())
                    .spawn_scoped(scope, artist);
                let Ok(worker) = worker else {
                    let artist = artist();
                    check()?;
                    return Ok((Some(artist), Some(tags())));
                };
                let metadata = tags();
                let artist = worker
                    .join()
                    .map_err(|_| "album artist lookup panicked".to_owned())?;
                Ok::<_, String>((Some(artist), Some(metadata)))
            })?
        } else {
            let artist = needs_artist.then(artist);
            check()?;
            let metadata = (needs_tags && !request.isrc.trim().is_empty()).then(tags);
            (artist, metadata)
        };
        check()?;
        if let Some(Ok(artist)) = artist
            && !artist.trim().is_empty()
        {
            request.album_artist = artist.trim().into();
        }
        if let Some(metadata) = metadata {
            if let Ok(metadata) = metadata {
                for (target, value) in [
                    (&mut request.genre, &metadata.genre),
                    (&mut request.label, &metadata.label),
                    (&mut request.copyright, &metadata.copyright),
                ] {
                    if target.is_empty() {
                        *target = value.clone();
                    }
                }
            }
            if request.genre.is_empty() {
                let genre = self.fetch_music_brainz_genre_by_isrc(request.isrc.trim(), check);
                check()?;
                if let Ok(genre) = genre {
                    request.genre = genre;
                }
            }
        }
        check()
    }
}
