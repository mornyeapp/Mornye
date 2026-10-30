//! `getCoverArt`: the cover file, or a JPEG resized to `size` (aspect ratio
//! kept, never upscaled) cached under `<temp_dir>/link-covers/`. A picture
//! embedded in an audio file is first extracted into that cache, then
//! served like a cover file. A listed cover file that is gone falls back to
//! the next source. The ETag and the resized copy follow the image, not the
//! id asking for it: a cover file's path, mtime and length, or those of the
//! audio file embedding the picture.

use super::media::file_response;
use super::{Failure, number, required};
use crate::catalog::{Catalog, cover_format, hex};
use crate::types::{HttpResponse, Shared, SubsonicRequest, full};
use http::header::{CACHE_CONTROL, ETAG, IF_NONE_MATCH};
use http::{HeaderMap, Response};
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{ImageReader, Limits};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex, MutexGuard, PoisonError};
use std::time::UNIX_EPOCH;

/// Cache folder under the temp dir.
pub(super) const CACHE_DIR: &str = "link-covers";
/// Largest edge a client may request.
const MAX_EDGE: u32 = 2048;
const JPEG_QUALITY: u8 = 85;
/// Cached covers (resized or extracted) kept before the oldest are removed.
const MAX_CACHED: usize = 4000;
/// Cover files larger than this are served as they are, never decoded.
const MAX_DECODE_BYTES: u64 = 64 * 1024 * 1024;
/// Extensions of the cached covers.
const CACHED_EXTENSIONS: &[&str] = &["jpg", "png", "gif", "webp", "bmp"];
/// Audio files remembered without a picture before the memory starts over.
const MAX_WITHOUT_PICTURE: usize = 50_000;

/// Audio files known to embed no picture, by the [`digest`] of their
/// version stamp, so repeated requests do not read them again. A changed
/// file has a new key.
static WITHOUT_PICTURE: LazyLock<Mutex<HashSet<[u8; 16]>>> = LazyLock::new(Mutex::default);

pub(super) async fn cover_art(
    shared: &Shared,
    catalog: &Catalog,
    request: &SubsonicRequest,
) -> Result<HttpResponse, Failure> {
    let id = required(request, "id")?;
    let not_found = || Failure::not_found("Cover art").with_status(404);
    let source = catalog.cover_source(id).ok_or_else(not_found)?;
    let files: Vec<PathBuf> = source.files.into_iter().map(Path::to_owned).collect();
    let candidates: Vec<(PathBuf, &'static str)> = source
        .embedded
        .into_iter()
        .map(|(path, format)| (path.to_owned(), format))
        .collect();
    let dir = shared.config.temp_dir.join(CACHE_DIR);
    let cache = dir.clone();
    let image = tokio::task::spawn_blocking(move || find_image(&cache, &files, &candidates))
        .await
        .ok()
        .flatten()
        .ok_or_else(not_found)?;
    let size = number::<i64>(request, "size")
        .filter(|size| *size > 0)
        .map(|size| u32::try_from(size.min(i64::from(MAX_EDGE))).unwrap_or(MAX_EDGE));
    let key = hex(&digest(&format!("{}\0{}", image.stamp, size.unwrap_or(0))));
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
    let mut target = image.path.clone();
    if let Some(size) = size
        && image.len <= MAX_DECODE_BYTES
        && let Some(resized) = resized(dir, image.path, key, size).await
    {
        target = resized;
    }
    let content_type = sniff(&target);
    file_response(&target, content_type, &request.headers, cache_headers)
        .await
        .map_err(|_| not_found())
}

/// The modification time in nanoseconds since the epoch, 0 when unknown.
fn modified_nanos(metadata: &fs::Metadata) -> u128 {
    metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |elapsed| elapsed.as_nanos())
}

/// The image a cover request serves.
struct Image {
    /// A cover file, or a picture extracted into the cache.
    path: PathBuf,
    /// The length of `path`.
    len: u64,
    /// Identifies this version of the image: the [`version_stamp`] of the
    /// cover file, or of the audio file embedding the picture.
    stamp: String,
}

/// The first of `files` on disk, else the first picture embedded in
/// `candidates` (audio file and extraction format), extracted into `dir` on
/// first use. Blocking.
fn find_image(
    dir: &Path,
    files: &[PathBuf],
    candidates: &[(PathBuf, &'static str)],
) -> Option<Image> {
    files
        .iter()
        .find_map(|path| {
            let metadata = fs::metadata(path).ok().filter(fs::Metadata::is_file)?;
            Some(Image {
                path: path.clone(),
                len: metadata.len(),
                stamp: version_stamp(path, &metadata),
            })
        })
        .or_else(|| {
            candidates
                .iter()
                .find_map(|(audio, format)| extract_cached(dir, audio, format))
        })
}

/// Identifies one version of a file: its path, mtime and length.
fn version_stamp(path: &Path, metadata: &fs::Metadata) -> String {
    format!(
        "{}\0{}\0{}",
        path.to_string_lossy(),
        modified_nanos(metadata),
        metadata.len()
    )
}

/// The first 16 bytes of the SHA-256 of `stamp`.
fn digest(stamp: &str) -> [u8; 16] {
    let mut key = [0u8; 16];
    key.copy_from_slice(&Sha256::digest(stamp.as_bytes())[..16]);
    key
}

fn without_picture() -> MutexGuard<'static, HashSet<[u8; 16]>> {
    WITHOUT_PICTURE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
}

fn remember_without_picture(key: [u8; 16]) {
    let mut remembered = without_picture();
    if remembered.len() >= MAX_WITHOUT_PICTURE {
        remembered.clear();
    }
    remembered.insert(key);
}

/// Whether the audio file at `path` embeds a picture `getCoverArt` would
/// serve; `None` when it is not a readable file. A file whose format cannot
/// embed one has none. Reads the picture without decoding it, and remembers
/// a file without one as `getCoverArt` does. Blocking.
pub fn embeds_picture(path: &Path) -> Option<bool> {
    let metadata = fs::metadata(path).ok().filter(fs::Metadata::is_file)?;
    let suffix = path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(str::to_ascii_lowercase)
        .unwrap_or_default();
    let Some(format) = cover_format(&suffix) else {
        return Some(false);
    };
    let key = digest(&format!("embedded\0{}", version_stamp(path, &metadata)));
    if without_picture().contains(&key) {
        return Some(false);
    }
    let mut file = fs::File::open(path).ok()?;
    match mornye_core::tags::extract_cover(&mut file, format, &|| Ok(())) {
        Ok(cover) if !cover.data.is_empty() => Some(true),
        _ => {
            remember_without_picture(key);
            Some(false)
        }
    }
}

/// The cached picture of `audio`, extracted when missing. `None` when the
/// file is unreadable or embeds no picture (remembered), or the cache is
/// unwritable.
fn extract_cached(dir: &Path, audio: &Path, format: &str) -> Option<Image> {
    let metadata = fs::metadata(audio).ok().filter(fs::Metadata::is_file)?;
    // The picture is a version of the audio file, whatever its cached copy.
    let stamp = format!("embedded\0{}", version_stamp(audio, &metadata));
    let key = digest(&stamp);
    if without_picture().contains(&key) {
        return None;
    }
    let name = hex(&key);
    if let Some((path, len)) = CACHED_EXTENSIONS
        .iter()
        .map(|extension| dir.join(format!("{name}.{extension}")))
        .find_map(|path| {
            let len = fs::metadata(&path)
                .ok()
                .filter(|cached| cached.is_file() && cached.len() > 0)?
                .len();
            Some((path, len))
        })
    {
        return Some(Image { path, len, stamp });
    }
    let mut file = fs::File::open(audio).ok()?;
    let cover = match mornye_core::tags::extract_cover(&mut file, format, &|| Ok(())) {
        Ok(cover) if !cover.data.is_empty() => cover,
        _ => {
            remember_without_picture(key);
            return None;
        }
    };
    let path = dir.join(format!("{name}.{}", image_extension(&cover.mime)));
    store(dir, &path, &cover.data)?;
    Some(Image {
        path,
        len: cover.data.len() as u64,
        stamp,
    })
}

/// The cache file extension for an embedded picture's MIME type.
fn image_extension(mime: &str) -> &'static str {
    let mime = mime.trim().to_ascii_lowercase();
    match mime.strip_prefix("image/").unwrap_or(&mime) {
        "png" => "png",
        "gif" => "gif",
        "webp" => "webp",
        "bmp" => "bmp",
        _ => "jpg",
    }
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
    store(dir, target, &encoded)?;
    Some(target.to_owned())
}

static STAGING: AtomicU64 = AtomicU64::new(0);

/// Writes `bytes` to `target` in the cache `dir` through a staging file,
/// then trims the cache.
fn store(dir: &Path, target: &Path, bytes: &[u8]) -> Option<()> {
    fs::create_dir_all(dir).ok()?;
    let staging = dir.join(format!(
        ".{}-{}-{}.tmp",
        std::process::id(),
        STAGING.fetch_add(1, Ordering::Relaxed),
        target.file_stem()?.to_string_lossy()
    ));
    if fs::write(&staging, bytes)
        .and_then(|()| fs::rename(&staging, target))
        .is_err()
    {
        let _ = fs::remove_file(&staging);
        return None;
    }
    trim_cache(dir, MAX_CACHED);
    Some(())
}

/// Removes the oldest cached covers beyond `keep`.
pub(super) fn trim_cache(dir: &Path, keep: usize) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = entries
        .filter_map(Result::ok)
        .filter(|entry| {
            entry.path().extension().is_some_and(|extension| {
                CACHED_EXTENSIONS.iter().any(|cached| extension == *cached)
            })
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
