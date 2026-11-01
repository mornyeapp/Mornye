//! Backend cover art handling: downloading, resizing, extracting from audio files, and caching.

use super::Backend;
use crate::files::{StagedFile, SyncBatch};
use cap_std::fs::OpenOptions;
use mornye_core::app_version::AppVersion;
use mornye_core::cover::{MAX_DOWNLOAD_BYTES, resize};
use mornye_core::tags::{CoverArt, extract_cover};
use mornye_network::{
    HttpRequest, NetworkService, NetworkSession, random_user_agent, url::UrlParts,
};
use sha2::{Digest, Sha256};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

type Check<'a> = dyn Fn() -> Result<(), String> + 'a;
type Outcome = Result<Arc<[u8]>, String>;
const CACHE_TTL: Duration = Duration::from_secs(15 * 60);
const SIZE_ERROR: &str = "cover download exceeds 24 MiB limit";

/// A forced rescan touches this file in the Library cover directory.
/// Thumbnails older than it are extracted again under the same name, so
/// playlists, sessions and statistics keep valid paths.
pub const LIBRARY_COVER_REGENERATE_MARKER: &str = ".regenerate";

/// File stem of the Library thumbnail cached under `key`. 128 bits of
/// SHA-256 make reuse by name safe: two songs never share a thumbnail.
pub fn library_cover_stem(key: &str) -> String {
    let digest = Sha256::digest(key.as_bytes());
    let hex: String = digest[..16]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    format!("cover_{hex}")
}

/// Songs that embed the same picture share one stored thumbnail through hard
/// links on desktop and iOS; every song keeps its own name. Android keeps a
/// file per song (content-addressed names there are a separate change), and
/// so does Windows, where a reader's sharing mode covers every name of a file.
const LINK_THUMBNAILS: bool = cfg!(any(target_vendor = "apple", target_os = "linux"));

/// Whether a thumbnail written at `modified` may be reused after the
/// directory's regenerate marker was touched at `regenerate`.
pub fn library_cover_is_current(modified: SystemTime, regenerate: Option<SystemTime>) -> bool {
    regenerate.is_none_or(|marker| modified >= marker)
}

struct Entry {
    data: Arc<[u8]>,
    expires: Instant,
}

#[derive(Default)]
struct Cache {
    entries: BTreeMap<String, Entry>,
    bytes: usize,
    flights: BTreeMap<String, Arc<Flight>>,
}

#[derive(Default)]
struct Flight {
    // Outer None is pending; inner None asks followers to retry after the
    // leader's cancellation. One caller cannot cancel another caller's work.
    outcome: Mutex<Option<Option<Outcome>>>,
    ready: Condvar,
}

pub(super) struct Cover {
    network: Arc<NetworkSession>,
    version: AppVersion,
    cache: Mutex<Cache>,
}

impl Cover {
    pub fn new(network: &Arc<NetworkService>, version: AppVersion) -> Self {
        Self {
            network: network.native_media_session(Duration::from_secs(60)),
            version,
            cache: Mutex::default(),
        }
    }

    pub fn clear(&self) {
        let mut cache = self.cache.lock().expect("cover cache lock");
        cache.entries.clear();
        cache.bytes = 0;
    }

    pub(super) fn download(&self, url: &str, limit: i64, check: &Check<'_>) -> Outcome {
        let key = if limit <= 0 {
            url.to_owned()
        } else {
            format!("{url}\0max-dimension={limit}")
        };
        self.cached(&key, check, &|| {
            if limit <= 0 {
                return self.fetch(url, check);
            }
            let original = self.download(url, 0, check)?;
            match resize(&original, limit, check)
                .map_err(|error| format!("resize artwork: {error}"))?
            {
                std::borrow::Cow::Borrowed(_) => Ok(original),
                std::borrow::Cow::Owned(data) => Ok(data.into()),
            }
        })
    }

    fn cached(&self, key: &str, check: &Check<'_>, fetch: &dyn Fn() -> Outcome) -> Outcome {
        loop {
            check()?;
            let (flight, leader) = {
                let mut cache = self.cache.lock().expect("cover cache lock");
                if let Some(entry) = cache.entries.get(key) {
                    if Instant::now() < entry.expires {
                        return Ok(entry.data.clone());
                    }
                    let entry = cache.entries.remove(key).expect("expired cover entry");
                    cache.bytes -= entry.data.len();
                }
                if let Some(flight) = cache.flights.get(key) {
                    (flight.clone(), false)
                } else {
                    let flight = Arc::new(Flight::default());
                    cache.flights.insert(key.into(), flight.clone());
                    (flight, true)
                }
            };
            if !leader {
                let mut outcome = flight.outcome.lock().expect("cover flight lock");
                loop {
                    check()?;
                    match outcome.as_ref() {
                        Some(Some(result)) => return result.clone(),
                        Some(None) => break,
                        None => {
                            outcome = flight
                                .ready
                                .wait_timeout(outcome, Duration::from_millis(25))
                                .expect("cover flight wait")
                                .0;
                        }
                    }
                }
                continue;
            }
            // A decoder/transport panic must not strand coalesced callers.
            let result = catch_unwind(AssertUnwindSafe(fetch))
                .unwrap_or_else(|_| Err("cover fetch aborted".into()));
            let cancelled = check().err();
            let mut cache = self.cache.lock().expect("cover cache lock");
            if cancelled.is_none()
                && let Ok(data) = &result
                && !data.is_empty()
                && data.len() <= MAX_DOWNLOAD_BYTES
            {
                cache.bytes += data.len();
                cache.entries.insert(
                    key.into(),
                    Entry {
                        data: data.clone(),
                        expires: Instant::now() + CACHE_TTL,
                    },
                );
                while cache.bytes > MAX_DOWNLOAD_BYTES {
                    let oldest = cache
                        .entries
                        .iter()
                        .min_by_key(|(_, entry)| entry.expires)
                        .map(|(key, _)| key.clone())
                        .expect("nonempty cover cache");
                    cache.bytes -= cache.entries.remove(&oldest).unwrap().data.len();
                }
            }
            cache.flights.remove(key);
            *flight.outcome.lock().expect("cover flight lock") =
                Some(cancelled.is_none().then(|| result.clone()));
            flight.ready.notify_all();
            return cancelled.map_or(result, Err);
        }
    }

    fn fetch(&self, url: &str, check: &Check<'_>) -> Outcome {
        let parsed = UrlParts::parse(url)
            .ok_or_else(|| "failed to create request: invalid URL".to_owned())?;
        let user_agent = if parsed.hostname.eq_ignore_ascii_case("api.zarz.moe") {
            self.version.user_agent()
        } else {
            random_user_agent()
        };
        let mut response = self
            .network
            .open_response_stream(
                HttpRequest {
                    url: url.into(),
                    method: "GET".into(),
                    body: String::new(),
                    headers: BTreeMap::new(),
                    default_json: false,
                    user_agent,
                },
                check,
            )
            .map_err(|error| format!("failed to download cover: {error}"))?;
        if response.response.status != 200 {
            return Err(format!(
                "cover download failed: HTTP {}",
                response.response.status
            ));
        }
        if response
            .response
            .headers
            .get("Content-Length")
            .and_then(|values| values.first())
            .and_then(|value| value.parse::<u64>().ok())
            .is_some_and(|length| length > MAX_DOWNLOAD_BYTES as u64)
        {
            return Err(SIZE_ERROR.into());
        }
        let mut data = Vec::new();
        let mut buffer = [0; 64 * 1024];
        loop {
            let capacity = buffer.len().min(MAX_DOWNLOAD_BYTES + 1 - data.len());
            let count = response
                .read(&mut buffer[..capacity], check)
                .map_err(|error| format!("failed to read cover data: {error}"))?;
            if count == 0 {
                break;
            }
            data.extend_from_slice(&buffer[..count]);
            if data.len() > MAX_DOWNLOAD_BYTES {
                return Err(SIZE_ERROR.into());
            }
        }
        Ok(data.into())
    }
}

impl Backend {
    pub fn extract_cover_to_file(
        &self,
        audio_path: &str,
        output_path: &str,
        check: &Check<'_>,
    ) -> Result<(), String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        check()?;
        let format = extension(audio_path);
        if !matches!(
            format.as_str(),
            "flac" | "m4a" | "aac" | "mp3" | "ogg" | "opus" | "wav" | "aiff" | "aif" | "aifc"
        ) {
            return Err("unsupported audio format for cover extraction".into());
        }
        let files = self.manager.environment().native_files()?;
        let input = files.resolve_legacy(audio_path)?;
        let cover = read_cover(&input, &format, &check)
            .map_err(|error| format!("failed to extract cover: {error}"))?;
        let write = || {
            let output = files.resolve_legacy(output_path)?;
            if input.absolute == output.absolute {
                return Err("cover output must differ from the audio source".into());
            }
            let _lock = files.lock(&output, &check)?;
            let permissions = output_permissions(&output)?;
            publish_cover(&output, permissions, &cover.data, &check)
        };
        write().map_err(|error| format!("failed to write cover file: {error}"))
    }

    pub fn save_cover_to_cache_with_hint_and_key(
        &self,
        audio_path: &str,
        hint: &str,
        cache_directory: &str,
        explicit_key: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        self.cache_cover(
            audio_path,
            hint,
            cache_directory,
            explicit_key,
            None,
            read_cover,
            None,
            check,
        )
    }

    /// With `batch`, the scan flushes the thumbnail folder once at its end
    /// instead of per file.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn save_cover_to_cache_for_scan(
        &self,
        audio_path: &str,
        hint: &str,
        cache_directory: &str,
        explicit_key: &str,
        read: impl FnOnce(&crate::files::FilePath, &str, &Check<'_>) -> Result<CoverArt, String>,
        batch: Option<&SyncBatch>,
        check: &Check<'_>,
    ) -> Result<String, String> {
        let format = mornye_core::tags::library_extension(audio_path, hint);
        // The scan's MP4-family reader also accepts .mp4/.aac. The standalone
        // cover export deliberately keeps its narrower legacy suffix policy.
        let format = matches!(format.as_str(), "mp4" | "aac").then_some("m4a");
        self.cache_cover(
            audio_path,
            hint,
            cache_directory,
            explicit_key,
            format,
            read,
            batch,
            check,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn cache_cover(
        &self,
        audio_path: &str,
        hint: &str,
        cache_directory: &str,
        explicit_key: &str,
        format_override: Option<&str>,
        read: impl FnOnce(&crate::files::FilePath, &str, &Check<'_>) -> Result<CoverArt, String>,
        batch: Option<&SyncBatch>,
        check: &Check<'_>,
    ) -> Result<String, String> {
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
        let files = self.manager.environment().native_files()?;
        let input = files.resolve_legacy(audio_path)?;
        input.native_display()?;
        let key = if !explicit_key.trim().is_empty() {
            explicit_key.trim().to_owned()
        } else if let Ok(metadata) = input.metadata() {
            let modified = metadata
                .modified()
                .map_err(|error| error.to_string())?
                .into_std();
            let nanos = match modified.duration_since(UNIX_EPOCH) {
                Ok(duration) => duration.as_nanos() as i128,
                Err(error) => -(error.duration().as_nanos() as i128),
            };
            format!("{audio_path}|{}|{nanos}", metadata.len())
        } else {
            audio_path.into()
        };
        let stem = library_cover_stem(&key);
        let path = |name: &str| Path::new(cache_directory).join(name);
        let jpg = files.resolve_legacy(&path(&format!("{stem}.jpg")).to_string_lossy())?;
        let png = files.resolve_legacy(&path(&format!("{stem}.png")).to_string_lossy())?;
        let regenerate = files
            .resolve_legacy(&path(LIBRARY_COVER_REGENERATE_MARKER).to_string_lossy())
            .ok()
            .and_then(|marker| marker.metadata().ok())
            .and_then(|metadata| metadata.modified().ok())
            .map(|modified| modified.into_std());
        jpg.native_display()?;
        png.native_display()?;
        // A regenerated thumbnail can change format; the newer file wins.
        if let Some((_, cached)) = [&jpg, &png]
            .into_iter()
            .filter_map(|cached| Some((reusable_cached_cover(cached, regenerate)?, cached)))
            .max_by_key(|(modified, _)| *modified)
        {
            return Ok(cached.display());
        }
        let mut format = extension(audio_path);
        if format.is_empty() {
            format = extension(hint);
        }
        if let Some(value) = format_override {
            format = value.into();
        }
        if !matches!(
            format.as_str(),
            "flac" | "m4a" | "mp3" | "ogg" | "opus" | "wav" | "aiff" | "aif" | "aifc"
        ) {
            return Err(format!(
                "unsupported format: {}",
                if format.is_empty() {
                    String::new()
                } else {
                    format!(".{format}")
                }
            ));
        }
        let mut cover = read(&input, &format, &check)?;
        let mut stored = None;
        if let Ok(thumbnail) = mornye_core::cover::library_thumbnail_entry(&cover.data, &check) {
            let resized = thumbnail.data;
            cover.mime = if resized.starts_with(b"\x89PNG") {
                "image/png"
            } else if resized.starts_with(b"\xff\xd8") {
                "image/jpeg"
            } else {
                &cover.mime
            }
            .into();
            cover.data = resized.to_vec();
            stored = LINK_THUMBNAILS.then_some(thumbnail.stored);
        }
        // Library caching may retain unsupported image bytes, but must never
        // swallow cancellation while attempting the optional resize.
        check()?;
        let output = if cover.mime.contains("png") { png } else { jpg };
        let _lock = files.lock(&output, &check)?;
        if reusable_cached_cover(&output, regenerate).is_some() {
            return Ok(output.display());
        }
        output
            .mkdir_parent()
            .map_err(|error| format!("failed to create cache dir: {error}"))?;
        let permissions = output_permissions(&output)
            .map_err(|error| format!("failed to write cover: {error}"))?;
        // Songs of one album reach this point together; holding the record
        // until the first file is published lets the others link it.
        let mut stored = stored.as_deref().and_then(|stored| stored.lock().ok());
        let source = stored
            .as_deref()
            .and_then(Option::as_deref)
            .and_then(|path| {
                stored_cover(
                    &files,
                    path,
                    &output,
                    &cover.data,
                    permissions.as_ref(),
                    regenerate,
                )
            });
        let source = source.as_ref().map(|(path, file)| (path, file));
        let stage = stage_cover(&output, permissions, &cover.data, source, &check)
            .map_err(|error| format!("failed to write cover: {error}"))?;
        match batch {
            Some(batch) => stage.publish_batched(batch, &check),
            None => stage.publish(&check),
        }
        .map_err(|error| format!("failed to write cover: {error}"))?;
        if let Some(stored) = stored.as_deref_mut() {
            *stored = Some(output.display());
        }
        Ok(output.display())
    }

    pub fn download_cover_to_file_sized(
        &self,
        url: &str,
        output_path: &str,
        max_dimension: i64,
        check: &Check<'_>,
    ) -> Result<(), String> {
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
        if url.is_empty() {
            return Err("no cover URL provided".into());
        }
        let files = self.manager.environment().native_files()?;
        // Validate and lock before doing network work for an unauthorized or
        // unavailable destination. Publication revalidates the same grant.
        let prepare = || {
            let output = files.resolve_legacy(output_path)?;
            let lock = files.lock(&output, &check)?;
            let permissions = output_permissions(&output)?;
            Ok((output, lock, permissions))
        };
        let (output, _lock, permissions) =
            prepare().map_err(|error: String| format!("failed to write cover file: {error}"))?;
        let data = self
            .cover
            .download(url, max_dimension, &check)
            .map_err(|error| format!("failed to download cover: {error}"))?;
        publish_cover(&output, permissions, &data, &check)
            .map_err(|error| format!("failed to write cover file: {error}"))
    }
}

fn extension(path: &str) -> String {
    Path::new(path)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_lowercase()
}

fn read_cover(
    input: &crate::files::FilePath,
    format: &str,
    check: &Check<'_>,
) -> Result<CoverArt, String> {
    input.native_display()?;
    let mut file = input
        .open(OpenOptions::new().read(true))
        .map_err(|error| error.to_string())?;
    extract_cover(&mut file, format, check)
}

/// The modification time of a cached thumbnail that may be reused. An empty
/// file, which a power loss before a scan's final flush can leave, is missing.
fn reusable_cached_cover(
    path: &crate::files::FilePath,
    regenerate: Option<SystemTime>,
) -> Option<SystemTime> {
    let metadata = path
        .metadata()
        .ok()
        .filter(|metadata| metadata.is_file() && metadata.len() > 0)?;
    let modified = metadata
        .modified()
        .map_or(UNIX_EPOCH, |modified| modified.into_std());
    if !library_cover_is_current(modified, regenerate) {
        return None;
    }
    // Re-extract legacy ID3 JPEG caches written with a leading NUL. Keep
    // other existing formats under the original cache reuse policy.
    let mut header = [0; 4];
    let padded = path
        .open(OpenOptions::new().read(true))
        .and_then(|mut file| file.read_exact(&mut header))
        .is_ok()
        && header == [0, 0xff, 0xd8, 0xff];
    (!padded).then_some(modified)
}

fn output_permissions(
    output: &crate::files::FilePath,
) -> Result<Option<cap_std::fs::Permissions>, String> {
    output.native_display()?;
    output.require_parent()?;
    match output.open(OpenOptions::new().write(true)) {
        Ok(file) => Ok(Some(
            file.metadata()
                .map_err(|error| error.to_string())?
                .permissions(),
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

/// `stored`, where an earlier song put this thumbnail, opened for linking. It
/// qualifies only while it holds exactly `data`, is current for the
/// regenerate marker and matches an existing output's permissions.
fn stored_cover(
    files: &crate::files::ExtensionFiles,
    stored: &str,
    output: &crate::files::FilePath,
    data: &[u8],
    permissions: Option<&cap_std::fs::Permissions>,
    regenerate: Option<SystemTime>,
) -> Option<(crate::files::FilePath, cap_std::fs::File)> {
    let source = files.resolve_legacy(stored).ok()?;
    if source.absolute == output.absolute {
        return None;
    }
    let mut file = source.open(OpenOptions::new().read(true)).ok()?;
    let metadata = file.metadata().ok()?;
    let modified = metadata.modified().ok()?.into_std();
    if metadata.len() != data.len() as u64
        || !library_cover_is_current(modified, regenerate)
        || permissions.is_some_and(|permissions| *permissions != metadata.permissions())
    {
        return None;
    }
    let mut bytes = Vec::with_capacity(data.len());
    (&mut file)
        .take(data.len() as u64 + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    (bytes == data).then_some((source, file))
}

fn publish_cover(
    output: &crate::files::FilePath,
    permissions: Option<cap_std::fs::Permissions>,
    data: &[u8],
    check: &Check<'_>,
) -> Result<(), String> {
    stage_cover(output, permissions, data, None, check)?.publish(check)
}

/// Stages `data` for `output`, as a hard link to `source` when it can.
fn stage_cover(
    output: &crate::files::FilePath,
    permissions: Option<cap_std::fs::Permissions>,
    data: &[u8],
    source: Option<(&crate::files::FilePath, &cap_std::fs::File)>,
    check: &Check<'_>,
) -> Result<StagedFile, String> {
    check()?;
    let mut stage = output
        .stage_existing_parent()
        .map_err(|error| error.to_string())?;
    if let Some(permissions) = permissions {
        stage
            .file
            .set_permissions(permissions)
            .map_err(|error| error.to_string())?;
    }
    if let Some((path, file)) = source {
        let permissions = stage
            .file
            .metadata()
            .map_err(|error| error.to_string())?
            .permissions();
        if file
            .metadata()
            .is_ok_and(|metadata| metadata.permissions() == permissions)
        {
            let (linked_stage, linked) = output
                .stage_from(path, file)
                .map_err(|error| error.to_string())?;
            if linked {
                return Ok(linked_stage);
            }
        }
    }
    for chunk in data.chunks(16 * 1024) {
        check()?;
        stage
            .file
            .write_all(chunk)
            .map_err(|error| error.to_string())?;
    }
    Ok(stage)
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use std::cell::Cell;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::mpsc;
    use std::thread;

    /// A `size` px JPEG with a little noise, so it compresses like album art.
    /// Each `seed` gives different bytes.
    pub(in crate::backend) fn artwork(seed: u32, size: u32) -> Vec<u8> {
        let mut state = seed.wrapping_mul(2_654_435_761) | 1;
        let image = image::RgbImage::from_fn(size, size, |x, y| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            let noise = (state & 63) as u8;
            image::Rgb([
                (x * 255 / size) as u8 ^ noise,
                (y * 255 / size) as u8 ^ noise,
                seed.wrapping_mul(37) as u8 ^ noise,
            ])
        });
        let mut jpeg = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 90)
            .encode_image(&image)
            .unwrap();
        jpeg
    }

    /// An untagged FLAC file with `jpeg` as its front cover.
    pub(in crate::backend) fn flac_with_picture(jpeg: &[u8]) -> Vec<u8> {
        let mut picture = 3_u32.to_be_bytes().to_vec();
        for field in [b"image/jpeg".as_slice(), b""] {
            picture.extend((field.len() as u32).to_be_bytes());
            picture.extend(field);
        }
        picture.extend([0; 16]);
        picture.extend((jpeg.len() as u32).to_be_bytes());
        picture.extend(jpeg);
        let mut info = [0; 34];
        let packed = (44_100_u64 << 44) | (1_u64 << 41) | (15_u64 << 36) | 44_100;
        info[10..18].copy_from_slice(&packed.to_be_bytes());
        let mut flac = b"fLaC\0".to_vec();
        flac.extend(&(info.len() as u32).to_be_bytes()[1..]);
        flac.extend(info);
        flac.push(0x86);
        flac.extend(&(picture.len() as u32).to_be_bytes()[1..]);
        flac.extend(picture);
        flac.extend([0xff, 0xf8]);
        flac
    }

    fn cover() -> Cover {
        Cover::new(&NetworkService::new().unwrap(), "1".into())
    }

    fn backend(directory: &Path) -> Backend {
        Backend::new(
            &directory.join("sources"),
            &directory.join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            crate::RuntimeLimits::default(),
        )
        .unwrap()
    }

    fn id3_audio(jpeg: &[u8]) -> Vec<u8> {
        let mut picture = b"\0image/jpeg\0\x03\0\0".to_vec();
        picture.extend(jpeg);
        let mut frame = b"APIC".to_vec();
        frame.extend((picture.len() as u32).to_be_bytes());
        frame.extend([0, 0]);
        frame.extend(picture);
        let mut audio = b"ID3\x03\0\0\0\0\0".to_vec();
        audio.push(frame.len() as u8);
        audio.extend(frame);
        audio
    }

    #[test]
    fn keys_that_collided_under_the_old_hash_get_separate_thumbnails() {
        let directory = tempfile::tempdir().unwrap();
        let backend = backend(directory.path());
        let data = directory.path().join("data");
        let cache = data.join("covers");
        // The old 32-bit name gave "song|AB" and "song|B!" one file.
        let mut cached = Vec::new();
        for (key, jpeg) in [
            ("song|AB", b"\xff\xd8\xff\xe0one".as_slice()),
            ("song|B!", b"\xff\xd8\xff\xe0two".as_slice()),
        ] {
            let source = data.join(format!("{}.mp3", cached.len()));
            std::fs::write(&source, id3_audio(jpeg)).unwrap();
            let path = backend
                .save_cover_to_cache_with_hint_and_key(
                    source.to_str().unwrap(),
                    "",
                    cache.to_str().unwrap(),
                    key,
                    &|| Ok(()),
                )
                .unwrap();
            assert_eq!(std::fs::read(&path).unwrap(), jpeg);
            cached.push(path);
        }
        assert_ne!(cached[0], cached[1]);
        assert_eq!(
            Path::new(&cached[0]).file_name().unwrap(),
            format!("{}.jpg", library_cover_stem("song|AB")).as_str()
        );
    }

    #[test]
    fn a_forced_rescan_regenerates_thumbnails_under_the_same_name() {
        let directory = tempfile::tempdir().unwrap();
        let backend = backend(directory.path());
        let data = directory.path().join("data");
        let cache = data.join("covers");
        let source = data.join("track.mp3");
        let save = |jpeg: &[u8]| {
            std::fs::write(&source, id3_audio(jpeg)).unwrap();
            backend
                .save_cover_to_cache_with_hint_and_key(
                    source.to_str().unwrap(),
                    "",
                    cache.to_str().unwrap(),
                    "content://provider/document/track",
                    &|| Ok(()),
                )
                .unwrap()
        };
        let cached = save(b"\xff\xd8\xff\xe0old");
        // A key without a timestamp keeps its thumbnail until a forced rescan.
        assert_eq!(save(b"\xff\xd8\xff\xe0new"), cached);
        assert_eq!(std::fs::read(&cached).unwrap(), b"\xff\xd8\xff\xe0old");
        std::fs::File::options()
            .write(true)
            .open(&cached)
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(60))
            .unwrap();
        std::fs::write(cache.join(LIBRARY_COVER_REGENERATE_MARKER), "").unwrap();
        assert_eq!(save(b"\xff\xd8\xff\xe0new"), cached);
        assert_eq!(std::fs::read(&cached).unwrap(), b"\xff\xd8\xff\xe0new");
        // Thumbnails written after the marker are reused again.
        assert_eq!(save(b"\xff\xd8\xff\xe0later"), cached);
        assert_eq!(std::fs::read(&cached).unwrap(), b"\xff\xd8\xff\xe0new");
    }

    #[test]
    fn padded_id3_cache_is_replaced_without_changing_the_audio() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        let backend = backend(directory.path());
        let jpeg = b"\xff\xd8\xff\xe0";
        let audio = id3_audio(jpeg);
        let source = data.join("track.mp3");
        std::fs::write(&source, &audio).unwrap();
        let cache = data.join("covers");
        let save = || {
            backend
                .save_cover_to_cache_with_hint_and_key(
                    source.to_str().unwrap(),
                    "",
                    cache.to_str().unwrap(),
                    "track",
                    &|| Ok(()),
                )
                .unwrap()
        };
        let cached = save();
        assert_eq!(std::fs::read(&cached).unwrap(), jpeg);
        std::fs::write(&cached, [b"\0".as_slice(), jpeg].concat()).unwrap();
        assert_eq!(save(), cached);
        assert_eq!(std::fs::read(&cached).unwrap(), jpeg);
        assert_eq!(std::fs::read(&source).unwrap(), audio);
    }

    #[cfg(unix)]
    fn inode(path: &str) -> u64 {
        use std::os::unix::fs::MetadataExt;
        std::fs::metadata(path).unwrap().ino()
    }

    /// Desktop and iOS link identical thumbnails; Android keeps copies.
    const LINKED: bool = cfg!(any(target_vendor = "apple", target_os = "linux"));

    #[cfg(unix)]
    #[test]
    fn songs_with_the_same_picture_link_one_file_that_still_holds_it() {
        let directory = tempfile::tempdir().unwrap();
        let backend = backend(directory.path());
        let data = directory.path().join("data");
        let cache = data.join("covers");
        let art = artwork(9_100, 600);
        let save = |key: &str, picture: &[u8]| {
            let source = data.join(format!("{key}.flac"));
            std::fs::write(&source, flac_with_picture(picture)).unwrap();
            backend
                .save_cover_to_cache_with_hint_and_key(
                    source.to_str().unwrap(),
                    "",
                    cache.to_str().unwrap(),
                    key,
                    &|| Ok(()),
                )
                .unwrap()
        };
        let first = save("first", &art);
        let second = save("second", &art);
        let other = save("other", &artwork(9_101, 600));
        assert_ne!(first, second);
        assert_eq!(std::fs::read(&second).unwrap(), art);
        assert_eq!(inode(&first) == inode(&second), LINKED);
        assert_ne!(inode(&first), inode(&other));

        // Removing one name leaves the other song's cover in place.
        std::fs::remove_file(&first).unwrap();
        assert_eq!(std::fs::read(&second).unwrap(), art);
        let third = save("third", &art);
        assert_eq!(inode(&third) == inode(&second), LINKED);

        // A stored file that no longer holds the bytes is never linked.
        let replaced = cache.join("replaced");
        std::fs::write(&replaced, vec![0; art.len()]).unwrap();
        std::fs::rename(&replaced, &third).unwrap();
        let fourth = save("fourth", &art);
        assert_eq!(std::fs::read(&fourth).unwrap(), art);
        assert_ne!(inode(&fourth), inode(&third));
        assert_eq!(std::fs::read(&second).unwrap(), art);
    }

    #[cfg(unix)]
    #[test]
    fn a_new_thumbnail_keeps_fresh_file_permissions() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let directory = tempfile::tempdir().unwrap();
        let backend = backend(directory.path());
        let data = directory.path().join("data");
        let cache = data.join("covers");
        let art = artwork(9_150, 600);
        let save = |key: &str| {
            let source = data.join(format!("{key}.flac"));
            std::fs::write(&source, flac_with_picture(&art)).unwrap();
            backend
                .save_cover_to_cache_with_hint_and_key(
                    source.to_str().unwrap(),
                    "",
                    cache.to_str().unwrap(),
                    key,
                    &|| Ok(()),
                )
                .unwrap()
        };
        let first = save("first");
        let mode = std::fs::metadata(&first).unwrap().mode() & 0o7777;
        std::fs::set_permissions(&first, std::fs::Permissions::from_mode(mode ^ 0o040)).unwrap();

        let second = save("second");
        assert_eq!(std::fs::metadata(&second).unwrap().mode() & 0o7777, mode);
        assert_ne!(inode(&first), inode(&second));
        assert_eq!(std::fs::read(&second).unwrap(), art);
    }

    #[cfg(unix)]
    #[test]
    fn a_thumbnail_older_than_the_regenerate_marker_is_not_linked() {
        let directory = tempfile::tempdir().unwrap();
        let backend = backend(directory.path());
        let data = directory.path().join("data");
        let cache = data.join("covers");
        let art = artwork(9_200, 600);
        let save = |key: &str| {
            let source = data.join(format!("{key}.flac"));
            std::fs::write(&source, flac_with_picture(&art)).unwrap();
            backend
                .save_cover_to_cache_with_hint_and_key(
                    source.to_str().unwrap(),
                    "",
                    cache.to_str().unwrap(),
                    key,
                    &|| Ok(()),
                )
                .unwrap()
        };
        let stale = save("stale");
        std::fs::File::options()
            .write(true)
            .open(&stale)
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(60))
            .unwrap();
        std::fs::write(cache.join(LIBRARY_COVER_REGENERATE_MARKER), "").unwrap();
        let fresh = save("fresh");
        assert_ne!(inode(&fresh), inode(&stale));
        assert_eq!(std::fs::read(&fresh).unwrap(), art);
        let later = save("later");
        assert_eq!(inode(&later) == inode(&fresh), LINKED);
    }

    #[test]
    fn an_empty_thumbnail_is_extracted_again() {
        let directory = tempfile::tempdir().unwrap();
        let data = directory.path().join("data");
        let backend = backend(directory.path());
        let jpeg = b"\xff\xd8\xff\xe0empty";
        let source = data.join("track.mp3");
        std::fs::write(&source, id3_audio(jpeg)).unwrap();
        let cache = data.join("covers");
        let save = || {
            backend
                .save_cover_to_cache_with_hint_and_key(
                    source.to_str().unwrap(),
                    "",
                    cache.to_str().unwrap(),
                    "track",
                    &|| Ok(()),
                )
                .unwrap()
        };
        let cached = save();
        // What a power loss between a scan's fsync and its final flush can leave.
        std::fs::write(&cached, b"").unwrap();
        assert_eq!(save(), cached);
        assert_eq!(std::fs::read(&cached).unwrap(), jpeg);
    }

    #[test]
    fn cache_coalesces_and_a_cancelled_caller_does_not_cancel_its_peer() {
        for cancel_leader in [false, true] {
            let cover = cover();
            let (entered_tx, entered_rx) = mpsc::channel();
            let (release_tx, release_rx) = mpsc::channel();
            let (waiting_tx, waiting_rx) = mpsc::channel();
            let cancelled = AtomicBool::new(false);
            let calls = AtomicUsize::new(0);
            thread::scope(|scope| {
                let cover = &cover;
                let cancelled = &cancelled;
                let calls = &calls;
                let leader = scope.spawn(move || {
                    cover.cached(
                        "shared",
                        &|| {
                            if cancelled.load(Ordering::Acquire) {
                                Err("leader cancelled".into())
                            } else {
                                Ok(())
                            }
                        },
                        &|| {
                            calls.fetch_add(1, Ordering::AcqRel);
                            entered_tx.send(()).unwrap();
                            release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                            Ok(Arc::from(&b"leader"[..]))
                        },
                    )
                });
                entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                let follower = scope.spawn(|| {
                    let checks = Cell::new(0);
                    cover.cached(
                        "shared",
                        &|| {
                            checks.set(checks.get() + 1);
                            if checks.get() == 2 {
                                waiting_tx.send(()).unwrap();
                                if !cancel_leader {
                                    return Err("follower cancelled".into());
                                }
                            }
                            Ok(())
                        },
                        &|| {
                            calls.fetch_add(1, Ordering::AcqRel);
                            Ok(Arc::from(&b"follower"[..]))
                        },
                    )
                });
                waiting_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                cancelled.store(cancel_leader, Ordering::Release);
                release_tx.send(()).unwrap();
                let (leader, follower) = (leader.join().unwrap(), follower.join().unwrap());
                let expected = if cancel_leader {
                    assert_eq!(leader.unwrap_err(), "leader cancelled");
                    assert_eq!(follower.unwrap().as_ref(), b"follower");
                    assert_eq!(calls.load(Ordering::Acquire), 2);
                    &b"follower"[..]
                } else {
                    assert_eq!(leader.unwrap().as_ref(), b"leader");
                    assert_eq!(follower.unwrap_err(), "follower cancelled");
                    assert_eq!(calls.load(Ordering::Acquire), 1);
                    &b"leader"[..]
                };
                assert_eq!(
                    cover
                        .cached("shared", &|| Ok(()), &|| panic!("cache miss"))
                        .unwrap()
                        .as_ref(),
                    expected
                );
            });
        }
    }

    #[test]
    fn cache_expires_evicts_by_byte_budget_and_does_not_retain_failures() {
        let cover = cover();
        let fetches = Cell::new(0);
        let fetch = || {
            fetches.set(fetches.get() + 1);
            Ok(Arc::from(vec![42; 16 << 20]))
        };
        for key in ["first", "first", "second", "first"] {
            assert_eq!(
                cover.cached(key, &|| Ok(()), &fetch).unwrap().len(),
                16 << 20
            );
        }
        assert_eq!(fetches.get(), 3);
        cover
            .cache
            .lock()
            .unwrap()
            .entries
            .get_mut("first")
            .unwrap()
            .expires = Instant::now() - Duration::from_secs(1);
        cover.cached("first", &|| Ok(()), &fetch).unwrap();
        assert_eq!(fetches.get(), 4);
        cover.clear();
        cover.cached("first", &|| Ok(()), &fetch).unwrap();
        assert_eq!(fetches.get(), 5);
        for _ in 0..2 {
            assert_eq!(
                cover
                    .cached("error", &|| Ok(()), &|| Err("HTTP 500".into()))
                    .unwrap_err(),
                "HTTP 500"
            );
        }
        assert_eq!(
            cover
                .cached("panic", &|| Ok(()), &|| panic!("decoder panic"))
                .unwrap_err(),
            "cover fetch aborted"
        );
        assert_eq!(
            cover.cached("panic", &|| Ok(()), &fetch).unwrap().len(),
            16 << 20
        );
        assert_eq!(fetches.get(), 6);
    }
}
