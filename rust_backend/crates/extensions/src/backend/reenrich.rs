//! Backend re-enrichment of an existing audio file with fresh metadata, cover art, and lyrics.

use super::{Backend, LyricsRequest};
use cap_std::fs::OpenOptions;
use mornye_core::lyrics::{file, lrc};
use mornye_core::metadata::TrackMetadata;
use mornye_core::metadata::reenrich::{self, Request, text};
use mornye_core::tags::{embed_flac_metadata, extract_cover};
use mornye_providers::deezer::MetadataLookup;
use mornye_providers::resolver::{Check, availability};
use serde_json::{Value, json};
use std::io::Write;
use std::sync::Mutex;

#[cfg(test)]
mod tests;

impl Backend {
    /// Execute FLAC enrichment or return the existing native FFmpeg plan.
    /// Returned cover files belong to the caller, which removes them after use.
    pub fn reenrich_file(&self, request_json: &str, check: &Check<'_>) -> Result<String, String> {
        let _operation = self.enter()?;
        let failure = Mutex::new(None::<String>);
        let check = || {
            if let Some(error) = failure.lock().expect("reenrich cancellation lock").as_ref() {
                return Err(error.clone());
            }
            self.check().and_then(|()| check()).inspect_err(|error| {
                *failure.lock().expect("reenrich cancellation lock") = Some(error.clone());
            })
        };
        check()?;
        let request = self.resolve_reenrich_request(request_json, &check)?;
        let enriched = request.result_metadata();
        if request.preview_only {
            return Ok(json!({"method":"preview","success":true,
                "enriched_metadata":enriched})
            .to_string());
        }
        let files = self.environment().native_files()?;
        files.resolve_legacy(&request.file_path)?.native_display()?;
        let is_flac = request.file_path.to_ascii_lowercase().ends_with(".flac");
        let wants_cover = !request.cover_url.is_empty() && request.selected("cover", "cover");
        let fetch_cover = || {
            if wants_cover {
                self.cover
                    .download(
                        &request.cover_url,
                        request.cover_max_dimension as i64,
                        &check,
                    )
                    .ok()
            } else {
                None
            }
        };
        let fetch_lyrics = || -> Result<(String, &str), String> {
            // Fetches and existing lyrics are best-effort; cancellation is not.
            check()?;
            let mut lyrics = String::new();
            let mut status = "not_requested";
            if request.selected("lyrics", "lyrics") {
                if let Ok(existing) = file::extract(
                    &request.file_path,
                    &|path| {
                        files
                            .resolve_legacy(path)?
                            .open(OpenOptions::new().read(true))
                            .map_err(|error| error.to_string())
                    },
                    &check,
                ) && lrc::has_usable_content(&existing)
                {
                    lyrics = existing;
                }
                check()?;
                if request.embed_lyrics {
                    status = if lyrics.is_empty() {
                        "not_found"
                    } else {
                        "preserved"
                    };
                    let query = LyricsRequest {
                        spotify_id: request.spotify_id.clone(),
                        track: request.track_name.clone(),
                        artist: request.artist_name.clone(),
                        duration_ms: request.duration_ms,
                        ..LyricsRequest::default()
                    };
                    if let Ok(response) = self.fetch_lyrics(&query, &check) {
                        if response.instrumental {
                            // Preserve real existing lyrics if a provider disagrees.
                            // Otherwise persist the marker used by the offline player.
                            if lyrics.is_empty() || lrc::is_instrumental_marker(&lyrics) {
                                lyrics = "[instrumental:true]".into();
                                status = "instrumental";
                            }
                        } else {
                            let fetched =
                                lrc::with_metadata(&response, &query.track, &query.artist);
                            if lrc::has_usable_content(&fetched) {
                                lyrics = fetched;
                                status = "updated";
                            }
                        }
                    }
                    check()?;
                } else {
                    status = "disabled";
                }
            }
            Ok((lyrics, status))
        };
        let (cover, (lyrics, lyrics_status)) = std::thread::scope(|scope| {
            let worker = (wants_cover && request.selected("lyrics", "lyrics")).then(|| {
                std::thread::Builder::new()
                    .name("reenrich-cover".into())
                    .spawn_scoped(scope, fetch_cover)
            });
            let lyrics = fetch_lyrics();
            let cover = match worker {
                Some(Ok(worker)) => worker
                    .join()
                    .map_err(|_| "cover worker panicked".to_owned())?,
                _ => fetch_cover(),
            };
            check()?;
            Ok::<_, String>((cover, lyrics?))
        })?;
        let metadata = request.write_metadata(&lyrics);
        let external = request.write_external_lrc(&lyrics);
        if is_flac {
            let cover = cover.as_deref().filter(|data| !data.is_empty());
            let prefix = if cover.is_some() {
                "failed to embed metadata with cover"
            } else {
                "failed to embed metadata"
            };
            self.rewrite_tag_file(&request.file_path, &check, |source, output, _| {
                embed_flac_metadata(
                    source,
                    output,
                    &metadata,
                    &request.artist_tag_mode,
                    cover,
                    &check,
                )
                .map_err(|error| format!("{prefix}: {error}"))?;
                // Verify the staged result before replacing the user's audio.
                if cover.is_some() {
                    let picture = extract_cover(output, "flac", &check).map_err(|error| {
                        format!("metadata embedded but cover verification failed: {error}")
                    })?;
                    if picture.data.is_empty() {
                        return Err(
                            "metadata embedded but cover verification failed: empty embedded cover"
                                .into(),
                        );
                    }
                }
                Ok(true)
            })
            .map_err(|error| {
                if error.starts_with("failed to embed metadata")
                    || error.starts_with("metadata embedded")
                {
                    error
                } else {
                    format!("{prefix}: {error}")
                }
            })?;
            return Ok(
                json!({"method":"native","success":true,"enriched_metadata":enriched,
                "lyrics":lyrics,"lyrics_status":lyrics_status,"write_external_lrc":external})
                .to_string(),
            );
        }

        let temporary = cover.as_deref().and_then(|data| {
            let write = || -> Result<tempfile::NamedTempFile, String> {
                let mut file = tempfile::Builder::new()
                    .prefix("reenrich_cover_")
                    .suffix(".jpg")
                    .tempfile_in(self.environment().data_directory())
                    .map_err(|error| error.to_string())?;
                for chunk in data.chunks(65536) {
                    check()?;
                    file.write_all(chunk).map_err(|error| error.to_string())?;
                }
                file.as_file()
                    .sync_all()
                    .map_err(|error| error.to_string())?;
                Ok(file)
            };
            write().ok()
        });
        check()?;
        let cover_path = if let Some(file) = &temporary {
            files
                .resolve_legacy(&file.path().to_string_lossy())?
                .native_display()?
        } else {
            String::new()
        };
        let result = json!({"method":"ffmpeg","cover_path":cover_path,"lyrics":lyrics,"lyrics_status":lyrics_status,
            "enriched_metadata":enriched,"metadata":metadata,"write_external_lrc":external})
        .to_string();
        check()?;
        if let Some(file) = temporary {
            file.keep().map_err(|error| error.to_string())?;
        }
        Ok(result)
    }

    fn resolve_reenrich_request(
        &self,
        request_json: &str,
        check: &Check<'_>,
    ) -> Result<Request, String> {
        let mut request = Request::parse(request_json)
            .map_err(|error| format!("failed to parse request: {error}"))?;
        if request.file_path.is_empty() {
            return Err("file_path is required".into());
        }
        if request.search_online {
            let mut found = false;
            let catalog_track = self.reenrich_identifiers(&request, &check);
            if let Some(track) = &catalog_track {
                request.apply(&reenrich::from_catalog(track));
                found = true;
            }
            check()?;
            let query = request.query();
            if !query.is_empty() {
                let tracks = self.metadata_provider_work_result(&check, |lease| {
                    self.manager.search_metadata_providers_value_with_lease(
                        &query,
                        5,
                        true,
                        "",
                        30_000,
                        Some(lease),
                    )
                });
                check()?;
                if let Ok(tracks) = tracks
                    && let Some(tracks) = tracks.as_array()
                    && let Some(track) = request.select(tracks)
                {
                    let mut track = track.clone();
                    if request.selected("cover", "cover") && request.same_release(&track) {
                        if let Some(video) = self.reenrich_motion_artwork(&request, &track, &check)
                        {
                            track["header_video"] = video.into();
                        }
                        check()?;
                    }
                    request.apply(&track);
                    found = true;
                }
            }
            if request.selected("basic_tags", "album_artist")
                && request.album_artist.is_empty()
                && !request.isrc.is_empty()
            {
                let artist = self.fetch_music_brainz_album_artist_by_isrc(
                    &request.isrc,
                    &request.album_name,
                    &check,
                );
                check()?;
                if let Ok(artist) = artist
                    && !artist.trim().is_empty()
                {
                    request.album_artist = artist.trim().into();
                    found = true;
                }
            }
            if found
                && !request.isrc.is_empty()
                && request.any_selected("extra", &["genre", "label", "copyright"])
                && (request.genre.is_empty()
                    || request.label.is_empty()
                    || request.copyright.is_empty())
            {
                let isrc = request.isrc.trim();
                if !isrc.is_empty() {
                    let extended = self.metadata_operation(10, &check, |check| {
                        if let Some(track) = catalog_track
                            .as_ref()
                            .filter(|track| track.isrc.trim().eq_ignore_ascii_case(isrc))
                        {
                            return self.deezer.get_extended_metadata_for_track(track, check);
                        }
                        self.deezer.get_extended_metadata_by_isrc(isrc, check)
                    });
                    check()?;
                    if let Ok(extended) = extended {
                        for (target, value) in [
                            (&mut request.genre, &extended.genre),
                            (&mut request.label, &extended.label),
                            (&mut request.copyright, &extended.copyright),
                        ] {
                            if target.is_empty() && !value.is_empty() {
                                *target = value.clone();
                            }
                        }
                    }
                    if request.genre.is_empty() {
                        let genre = self.fetch_music_brainz_genre_by_isrc(isrc, &check);
                        check()?;
                        if let Ok(genre) = genre
                            && !genre.is_empty()
                        {
                            request.genre = genre;
                        }
                    }
                }
            }
        }
        check()?;
        Ok(request)
    }

    /// Album editorial video is optional and never becomes an embedded cover.
    fn reenrich_motion_artwork(
        &self,
        request: &Request,
        track: &Value,
        check: &Check<'_>,
    ) -> Option<String> {
        if !text(track, "header_video").trim().is_empty() {
            return Some(text(track, "header_video").trim().into());
        }
        let provider = text(track, "provider_id").trim();
        if provider.is_empty() {
            return None;
        }
        let mut album_id = text(track, "album_id").trim().to_owned();
        if album_id.is_empty() {
            let id = text(track, "id").trim();
            if id.is_empty() {
                return None;
            }
            let raw = self
                .get_provider_metadata_json(provider, "track", id, check)
                .ok()?;
            let details: Value = serde_json::from_str(&raw).ok()?;
            let track = details.get("track")?;
            if !request.verified(track) || !request.same_release(track) {
                return None;
            }
            if !text(track, "header_video").trim().is_empty() {
                return Some(text(track, "header_video").trim().into());
            }
            album_id = text(track, "album_id").trim().into();
        }
        if album_id.is_empty() {
            return None;
        }
        let raw = self
            .get_provider_metadata_json(provider, "album", &album_id, check)
            .ok()?;
        let details: Value = serde_json::from_str(&raw).ok()?;
        let album = details.get("album_info").or_else(|| details.get("album"))?;
        let identity = json!({"album_name": text(album, "name")});
        if !request.same_release(&identity) {
            return None;
        }
        let video = text(album, "header_video").trim();
        (!video.is_empty()).then(|| video.into())
    }

    fn reenrich_identifiers(&self, request: &Request, check: &Check<'_>) -> Option<TrackMetadata> {
        let isrc = request.isrc.trim();
        if !isrc.is_empty() {
            let track =
                self.metadata_operation(10, check, |check| self.deezer.search_by_isrc(isrc, check));
            if check().is_err() {
                return None;
            }
            if let Ok(track) = track
                && request.verified(&reenrich::from_catalog(&track))
            {
                return Some(track);
            }
        }
        let source = request.spotify_id.trim();
        if source.is_empty() {
            return None;
        }
        let mut deezer_id = source
            .strip_prefix("deezer:")
            .unwrap_or(source)
            .trim()
            .to_owned();
        if deezer_id == source {
            deezer_id = availability::deezer_id_from_url(source);
        }
        if deezer_id.is_empty() {
            let mut spotify_id = availability::spotify_id_from_url(source);
            if spotify_id.is_empty() && source.len() == 22 && !source.contains([':', '/']) {
                spotify_id = source.into();
            }
            if !spotify_id.is_empty() {
                if let Ok(id) = self.get_deezer_id_from_spotify(&spotify_id, check) {
                    deezer_id = id.trim().into();
                }
                if check().is_err() {
                    return None;
                }
            }
        }
        if deezer_id.is_empty() {
            return None;
        }
        let track = self
            .metadata_operation(15, check, |check| self.deezer.get_track(&deezer_id, check))
            .ok()?;
        request
            .verified(&reenrich::from_catalog(&track))
            .then_some(track)
    }
}
