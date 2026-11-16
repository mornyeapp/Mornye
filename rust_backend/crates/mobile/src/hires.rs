use crate::cancellation::RequestLease;
use crate::tags::{check_lease, open_audio_file};
use mornye_core::media::hires::{self, HiResCheckOptions};
use std::sync::Arc;

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum HiResCheckError {
    #[error("{message}")]
    Failed { message: String },
}

impl From<String> for HiResCheckError {
    fn from(message: String) -> Self {
        Self::Failed { message }
    }
}

/// Runs the fake Hi-Res check on one local FLAC or WAV file; `options_json`
/// may be empty or override any `HiResCheckOptions` field. A format the
/// checker cannot decode is not an error: it returns `{"supported": false}`
/// so the UI can say "not checkable" rather than report a broken file.
/// CPU-bound for a second or two: call it off the main thread.
/// With `"detailed": true` the whole file is read instead of a sample of it,
/// which takes several seconds, and the result carries a `report` on its
/// integrity, real bit depth and any trace of a lossy source.
/// With `verify_replacement_path`, bypasses sampled analysis and compares the
/// entire decoded PCM stream, returning only `replacement_equivalent`.
#[uniffi::export]
pub fn check_hires_authenticity(
    path: String,
    options_json: String,
    lease: Option<Arc<RequestLease>>,
) -> Result<String, HiResCheckError> {
    let check = || check_lease(lease.as_deref());
    check()?;
    let request: serde_json::Value = if options_json.trim().is_empty() {
        serde_json::json!({})
    } else {
        serde_json::from_str(&options_json)
            .map_err(|error| format!("invalid hi-res check options: {error}"))?
    };
    if let Some(replacement_path) = request.get("verify_replacement_path") {
        let replacement_path = replacement_path
            .as_str()
            .filter(|path| !path.trim().is_empty())
            .ok_or("invalid replacement path".to_string())?;
        let equivalent = hires::replacement_preserves_audio(
            open_audio_file(&path)?,
            open_audio_file(replacement_path)?,
            &check,
        )
        .map_err(|error| error.to_string())?;
        return Ok(serde_json::json!({"replacement_equivalent": equivalent}).to_string());
    }
    let options: HiResCheckOptions = if options_json.trim().is_empty() {
        HiResCheckOptions::default()
    } else {
        serde_json::from_str(&options_json)
            .map_err(|error| format!("invalid hi-res check options: {error}"))?
    };
    let detailed = request
        .get("detailed")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let file = open_audio_file(&path)?;
    let checked = if detailed {
        hires::inspect_file(file, &path, &options, &check)
            .map(|inspection| (inspection.check, Some(inspection.report)))
    } else {
        hires::check_file(file, &path, &options, &check).map(|result| (result, None))
    };
    let (result, report) = match checked {
        Ok(checked) => checked,
        Err(hires::HiResCheckError::Unsupported) => {
            return Ok(serde_json::json!({"supported": false, "file_path": path}).to_string());
        }
        Err(error) => return Err(error.to_string().into()),
    };
    let mut value = serde_json::to_value(&result).map_err(|error| error.to_string())?;
    if let Some(object) = value.as_object_mut() {
        if let Some(report) = report {
            let report = serde_json::to_value(&report).map_err(|error| error.to_string())?;
            object.insert("report".into(), report);
        }
        object.insert("supported".into(), true.into());
        object.insert("is_suspicious".into(), result.is_suspicious().into());
        object.insert("padded_bit_depth".into(), result.padded_bit_depth().into());
        object.insert("redownload_safe".into(), result.redownload_safe().into());
    }
    Ok(value.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replacement_verification_is_exposed_and_fails_closed() {
        let dir = std::env::temp_dir().join(format!("mornye-hires-verify-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let original = dir.join("original.wav");
        let replacement = dir.join("replacement.wav");
        let wav = |bits: u16, sample: i32| {
            let bytes = u32::from(bits / 8);
            let mut data = b"RIFF".to_vec();
            data.extend_from_slice(&(36 + bytes).to_le_bytes());
            data.extend_from_slice(b"WAVEfmt ");
            data.extend_from_slice(&16u32.to_le_bytes());
            data.extend_from_slice(&1u16.to_le_bytes());
            data.extend_from_slice(&1u16.to_le_bytes());
            data.extend_from_slice(&44_100u32.to_le_bytes());
            data.extend_from_slice(&(44_100 * bytes).to_le_bytes());
            data.extend_from_slice(&(bytes as u16).to_le_bytes());
            data.extend_from_slice(&bits.to_le_bytes());
            data.extend_from_slice(b"data");
            data.extend_from_slice(&bytes.to_le_bytes());
            data.extend_from_slice(&sample.to_le_bytes()[..bytes as usize]);
            data
        };
        std::fs::write(&original, wav(24, 256)).expect("original");
        for (sample, expected) in [(1, true), (2, false)] {
            std::fs::write(&replacement, wav(16, sample)).expect("replacement");
            let raw = check_hires_authenticity(
                original.to_string_lossy().into_owned(),
                serde_json::json!({"verify_replacement_path": replacement}).to_string(),
                None,
            )
            .expect("verify");
            let value: serde_json::Value = serde_json::from_str(&raw).expect("json");
            assert_eq!(value["replacement_equivalent"], expected);
            assert!(value.get("redownload_safe").is_none());
        }
        assert!(
            check_hires_authenticity(
                original.to_string_lossy().into_owned(),
                "{\"verify_replacement_path\":123}".into(),
                None,
            )
            .is_err()
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn unsupported_formats_are_not_errors_and_bad_options_are() {
        let dir = std::env::temp_dir().join(format!("mornye-hires-export-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let mp3 = dir.join("song.mp3");
        std::fs::write(&mp3, b"ID3\x04\x00\x00\x00\x00\x00\x00junk").expect("write");
        let path = mp3.to_string_lossy().to_string();

        let raw = check_hires_authenticity(path.clone(), String::new(), None).expect("check");
        let value: serde_json::Value = serde_json::from_str(&raw).expect("json");
        assert_eq!(value["supported"], false);

        assert!(check_hires_authenticity(path, "{bad".into(), None).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
