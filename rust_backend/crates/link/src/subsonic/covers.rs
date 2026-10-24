//! `getCoverArt`: the cover file, or a JPEG resized to `size` (aspect ratio
//! kept, never upscaled) cached under `<temp_dir>/link-covers/`.

use super::media::file_response;
use super::{Failure, number, required};
use crate::catalog::{Catalog, hex};
use crate::types::{HttpResponse, Shared, SubsonicRequest, full};
use http::header::{CACHE_CONTROL, ETAG, IF_NONE_MATCH};
use http::{HeaderMap, Response};
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{ImageReader, Limits};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::UNIX_EPOCH;

/// Cache folder under the temp dir.
pub(super) const CACHE_DIR: &str = "link-covers";
/// Largest edge a client may request.
const MAX_EDGE: u32 = 2048;
const JPEG_QUALITY: u8 = 85;
/// Resized covers kept before the oldest are removed.
const MAX_CACHED: usize = 4000;
/// Cover files larger than this are served as they are, never decoded.
const MAX_DECODE_BYTES: u64 = 64 * 1024 * 1024;

pub(super) async fn cover_art(
    shared: &Shared,
    catalog: &Catalog,
    request: &SubsonicRequest,
) -> Result<HttpResponse, Failure> {
    let id = required(request, "id")?;
    let not_found = || Failure::not_found("Cover art").with_status(404);
    let source = catalog.cover_path(id).ok_or_else(not_found)?.to_owned();
    let metadata = tokio::fs::metadata(&source)
        .await
        .ok()
        .filter(fs::Metadata::is_file)
        .ok_or_else(not_found)?;
    let size = number::<i64>(request, "size")
        .filter(|size| *size > 0)
        .map(|size| u32::try_from(size.min(i64::from(MAX_EDGE))).unwrap_or(MAX_EDGE));
    let stamp = format!(
        "{}\0{}\0{}\0{}",
        source.to_string_lossy(),
        metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map_or(0, |elapsed| elapsed.as_nanos()),
        metadata.len(),
        size.unwrap_or(0)
    );
    let key = hex(&Sha256::digest(stamp.as_bytes())[..16]);
    let etag = format!("\"{key}\"");
    let cache_headers = vec![
        (ETAG, etag.clone()),
        (CACHE_CONTROL, "private, max-age=86400".to_owned()),
    ];
    if matches_etag(&request.headers, &etag) {
        let mut builder = Response::builder().status(304);
        for (name, value) in cache_headers {
            builder = builder.header(name, value);
        }
        return builder
            .body(full(bytes::Bytes::new()))
            .map_err(|error| Failure::new(super::code::GENERIC, error.to_string()));
    }
    let mut target = source.clone();
    if let Some(size) = size
        && metadata.len() <= MAX_DECODE_BYTES
    {
        let dir = shared.config.temp_dir.join(CACHE_DIR);
        if let Some(resized) = resized(dir, source.clone(), key, size).await {
            target = resized;
        }
    }
    let content_type = sniff(&target);
    file_response(&target, content_type, &request.headers, cache_headers)
        .await
        .map_err(|_| not_found())
}

fn matches_etag(headers: &HeaderMap, etag: &str) -> bool {
    headers
        .get_all(IF_NONE_MATCH)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .any(|tag| {
            let tag = tag.trim();
            tag == "*" || tag.trim_start_matches("W/") == etag
        })
}

/// The cached resized cover, made on demand; `None` serves the original
/// (smaller than `size`, undecodable, or the cache is unwritable).
async fn resized(dir: PathBuf, source: PathBuf, key: String, size: u32) -> Option<PathBuf> {
    let target = dir.join(format!("{key}.jpg"));
    if tokio::fs::metadata(&target)
        .await
        .is_ok_and(|metadata| metadata.is_file() && metadata.len() > 0)
    {
        return Some(target);
    }
    tokio::task::spawn_blocking(move || resize_into(&source, size, &dir, &target))
        .await
        .ok()
        .flatten()
}

fn resize_into(source: &Path, size: u32, dir: &Path, target: &Path) -> Option<PathBuf> {
    let bytes = fs::read(source).ok()?;
    let reader = ImageReader::new(Cursor::new(&bytes))
        .with_guessed_format()
        .ok()?;
    let (width, height) = reader.into_dimensions().ok()?;
    if width <= size && height <= size {
        return None;
    }
    let mut reader = ImageReader::new(Cursor::new(&bytes))
        .with_guessed_format()
        .ok()?;
    let mut limits = Limits::default();
    limits.max_alloc = Some(512 * 1024 * 1024);
    reader.limits(limits);
    let image = reader.decode().ok()?;
    let rgb = image.resize(size, size, FilterType::CatmullRom).to_rgb8();
    let mut encoded = Vec::new();
    JpegEncoder::new_with_quality(&mut encoded, JPEG_QUALITY)
        .encode_image(&rgb)
        .ok()?;
    fs::create_dir_all(dir).ok()?;
    let staging = dir.join(format!(
        ".{}-{}-{}.tmp",
        std::process::id(),
        STAGING.fetch_add(1, Ordering::Relaxed),
        target.file_stem()?.to_string_lossy()
    ));
    if fs::write(&staging, &encoded)
        .and_then(|()| fs::rename(&staging, target))
        .is_err()
    {
        let _ = fs::remove_file(&staging);
        return None;
    }
    trim_cache(dir, MAX_CACHED);
    Some(target.to_owned())
}

static STAGING: AtomicU64 = AtomicU64::new(0);

/// Removes the oldest cached covers beyond `keep`.
pub(super) fn trim_cache(dir: &Path, keep: usize) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = entries
        .filter_map(Result::ok)
        .filter(|entry| {
            entry
                .path()
                .extension()
                .is_some_and(|extension| extension == "jpg")
        })
        .filter_map(|entry| {
            let modified = entry.metadata().ok()?.modified().ok()?;
            Some((modified, entry.path()))
        })
        .collect();
    if files.len() <= keep {
        return;
    }
    files.sort();
    let excess = files.len() - keep;
    for (_, path) in files.into_iter().take(excess) {
        let _ = fs::remove_file(path);
    }
}

/// The image MIME type from the file's magic bytes, else its extension.
pub(super) fn sniff(path: &Path) -> &'static str {
    let mut head = [0u8; 12];
    let read = fs::File::open(path)
        .and_then(|mut file| file.read(&mut head))
        .unwrap_or(0);
    let head = &head[..read];
    if head.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return "image/jpeg";
    }
    if head.starts_with(b"\x89PNG") {
        return "image/png";
    }
    if head.starts_with(b"GIF8") {
        return "image/gif";
    }
    if head.len() >= 12 && head.starts_with(b"RIFF") && &head[8..12] == b"WEBP" {
        return "image/webp";
    }
    if head.starts_with(b"BM") {
        return "image/bmp";
    }
    let extension = path
        .extension()
        .map(|extension| extension.to_string_lossy().to_ascii_lowercase());
    match extension.as_deref() {
        Some("png") => "image/png",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("bmp") => "image/bmp",
        _ => "image/jpeg",
    }
}
