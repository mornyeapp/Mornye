//! Metadata from a descriptor already opened by the native document provider.
//! This entry point is not exposed to extensions and does not grant filesystem roots.

use crate::cancellation::RequestLease;
use crate::tags::{AudioTagsError, check_lease, open_audio_file};
use mornye_core::{cover, tags};
use mornye_extensions::backend::{
    LIBRARY_COVER_REGENERATE_MARKER, library_cover_is_current, library_cover_stem,
};
use std::path::Path;
use std::sync::Arc;
use std::time::UNIX_EPOCH;

#[derive(uniffi::Record)]
pub struct DescriptorLibraryMetadata {
    pub metadata_json: String,
    pub cover_bytes: Vec<u8>,
    pub cover_mime: String,
}

/// A Library thumbnail slot for the document provider scan, which writes
/// descriptor artwork itself: the file to reuse, if any, and the stem for a
/// new `.jpg` or `.png` file. Names match the Rust scan's thumbnails.
#[derive(uniffi::Record)]
pub struct LibraryCoverSlot {
    pub stem: String,
    pub cached: Option<String>,
}

#[uniffi::export]
pub fn library_cover_slot(directory: String, key: String) -> LibraryCoverSlot {
    let stem = library_cover_stem(key.trim());
    let directory = Path::new(&directory);
    let regenerate = std::fs::metadata(directory.join(LIBRARY_COVER_REGENERATE_MARKER))
        .and_then(|metadata| metadata.modified())
        .ok();
    let cached = ["jpg", "png"]
        .into_iter()
        .filter_map(|extension| {
            let path = directory.join(format!("{stem}.{extension}"));
            let metadata = std::fs::metadata(&path)
                .ok()
                .filter(|metadata| metadata.is_file())?;
            let modified = metadata.modified().unwrap_or(UNIX_EPOCH);
            library_cover_is_current(modified, regenerate).then_some((modified, path))
        })
        .max_by_key(|(modified, _)| *modified)
        .map(|(_, path)| path.to_string_lossy().into_owned());
    LibraryCoverSlot { stem, cached }
}

fn descriptor_path(descriptor: i32) -> Result<String, AudioTagsError> {
    if descriptor < 0 {
        return Err("invalid audio descriptor".to_owned().into());
    }
    let directory = if cfg!(any(target_os = "android", target_os = "linux")) {
        "/proc/self/fd"
    } else {
        "/dev/fd"
    };
    Ok(format!("{directory}/{descriptor}"))
}

/// Read original embedded artwork for metadata, export and editing. Unlike the
/// Library scan result, these bytes must never be resized or re-encoded.
/// The native caller retains the descriptor until this synchronous call returns.
#[uniffi::export]
pub fn extract_cover_from_descriptor(
    descriptor: i32,
    hint: String,
    lease: Option<Arc<RequestLease>>,
) -> Result<Vec<u8>, AudioTagsError> {
    let check = || check_lease(lease.as_deref());
    check()?;
    let path = descriptor_path(descriptor)?;
    let mut file = open_audio_file(&path)?;
    let format = tags::library_extension(&path, &hint);
    // .aac stays as it is: the reader tells MP4 from raw ADTS by content.
    let format = if format == "mp4" { "m4a" } else { &format };
    Ok(tags::extract_cover(&mut file, format, &check)?.data)
}

/// The caller keeps the descriptor open until this synchronous read returns.
/// Duplicating its descriptor preserves SAF access, including single-open
/// AppFuse proxies, without resolving a protected path or copying the audio.
#[uniffi::export]
pub fn read_library_metadata_from_descriptor(
    descriptor: i32,
    hint: String,
    scan_time: String,
    include_cover: bool,
    lease: Option<Arc<RequestLease>>,
) -> Result<DescriptorLibraryMetadata, AudioTagsError> {
    let path = descriptor_path(descriptor)?;
    let check = || check_lease(lease.as_deref());
    check()?;
    let mut file = open_audio_file(&path)?;
    let format = tags::library_extension(&path, &hint);
    let (metadata, mut artwork) = if include_cover && format == "flac" {
        tags::read_library_metadata_with_cover(&mut file, &path, &hint, &scan_time, 0, &check)?
    } else {
        let metadata = tags::read_library_metadata(&mut file, &path, &hint, &scan_time, 0, &check)?;
        let artwork = if include_cover {
            let format = if format == "mp4" { "m4a" } else { &format };
            tags::extract_cover(&mut file, format, &check).ok()
        } else {
            None
        };
        (metadata, artwork)
    };
    if let Some(artwork) = artwork.as_mut()
        && let Ok(resized) = cover::library_thumbnail(&artwork.data, &check)
    {
        artwork.mime = if resized.starts_with(b"\x89PNG") {
            "image/png"
        } else if resized.starts_with(b"\xff\xd8") {
            "image/jpeg"
        } else {
            &artwork.mime
        }
        .into();
        artwork.data = resized.to_vec();
    }
    check()?;
    let (cover_bytes, cover_mime) = artwork.map_or_else(
        || (Vec::new(), String::new()),
        |artwork| (artwork.data, artwork.mime),
    );
    Ok(DescriptorLibraryMetadata {
        metadata_json: metadata.to_string(),
        cover_bytes,
        cover_mime,
    })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::fs::{File, OpenOptions};
    use std::io::Write;
    use std::os::fd::AsRawFd;
    use std::time::{Duration, SystemTime};

    #[test]
    fn document_scan_thumbnails_share_names_and_regeneration_with_the_rust_scan() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().to_str().unwrap().to_owned();
        let key = "content://provider/document/track|1700000000000";
        let slot = library_cover_slot(root.clone(), format!(" {key} "));
        assert_eq!(slot.stem, library_cover_stem(key));
        assert_eq!(slot.cached, None);
        let jpg = directory.path().join(format!("{}.jpg", slot.stem));
        std::fs::write(&jpg, b"old").unwrap();
        File::options()
            .write(true)
            .open(&jpg)
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(60))
            .unwrap();
        let cached = library_cover_slot(root.clone(), key.into()).cached;
        assert_eq!(cached.as_deref(), jpg.to_str());
        std::fs::write(directory.path().join(LIBRARY_COVER_REGENERATE_MARKER), "").unwrap();
        assert_eq!(library_cover_slot(root.clone(), key.into()).cached, None);
        // A regenerated thumbnail may change format; the newer file wins.
        let png = directory.path().join(format!("{}.png", slot.stem));
        std::fs::write(&png, b"new").unwrap();
        let cached = library_cover_slot(root, key.into()).cached;
        assert_eq!(cached.as_deref(), png.to_str());
    }

    #[test]
    fn original_artwork_is_copied_without_decoding_or_changing_the_source() {
        // Extraction preserves even formats the thumbnail decoder cannot read.
        let artwork = b"original embedded image bytes";
        let mut picture = 3_u32.to_be_bytes().to_vec();
        picture.extend(10_u32.to_be_bytes());
        picture.extend(b"image/jpeg");
        picture.extend(0_u32.to_be_bytes());
        for value in [4500_u32, 4500, 24, 0, artwork.len() as u32] {
            picture.extend(value.to_be_bytes());
        }
        picture.extend(artwork);
        let mut flac = b"fLaC".to_vec();
        flac.push(0x86);
        flac.extend(&u32::try_from(picture.len()).unwrap().to_be_bytes()[1..]);
        flac.extend(picture);
        flac.extend([0xff, 0xf8]);
        let mut source = tempfile::tempfile().unwrap();
        source.write_all(&flac).unwrap();
        let descriptor = source.as_raw_fd();
        assert_eq!(
            extract_cover_from_descriptor(descriptor, "Track.FLAC".into(), None).unwrap(),
            artwork
        );
        assert_eq!(source.metadata().unwrap().len(), flac.len() as u64);
        use std::io::{Read, Seek, SeekFrom};
        source.seek(SeekFrom::Start(0)).unwrap();
        let mut unchanged = Vec::new();
        source.read_to_end(&mut unchanged).unwrap();
        assert_eq!(unchanged, flac);

        use crate::cancellation::{CancellationDomain, CancellationRegistry};
        let registry = CancellationRegistry::new(CancellationDomain::ExtensionRequest);
        let lease = registry.acquire("artwork".into()).unwrap();
        registry.cancel("artwork".into()).unwrap();
        assert!(
            extract_cover_from_descriptor(descriptor, "Track.flac".into(), Some(lease)).is_err()
        );
        assert!(source.metadata().is_ok());
        assert!(extract_cover_from_descriptor(-1, "Track.flac".into(), None).is_err());
        assert!(extract_cover_from_descriptor(descriptor, "Track.xyz".into(), None).is_err());
    }

    #[test]
    fn descriptor_remains_open_and_audio_does_not_need_a_path_grant() {
        let path = std::env::temp_dir().join(format!("library-fd-{}.wav", std::process::id()));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        let mut wav = b"RIFF".to_vec();
        wav.extend(38_u32.to_le_bytes());
        wav.extend(b"WAVEfmt ");
        wav.extend(16_u32.to_le_bytes());
        wav.extend(1_u16.to_le_bytes());
        wav.extend(1_u16.to_le_bytes());
        wav.extend(44100_u32.to_le_bytes());
        wav.extend(88200_u32.to_le_bytes());
        wav.extend(2_u16.to_le_bytes());
        wav.extend(16_u16.to_le_bytes());
        wav.extend(b"data");
        wav.extend(2_u32.to_le_bytes());
        wav.extend(0_i16.to_le_bytes());
        file.write_all(&wav).unwrap();
        drop(file);
        let source = File::open(&path).unwrap();
        let read = read_library_metadata_from_descriptor(
            source.as_raw_fd(),
            "Track.wav".into(),
            "2026-09-30T00:00:00Z".into(),
            true,
            None,
        );
        std::fs::remove_file(path).unwrap();
        let metadata = read.unwrap();
        let json: serde_json::Value = serde_json::from_str(&metadata.metadata_json).unwrap();
        assert_eq!(json["format"], "wav");
        assert_eq!(json["sampleRate"], 44100);
        assert_eq!(json["bitDepth"], 16);
        assert!(metadata.cover_bytes.is_empty());
        assert!(source.metadata().unwrap().is_file());
        assert!(
            extract_cover_from_descriptor(source.as_raw_fd(), "Track.wav".into(), None).is_err()
        );
        assert!(
            read_library_metadata_from_descriptor(-1, "x.flac".into(), "".into(), false, None)
                .is_err()
        );
    }
}
