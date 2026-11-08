//! Native-owned registry cache and verified package downloads.

mod model;
mod package;
mod urls;

pub use model::{Registry, RepoExtension, normalize_sha256};
pub use package::{destination_path, write_verified_package};
pub use urls::{RegistryLocation, registry_location, require_https};

use mornye_core::fs::{DEFAULT_TEMP_PREFIX, OpenOptionsPortableExt, write_atomic};
use mornye_network::{HttpRequest, NetworkService, NetworkSession};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const MAX_REGISTRY_BYTES: usize = 4 << 20;
const MAX_CACHE_BYTES: u64 = 8 << 20;
const CACHE_TTL: Duration = Duration::from_secs(30 * 60);
const CACHE_FILE: &str = "store_cache.json";
const REGISTRY_TIMEOUT: Duration = Duration::from_secs(30);
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(300);

#[derive(Clone, Debug, thiserror::Error)]
#[error("{0}")]
pub struct RepositoryError(pub String);

fn error(message: impl Into<String>) -> RepositoryError {
    RepositoryError(message.into())
}
fn cause(context: &str, error: impl std::fmt::Display) -> RepositoryError {
    RepositoryError(format!("{context}: {error}"))
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default)]
struct Cache {
    registry_url: String,
    #[serde(
        serialize_with = "serialize_registry",
        deserialize_with = "deserialize_registry"
    )]
    registry: Arc<Registry>,
    cache_time: i64,
    etag: String,
    last_modified: String,
}

fn serialize_registry<S>(registry: &Arc<Registry>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    registry.as_ref().serialize(serializer)
}

fn deserialize_registry<'de, D>(deserializer: D) -> Result<Arc<Registry>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Registry::deserialize(deserializer).map(Arc::new)
}

#[derive(Default)]
struct Flight {
    result: Mutex<Option<Result<Arc<Registry>, RepositoryError>>>,
    ready: Condvar,
}

#[derive(Default)]
struct State {
    url: String,
    generation: u64,
    cache: Option<Arc<Cache>>,
    flights: BTreeMap<u64, Arc<Flight>>,
}

pub struct ExtensionRepository {
    network: Arc<NetworkService>,
    cache_directory: PathBuf,
    _directory_lock: File,
    state: Mutex<State>,
    pending: Mutex<usize>,
    idle: Condvar,
    closed: AtomicBool,
    parent_closed: Option<Arc<AtomicBool>>,
}

impl ExtensionRepository {
    /// The cache directory belongs to this native object, never to JavaScript.
    pub fn with_network(
        directory: &Path,
        network: Arc<NetworkService>,
    ) -> Result<Self, RepositoryError> {
        if directory.as_os_str().is_empty() {
            return Err(error("repository cache directory is not configured"));
        }
        fs::create_dir_all(directory).map_err(|e| cause("failed to create repository cache", e))?;
        let cache_directory = fs::canonicalize(directory)
            .map_err(|e| cause("failed to inspect repository cache", e))?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .unix_mode(0o600)
            .nofollow_nonblock()
            .open(cache_directory.join(".backend-repository.lock"))
            .map_err(|e| cause("failed to lock repository cache", e))?;
        if !lock
            .metadata()
            .map_err(|e| cause("failed to inspect repository lock", e))?
            .is_file()
        {
            return Err(error("repository cache lock must be a regular file"));
        }
        lock.try_lock()
            .map_err(|_| error("repository cache is already managed"))?;
        let cache = (|| {
            let file = OpenOptions::new()
                .read(true)
                .nofollow_nonblock()
                .open(cache_directory.join(CACHE_FILE))
                .ok()?;
            let metadata = file.metadata().ok()?;
            if !metadata.is_file() || metadata.len() > MAX_CACHE_BYTES {
                return None;
            }
            let mut bytes = Vec::new();
            file.take(MAX_CACHE_BYTES + 1)
                .read_to_end(&mut bytes)
                .ok()?;
            if bytes.len() as u64 > MAX_CACHE_BYTES {
                return None;
            }
            serde_json::from_slice::<Cache>(&bytes).ok().map(Arc::new)
        })();
        Ok(Self {
            network,
            cache_directory,
            _directory_lock: lock,
            state: Mutex::new(State {
                url: cache
                    .as_ref()
                    .map_or_else(String::new, |cache| cache.registry_url.clone()),
                cache,
                ..State::default()
            }),
            pending: Mutex::new(0),
            idle: Condvar::new(),
            closed: AtomicBool::new(false),
            parent_closed: None,
        })
    }

    pub(crate) fn attach_environment(mut self, closed: Arc<AtomicBool>) -> Self {
        self.parent_closed = Some(closed);
        self
    }

    fn enter(&self) -> Result<Operation<'_>, RepositoryError> {
        let mut pending = self.pending.lock().expect("repository operations lock");
        self.check()?;
        *pending += 1;
        Ok(Operation(self))
    }

    fn check(&self) -> Result<(), RepositoryError> {
        if self.closed.load(Ordering::Acquire)
            || self
                .parent_closed
                .as_ref()
                .is_some_and(|closed| closed.load(Ordering::Acquire))
        {
            Err(error("extension repository closed"))
        } else {
            Ok(())
        }
    }

    fn check_generation(&self, generation: u64) -> Result<(), RepositoryError> {
        self.check()?;
        if self.state.lock().expect("repository state lock").generation != generation {
            Err(error("registry changed while operation was running"))
        } else {
            Ok(())
        }
    }

    pub fn registry_url(&self) -> Result<String, RepositoryError> {
        self.check()?;
        Ok(self
            .state
            .lock()
            .expect("repository state lock")
            .url
            .clone())
    }

    pub fn set_registry_url(&self, input: &str) -> Result<(), RepositoryError> {
        let _operation = self.enter()?;
        let url = match registry_location(input)? {
            RegistryLocation::Direct(url) => url,
            RegistryLocation::GitHub { owner, repository } => {
                let api = format!("https://api.github.com/repos/{owner}/{repository}");
                let session = self.network.native_session(Duration::from_secs(10));
                let response = session.request(request(&api, BTreeMap::new()), || {
                    self.check().map_err(|e| e.to_string())
                });
                self.check()?;
                let branch = response
                    .ok()
                    .filter(|response| response.status == 200)
                    .and_then(|response| {
                        serde_json::from_slice::<serde_json::Value>(&response.body).ok()
                    })
                    .and_then(|value| {
                        value["default_branch"]
                            .as_str()
                            .filter(|value| !value.is_empty())
                            .map(str::to_owned)
                    })
                    .unwrap_or_else(|| "main".into());
                format!(
                    "https://raw.githubusercontent.com/{owner}/{repository}/{branch}/registry.json"
                )
            }
        };
        require_https(&url, "registry")?;
        let mut state = self.state.lock().expect("repository state lock");
        self.check()?;
        if state.url != url {
            state.url = url;
            self.clear_locked(&mut state);
        }
        Ok(())
    }

    pub fn clear_registry_url(&self) -> Result<(), RepositoryError> {
        self.check()?;
        let mut state = self.state.lock().expect("repository state lock");
        state.url.clear();
        self.clear_locked(&mut state);
        Ok(())
    }

    fn clear_locked(&self, state: &mut State) {
        state.generation = state.generation.wrapping_add(1);
        state.cache = None;
        state.flights.clear();
        let _ = fs::remove_file(self.cache_directory.join(CACHE_FILE));
    }

    fn save_locked(&self, cache: &Cache) {
        // Hold the state lock through publication: a URL change/clear cannot
        // race an old snapshot back onto disk. A cache write failure is benign.
        let _ = (|| -> Result<(), Box<dyn std::error::Error>> {
            let bytes = serde_json::to_vec(cache)?;
            if bytes.len() as u64 > MAX_CACHE_BYTES {
                return Ok(());
            }
            write_atomic(
                &self.cache_directory,
                &self.cache_directory.join(CACHE_FILE),
                DEFAULT_TEMP_PREFIX,
                |file| file.write_all(&bytes),
                || Ok(()),
                false,
            )?;
            Ok(())
        })();
    }

    pub fn fetch(&self, force: bool) -> Result<Arc<Registry>, RepositoryError> {
        let _operation = self.enter()?;
        let (url, generation, cached, flight, leader) = {
            let mut state = self.state.lock().expect("repository state lock");
            if state.url.is_empty() {
                return Err(error(
                    "no registry URL configured. Please add a repository URL first",
                ));
            }
            require_https(&state.url, "registry")?;
            if !force
                && let Some(cache) = &state.cache
                && now().saturating_sub(cache.cache_time) < CACHE_TTL.as_secs() as i64
            {
                return Ok(Arc::clone(&cache.registry));
            }
            let generation = state.generation;
            let leader = !state.flights.contains_key(&generation);
            let flight = state.flights.entry(generation).or_default().clone();
            (
                state.url.clone(),
                generation,
                state.cache.clone(),
                flight,
                leader,
            )
        };
        if !leader {
            let mut result = flight.result.lock().expect("repository refresh lock");
            loop {
                self.check_generation(generation)?;
                if let Some(result) = &*result {
                    return result.clone();
                }
                result = flight
                    .ready
                    .wait_timeout(result, Duration::from_millis(10))
                    .expect("repository refresh wait")
                    .0;
            }
        }
        let result = self.refresh(&url, generation, cached);
        *flight.result.lock().expect("repository refresh lock") = Some(result.clone());
        flight.ready.notify_all();
        self.state
            .lock()
            .expect("repository state lock")
            .flights
            .remove(&generation);
        result
    }

    fn refresh(
        &self,
        url: &str,
        generation: u64,
        cached: Option<Arc<Cache>>,
    ) -> Result<Arc<Registry>, RepositoryError> {
        let check = || self.check_generation(generation).map_err(|e| e.to_string());
        let session = self.network.native_session(REGISTRY_TIMEOUT);
        let mut headers = BTreeMap::new();
        if let Some(cache) = &cached {
            if !cache.etag.is_empty() {
                headers.insert("If-None-Match".into(), cache.etag.clone());
            }
            if !cache.last_modified.is_empty() {
                headers.insert("If-Modified-Since".into(), cache.last_modified.clone());
            }
        }
        let response = read_registry(&session, request(url, headers), &check);
        self.check_generation(generation)?;
        let (status, headers, body) = match response {
            Ok(response) => response,
            Err(error) if error.0.starts_with("failed to read registry:") => return Err(error),
            Err(error) => {
                return cached.map(|cache| Arc::clone(&cache.registry)).ok_or(error);
            }
        };
        if status != 200 && !(status == 304 && cached.is_some()) {
            return cached
                .map(|cache| Arc::clone(&cache.registry))
                .ok_or_else(|| error(format!("registry returned HTTP {status}")));
        }
        let cache = if status == 304 {
            let mut cache = (*cached.expect("304 cache")).clone();
            cache.cache_time = now();
            cache
        } else {
            let registry = match Registry::parse(&body) {
                Ok(registry) => registry,
                Err(error) => {
                    return cached.map(|cache| Arc::clone(&cache.registry)).ok_or(error);
                }
            };
            let header = |name| {
                headers
                    .get(name)
                    .and_then(|values| values.first())
                    .map_or("", |value| value.trim())
                    .to_owned()
            };
            Cache {
                registry_url: url.into(),
                registry: Arc::new(registry),
                cache_time: now(),
                etag: header("Etag"),
                last_modified: header("Last-Modified"),
            }
        };
        let registry = Arc::clone(&cache.registry);
        let mut state = self.state.lock().expect("repository state lock");
        self.check()?;
        if state.generation != generation {
            return Err(error("registry changed while operation was running"));
        }
        self.save_locked(&cache);
        state.cache = Some(Arc::new(cache));
        Ok(registry)
    }

    pub fn extensions(
        &self,
        force: bool,
        installed: &BTreeMap<String, String>,
        query: &str,
        category: &str,
    ) -> Result<String, RepositoryError> {
        Ok(
            serde_json::to_string(&self.fetch(force)?.responses(installed, query, category))
                .expect("registry JSON"),
        )
    }

    pub fn download(&self, id: &str, directory: &Path) -> Result<PathBuf, RepositoryError> {
        let _operation = self.enter()?;
        let generation = self.state.lock().expect("repository state lock").generation;
        let registry = self.fetch(false)?;
        let extension = registry
            .extensions
            .iter()
            .find(|entry| entry.id == id)
            .ok_or_else(|| error(format!("extension {id} not found in repo")))?;
        if !extension.is_supported_runtime() {
            return Err(error(format!(
                "extension {id} targets the {} runtime and cannot be installed in this app",
                extension.runtime.trim()
            )));
        }
        require_https(extension.download_url(), "extension download")?;
        let destination = destination_path(directory, id, extension.download_url())?;
        let check = || self.check_generation(generation).map_err(|e| e.to_string());
        let session = self.network.native_session(DOWNLOAD_TIMEOUT);
        let headers = [
            ("Cache-Control".into(), "no-cache".into()),
            ("Pragma".into(), "no-cache".into()),
        ]
        .into();
        let mut stream = session
            .open_stream(
                request(extension.download_url(), headers),
                DOWNLOAD_TIMEOUT,
                DOWNLOAD_TIMEOUT,
                check,
            )
            .map_err(|e| cause("failed to download", e))?;
        if stream.response.status != 200 {
            return Err(error(format!(
                "download returned HTTP {}",
                stream.response.status
            )));
        }
        write_verified_package(
            |buffer| stream.read(buffer, check),
            &destination,
            extension.raw_sha256(),
            &check,
        )?;
        Ok(destination)
    }

    pub fn shutdown(&self) {
        self.closed.store(true, Ordering::Release);
        let pending = self.pending.lock().expect("repository operations lock");
        drop(
            self.idle
                .wait_while(pending, |pending| *pending > 0)
                .expect("repository operations wait"),
        );
    }
}

struct Operation<'a>(&'a ExtensionRepository);

impl Drop for Operation<'_> {
    fn drop(&mut self) {
        let mut pending = self.0.pending.lock().expect("repository operations lock");
        *pending -= 1;
        self.0.idle.notify_all();
    }
}

fn request(url: &str, headers: BTreeMap<String, String>) -> HttpRequest {
    HttpRequest {
        url: url.into(),
        method: "GET".into(),
        body: String::new(),
        headers,
        default_json: false,
        user_agent: "Go-http-client/1.1".into(),
    }
}

type RegistryResponse = (u16, BTreeMap<String, Vec<String>>, Vec<u8>);

fn read_registry(
    session: &NetworkSession,
    request: HttpRequest,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<RegistryResponse, RepositoryError> {
    let mut stream = session
        .open_stream(request, REGISTRY_TIMEOUT, REGISTRY_TIMEOUT, check)
        .map_err(|e| cause("failed to fetch registry", e))?;
    let status = stream.response.status;
    let mut body = Vec::new();
    if status == 200 {
        body = stream
            .read_limited(MAX_REGISTRY_BYTES, &mut [0; 64 * 1024], check)
            .map_err(|e| cause("failed to read registry", e))?
            .ok_or_else(|| {
                error(format!(
                    "registry response exceeds {MAX_REGISTRY_BYTES} bytes"
                ))
            })?;
    }
    Ok((status, stream.response.headers, body))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn downloaded_packages_use_current_brand_and_keep_sflx_extension() {
        for (url, name) in [
            (
                "https://example.test/example.spotiflac-ext",
                "example.mornye-ext",
            ),
            (
                "https://example.test/example.mornye-ext",
                "example.mornye-ext",
            ),
            ("https://example.test/example.sflx", "example.sflx"),
        ] {
            assert_eq!(
                destination_path(Path::new("/extensions"), "example", url).unwrap(),
                Path::new("/extensions").join(name)
            );
        }
    }

    #[test]
    fn cache_registry_clone_shares_arc_and_round_trips_disk_shape() {
        let bytes = br#"{"registry_url":"https://example.test/registry.json","registry":{"version":1,"updated_at":"2026-09-14","extensions":[]},"cache_time":123,"etag":"etag","last_modified":"Mon, 14 Sep 2026 00:00:00 GMT"}"#;
        let cache: Cache = serde_json::from_slice(bytes).unwrap();
        let clone = cache.clone();

        assert!(Arc::ptr_eq(&cache.registry, &clone.registry));
        assert_eq!(serde_json::to_vec(&cache).unwrap(), bytes);
    }
}
