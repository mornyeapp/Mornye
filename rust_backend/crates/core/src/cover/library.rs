//! Bounded thumbnail reuse for tracks that embed the same album artwork.

use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, OnceLock, TryLockError};
use std::time::Duration;

const MAX_BYTES: usize = 8 << 20;
const MAX_ENTRIES: usize = 32;
static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
static DECODE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

/// Android Library names identify the final thumbnail bytes, independently
/// of the song, source, and original image encoding.
pub fn library_content_stem(data: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let digest = Sha256::digest(data);
    let mut out = String::with_capacity("cover_content_".len() + digest.len() * 2);
    out.push_str("cover_content_");
    for &byte in &digest {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

struct Entry {
    digest: [u8; 32],
    original_len: usize,
    thumbnail: Arc<[u8]>,
    stored: Arc<Mutex<Option<String>>>,
    bytes: usize,
}

/// A Library thumbnail. Every hit on the same artwork shares `stored`, where
/// a caller notes the file that holds these bytes, so the next song can link
/// that file instead of writing them again.
pub struct LibraryThumbnail {
    pub data: Arc<[u8]>,
    pub stored: Arc<Mutex<Option<String>>>,
}

#[derive(Default)]
struct Cache {
    entries: VecDeque<Entry>,
    bytes: usize,
}

impl Cache {
    fn get(&mut self, digest: &[u8; 32], original_len: usize) -> Option<LibraryThumbnail> {
        let index = self
            .entries
            .iter()
            .position(|entry| entry.original_len == original_len && entry.digest == *digest)?;
        let entry = self.entries.remove(index).expect("cached thumbnail");
        let thumbnail = LibraryThumbnail {
            data: entry.thumbnail.clone(),
            stored: entry.stored.clone(),
        };
        self.entries.push_back(entry);
        Some(thumbnail)
    }

    fn insert(&mut self, entry: Entry) {
        if entry.bytes > MAX_BYTES {
            return;
        }
        while self.bytes + entry.bytes > MAX_BYTES || self.entries.len() >= MAX_ENTRIES {
            self.bytes -= self
                .entries
                .pop_front()
                .expect("nonempty thumbnail cache")
                .bytes;
        }
        self.bytes += entry.bytes;
        self.entries.push_back(entry);
    }
}

fn lock_checked<'a, T>(
    mutex: &'a Mutex<T>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<std::sync::MutexGuard<'a, T>, String> {
    loop {
        check()?;
        match mutex.try_lock() {
            Ok(guard) => return Ok(guard),
            Err(TryLockError::WouldBlock) => std::thread::sleep(Duration::from_millis(10)),
            Err(TryLockError::Poisoned(_)) => return Err("thumbnail cache unavailable".into()),
        }
    }
}

/// Large decodes run one at a time; tag reads and cache hits stay parallel.
/// Artwork is reused by content, so alternate covers are never confused.
pub fn library_thumbnail(
    data: &[u8],
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Arc<[u8]>, String> {
    library_thumbnail_entry(data, check).map(|thumbnail| thumbnail.data)
}

/// [`library_thumbnail`] with the record of where its bytes are stored.
pub fn library_thumbnail_entry(
    data: &[u8],
    check: &dyn Fn() -> Result<(), String>,
) -> Result<LibraryThumbnail, String> {
    check()?;
    let digest: [u8; 32] = Sha256::digest(data).into();
    let original_len = data.len();
    let cache_mutex = CACHE.get_or_init(Mutex::default);
    {
        let mut cache = lock_checked(cache_mutex, check)?;
        if let Some(hit) = cache.get(&digest, original_len) {
            return Ok(hit);
        }
    }
    let decode_mutex = DECODE_LOCK.get_or_init(|| Mutex::new(()));
    let _decode_guard = lock_checked(decode_mutex, check)?;
    {
        let mut cache = lock_checked(cache_mutex, check)?;
        if let Some(hit) = cache.get(&digest, original_len) {
            return Ok(hit);
        }
    }
    let resized = super::resize(data, super::LIBRARY_MAX_DIMENSION, check)?;
    check()?;
    let thumbnail: Arc<[u8]> = match resized {
        std::borrow::Cow::Borrowed(bytes) => bytes.into(),
        std::borrow::Cow::Owned(bytes) => bytes.into(),
    };
    let bytes = thumbnail.len();
    let stored = Arc::<Mutex<_>>::default();
    if bytes <= MAX_BYTES {
        let mut cache = lock_checked(cache_mutex, check)?;
        if let Some(hit) = cache.get(&digest, original_len) {
            return Ok(hit);
        }
        cache.insert(Entry {
            digest,
            original_len,
            thumbnail: thumbnail.clone(),
            stored: stored.clone(),
            bytes,
        });
    }
    Ok(LibraryThumbnail {
        data: thumbnail,
        stored,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, ImageFormat, Rgb};
    use std::io::Cursor;

    #[test]
    fn android_content_names_use_the_complete_sha256() {
        assert_eq!(
            library_content_stem(b"abc"),
            "cover_content_ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_ne!(library_content_stem(b"abc"), library_content_stem(b"abd"));
    }

    #[test]
    fn repeated_artwork_reuses_pixels_and_checks_cancellation_on_hits() {
        let mut png = Cursor::new(Vec::new());
        ImageBuffer::from_pixel(1000, 1000, Rgb([30_u8, 90, 150]))
            .write_to(&mut png, ImageFormat::Png)
            .unwrap();
        let first = library_thumbnail(png.get_ref(), &|| Ok(())).unwrap();
        let second = library_thumbnail(png.get_ref(), &|| Ok(())).unwrap();
        assert!(Arc::ptr_eq(&first, &second));
        assert_eq!(super::super::dimensions(&first), (800, 800));
        assert!(library_thumbnail(png.get_ref(), &|| Err("cancelled".into())).is_err());
    }

    #[test]
    fn hits_on_the_same_artwork_share_where_it_is_stored() {
        let picture = |red: u8| {
            let mut png = Cursor::new(Vec::new());
            ImageBuffer::from_pixel(900, 900, Rgb([red, 7, 7]))
                .write_to(&mut png, ImageFormat::Png)
                .unwrap();
            png.into_inner()
        };
        let first = library_thumbnail_entry(&picture(11), &|| Ok(())).unwrap();
        *first.stored.lock().unwrap() = Some("first.jpg".into());
        let again = library_thumbnail_entry(&picture(11), &|| Ok(())).unwrap();
        assert!(Arc::ptr_eq(&first.data, &again.data));
        assert_eq!(again.stored.lock().unwrap().as_deref(), Some("first.jpg"));
        let other = library_thumbnail_entry(&picture(12), &|| Ok(())).unwrap();
        assert_eq!(*other.stored.lock().unwrap(), None);
    }

    #[test]
    fn oversized_original_still_returns_a_resized_thumbnail() {
        let mut png = Cursor::new(Vec::new());
        ImageBuffer::from_pixel(1000, 1000, Rgb([30_u8, 90, 150]))
            .write_to(&mut png, ImageFormat::Png)
            .unwrap();
        // Trailing bytes leave the decoded pixels unchanged but put the
        // original beyond the cache budget.
        png.get_mut().resize(MAX_BYTES + 1, 0);
        let thumbnail = library_thumbnail(png.get_ref(), &|| Ok(())).unwrap();
        assert_eq!(super::super::dimensions(&thumbnail), (800, 800));
        assert!(thumbnail.len() < MAX_BYTES);
        let cache = CACHE.get().unwrap().lock().unwrap();
        assert!(cache.entries.iter().all(|entry| entry.bytes <= MAX_BYTES));
    }

    #[test]
    fn cache_has_fixed_byte_and_entry_bounds() {
        let mut cache = Cache::default();
        for hash in 0_u64..100 {
            let mut digest = [0_u8; 32];
            digest[..8].copy_from_slice(&hash.to_le_bytes());
            let data: Arc<[u8]> = vec![0; 1 << 20].into();
            cache.insert(Entry {
                digest,
                original_len: 1 << 20,
                thumbnail: data,
                stored: Arc::default(),
                bytes: 1 << 20,
            });
            assert!(cache.bytes <= MAX_BYTES);
            assert!(cache.entries.len() <= MAX_ENTRIES);
        }
        assert_eq!(cache.bytes, MAX_BYTES);
        assert_eq!(
            u64::from_le_bytes(
                cache.entries.front().unwrap().digest[..8]
                    .try_into()
                    .unwrap()
            ),
            92
        );
    }
}
