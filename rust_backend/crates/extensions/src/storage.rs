//! Go-compatible extension persistence. Each file is serialized per path.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine;
use base64::alphabet;
use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig};
use hmac::{Hmac, Mac};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, RwLock, RwLockReadGuard, Weak};
use std::time::SystemTime;
use zeroize::Zeroizing;

#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("extension storage closed")]
    Closed,
    #[error("extension storage master key must be 32 base64-encoded bytes")]
    InvalidKey,
    #[error("extension storage master key is not configured")]
    MissingKey,
    #[error("invalid extension ID")]
    InvalidExtensionId,
    #[error("extension storage path must be a regular file")]
    InvalidPath,
    #[error("ciphertext too short")]
    ShortCiphertext,
    #[error("cipher: message authentication failed")]
    Authentication,
    #[error("failed to generate nonce: {0}")]
    Random(String),
    #[error("{0}")]
    Io(#[from] io::Error),
    #[error("{0}")]
    Json(#[from] serde_json::Error),
    #[error("extension storage must contain a JSON object")]
    InvalidObject,
}

/// The platform supplies this key. Rust never persists it or includes it in Debug.
pub struct StorageMasterKey(Zeroizing<[u8; 32]>);

impl StorageMasterKey {
    pub fn from_base64(encoded: &str) -> Result<Self, StorageError> {
        let encoding = GeneralPurpose::new(
            &alphabet::STANDARD,
            GeneralPurposeConfig::new().with_decode_allow_trailing_bits(true),
        );
        let decoded = Zeroizing::new(
            encoding
                .decode(encoded.replace(['\r', '\n'], ""))
                .map_err(|_| StorageError::InvalidKey)?,
        );
        let key: [u8; 32] = decoded
            .as_slice()
            .try_into()
            .map_err(|_| StorageError::InvalidKey)?;
        Ok(Self(Zeroizing::new(key)))
    }

    pub fn derive(&self, extension_id: &str, purpose: &str) -> Zeroizing<[u8; 32]> {
        let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(self.0.as_ref())
            .expect("HMAC accepts any key length");
        // Keep the domain stable across app renames to decrypt existing snapshots.
        mac.update(b"SpotiFLAC Mobile extension storage v2\0");
        mac.update(purpose.as_bytes());
        mac.update(&[0]);
        mac.update(extension_id.as_bytes());
        Zeroizing::new(mac.finalize().into_bytes().into())
    }
}

/// Go's wire format: 12-byte nonce, ciphertext, then the 16-byte authentication tag.
pub fn encrypt(plaintext: &[u8], key: &[u8; 32]) -> Result<Vec<u8>, StorageError> {
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut nonce).map_err(|error| StorageError::Random(error.to_string()))?;
    let cipher = Aes256Gcm::new(key.into());
    let ciphertext = cipher
        .encrypt(&Nonce::from(nonce), plaintext)
        .map_err(|_| StorageError::Authentication)?;
    let mut result = Vec::with_capacity(nonce.len() + ciphertext.len());
    result.extend_from_slice(&nonce);
    result.extend_from_slice(&ciphertext);
    Ok(result)
}

pub fn decrypt(ciphertext: &[u8], key: &[u8; 32]) -> Result<Zeroizing<Vec<u8>>, StorageError> {
    if ciphertext.len() < 12 {
        return Err(StorageError::ShortCiphertext);
    }
    let cipher = Aes256Gcm::new(key.into());
    let plaintext = cipher
        .decrypt(
            ciphertext[..12].try_into().expect("checked nonce length"),
            &ciphertext[12..],
        )
        .map_err(|_| StorageError::Authentication)?;
    Ok(Zeroizing::new(plaintext))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StoreKind {
    Storage,
    Credentials,
    Settings,
}

impl StoreKind {
    fn filename(self) -> &'static str {
        match self {
            Self::Storage => "storage.json",
            Self::Credentials => ".credentials.enc",
            Self::Settings => "settings.enc",
        }
    }

    fn purpose(self) -> &'static str {
        match self {
            Self::Storage => "",
            Self::Credentials => "credentials",
            Self::Settings => "settings",
        }
    }
}

#[derive(PartialEq, Eq)]
struct Identity {
    length: u64,
    modified: Option<SystemTime>,
    #[cfg(unix)]
    inode: u64,
}

#[derive(Default)]
struct FileCache {
    snapshot: Option<Map<String, Value>>,
    identity: Option<Identity>,
    key_tag: Option<[u8; 32]>,
}

type SharedFile = Arc<Mutex<FileCache>>;

fn shared_file(path: &Path) -> SharedFile {
    static FILES: OnceLock<Mutex<HashMap<PathBuf, Weak<Mutex<FileCache>>>>> = OnceLock::new();
    let mut files = FILES
        .get_or_init(Mutex::default)
        .lock()
        .expect("extension file registry lock");
    if let Some(file) = files.get(path).and_then(Weak::upgrade) {
        return file;
    }
    files.retain(|_, file| file.strong_count() > 0);
    let file = Arc::new(Mutex::new(FileCache::default()));
    files.insert(path.to_owned(), Arc::downgrade(&file));
    file
}

/// Stores for one canonical data directory. Instances share locks and immutable
/// snapshots, while values returned to callers are independent deep copies.
pub struct ExtensionStore {
    directory: PathBuf,
    extension_id: String,
    master_key: Option<Arc<StorageMasterKey>>,
    credentials_tag: OnceLock<Option<[u8; 32]>>,
    settings_tag: OnceLock<Option<[u8; 32]>>,
    storage: SharedFile,
    credentials: SharedFile,
    settings: SharedFile,
    salt: SharedFile,
    closed: RwLock<bool>,
}

impl ExtensionStore {
    pub fn open(
        directory: &Path,
        extension_id: &str,
        master_key: Option<Arc<StorageMasterKey>>,
    ) -> Result<Self, StorageError> {
        if !valid_extension_id(extension_id) {
            return Err(StorageError::InvalidExtensionId);
        }
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(directory)?;
        let directory = fs::canonicalize(directory)?;
        Ok(Self {
            storage: shared_file(&directory.join(StoreKind::Storage.filename())),
            credentials: shared_file(&directory.join(StoreKind::Credentials.filename())),
            settings: shared_file(&directory.join(StoreKind::Settings.filename())),
            salt: shared_file(&directory.join(".cred_salt")),
            directory,
            extension_id: extension_id.to_owned(),
            master_key,
            credentials_tag: OnceLock::new(),
            settings_tag: OnceLock::new(),
            closed: RwLock::new(false),
        })
    }

    fn file(&self, kind: StoreKind) -> &SharedFile {
        match kind {
            StoreKind::Storage => &self.storage,
            StoreKind::Credentials => &self.credentials,
            StoreKind::Settings => &self.settings,
        }
    }

    fn key(&self, kind: StoreKind) -> Result<Zeroizing<[u8; 32]>, StorageError> {
        Ok(self
            .master_key
            .as_ref()
            .ok_or(StorageError::MissingKey)?
            .derive(&self.extension_id, kind.purpose()))
    }

    fn cache_tag(&self, kind: StoreKind) -> Option<[u8; 32]> {
        let cache = match kind {
            StoreKind::Storage => return None,
            StoreKind::Credentials => &self.credentials_tag,
            StoreKind::Settings => &self.settings_tag,
        };
        *cache.get_or_init(|| {
            self.master_key.as_ref().map(|key| {
                Sha256::digest(key.derive(&self.extension_id, kind.purpose()).as_ref()).into()
            })
        })
    }

    fn refresh<'a>(
        &self,
        kind: StoreKind,
        cache: &'a mut FileCache,
    ) -> Result<&'a Map<String, Value>, StorageError> {
        let path = self.directory.join(kind.filename());
        let identity = file_identity(&path)?;
        let key_tag = self.cache_tag(kind);
        if cache.snapshot.is_none()
            || cache.identity != identity
            || cache.key_tag != key_tag
            || (kind == StoreKind::Settings && identity.is_none())
        {
            let snapshot = match read_optional(&path)? {
                Some(data) if kind == StoreKind::Storage => parse_object(&data)?,
                Some(data) => {
                    let key = self.key(kind)?;
                    let plaintext = match decrypt(&data, &key) {
                        Ok(plaintext) => plaintext,
                        Err(error) if kind == StoreKind::Credentials => {
                            let legacy = self.legacy_credentials_key()?;
                            let plaintext = decrypt(&data, &legacy).map_err(|_| error)?;
                            // Validate before replacing a legacy file. Corrupt data is preserved.
                            parse_object(&plaintext)?;
                            atomic_write(&path, &encrypt(&plaintext, &key)?)?;
                            plaintext
                        }
                        Err(error) => return Err(error),
                    };
                    parse_object(&plaintext)?
                }
                None if kind == StoreKind::Settings => self.migrate_settings(&path)?,
                None => Map::new(),
            };
            cache.identity = file_identity(&path)?;
            cache.key_tag = key_tag;
            cache.snapshot = Some(snapshot);
        }
        Ok(cache.snapshot.as_ref().expect("loaded storage snapshot"))
    }

    fn legacy_credentials_key(&self) -> Result<Zeroizing<[u8; 32]>, StorageError> {
        let _guard = self.salt.lock().expect("extension salt lock");
        let path = self.directory.join(".cred_salt");
        let salt = match read_optional(&path)? {
            Some(salt) if salt.len() == 32 => salt,
            _ => {
                let mut salt = vec![0u8; 32];
                getrandom::fill(&mut salt)
                    .map_err(|error| StorageError::Random(error.to_string()))?;
                atomic_write(&path, &salt)?;
                salt
            }
        };
        let mut hash = Sha256::new();
        hash.update(self.extension_id.as_bytes());
        hash.update(&salt);
        Ok(Zeroizing::new(hash.finalize().into()))
    }

    fn migrate_settings(&self, path: &Path) -> Result<Map<String, Value>, StorageError> {
        let legacy = self.directory.join("settings.json");
        let Some(data) = read_optional(&legacy)? else {
            return Ok(Map::new());
        };
        let snapshot = parse_object(&data)?;
        let key = self.key(StoreKind::Settings)?;
        atomic_write(path, &encrypt(&data, &key)?)?;
        fs::remove_file(legacy)?;
        Ok(snapshot)
    }

    pub fn get(&self, kind: StoreKind, key: &str) -> Result<Option<Value>, StorageError> {
        let _access = self.access()?;
        let mut cache = self.file(kind).lock().expect("extension storage lock");
        Ok(self.refresh(kind, &mut cache)?.get(key).cloned())
    }

    pub fn all(&self, kind: StoreKind) -> Result<Map<String, Value>, StorageError> {
        let _access = self.access()?;
        let mut cache = self.file(kind).lock().expect("extension storage lock");
        Ok(self.refresh(kind, &mut cache)?.clone())
    }

    pub fn set(&self, kind: StoreKind, key: &str, value: Value) -> Result<(), StorageError> {
        self.mutate(kind, |snapshot| {
            if snapshot.get(key) == Some(&value) {
                return false;
            }
            snapshot.insert(key.to_owned(), value);
            true
        })
    }

    pub fn remove(&self, kind: StoreKind, key: &str) -> Result<(), StorageError> {
        self.mutate(kind, |snapshot| {
            let existed = snapshot.remove(key).is_some();
            // Go credentials.remove persists even if the key did not exist.
            existed || kind != StoreKind::Storage
        })
    }

    pub fn replace(&self, kind: StoreKind, value: Map<String, Value>) -> Result<(), StorageError> {
        self.mutate(kind, |snapshot| {
            *snapshot = value;
            true
        })
    }

    fn mutate(
        &self,
        kind: StoreKind,
        mutate: impl FnOnce(&mut Map<String, Value>) -> bool,
    ) -> Result<(), StorageError> {
        let _access = self.access()?;
        let mut cache = self.file(kind).lock().expect("extension storage lock");
        let mut snapshot = self.refresh(kind, &mut cache)?.clone();
        if !mutate(&mut snapshot) {
            return Ok(());
        }
        let data = Zeroizing::new(serde_json::to_vec(&snapshot)?);
        let path = self.directory.join(kind.filename());
        if kind == StoreKind::Storage {
            atomic_write(&path, &data)?;
        } else {
            let key = self.key(kind)?;
            atomic_write(&path, &encrypt(&data, &key)?)?;
        }
        cache.identity = file_identity(&path)?;
        cache.key_tag = self.cache_tag(kind);
        cache.snapshot = Some(snapshot);
        Ok(())
    }

    fn access(&self) -> Result<RwLockReadGuard<'_, bool>, StorageError> {
        let guard = self
            .closed
            .read()
            .expect("extension storage lifecycle lock");
        if *guard {
            Err(StorageError::Closed)
        } else {
            Ok(guard)
        }
    }

    /// Wait for current reads/writes, then prevent stale handles from accessing
    /// a replacement installation at the same data path.
    pub(crate) fn close(&self) {
        *self
            .closed
            .write()
            .expect("extension storage lifecycle lock") = true;
    }
}

pub(crate) fn valid_extension_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && (id.as_bytes()[0].is_ascii_lowercase() || id.as_bytes()[0].is_ascii_digit())
        && id.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"._-".contains(&byte)
        })
}

fn file_identity(path: &Path) -> Result<Option<Identity>, StorageError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if !metadata.is_file() {
        return Err(StorageError::InvalidPath);
    }
    #[cfg(unix)]
    use std::os::unix::fs::MetadataExt;
    Ok(Some(Identity {
        length: metadata.len(),
        modified: metadata.modified().ok(),
        #[cfg(unix)]
        inode: metadata.ino(),
    }))
}

fn read_optional(path: &Path) -> Result<Option<Vec<u8>>, StorageError> {
    if file_identity(path)?.is_none() {
        return Ok(None);
    }
    Ok(Some(fs::read(path)?))
}

fn parse_object(data: &[u8]) -> Result<Map<String, Value>, StorageError> {
    match serde_json::from_slice(data)? {
        Value::Object(value) => Ok(value),
        Value::Null => Ok(Map::new()),
        _ => Err(StorageError::InvalidObject),
    }
}

pub(crate) fn atomic_write(path: &Path, data: &[u8]) -> Result<(), StorageError> {
    file_identity(path)?;
    let directory = path.parent().ok_or(StorageError::InvalidPath)?;
    mornye_core::fs::write_atomic(
        directory,
        path,
        ".mornye-",
        |file| file.write_all(data),
        || Ok(()),
        true,
    )
    .map_err(io::Error::from)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aes_gcm_upgrade_reads_existing_wire_format_and_rejects_tampering() {
        let mut stored = vec![0; 12];
        stored.extend(
            crate::binary::decode_string(
                "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919",
                "hex",
            )
            .unwrap(),
        );
        assert_eq!(&*decrypt(&stored, &[0; 32]).unwrap(), &[0; 16]);
        stored[15] ^= 1;
        assert!(matches!(
            decrypt(&stored, &[0; 32]),
            Err(StorageError::Authentication)
        ));
        let generated = encrypt(b"example persisted settings", &[7; 32]).unwrap();
        assert_eq!(
            &*decrypt(&generated, &[7; 32]).unwrap(),
            b"example persisted settings"
        );
    }

    #[test]
    fn retired_store_cannot_read_or_overwrite_a_reinstalled_extension() {
        let directory = tempfile::tempdir().unwrap();
        let key = Arc::new(
            StorageMasterKey::from_base64("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=").unwrap(),
        );
        let old = ExtensionStore::open(
            directory.path(),
            "example.extension",
            Some(Arc::clone(&key)),
        )
        .unwrap();
        old.set(StoreKind::Storage, "old", true.into()).unwrap();
        old.close();
        fs::remove_file(directory.path().join("storage.json")).unwrap();
        let replacement =
            ExtensionStore::open(directory.path(), "example.extension", Some(key)).unwrap();
        for kind in [
            StoreKind::Storage,
            StoreKind::Credentials,
            StoreKind::Settings,
        ] {
            replacement.set(kind, "new", true.into()).unwrap();
            assert!(matches!(old.get(kind, "new"), Err(StorageError::Closed)));
            assert!(matches!(old.all(kind), Err(StorageError::Closed)));
            assert!(matches!(
                old.set(kind, "stale", true.into()),
                Err(StorageError::Closed)
            ));
            assert!(matches!(old.remove(kind, "new"), Err(StorageError::Closed)));
            assert_eq!(
                replacement.all(kind).unwrap(),
                Map::from_iter([("new".into(), true.into())])
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn setting_an_unchanged_value_does_not_rewrite_the_store() {
        use serde_json::json;
        use std::os::unix::fs::MetadataExt;

        let directory = tempfile::tempdir().unwrap();
        let key = Arc::new(
            StorageMasterKey::from_base64("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=").unwrap(),
        );
        let open = || {
            ExtensionStore::open(
                directory.path(),
                "example.extension",
                Some(Arc::clone(&key)),
            )
            .unwrap()
        };
        let store = open();
        for kind in [
            StoreKind::Storage,
            StoreKind::Credentials,
            StoreKind::Settings,
        ] {
            // Every persisted write replaces the file through a rename.
            let inode = || {
                fs::metadata(directory.path().join(kind.filename()))
                    .unwrap()
                    .ino()
            };
            store
                .set(kind, "region", json!({"code":"example"}))
                .unwrap();
            let written = inode();
            store
                .set(kind, "region", json!({"code":"example"}))
                .unwrap();
            open()
                .set(kind, "region", json!({"code":"example"}))
                .unwrap();
            assert_eq!(inode(), written);
            store.set(kind, "region", json!({"code":"other"})).unwrap();
            assert_ne!(inode(), written);
            let written = inode();
            store.remove(kind, "absent").unwrap();
            assert_eq!(inode() != written, kind != StoreKind::Storage);
            assert_eq!(
                open().get(kind, "region").unwrap(),
                Some(json!({"code":"other"}))
            );
        }
    }

    #[test]
    fn encrypted_snapshots_are_scoped_to_master_key() {
        let directory = tempfile::tempdir().unwrap();
        let key = Arc::new(
            StorageMasterKey::from_base64("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=").unwrap(),
        );
        let other_key = Arc::new(
            StorageMasterKey::from_base64("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=").unwrap(),
        );
        let store = ExtensionStore::open(
            directory.path(),
            "example.extension",
            Some(Arc::clone(&key)),
        )
        .unwrap();
        store
            .set(StoreKind::Credentials, "token", "secret".into())
            .unwrap();
        store
            .set(StoreKind::Settings, "theme", "dark".into())
            .unwrap();

        let other =
            ExtensionStore::open(directory.path(), "example.extension", Some(other_key)).unwrap();
        for kind in [StoreKind::Credentials, StoreKind::Settings] {
            assert!(matches!(other.all(kind), Err(StorageError::Authentication)));
        }

        let missing = ExtensionStore::open(directory.path(), "example.extension", None).unwrap();
        for kind in [StoreKind::Credentials, StoreKind::Settings] {
            assert!(matches!(missing.all(kind), Err(StorageError::MissingKey)));
        }
    }
}
