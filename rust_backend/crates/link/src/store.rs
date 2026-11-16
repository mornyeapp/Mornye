//! Persistent server state under `<app_support_dir>/link` (contract section
//! 2): `server.json` (server ID, port, name) and `devices.json` (paired
//! devices and their API keys). Files are replaced atomically and are private
//! to the user where the OS supports it.

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

const SERVER_FILE: &str = "server.json";
const DEVICES_FILE: &str = "devices.json";
/// `lastSeenMs` is persisted at most this often per device.
const TOUCH_INTERVAL_MS: i64 = 60_000;

/// `server.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ServerFile {
    server_id: String,
    #[serde(default)]
    port: u16,
    #[serde(default)]
    name: String,
}

/// `devices.json`.
#[derive(Debug, Default, Serialize, Deserialize)]
struct DevicesFile {
    #[serde(default)]
    devices: Vec<DeviceRecord>,
}

/// A paired phone or a third-party Subsonic app.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DeviceRecord {
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) platform: String,
    pub(crate) api_key: String,
    pub(crate) paired_ms: i64,
    /// `None` until the device first authenticates.
    #[serde(default)]
    pub(crate) last_seen_ms: Option<i64>,
}

impl DeviceRecord {
    pub(crate) fn device(&self) -> crate::Device {
        crate::Device {
            device_id: self.device_id.clone(),
            name: self.name.clone(),
            platform: self.platform.clone(),
        }
    }

    /// One `linkDevices` entry.
    pub(crate) fn to_json(&self, connected: bool) -> Value {
        json!({
            "deviceId": self.device_id,
            "name": self.name,
            "platform": self.platform,
            "pairedMs": self.paired_ms,
            "lastSeenMs": self.last_seen_ms,
            "connected": connected,
        })
    }
}

/// Thread-safe owner of both state files.
pub(crate) struct Store {
    dir: PathBuf,
    server: Mutex<ServerFile>,
    devices: Mutex<Devices>,
    /// Held across every `devices.json` write, so writes never overlap or
    /// land out of order. Taken before `devices`.
    saving: Mutex<()>,
    #[cfg(test)]
    writes: std::sync::atomic::AtomicUsize,
}

/// The paired devices as authentication sees them.
struct Devices {
    records: Vec<DeviceRecord>,
    /// A `lastSeenMs` in `records` is not yet in `devices.json`.
    unsaved: bool,
}

impl Store {
    /// Opens `dir`, creating it and a new server ID on first use. An
    /// unreadable file is moved aside to `<name>.bad` and started over.
    pub(crate) fn open(dir: &Path) -> Result<Self, String> {
        create_private_dir(dir)?;
        let server = match read_json::<ServerFile>(&dir.join(SERVER_FILE))? {
            Some(server) if !server.server_id.is_empty() => server,
            _ => {
                let server = ServerFile {
                    server_id: new_uuid()?,
                    port: 0,
                    name: String::new(),
                };
                write_json(&dir.join(SERVER_FILE), &server)?;
                server
            }
        };
        let devices = load_devices(dir)?;
        Ok(Self {
            dir: dir.to_owned(),
            server: Mutex::new(server),
            devices: Mutex::new(Devices {
                records: devices,
                unsaved: false,
            }),
            saving: Mutex::new(()),
            #[cfg(test)]
            writes: std::sync::atomic::AtomicUsize::new(0),
        })
    }

    pub(crate) fn server_id(&self) -> String {
        self.server
            .lock()
            .expect("link server file")
            .server_id
            .clone()
    }

    /// The port of the previous run, or 0.
    pub(crate) fn port(&self) -> u16 {
        self.server.lock().expect("link server file").port
    }

    /// Persists the port and name this run uses.
    pub(crate) fn set_server(&self, port: u16, name: &str) -> Result<(), String> {
        let mut server = self.server.lock().expect("link server file");
        if server.port == port && server.name == name {
            return Ok(());
        }
        let updated = ServerFile {
            server_id: server.server_id.clone(),
            port,
            name: name.to_owned(),
        };
        write_json(&self.dir.join(SERVER_FILE), &updated)?;
        *server = updated;
        Ok(())
    }

    pub(crate) fn devices(&self) -> Vec<DeviceRecord> {
        self.devices.lock().expect("link devices").records.clone()
    }

    /// The device whose key satisfies `matches`. Every key is checked so the
    /// time taken does not reveal which one matched.
    pub(crate) fn find(&self, matches: impl Fn(&str) -> bool) -> Option<DeviceRecord> {
        let devices = self.devices.lock().expect("link devices");
        let mut found = None;
        for record in devices.records.iter() {
            if matches(&record.api_key) && found.is_none() {
                found = Some(record.clone());
            }
        }
        found
    }

    /// Adds `device_id` with a new key, replacing an existing entry and its
    /// key. Returns the new record.
    pub(crate) fn upsert(
        &self,
        device_id: &str,
        name: &str,
        platform: &str,
        seen: bool,
    ) -> Result<DeviceRecord, String> {
        let now = now_ms();
        let record = DeviceRecord {
            device_id: device_id.to_owned(),
            name: name.to_owned(),
            platform: platform.to_owned(),
            api_key: new_api_key()?,
            paired_ms: now,
            last_seen_ms: seen.then_some(now),
        };
        let _saving = self.saving.lock().expect("link devices file");
        let mut devices = self.devices.lock().expect("link devices");
        let mut updated: Vec<DeviceRecord> = devices
            .records
            .iter()
            .filter(|existing| existing.device_id != device_id)
            .cloned()
            .collect();
        updated.push(record.clone());
        self.save(&updated)?;
        devices.records = updated;
        devices.unsaved = false;
        Ok(record)
    }

    /// Removes `device_id`. Returns whether it existed.
    pub(crate) fn remove(&self, device_id: &str) -> Result<bool, String> {
        let _saving = self.saving.lock().expect("link devices file");
        let mut devices = self.devices.lock().expect("link devices");
        let before = devices.records.len();
        let updated: Vec<DeviceRecord> = devices
            .records
            .iter()
            .filter(|record| record.device_id != device_id)
            .cloned()
            .collect();
        if updated.len() == before {
            return Ok(false);
        }
        self.save(&updated)?;
        devices.records = updated;
        devices.unsaved = false;
        Ok(true)
    }

    /// Records that `device_id` was just seen. Persisted at most once a
    /// minute per device, without holding the lock authentication takes; a
    /// failed write is retried on a later touch.
    pub(crate) fn touch(&self, device_id: &str) {
        let now = now_ms();
        {
            let mut guard = self.devices.lock().expect("link devices");
            let devices = &mut *guard;
            let Some(record) = devices
                .records
                .iter_mut()
                .find(|record| record.device_id == device_id)
            else {
                return;
            };
            if record
                .last_seen_ms
                .is_some_and(|seen| now - seen < TOUCH_INTERVAL_MS)
            {
                if !devices.unsaved {
                    return;
                }
            } else {
                record.last_seen_ms = Some(now);
                devices.unsaved = true;
            }
        }
        blocking(|| self.save_seen());
    }

    /// Writes `devices.json` when a `lastSeenMs` is not in it yet.
    fn save_seen(&self) {
        let _saving = self.saving.lock().expect("link devices file");
        let records = {
            let mut devices = self.devices.lock().expect("link devices");
            if !devices.unsaved {
                return;
            }
            devices.unsaved = false;
            devices.records.clone()
        };
        if self.save(&records).is_err() {
            self.devices.lock().expect("link devices").unsaved = true;
        }
    }

    fn save(&self, records: &[DeviceRecord]) -> Result<(), String> {
        #[cfg(test)]
        self.writes
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        save_devices(&self.dir, records)
    }
}

/// Runs `work` here, handing the other tasks of a multi-thread runtime
/// worker to another thread first.
fn blocking<T>(work: impl FnOnce() -> T) -> T {
    match tokio::runtime::Handle::try_current() {
        Ok(handle) if handle.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread => {
            tokio::task::block_in_place(work)
        }
        _ => work(),
    }
}

/// The devices stored in `dir` without opening a server (for the Devices
/// panel while sharing is off).
pub(crate) fn stored_devices(dir: &Path) -> Result<Vec<DeviceRecord>, String> {
    if !dir.join(DEVICES_FILE).exists() {
        return Ok(Vec::new());
    }
    load_devices(dir)
}

/// Removes `device_id` from the devices stored in `dir`.
pub(crate) fn revoke_stored(dir: &Path, device_id: &str) -> Result<(), String> {
    let devices = stored_devices(dir)?;
    if devices.iter().any(|record| record.device_id == device_id) {
        let updated: Vec<DeviceRecord> = devices
            .into_iter()
            .filter(|record| record.device_id != device_id)
            .collect();
        save_devices(dir, &updated)?;
    }
    Ok(())
}

fn load_devices(dir: &Path) -> Result<Vec<DeviceRecord>, String> {
    Ok(read_json::<DevicesFile>(&dir.join(DEVICES_FILE))?
        .map(|file| file.devices)
        .unwrap_or_default())
}

fn save_devices(dir: &Path, devices: &[DeviceRecord]) -> Result<(), String> {
    write_json(
        &dir.join(DEVICES_FILE),
        &json!({"version": 1, "devices": devices}),
    )
}

/// Reads `path`. A missing file is `None`; an unreadable one is moved aside
/// to `<path>.bad` and also reads as `None`.
fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<Option<T>, String> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("Cannot read {}: {error}", path.display())),
    };
    match serde_json::from_slice(&bytes) {
        Ok(value) => Ok(Some(value)),
        Err(_) => {
            let mut aside = path.as_os_str().to_owned();
            aside.push(".bad");
            std::fs::rename(path, &aside)
                .map_err(|error| format!("Cannot move aside {}: {error}", path.display()))?;
            Ok(None)
        }
    }
}

fn write_json(path: &Path, value: &impl Serialize) -> Result<(), String> {
    let text = serde_json::to_vec_pretty(value).map_err(|error| error.to_string())?;
    write_private(path, &text)
}

/// Creates `dir` (0700 on Unix).
pub(crate) fn create_private_dir(dir: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dir)
        .map_err(|error| format!("Cannot create {}: {error}", dir.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    Ok(())
}

/// Replaces `path` atomically: a private temporary file in the same folder,
/// synced, then renamed over the target.
pub(crate) fn write_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let fail = |error: std::io::Error| format!("Cannot write {}: {error}", path.display());
    let mut temp = path.as_os_str().to_owned();
    temp.push(format!(".tmp-{}", crate::auth::hex(&random_bytes::<6>()?)));
    let temp = PathBuf::from(temp);
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let written = options.open(&temp).and_then(|mut file| {
        file.write_all(bytes)?;
        file.sync_all()
    });
    if let Err(error) = written.and_then(|()| std::fs::rename(&temp, path)) {
        let _ = std::fs::remove_file(&temp);
        return Err(fail(error));
    }
    Ok(())
}

pub(crate) fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

pub(crate) fn random_bytes<const N: usize>() -> Result<[u8; N], String> {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).map_err(|error| format!("No system randomness: {error}"))?;
    Ok(bytes)
}

/// A random UUID version 4, lowercase with hyphens.
pub(crate) fn new_uuid() -> Result<String, String> {
    let mut bytes = random_bytes::<16>()?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = crate::auth::hex(&bytes);
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    ))
}

/// 32 random bytes, base64url without padding.
pub(crate) fn new_api_key() -> Result<String, String> {
    Ok(URL_SAFE_NO_PAD.encode(random_bytes::<32>()?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_server_id_and_devices_across_opens() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let id = store.server_id();
        assert_eq!(id.len(), 36);
        assert_eq!(&id[14..15], "4");
        store.set_server(47711, "Desk").unwrap();
        let record = store.upsert("phone", "Phone", "android", true).unwrap();
        assert_eq!(record.api_key.len(), 43);

        let reopened = Store::open(dir.path()).unwrap();
        assert_eq!(reopened.server_id(), id);
        assert_eq!(reopened.port(), 47711);
        assert_eq!(reopened.devices(), vec![record.clone()]);

        let replaced = reopened.upsert("phone", "Phone", "android", true).unwrap();
        assert_ne!(replaced.api_key, record.api_key);
        assert_eq!(reopened.devices().len(), 1);
        assert!(reopened.remove("phone").unwrap());
        assert!(!reopened.remove("phone").unwrap());
        assert!(stored_devices(dir.path()).unwrap().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn state_files_are_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store.upsert("phone", "Phone", "ios", false).unwrap();
        for name in [SERVER_FILE, DEVICES_FILE] {
            let mode = std::fs::metadata(dir.path().join(name))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600, "{name}");
        }
    }

    #[test]
    fn unreadable_file_is_moved_aside() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(DEVICES_FILE), b"{not json").unwrap();
        let store = Store::open(dir.path()).unwrap();
        assert!(store.devices().is_empty());
        assert!(dir.path().join("devices.json.bad").exists());
    }

    fn writes(store: &Store) -> usize {
        store.writes.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Waits until `done` holds, at most 5 s.
    fn wait_for(done: impl Fn() -> bool) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !done() {
            assert!(std::time::Instant::now() < deadline, "timed out");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    #[test]
    fn a_touch_writes_without_holding_up_authentication_and_coalesces() {
        let dir = tempfile::tempdir().unwrap();
        let store = std::sync::Arc::new(Store::open(dir.path()).unwrap());
        let a = store.upsert("a", "A", "android", false).unwrap();
        store.upsert("b", "B", "subsonic", false).unwrap();
        let before = writes(&store);

        // A write in progress holds the writer lock.
        let writing = store.saving.lock().unwrap();
        let touches: Vec<_> = ["a", "b", "a", "b"]
            .into_iter()
            .map(|device| {
                let store = std::sync::Arc::clone(&store);
                std::thread::spawn(move || store.touch(device))
            })
            .collect();
        let (found, answered) = std::sync::mpsc::channel();
        let finder = std::sync::Arc::clone(&store);
        std::thread::spawn(move || {
            wait_for(|| {
                finder
                    .devices()
                    .iter()
                    .all(|record| record.last_seen_ms.is_some())
            });
            let _ = found.send(finder.find(|key| key == a.api_key).map(|r| r.device_id));
        });
        assert_eq!(
            answered
                .recv_timeout(std::time::Duration::from_secs(10))
                .expect("authentication waited for the write"),
            Some("a".to_owned())
        );
        drop(writing);
        for touch in touches {
            touch.join().unwrap();
        }
        assert_eq!(writes(&store) - before, 1, "both devices in one write");
        assert!(
            stored_devices(dir.path())
                .unwrap()
                .iter()
                .all(|record| record.last_seen_ms.is_some())
        );

        for _ in 0..10 {
            store.touch("a");
            store.touch("b");
        }
        assert_eq!(writes(&store) - before, 1, "once a minute per device");
    }

    #[cfg(unix)]
    #[test]
    fn a_failed_touch_write_is_retried_and_never_brings_back_a_revoked_device() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store.upsert("a", "A", "android", false).unwrap();
        store.upsert("b", "B", "android", false).unwrap();
        let mode = |mode| {
            std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(mode)).unwrap()
        };
        mode(0o500);
        store.touch("a");
        mode(0o700);
        if stored_devices(dir.path()).unwrap()[0]
            .last_seen_ms
            .is_some()
        {
            return; // The folder stayed writable (running as root).
        }
        store.touch("a");
        let stored = stored_devices(dir.path()).unwrap();
        assert!(stored[0].last_seen_ms.is_some(), "retried");

        assert!(store.remove("b").unwrap());
        store.touch("b");
        store.touch("a");
        let left: Vec<String> = stored_devices(dir.path())
            .unwrap()
            .into_iter()
            .map(|record| record.device_id)
            .collect();
        assert_eq!(left, vec!["a".to_owned()]);
    }

    #[test]
    fn revokes_while_stopped() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store.upsert("a", "A", "android", false).unwrap();
        store.upsert("b", "B", "subsonic", false).unwrap();
        drop(store);
        revoke_stored(dir.path(), "a").unwrap();
        let left: Vec<String> = stored_devices(dir.path())
            .unwrap()
            .into_iter()
            .map(|record| record.device_id)
            .collect();
        assert_eq!(left, vec!["b".to_owned()]);
    }
}
