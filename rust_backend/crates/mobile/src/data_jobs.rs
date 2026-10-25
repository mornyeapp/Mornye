//! CPU and file work submitted by Flutter. Platform dispatch owns the worker
//! thread and the cancellation lease; widgets continue to own presentation.
use crate::cancellation::RequestLease;
use crate::manager::ExtensionManager;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{fs::File, io::Read, sync::Arc};

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum NativeDataJobError {
    #[error("{0}")]
    Operation(String),
}

#[uniffi::export]
pub fn run_native_data_job(
    request_json: String,
    bytes: Vec<u8>,
    lease: Option<Arc<RequestLease>>,
) -> Result<String, NativeDataJobError> {
    run(&request_json, &bytes, lease.as_deref(), None)
}

#[uniffi::export]
impl ExtensionManager {
    pub fn run_native_data_job(
        &self,
        request_json: String,
        bytes: Vec<u8>,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, NativeDataJobError> {
        run(&request_json, &bytes, lease.as_deref(), Some(self))
    }
}

fn run(
    request_json: &str,
    bytes: &[u8],
    lease: Option<&RequestLease>,
    manager: Option<&ExtensionManager>,
) -> Result<String, NativeDataJobError> {
    let check = || crate::tags::check_lease(lease);
    check().map_err(NativeDataJobError::Operation)?;
    let request: Value = serde_json::from_str(request_json)
        .map_err(|error| NativeDataJobError::Operation(error.to_string()))?;
    let value = execute(&request, bytes, &check, manager).map_err(NativeDataJobError::Operation)?;
    if value.get("committed") != Some(&Value::Bool(true)) {
        check().map_err(NativeDataJobError::Operation)?;
    }
    serde_json::to_string(&value).map_err(|error| NativeDataJobError::Operation(error.to_string()))
}

fn execute(
    request: &Value,
    bytes: &[u8],
    check: &(dyn Fn() -> Result<(), String> + Sync),
    manager: Option<&ExtensionManager>,
) -> Result<Value, String> {
    let operation = string(request, "operation")?;
    match operation {
        "hash_file" => Ok(json!({"sha256": hash_file(string(request, "path")?, check)?})),
        "matches_network_upload" => crate::network_tags::matches_upload(request, check),
        "network_metadata" => {
            let metadata = crate::network_tags::read_to_cache(
                string(request, "url")?,
                string(request, "display_name")?,
                string(request, "cache_directory")?,
                check,
            )?;
            let cacheable = serde_json::to_vec(&metadata)
                .map_err(|error| error.to_string())?
                .len()
                <= 128 * 1024;
            Ok(json!({"metadata": metadata, "cacheable": cacheable}))
        }
        "promote_network_cover" => crate::network_tags::promote_cover(
            string(request, "path")?,
            string(request, "directory")?,
            check,
        ),
        "parse_network_listing" => crate::native_listing::execute(request, Some(bytes)),
        "parse_playlist" | "build_m3u" => {
            crate::native_playlists::execute(request, Some(bytes), check)
        }
        "write_id3v23_lyrics" | "build_metadata_picture" => {
            crate::native_id3::execute(request, Some(bytes), check)
        }
        "parse_lyrics" => crate::native_lyrics::execute(request, Some(bytes), check),
        "palette" => {
            let colors = mornye_core::native_palette::quantize_rgba(bytes, check)?;
            Ok(json!({"colors": colors}))
        }
        "automix" => {
            let grid = mornye_core::native_audio_analysis::analyze_automix_pcm_file(
                string(request, "path")?,
                check,
            )?;
            serde_json::to_value(grid).map_err(|error| error.to_string())
        }
        "audio_features" => {
            use mornye_core::native_audio_features as features;
            let paths = request
                .get("paths")
                .and_then(Value::as_array)
                .ok_or("Missing native data field: paths")?
                .iter()
                .map(|path| path.as_str().ok_or("Invalid audio feature window path"))
                .collect::<Result<Vec<_>, _>>()?;
            let described = features::analyze_audio_features_files(&paths, check)?;
            Ok(json!({
                "version": features::AUDIO_FEATURES_VERSION,
                "features": described.map(|value| value.to_vector()),
            }))
        }
        "spectral_cutoff" => {
            let width = request
                .get("width")
                .and_then(Value::as_u64)
                .ok_or("Missing width")?;
            let height = request
                .get("height")
                .and_then(Value::as_u64)
                .ok_or("Missing height")?;
            let maximum = request
                .get("max_frequency")
                .and_then(Value::as_f64)
                .ok_or("Missing maximum frequency")?;
            let cutoff = mornye_core::native_audio_analysis::estimate_spectral_cutoff_file(
                string(request, "path")?,
                usize::try_from(width).map_err(|e| e.to_string())?,
                usize::try_from(height).map_err(|e| e.to_string())?,
                maximum,
                check,
            )?;
            Ok(json!({"cutoff": cutoff}))
        }
        "library_scan_incremental" => crate::native_library::scan_incremental(
            manager.ok_or("Library scan requires the initialized backend")?,
            request,
            check,
        ),
        "collections_snapshot" => crate::native_collections::execute(request, check),
        "collections_stage_playlist_additions" => {
            crate::native_playlist_write::execute(request, check)
        }
        operation if operation.starts_with("library_") => {
            crate::native_library::execute(request, check)
        }
        operation if operation.starts_with("backup_") => {
            crate::native_backup::execute(request, check)
        }
        operation if operation.starts_with("cache_") => {
            crate::native_cache::execute(request, check)
        }
        _ => Err(format!("Unknown native data operation: {operation}")),
    }
}

pub(crate) fn string<'a>(request: &'a Value, name: &str) -> Result<&'a str, String> {
    request
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("Missing native data field: {name}"))
}

pub(crate) fn hash_file(
    path: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<String, String> {
    check()?;
    if !std::fs::metadata(path)
        .map_err(|error| error.to_string())?
        .is_file()
    {
        return Err("Hash input must be a regular file".into());
    }
    let mut file = File::open(path).map_err(|error| error.to_string())?;
    if !file
        .metadata()
        .map_err(|error| error.to_string())?
        .is_file()
    {
        return Err("Hash input must be a regular file".into());
    }
    let mut hash = Sha256::new();
    let mut buffer = [0; 64 * 1024];
    loop {
        check()?;
        let count = file.read(&mut buffer).map_err(|error| error.to_string())?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    check()?;
    Ok(mornye_core::lower_hex(&hash.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn hashes_streamed_files_and_obeys_cancellation() {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        file.write_all(b"abc").unwrap();
        assert_eq!(
            hash_file(file.path().to_str().unwrap(), &|| Ok(())).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert!(hash_file(file.path().to_str().unwrap(), &|| Err("cancelled".into())).is_err());
    }

    #[test]
    fn describes_decoded_windows_and_rejects_bad_requests() {
        let mut tone = tempfile::NamedTempFile::new().unwrap();
        for index in 0..22_050 * 8 {
            let value = 0.5 * (index as f64 * 440.0 * std::f64::consts::TAU / 22_050.0).sin();
            tone.write_all(&(((value * 32767.0) as i16).to_le_bytes()))
                .unwrap();
        }
        let mut silence = tempfile::NamedTempFile::new().unwrap();
        silence.write_all(&[0; 22_050 * 2 * 8]).unwrap();
        let run = |paths: Value| {
            execute(
                &json!({"operation": "audio_features", "paths": paths}),
                &[],
                &|| Ok(()),
                None,
            )
        };
        let tone_path = tone.path().to_str().unwrap();
        let described = run(json!([tone_path, tone_path])).unwrap();
        assert_eq!(described["version"], 1);
        assert_eq!(
            described["features"].as_array().unwrap().len(),
            mornye_core::native_audio_features::AudioFeatures::LEN
        );
        let silent = run(json!([silence.path().to_str().unwrap()])).unwrap();
        assert!(silent["features"].is_null());
        assert!(run(json!([])).is_err());
        assert!(run(json!([1])).is_err());
        assert!(run(json!(["/missing/window.pcm"])).is_err());
    }
}
