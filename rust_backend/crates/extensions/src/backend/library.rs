//! Backend operations for local library files: audio metadata reads and CUE sheet parsing and scanning.

use super::Backend;
use cap_std::fs::OpenOptions;
use chrono::{SecondsFormat, Utc};
use mornye_core::cue::{self, CueSheet};
use mornye_core::tags::{
    extract_cover, library_extension, library_id, library_metadata, read_library_metadata,
    read_library_metadata_with_cover,
};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::path::Path;
use std::time::UNIX_EPOCH;

mod scan;
pub(super) use scan::ScanState;

impl Backend {
    pub fn set_library_cover_cache_directory(&self, directory: &str) -> Result<(), String> {
        let _operation = self.enter()?;
        if !directory.is_empty() {
            self.environment()
                .native_files()?
                .resolve_legacy(directory)?
                .native_display()?;
        }
        *self
            .library_cover_directory
            .lock()
            .expect("library cover directory lock") = directory.into();
        Ok(())
    }

    pub fn read_audio_metadata(
        &self,
        path: &str,
        hint: &str,
        cache_key: &str,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<Value, String> {
        let _operation = self.enter()?;
        let failure = RefCell::new(None::<String>);
        let check = || {
            if let Some(error) = failure.borrow().as_ref() {
                return Err(error.clone());
            }
            self.check().and_then(|()| check()).inspect_err(|error| {
                *failure.borrow_mut() = Some(error.clone());
            })
        };
        check()?;
        let files = self.environment().native_files()?;
        self.scan_audio_file(&files, path, hint, cache_key, &scan_time(), 0, None, &check)
    }

    #[allow(clippy::too_many_arguments)]
    fn scan_audio_file(
        &self,
        files: &crate::files::ExtensionFiles,
        path: &str,
        hint: &str,
        cache_key: &str,
        scan_time: &str,
        mod_time: i64,
        covers: Option<&crate::files::SyncBatch>,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<Value, String> {
        check()?;
        let input = files.resolve_legacy(path)?;
        let mut file = match input.open_native_read() {
            Ok(file) => Some(file),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(error.to_string()),
        };
        let mod_time = if mod_time > 0 {
            mod_time
        } else {
            modified(&input)
        };
        let mut metadata = None;
        let directory = self
            .library_cover_directory
            .lock()
            .expect("library cover directory lock")
            .clone();
        let cover = if directory.is_empty() {
            None
        } else {
            self.save_cover_to_cache_for_scan(
                path,
                hint,
                &directory,
                cache_key,
                |_, format, check| {
                    let file = file.as_mut().ok_or("audio file unavailable")?;
                    if format == "flac" {
                        let (tags, cover) = read_library_metadata_with_cover(
                            file, path, hint, scan_time, mod_time, check,
                        )?;
                        metadata = Some(tags);
                        cover.ok_or_else(|| "no cover art found in file".into())
                    } else {
                        // The cover cache files .aac under its MP4 reader; the
                        // container check also recognizes raw ADTS.
                        let aac = library_extension(path, hint) == "aac";
                        extract_cover(file, if aac { "aac" } else { format }, check)
                    }
                },
                covers,
                check,
            )
            .ok()
        };
        check()?;
        let mut result = match metadata {
            Some(metadata) => metadata,
            None => match file.as_mut() {
                Some(file) => read_library_metadata(file, path, hint, scan_time, mod_time, check)?,
                None => library_metadata(path, hint, scan_time, mod_time),
            },
        };
        if let Some(cover) = cover.filter(|cover| !cover.is_empty()) {
            result["coverPath"] = cover.into();
        }
        check()?;
        if result["hasLyrics"] == false {
            let open = |path: &str| {
                let input = files.resolve_legacy(path)?;
                input.open_native_read().map_err(|error| error.to_string())
            };
            if let Ok(lyrics) = mornye_core::lyrics::file::sidecar(path, &open, check) {
                result["hasLyrics"] = mornye_core::lyrics::lrc::has_usable_content(&lyrics).into();
            }
        }
        check()?;
        Ok(result)
    }

    pub fn parse_cue_file(
        &self,
        path: &str,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<CueSheet, String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        check()?;
        let input = self.environment().native_files()?.resolve_legacy(path)?;
        input.native_display()?;
        let mut file = input
            .open(OpenOptions::new().read(true))
            .map_err(|error| format!("failed to open cue file: {error}"))?;
        cue::parse(&mut file, &check)
    }

    fn resolve_cue_audio(
        &self,
        path: &str,
        name: &str,
        audio_directory: &str,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<String, String> {
        let base = Path::new(path).parent().unwrap_or(Path::new("."));
        let directory = if audio_directory.is_empty() {
            base
        } else {
            Path::new(audio_directory)
        };
        let files = self.environment().native_files()?;
        let exists = |name: &str| -> Result<Option<String>, String> {
            check()?;
            let candidate = crate::files::clean(&directory.join(name.trim_start_matches('/')));
            let candidate = candidate.to_string_lossy();
            let input = files.resolve_legacy(&candidate)?;
            input.native_display()?;
            Ok(input.metadata().is_ok().then(|| candidate.into_owned()))
        };
        if let Some(path) = exists(name)? {
            return Ok(path);
        }
        let suffix = library_extension(name, "");
        let stem = if suffix.is_empty() {
            name
        } else {
            &name[..name.len() - suffix.len() - 1]
        };
        let extensions = [
            "flac", "wav", "aiff", "aif", "ape", "mp3", "ogg", "wv", "m4a",
        ];
        for extension in extensions {
            for extension in [extension.to_owned(), extension.to_uppercase()] {
                if let Some(path) = exists(&format!("{stem}.{extension}"))? {
                    return Ok(path);
                }
            }
        }
        let stem = Path::new(path)
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or_default();
        for extension in extensions {
            if let Some(path) = exists(&format!("{stem}.{extension}"))? {
                return Ok(path);
            }
        }
        let directory_path = files.resolve_legacy(&directory.to_string_lossy())?;
        directory_path.native_display()?;
        if let Ok(entries) = directory_path.entries() {
            let mut candidates = entries.into_iter().filter(|(name, directory)| {
                !directory
                    && matches!(
                        library_extension(name, "").as_str(),
                        "flac" | "wav" | "ape" | "mp3" | "ogg" | "wv" | "m4a" | "aiff"
                    )
            });
            if let Some((name, _)) = candidates.next()
                && candidates.next().is_none()
                && let Some(path) = exists(&name)?
            {
                return Ok(path);
            }
        }
        check()?;
        Err(format!(
            "audio file not found for cue: {path} (referenced: {name})"
        ))
    }

    pub fn parse_cue_file_json(
        &self,
        path: &str,
        audio_directory: &str,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<Value, String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        let sheet = self
            .parse_cue_file(path, &check)
            .map_err(|error| format!("failed to parse cue file: {error}"))?;
        let audio = self
            .resolve_cue_audio(path, &sheet.file_name, audio_directory, &check)
            .map_err(|error| {
                error.replace(
                    "audio file not found for cue:",
                    "audio file not found for cue sheet:",
                )
            })?;
        cue_sheet_json(path, &sheet, &audio, &check)
    }

    /// Native callers resolve and validate the audio reference themselves (for
    /// example an Android SAF URI). Parsing the sheet needs no audio contents.
    pub fn parse_cue_file_json_with_resolved_audio(
        &self,
        path: &str,
        audio_path: &str,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<Value, String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        check()?;
        if audio_path.trim().is_empty() {
            return Err("resolved audio path is empty".into());
        }
        let sheet = self
            .parse_cue_file(path, &check)
            .map_err(|error| format!("failed to parse cue file: {error}"))?;
        cue_sheet_json(path, &sheet, audio_path, &check)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn scan_cue_file_for_library(
        &self,
        path: &str,
        audio_directory: &str,
        virtual_prefix: &str,
        mod_time: i64,
        cache_key: &str,
        scan_time: &str,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<Value, String> {
        let _operation = self.enter()?;
        let failure = RefCell::new(None::<String>);
        let check = || {
            if let Some(error) = failure.borrow().as_ref() {
                return Err(error.clone());
            }
            self.check().and_then(|()| check()).inspect_err(|error| {
                *failure.borrow_mut() = Some(error.clone());
            })
        };
        let sheet = self.parse_cue_file(path, &check)?;
        let audio = self.resolve_cue_audio(path, &sheet.file_name, audio_directory, &check)?;
        self.scan_cue_sheet(
            path,
            &sheet,
            &audio,
            virtual_prefix,
            mod_time,
            cache_key,
            scan_time,
            &check,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn scan_cue_file_for_library_with_metadata(
        &self,
        path: &str,
        audio_hint: &str,
        metadata_json: &str,
        virtual_prefix: &str,
        mod_time: i64,
        scan_time: &str,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<Value, String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        check()?;
        let metadata: Value = serde_json::from_str(metadata_json).map_err(|e| e.to_string())?;
        if !metadata.is_object() || audio_hint.trim().is_empty() {
            return Err("invalid resolved CUE audio metadata".into());
        }
        let sheet = self.parse_cue_file(path, &check)?;
        let mod_time = if mod_time > 0 {
            mod_time
        } else {
            modified(&self.environment().native_files()?.resolve_legacy(path)?)
        };
        cue_library_rows(
            path,
            &sheet,
            virtual_prefix,
            mod_time,
            scan_time,
            &library_extension(audio_hint, ""),
            &metadata,
            &check,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn scan_cue_sheet(
        &self,
        path: &str,
        sheet: &CueSheet,
        audio: &str,
        virtual_prefix: &str,
        mod_time: i64,
        cache_key: &str,
        scan_time: &str,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<Value, String> {
        let files = self.environment().native_files()?;
        let input = files.resolve_legacy(audio)?;
        input.native_display()?;
        let format = library_extension(audio, "");
        let mut depth = 0;
        let mut rate = 0;
        let mut duration = 0.0;
        if let Ok(mut file) = input.open(OpenOptions::new().read(true)) {
            if format == "flac" {
                if let Ok(quality) = mornye_core::media::probe_quality(&mut file, check) {
                    depth = quality.bit_depth;
                    rate = quality.sample_rate;
                    if rate > 0 && quality.total_samples > 0 {
                        duration = quality.total_samples as f64 / rate as f64;
                    }
                }
            } else if format == "mp3"
                && let Ok(metadata) =
                    mornye_core::tags::read_file_metadata(&mut file, audio, "", check)
            {
                rate = metadata["sample_rate"].as_i64().unwrap_or_default();
                duration = metadata["duration"].as_f64().unwrap_or_default();
            }
        }
        check()?;
        let directory = self
            .library_cover_directory
            .lock()
            .expect("library cover directory lock")
            .clone();
        let cover = if directory.is_empty() {
            String::new()
        } else {
            self.save_cover_to_cache_with_hint_and_key(audio, "", &directory, cache_key, check)
                .unwrap_or_default()
        };
        check()?;
        let mod_time = if mod_time > 0 {
            mod_time
        } else {
            modified(&files.resolve_legacy(path)?)
        };
        cue_library_rows(
            path,
            sheet,
            virtual_prefix,
            mod_time,
            scan_time,
            &format,
            &json!({"bitDepth":depth,"sampleRate":rate,"duration":duration,"coverPath":cover}),
            check,
        )
    }
}

#[allow(clippy::too_many_arguments)]
fn cue_library_rows(
    path: &str,
    sheet: &CueSheet,
    virtual_prefix: &str,
    mod_time: i64,
    scan_time: &str,
    format: &str,
    metadata: &Value,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    let prefix = prefer(virtual_prefix, path);
    let depth = metadata["bitDepth"].as_i64().unwrap_or_default();
    let rate = metadata["sampleRate"].as_i64().unwrap_or_default();
    let duration = metadata["duration"].as_f64().unwrap_or_default();
    let cover = metadata["coverPath"].as_str().unwrap_or_default();
    let mut results = Vec::with_capacity(sheet.tracks.len());
    for (index, track) in sheet.tracks.iter().enumerate() {
        check()?;
        let end = next_start(sheet, index).or_else(|| (duration > 0.0).then_some(duration));
        let mut result = json!({
            "id":library_id(&format!("{prefix}#track{}", track.number)),
            "filePath":format!("{prefix}#track{:02}", track.number),
            "trackName":if track.title.is_empty() { format!("Track {:02}", track.number) } else { track.title.clone() },
            "artistName":prefer(prefer(&track.performer, &sheet.performer), "Unknown Artist"),
            "albumName":prefer(&sheet.title, "Unknown Album"), "scannedAt":scan_time,
            "hasLyrics":false,"totalTracks":sheet.tracks.len(),"discNumber":1,"totalDiscs":1,
            "format":format!("cue+{format}"),
        });
        for (key, value) in [
            ("fileModTime", mod_time),
            ("trackNumber", track.number),
            (
                "duration",
                end.map_or(0, |end| (end - track.start_time) as i64),
            ),
            ("bitDepth", depth),
            ("sampleRate", rate),
        ] {
            if value != 0 {
                result[key] = value.into();
            }
        }
        for (key, value) in [
            ("albumArtist", sheet.performer.as_str()),
            ("coverPath", cover),
            ("isrc", &track.isrc),
            ("releaseDate", &sheet.date),
            ("genre", &sheet.genre),
            ("composer", prefer(&track.composer, &sheet.composer)),
        ] {
            optional(&mut result, key, value);
        }
        results.push(result);
    }
    Ok(results.into())
}

fn scan_time() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn modified(path: &crate::files::FilePath) -> i64 {
    path.metadata()
        .map(|metadata| modified_time(&metadata))
        .unwrap_or_default()
}

fn modified_time(metadata: &cap_std::fs::Metadata) -> i64 {
    metadata
        .modified()
        .map(|time| match time.into_std().duration_since(UNIX_EPOCH) {
            Ok(duration) => duration.as_millis() as i64,
            Err(error) => -((error.duration().as_nanos().div_ceil(1_000_000)) as i64),
        })
        .unwrap_or_default()
}

fn prefer<'a>(value: &'a str, fallback: &'a str) -> &'a str {
    if value.is_empty() { fallback } else { value }
}

fn optional(result: &mut Value, key: &str, value: &str) {
    if !value.is_empty() {
        result[key] = value.into();
    }
}

fn next_start(sheet: &CueSheet, index: usize) -> Option<f64> {
    sheet.tracks.get(index + 1).map(|track| {
        if track.pre_gap >= 0.0 {
            track.pre_gap
        } else {
            track.start_time
        }
    })
}

fn cue_sheet_json(
    path: &str,
    sheet: &CueSheet,
    audio: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    let mut tracks = Vec::with_capacity(sheet.tracks.len());
    for (index, track) in sheet.tracks.iter().enumerate() {
        check()?;
        let mut value = json!({"number":track.number,"title":track.title,
        "artist":prefer(&track.performer, &sheet.performer),"start_sec":track.start_time,
        "end_sec":next_start(sheet, index).unwrap_or(-1.0)});
        optional(&mut value, "isrc", &track.isrc);
        optional(
            &mut value,
            "composer",
            prefer(&track.composer, &sheet.composer),
        );
        tracks.push(value);
    }
    check()?;
    let mut result = json!({"cue_path":path,"audio_path":audio,"album":sheet.title,"artist":sheet.performer,"tracks":tracks});
    optional(&mut result, "genre", &sheet.genre);
    optional(&mut result, "date", &sheet.date);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::io::Cursor;

    const CUE: &str = "PERFORMER \"Album Artist\"\nTITLE \"Album\"\nREM GENRE Jazz\nREM DATE 2026\nREM COMPOSER \"Album Writer\"\nFILE \"album.flac\" WAVE\nTRACK 01 AUDIO\nTITLE \"First\"\nPERFORMER \"Track Artist\"\nISRC XXAAA2600001\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nTITLE \"Second\"\nINDEX 00 03:00:00\nINDEX 01 03:02:00\n";

    #[test]
    fn resolved_cue_audio_is_opaque_and_matches_legacy_tracks_without_audio() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        let backend = Backend::new(
            &directory.path().join("sources"),
            &data,
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            crate::RuntimeLimits::default(),
        )
        .unwrap();
        let path = data.join("album.cue");
        std::fs::write(&path, CUE).unwrap();
        let path = path.to_str().unwrap();
        let audio = data.join("album.flac");
        std::fs::write(&audio, []).unwrap();
        let mut expected = backend.parse_cue_file_json(path, "", &|| Ok(())).unwrap();
        std::fs::remove_file(audio).unwrap();
        let resolved = "content://example.documents/tree/root/document/opaque%2F音楽.flac";
        expected["audio_path"] = resolved.into();
        let result = backend
            .parse_cue_file_json_with_resolved_audio(path, resolved, &|| Ok(()))
            .unwrap();
        assert_eq!(result, expected);
        assert_eq!(result["tracks"][0]["end_sec"], 180.0);
        assert_eq!(result["tracks"][1]["end_sec"], -1.0);
        assert_eq!(result["tracks"][1]["composer"], "Album Writer");
        assert!(
            backend
                .parse_cue_file_json(path, "", &|| Ok(()))
                .unwrap_err()
                .contains("audio file not found")
        );
        assert_eq!(std::fs::read_to_string(path).unwrap(), CUE);
        assert_eq!(
            backend
                .parse_cue_file_json_with_resolved_audio(path, " \t", &|| Ok(()))
                .unwrap_err(),
            "resolved audio path is empty"
        );
        assert_eq!(
            backend
                .parse_cue_file_json_with_resolved_audio(path, resolved, &|| {
                    Err("cancelled".into())
                })
                .unwrap_err(),
            "cancelled"
        );
        std::fs::write(path, "TITLE \"No tracks\"\n").unwrap();
        assert!(
            backend
                .parse_cue_file_json_with_resolved_audio(path, resolved, &|| Ok(()))
                .unwrap_err()
                .contains("no tracks found")
        );
    }

    #[test]
    fn cue_json_checks_cancellation_while_mapping_tracks() {
        let sheet = cue::parse(&mut Cursor::new(CUE), &|| Ok(())).unwrap();
        let checks = Cell::new(0);
        let error = cue_sheet_json("album.cue", &sheet, "opaque-audio", &|| {
            checks.set(checks.get() + 1);
            if checks.get() == 2 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        })
        .unwrap_err();
        assert_eq!(error, "cancelled");
        assert_eq!(checks.get(), 2);
    }

    #[test]
    fn resolved_cue_metadata_scans_without_materializing_audio() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        let backend = Backend::new(
            &directory.path().join("sources"),
            &data,
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            crate::RuntimeLimits::default(),
        )
        .unwrap();
        let path = data.join("album.cue");
        std::fs::write(&path, CUE).unwrap();
        let prefix = "content://example.documents/document/album.cue";
        let metadata = json!({
            "bitDepth": 24, "sampleRate": 96000, "duration": 367.75,
            "coverPath": "cached-cover.jpg",
        });
        let result = backend
            .scan_cue_file_for_library_with_metadata(
                path.to_str().unwrap(),
                "album.flac",
                &metadata.to_string(),
                prefix,
                123,
                "scan-time",
                &|| Ok(()),
            )
            .unwrap();
        assert_eq!(result.as_array().unwrap().len(), 2);
        assert_eq!(result[0]["filePath"], format!("{prefix}#track01"));
        assert_eq!(result[0]["duration"], 180);
        assert_eq!(result[1]["duration"], 185);
        assert_eq!(result[1]["artistName"], "Album Artist");
        assert_eq!(result[1]["bitDepth"], 24);
        assert_eq!(result[1]["sampleRate"], 96000);
        assert_eq!(result[1]["format"], "cue+flac");
        assert_eq!(result[1]["coverPath"], "cached-cover.jpg");
        assert_eq!(result[1]["fileModTime"], 123);
        assert_eq!(result[1]["scannedAt"], "scan-time");
        assert!(!data.join("album.flac").exists());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), CUE);
        assert_eq!(
            backend
                .scan_cue_file_for_library_with_metadata(
                    path.to_str().unwrap(),
                    "album.flac",
                    "[]",
                    prefix,
                    123,
                    "scan-time",
                    &|| Ok(()),
                )
                .unwrap_err(),
            "invalid resolved CUE audio metadata"
        );
        assert_eq!(
            backend
                .scan_cue_file_for_library_with_metadata(
                    path.to_str().unwrap(),
                    "album.flac",
                    &metadata.to_string(),
                    prefix,
                    123,
                    "scan-time",
                    &|| Err("cancelled".into()),
                )
                .unwrap_err(),
            "cancelled"
        );
    }

    #[test]
    fn cue_library_mapping_checks_cancellation_per_track() {
        let sheet = cue::parse(&mut Cursor::new(CUE), &|| Ok(())).unwrap();
        let checks = Cell::new(0);
        let error = cue_library_rows(
            "album.cue",
            &sheet,
            "opaque-cue",
            123,
            "scan-time",
            "flac",
            &json!({}),
            &|| {
                checks.set(checks.get() + 1);
                if checks.get() == 2 {
                    Err("cancelled".into())
                } else {
                    Ok(())
                }
            },
        )
        .unwrap_err();
        assert_eq!(error, "cancelled");
        assert_eq!(checks.get(), 2);
    }
}
