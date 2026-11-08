//! Native-owned registry caches and verified package downloads. The store
//! reads an ordered list of registries; each keeps its own cache.

mod model;
mod package;
mod urls;

pub use model::{LenientString, Registry, RepoExtension, normalize_sha256};
pub use package::{destination_path, write_verified_package};
pub use urls::{RegistryLocation, registry_location, require_https, source_name};

use mornye_core::fs::{DEFAULT_TEMP_PREFIX, OpenOptionsPortableExt, write_atomic};
use mornye_network::{HttpRequest, NetworkService, NetworkSession};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const MAX_REGISTRY_BYTES: usize = 4 << 20;
const MAX_CACHE_BYTES: u64 = 8 << 20;
const CACHE_TTL: Duration = Duration::from_secs(30 * 60);
/// The single-registry cache of earlier versions; it is only a cache.
const LEGACY_CACHE_FILE: &str = "store_cache.json";
/// One cache file per source, named by the SHA-256 of its registry URL.
const CACHE_DIRECTORY: &str = "store_sources";
const NO_SOURCES: &str = "no registry URL configured. Please add a repository URL first";
const SOURCE_CHANGED: &str = "registry changed while operation was running";
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

struct Source {
    url: String,
    /// Unique for the repository's lifetime: a URL removed and added again is
    /// a new source, so an older fetch can never publish into it.
    generation: u64,
    cache: Option<Arc<Cache>>,
    flight: Option<Arc<Flight>>,
}

#[derive(Default)]
struct State {
    sources: Vec<Source>,
    generations: u64,
}

impl State {
    fn source_mut(&mut self, url: &str, generation: u64) -> Option<&mut Source> {
        self.sources
            .iter_mut()
            .find(|source| source.url == url && source.generation == generation)
    }

    fn urls(&self) -> Vec<String> {
        self.sources
            .iter()
            .map(|source| source.url.clone())
            .collect()
    }
}

fn cache_file_name(url: &str) -> String {
    let digest =
        crate::binary::encode(&Sha256::digest(url.as_bytes()), "hex").expect("hex encoding");
    format!("{digest}.json")
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
        // Sources arrive from the app; per-source caches load as they do.
        let _ = fs::remove_file(cache_directory.join(LEGACY_CACHE_FILE));
        Ok(Self {
            network,
            cache_directory,
            _directory_lock: lock,
            state: Mutex::new(State::default()),
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

    /// Fails once `url` was removed, or removed and added again, after the
    /// caller read `generation`.
    fn check_source(&self, url: &str, generation: u64) -> Result<(), RepositoryError> {
        self.check()?;
        self.state
            .lock()
            .expect("repository state lock")
            .source_mut(url, generation)
            .map(|_| ())
            .ok_or_else(|| error(SOURCE_CHANGED))
    }

    /// Resolves what the user typed to a registry URL without changing any
    /// state: a GitHub repository page becomes its default branch's raw
    /// `registry.json`; other URLs stay as they are. HTTPS is required.
    pub fn resolve_registry_url(&self, input: &str) -> Result<String, RepositoryError> {
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
        Ok(url)
    }

    /// Replaces the ordered source list. Entries are trimmed; empty entries
    /// and exact duplicates are dropped, keeping the first. Any URL failing
    /// `require_https` rejects the whole list and nothing changes. Kept URLs
    /// keep their caches; dropped URLs lose them and their in-flight fetches.
    pub fn set_registry_urls(&self, inputs: &[String]) -> Result<(), RepositoryError> {
        self.check()?;
        let mut urls: Vec<String> = Vec::with_capacity(inputs.len());
        for input in inputs {
            let url = input.trim();
            if url.is_empty() || urls.iter().any(|kept| kept == url) {
                continue;
            }
            require_https(url, "registry")?;
            urls.push(url.into());
        }
        let mut state = self.state.lock().expect("repository state lock");
        self.check()?;
        let mut previous = std::mem::take(&mut state.sources);
        for url in urls {
            let source = match previous.iter().position(|source| source.url == url) {
                Some(index) => previous.swap_remove(index),
                None => {
                    state.generations += 1;
                    Source {
                        cache: self.load_cache(&url),
                        url,
                        generation: state.generations,
                        flight: None,
                    }
                }
            };
            state.sources.push(source);
        }
        // Dropped sources take their memory caches with them. Their fetches
        // fail the generation check and never publish.
        drop(previous);
        self.sweep_locked(&state);
        Ok(())
    }

    /// The per-source cache directory, refused when it is not a real directory.
    fn sources_directory(&self) -> Option<PathBuf> {
        let directory = self.cache_directory.join(CACHE_DIRECTORY);
        fs::symlink_metadata(&directory)
            .ok()?
            .is_dir()
            .then_some(directory)
    }

    fn load_cache(&self, url: &str) -> Option<Arc<Cache>> {
        let file = OpenOptions::new()
            .read(true)
            .nofollow_nonblock()
            .open(self.sources_directory()?.join(cache_file_name(url)))
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
        serde_json::from_slice::<Cache>(&bytes)
            .ok()
            .filter(|cache| cache.registry_url == url)
            .map(Arc::new)
    }

    /// Removes every cache file that no configured source owns. Callers hold
    /// the state lock, as cache writes do.
    fn sweep_locked(&self, state: &State) {
        let Some(directory) = self.sources_directory() else {
            return;
        };
        let Ok(entries) = fs::read_dir(&directory) else {
            return;
        };
        let kept: BTreeSet<_> = state
            .sources
            .iter()
            .map(|source| cache_file_name(&source.url))
            .collect();
        for entry in entries.flatten() {
            let owned = entry
                .file_name()
                .to_str()
                .is_some_and(|name| kept.contains(name));
            if !owned && entry.file_type().is_ok_and(|kind| !kind.is_dir()) {
                let _ = fs::remove_file(entry.path());
            }
        }
    }

    fn save_locked(&self, cache: &Cache) {
        // Hold the state lock through publication: a list change cannot race
        // an old snapshot back onto disk. A cache write failure is benign.
        let _ = (|| -> Result<(), Box<dyn std::error::Error>> {
            let bytes = serde_json::to_vec(cache)?;
            if bytes.len() as u64 > MAX_CACHE_BYTES {
                return Ok(());
            }
            let _ = fs::create_dir(self.cache_directory.join(CACHE_DIRECTORY));
            let directory = self
                .sources_directory()
                .ok_or("repository source cache is not a directory")?;
            write_atomic(
                &directory,
                &directory.join(cache_file_name(&cache.registry_url)),
                DEFAULT_TEMP_PREFIX,
                |file| file.write_all(&bytes),
                || Ok(()),
                false,
            )?;
            Ok(())
        })();
    }

    /// One source's registry and the generation it was read under. Each
    /// source has its own TTL cache and single flight.
    fn fetch(&self, url: &str, force: bool) -> Result<(Arc<Registry>, u64), RepositoryError> {
        let _operation = self.enter()?;
        let (generation, cached, flight, leader) = {
            let mut state = self.state.lock().expect("repository state lock");
            let Some(source) = state.sources.iter_mut().find(|source| source.url == url) else {
                return Err(error(format!("registry {url} is not configured")));
            };
            if !force
                && let Some(cache) = &source.cache
                && now().saturating_sub(cache.cache_time) < CACHE_TTL.as_secs() as i64
            {
                return Ok((Arc::clone(&cache.registry), source.generation));
            }
            let leader = source.flight.is_none();
            let flight = Arc::clone(source.flight.get_or_insert_with(Arc::default));
            (source.generation, source.cache.clone(), flight, leader)
        };
        if !leader {
            let mut result = flight.result.lock().expect("repository refresh lock");
            loop {
                self.check_source(url, generation)?;
                if let Some(result) = &*result {
                    return result.clone().map(|registry| (registry, generation));
                }
                result = flight
                    .ready
                    .wait_timeout(result, Duration::from_millis(10))
                    .expect("repository refresh wait")
                    .0;
            }
        }
        let result = self.refresh(url, generation, cached);
        *flight.result.lock().expect("repository refresh lock") = Some(result.clone());
        flight.ready.notify_all();
        if let Some(source) = self
            .state
            .lock()
            .expect("repository state lock")
            .source_mut(url, generation)
        {
            source.flight = None;
        }
        result.map(|registry| (registry, generation))
    }

    fn refresh(
        &self,
        url: &str,
        generation: u64,
        cached: Option<Arc<Cache>>,
    ) -> Result<Arc<Registry>, RepositoryError> {
        let check = || {
            self.check_source(url, generation)
                .map_err(|e| e.to_string())
        };
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
        self.check_source(url, generation)?;
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
        let Some(source) = state.source_mut(url, generation) else {
            return Err(error(SOURCE_CHANGED));
        };
        self.save_locked(&cache);
        source.cache = Some(Arc::new(cache));
        Ok(registry)
    }

    /// Every configured source fetched concurrently, as the catalog JSON:
    /// `sources` in list order with name, count and error, and `extensions`
    /// with every supported entry of every source tagged with its source.
    /// A failing source reports its error and contributes no entries.
    pub fn catalog(
        &self,
        force: bool,
        installed: &BTreeMap<String, String>,
    ) -> Result<String, RepositoryError> {
        let _operation = self.enter()?;
        let urls = self.state.lock().expect("repository state lock").urls();
        let results: Vec<_> = std::thread::scope(|scope| {
            let others: Vec<_> = urls
                .iter()
                .skip(1)
                .map(|url| scope.spawn(move || self.fetch(url, force)))
                .collect();
            let first = urls.first().map(|url| self.fetch(url, force));
            first
                .into_iter()
                .chain(others.into_iter().map(|worker| {
                    worker
                        .join()
                        .unwrap_or_else(|_| Err(error("registry fetch failed")))
                }))
                .collect()
        });
        self.check()?;
        let mut sources = Vec::with_capacity(urls.len());
        let mut extensions = Vec::new();
        for (url, result) in urls.iter().zip(results) {
            let (name, count, message) = match result {
                Ok((registry, _)) => {
                    let name = source_name(url, &registry.name);
                    let entries = registry.responses(installed, "", "");
                    let count = entries.len();
                    for mut entry in entries {
                        entry["registry_url"] = url.as_str().into();
                        entry["registry_name"] = name.as_str().into();
                        extensions.push(entry);
                    }
                    (name, count, String::new())
                }
                Err(error) => (source_name(url, ""), 0, error.0),
            };
            sources.push(json!({
                "registry_url": url, "name": name, "extension_count": count, "error": message,
            }));
        }
        Ok(
            serde_json::to_string(&json!({"sources": sources, "extensions": extensions}))
                .expect("catalog JSON"),
        )
    }

    /// Downloads `id` from `registry_url`, which must be configured and list
    /// the id. An empty `registry_url` picks the first source, in list order,
    /// that lists it.
    pub fn download(
        &self,
        id: &str,
        directory: &Path,
        registry_url: &str,
    ) -> Result<PathBuf, RepositoryError> {
        let _operation = self.enter()?;
        let registry_url = registry_url.trim();
        let urls = {
            let state = self.state.lock().expect("repository state lock");
            if registry_url.is_empty() {
                state.urls()
            } else if state
                .sources
                .iter()
                .any(|source| source.url == registry_url)
            {
                vec![registry_url.to_owned()]
            } else {
                return Err(error(format!("registry {registry_url} is not configured")));
            }
        };
        if urls.is_empty() {
            return Err(error(NO_SOURCES));
        }
        let mut failure = None;
        let mut found = None;
        for url in &urls {
            let registry = match self.fetch(url, false) {
                Ok(registry) => registry,
                Err(error) => {
                    failure.get_or_insert(error);
                    continue;
                }
            };
            let Some(extension) = registry.0.extensions.iter().find(|entry| entry.id == id) else {
                continue;
            };
            if extension.is_supported_runtime() {
                found = Some((url, registry.1, extension.clone()));
                break;
            }
            failure.get_or_insert_with(|| {
                error(format!(
                    "extension {id} targets the {} runtime and cannot be installed in this app",
                    extension.runtime.trim()
                ))
            });
        }
        let Some((url, generation, extension)) = found else {
            return Err(
                failure.unwrap_or_else(|| error(format!("extension {id} not found in repo")))
            );
        };
        require_https(extension.download_url(), "extension download")?;
        let destination = destination_path(directory, id, extension.download_url())?;
        let check = || {
            self.check_source(url, generation)
                .map_err(|e| e.to_string())
        };
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
        let bytes = br#"{"registry_url":"https://example.test/registry.json","registry":{"version":1,"updated_at":"2026-09-14","extensions":[],"name":"Example"},"cache_time":123,"etag":"etag","last_modified":"Mon, 14 Sep 2026 00:00:00 GMT"}"#;
        let cache: Cache = serde_json::from_slice(bytes).unwrap();
        let clone = cache.clone();

        assert!(Arc::ptr_eq(&cache.registry, &clone.registry));
        assert_eq!(serde_json::to_vec(&cache).unwrap(), bytes);
    }

    #[test]
    fn source_names_prefer_the_registry_name_then_the_url() {
        for (url, name, expected) in [
            (
                "https://example.com/registry.json",
                " Example Store ",
                "Example Store",
            ),
            (
                "https://raw.githubusercontent.com/example/repo/main/registry.json",
                "",
                "example/repo",
            ),
            ("https://github.com/example/repo", "", "example/repo"),
            ("https://github.com/example/repo.git", "", "example/repo"),
            (
                "https://github.com/example/repo/tree/main",
                "",
                "example/repo",
            ),
            (
                "https://example.com/store/registry.json",
                "",
                "example.com/store",
            ),
            ("https://example.com/registry.json", "", "example.com"),
            (
                "https://example.com:8443/registry.json?v=1",
                "",
                "example.com:8443",
            ),
            (
                "https://example.com/store/list.json",
                "",
                "example.com/store/list.json",
            ),
            ("https://example.com/", "", "example.com"),
        ] {
            assert_eq!(source_name(url, name), expected, "{url}");
        }
    }

    use std::net::TcpListener;
    use std::sync::atomic::AtomicUsize;
    use std::sync::mpsc;
    use std::thread;
    use std::time::Instant;

    type Response = (u16, Vec<(&'static str, String)>, Vec<u8>);

    fn network() -> (Arc<NetworkService>, Arc<rustls::ServerConfig>) {
        let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
        let config = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![certificate.cert.der().clone()],
            rustls::pki_types::PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der())
                .into(),
        )
        .unwrap();
        let network = NetworkService::with_options(mornye_network::NetworkOptions {
            extra_root_pem: certificate.cert.pem().into_bytes(),
            doh_upstreams: vec![],
            ..Default::default()
        })
        .unwrap();
        network.set_allow_private_network(true);
        (network, Arc::new(config))
    }

    /// A local HTTPS fixture: every connection runs `handler` with the path
    /// and records the request head.
    struct Server {
        base: String,
        heads: Arc<Mutex<Vec<String>>>,
        stop: Arc<AtomicBool>,
        worker: Option<thread::JoinHandle<()>>,
    }

    impl Server {
        fn start(
            config: Arc<rustls::ServerConfig>,
            handler: impl Fn(&str) -> Response + Send + Sync + 'static,
        ) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let base = format!("https://{}", listener.local_addr().unwrap());
            let heads = Arc::new(Mutex::new(Vec::new()));
            let stop = Arc::new(AtomicBool::new(false));
            let (recorded, stopped) = (Arc::clone(&heads), Arc::clone(&stop));
            let handler = Arc::new(handler);
            let worker = thread::spawn(move || {
                let deadline = Instant::now() + Duration::from_secs(20);
                let mut connections = Vec::new();
                while !stopped.load(Ordering::Acquire) && Instant::now() < deadline {
                    let stream = match listener.accept() {
                        Ok((stream, _)) => stream,
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(1));
                            continue;
                        }
                        Err(error) => panic!("fixture accept: {error}"),
                    };
                    let (config, recorded, handler) = (
                        Arc::clone(&config),
                        Arc::clone(&recorded),
                        Arc::clone(&handler),
                    );
                    connections.push(thread::spawn(move || {
                        stream.set_nonblocking(false).unwrap();
                        stream
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        stream
                            .set_write_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        let mut stream = rustls::StreamOwned::new(
                            rustls::ServerConnection::new(config).unwrap(),
                            stream,
                        );
                        let mut head = Vec::new();
                        while !head.windows(4).any(|part| part == b"\r\n\r\n") {
                            let mut bytes = [0; 4096];
                            match stream.read(&mut bytes) {
                                Ok(count) if count > 0 => head.extend_from_slice(&bytes[..count]),
                                _ => return,
                            }
                        }
                        let head = String::from_utf8_lossy(&head).into_owned();
                        let path = head.split_whitespace().nth(1).unwrap_or("").to_owned();
                        recorded.lock().unwrap().push(head);
                        let (status, headers, body) = handler(&path);
                        let mut reply = format!("HTTP/1.1 {status} Fixture\r\n");
                        for (name, value) in headers {
                            reply.push_str(&format!("{name}: {value}\r\n"));
                        }
                        reply.push_str(&format!(
                            "Content-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        ));
                        let _ = stream.write_all(reply.as_bytes());
                        let _ = stream.write_all(&body);
                        let _ = stream.flush();
                    }));
                }
                for connection in connections {
                    let _ = connection.join();
                }
            });
            Self {
                base,
                heads,
                stop,
                worker: Some(worker),
            }
        }

        fn url(&self, path: &str) -> String {
            format!("{}{path}", self.base)
        }

        fn requests(&self, path: &str) -> Vec<String> {
            self.heads
                .lock()
                .unwrap()
                .iter()
                .filter(|head| head.split_whitespace().nth(1) == Some(path))
                .cloned()
                .collect()
        }
    }

    impl Drop for Server {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Release);
            if let Some(worker) = self.worker.take() {
                let _ = worker.join();
            }
        }
    }

    fn ok(body: impl Into<Vec<u8>>) -> Response {
        (200, Vec::new(), body.into())
    }

    fn sha256(bytes: &[u8]) -> String {
        crate::binary::encode(&Sha256::digest(bytes), "hex").unwrap()
    }

    fn repository(directory: &Path, network: &Arc<NetworkService>) -> ExtensionRepository {
        ExtensionRepository::with_network(directory, Arc::clone(network)).unwrap()
    }

    fn catalog(repository: &ExtensionRepository, force: bool) -> serde_json::Value {
        let installed = [("one".to_owned(), "1.0.0".to_owned())].into();
        serde_json::from_str(&repository.catalog(force, &installed).unwrap()).unwrap()
    }

    fn cache_files(directory: &Path) -> Vec<String> {
        let mut names: Vec<_> = fs::read_dir(directory.join(CACHE_DIRECTORY))
            .map(|entries| {
                entries
                    .flatten()
                    .map(|entry| entry.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        names.sort();
        names
    }

    #[test]
    fn legacy_cache_file_is_removed_and_no_sources_give_an_empty_catalog() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join(LEGACY_CACHE_FILE), b"{}").unwrap();
        let (network, _) = network();
        let repository = repository(directory.path(), &network);

        assert!(!directory.path().join(LEGACY_CACHE_FILE).exists());
        assert_eq!(
            repository.catalog(true, &BTreeMap::new()).unwrap(),
            r#"{"extensions":[],"sources":[]}"#
        );
        let download = repository.download("one", directory.path(), "");
        assert_eq!(download.unwrap_err().0, NO_SOURCES);
    }

    #[test]
    fn catalog_merges_sources_in_order_and_isolates_a_failing_source() {
        let directory = tempfile::tempdir().unwrap();
        let (network, config) = network();
        let server = Server::start(config, |path| match path {
            "/a/registry.json" => ok(r#"{"extensions":[
                {"id":"one","name":"One","version":"1.0.0"},
                {"id":"two","name":"Two","version":"1.0.0"},
                {"id":"py","name":"Py","version":"1.0.0","runtime":"python"}
            ]}"#),
            "/b/registry.json" => ok(r#"{"name":"Second","extensions":[
                {"id":"one","name":"One","version":"2.0.0"}
            ]}"#),
            _ => (500, Vec::new(), Vec::new()),
        });
        let (a, b, c) = (
            server.url("/a/registry.json"),
            server.url("/b/registry.json"),
            server.url("/c/registry.json"),
        );
        let repository = repository(directory.path(), &network);
        repository
            .set_registry_urls(&[a.clone(), c.clone(), b.clone()])
            .unwrap();

        let catalog = catalog(&repository, false);
        let host = server.base.strip_prefix("https://").unwrap();
        assert_eq!(
            catalog["sources"],
            json!([
                {"registry_url": a, "name": format!("{host}/a"), "extension_count": 2, "error": ""},
                {"registry_url": c, "name": format!("{host}/c"), "extension_count": 0,
                    "error": "registry returned HTTP 500"},
                {"registry_url": b, "name": "Second", "extension_count": 1, "error": ""},
            ])
        );
        let entries: Vec<_> = catalog["extensions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| {
                (
                    entry["id"].as_str().unwrap(),
                    entry["registry_url"].as_str().unwrap(),
                    entry["registry_name"].as_str().unwrap(),
                    entry["is_installed"].as_bool().unwrap(),
                    entry["has_update"].as_bool().unwrap(),
                    entry["installed_version"].as_str().unwrap_or(""),
                )
            })
            .collect();
        let name_a = format!("{host}/a");
        assert_eq!(
            entries,
            [
                ("one", a.as_str(), name_a.as_str(), true, false, "1.0.0"),
                ("two", a.as_str(), name_a.as_str(), false, false, ""),
                ("one", b.as_str(), "Second", true, true, "1.0.0"),
            ]
        );
    }

    #[test]
    fn each_source_revalidates_and_falls_back_to_its_own_cache() {
        let directory = tempfile::tempdir().unwrap();
        let (network, config) = network();
        let calls = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&calls);
        let server = Server::start(config, move |path| match path {
            "/a/registry.json" => match counter.fetch_add(1, Ordering::AcqRel) {
                0 => (
                    200,
                    vec![("ETag", "\"v1\"".into())],
                    br#"{"extensions":[{"id":"one","version":"1.0.0"}]}"#.to_vec(),
                ),
                1 => (304, Vec::new(), Vec::new()),
                _ => (500, Vec::new(), Vec::new()),
            },
            _ => ok(r#"{"extensions":[{"id":"two","version":"1.0.0"}]}"#),
        });
        let (a, b) = (
            server.url("/a/registry.json"),
            server.url("/b/registry.json"),
        );
        let ids = |catalog: &serde_json::Value| -> Vec<String> {
            catalog["extensions"]
                .as_array()
                .unwrap()
                .iter()
                .map(|entry| entry["id"].as_str().unwrap().to_owned())
                .collect()
        };
        {
            let repository = repository(directory.path(), &network);
            repository
                .set_registry_urls(&[a.clone(), b.clone()])
                .unwrap();
            for _ in 0..3 {
                let catalog = catalog(&repository, true);
                assert_eq!(ids(&catalog), ["one", "two"]);
                assert_eq!(catalog["sources"][0]["error"], "");
            }
            let heads = server.requests("/a/registry.json");
            assert_eq!(heads.len(), 3);
            assert!(!heads[0].to_ascii_lowercase().contains("if-none-match"));
            assert!(
                heads[1]
                    .to_ascii_lowercase()
                    .contains("if-none-match: \"v1\"")
            );
            assert_eq!(cache_files(directory.path()).len(), 2);
        }
        // A new owner reads the per-source disk cache when the URL returns.
        let repository = repository(directory.path(), &network);
        repository
            .set_registry_urls(std::slice::from_ref(&a))
            .unwrap();
        assert_eq!(cache_files(directory.path()), [cache_file_name(&a)]);
        let catalog = catalog(&repository, true);
        assert_eq!(ids(&catalog), ["one"]);
        assert_eq!(catalog["sources"][0]["error"], "");
        assert_eq!(server.requests("/a/registry.json").len(), 4);
    }

    #[test]
    fn set_registry_urls_keeps_kept_caches_and_drops_removed_ones() {
        let directory = tempfile::tempdir().unwrap();
        let (network, config) = network();
        let server = Server::start(config, |_| ok(r#"{"extensions":[{"id":"one"}]}"#));
        let (a, b) = (
            server.url("/a/registry.json"),
            server.url("/b/registry.json"),
        );
        let repository = repository(directory.path(), &network);
        repository
            .set_registry_urls(&[a.clone(), b.clone()])
            .unwrap();
        catalog(&repository, false);
        let mut both = vec![cache_file_name(&a), cache_file_name(&b)];
        both.sort();
        assert_eq!(cache_files(directory.path()), both);

        repository
            .set_registry_urls(std::slice::from_ref(&b))
            .unwrap();
        assert_eq!(cache_files(directory.path()), [cache_file_name(&b)]);
        catalog(&repository, false);
        assert_eq!(server.requests("/b/registry.json").len(), 1);

        // Reordering keeps both caches; a re-added URL starts without one.
        repository
            .set_registry_urls(&[b.clone(), a.clone()])
            .unwrap();
        let catalog = catalog(&repository, false);
        assert_eq!(catalog["sources"][0]["registry_url"], b);
        assert_eq!(catalog["sources"][1]["registry_url"], a);
        assert_eq!(server.requests("/b/registry.json").len(), 1);
        assert_eq!(server.requests("/a/registry.json").len(), 2);

        repository.set_registry_urls(&[]).unwrap();
        assert!(cache_files(directory.path()).is_empty());
    }

    #[test]
    fn set_registry_urls_trims_dedupes_and_rejects_invalid_lists() {
        let directory = tempfile::tempdir().unwrap();
        let (network, config) = network();
        let server = Server::start(config, |_| ok(r#"{"extensions":[]}"#));
        let (a, b) = (
            server.url("/a/registry.json"),
            server.url("/b/registry.json"),
        );
        let repository = repository(directory.path(), &network);
        repository
            .set_registry_urls(&[
                format!(" {a} "),
                String::new(),
                "  ".into(),
                a.clone(),
                b.clone(),
            ])
            .unwrap();
        let listed = |repository: &ExtensionRepository| -> Vec<String> {
            catalog(repository, false)["sources"]
                .as_array()
                .unwrap()
                .iter()
                .map(|source| source["registry_url"].as_str().unwrap().to_owned())
                .collect()
        };
        assert_eq!(listed(&repository), [a.clone(), b.clone()]);

        for invalid in ["http://example.com/registry.json", "not a url", "https://"] {
            let error = repository
                .set_registry_urls(&[b.clone(), invalid.into()])
                .unwrap_err();
            assert!(error.0.starts_with("registry URL"), "{invalid}: {error}");
            assert_eq!(listed(&repository), [a.clone(), b.clone()]);
        }
        assert_eq!(server.requests("/a/registry.json").len(), 1);

        assert_eq!(
            repository
                .resolve_registry_url(" https://example.com/registry.json ")
                .unwrap(),
            "https://example.com/registry.json"
        );
        assert!(
            repository
                .resolve_registry_url("http://example.com/registry.json")
                .is_err()
        );
        assert!(repository.resolve_registry_url(" ").is_err());
        assert_eq!(listed(&repository), [a, b]);
    }

    #[test]
    fn a_removed_source_never_publishes_its_in_flight_fetch() {
        let directory = tempfile::tempdir().unwrap();
        let (network, config) = network();
        let (started, ready) = mpsc::channel();
        let (release, released) = mpsc::channel::<()>();
        let gate = Mutex::new((started, released));
        let first = AtomicBool::new(true);
        let server = Server::start(config, move |_| {
            if first.swap(false, Ordering::AcqRel) {
                let gate = gate.lock().unwrap();
                gate.0.send(()).unwrap();
                let _ = gate.1.recv_timeout(Duration::from_secs(5));
                return ok(r#"{"extensions":[{"id":"one"}]}"#);
            }
            (500, Vec::new(), Vec::new())
        });
        let a = server.url("/a/registry.json");
        let repository = repository(directory.path(), &network);
        repository
            .set_registry_urls(std::slice::from_ref(&a))
            .unwrap();

        thread::scope(|scope| {
            let fetch = scope.spawn(|| catalog(&repository, false));
            ready.recv_timeout(Duration::from_secs(5)).unwrap();
            repository.set_registry_urls(&[]).unwrap();
            let catalog = fetch.join().unwrap();
            release.send(()).unwrap();
            assert_eq!(catalog["sources"][0]["error"], SOURCE_CHANGED);
            assert_eq!(catalog["extensions"], json!([]));
        });
        assert!(cache_files(directory.path()).is_empty());

        repository
            .set_registry_urls(std::slice::from_ref(&a))
            .unwrap();
        let catalog = catalog(&repository, false);
        assert_eq!(catalog["sources"][0]["error"], "registry returned HTTP 500");
        assert!(cache_files(directory.path()).is_empty());
    }

    #[test]
    fn catalog_fetches_sources_concurrently() {
        let directory = tempfile::tempdir().unwrap();
        let (network, config) = network();
        let (arrived, waiting) = mpsc::channel();
        let (arrived, waiting) = (Mutex::new(arrived), Mutex::new(waiting));
        let server = Server::start(config, move |path| {
            if path == "/b/registry.json" {
                arrived.lock().unwrap().send(()).unwrap();
                return ok(r#"{"extensions":[]}"#);
            }
            // The first source answers only once the second one has asked.
            let waiting = waiting.lock().unwrap();
            match waiting.recv_timeout(Duration::from_secs(3)) {
                Ok(()) => ok(r#"{"extensions":[]}"#),
                Err(_) => (500, Vec::new(), Vec::new()),
            }
        });
        let repository = repository(directory.path(), &network);
        repository
            .set_registry_urls(&[
                server.url("/a/registry.json"),
                server.url("/b/registry.json"),
            ])
            .unwrap();
        let catalog = catalog(&repository, false);
        assert_eq!(catalog["sources"][0]["error"], "");
        assert_eq!(catalog["sources"][1]["error"], "");
    }

    #[test]
    fn downloads_come_from_the_named_or_first_listing_source() {
        let directory = tempfile::tempdir().unwrap();
        let (network, config) = network();
        let base = Arc::new(Mutex::new(String::new()));
        let host = Arc::clone(&base);
        let server = Server::start(config, move |path| {
            let base = host.lock().unwrap().clone();
            let entry = |id: &str, package: &str, body: &[u8]| {
                json!({"id": id, "version": "1.0.0",
                    "download_url": format!("{base}/pkg/{package}.mornye-ext"),
                    "sha256": sha256(body)})
            };
            match path {
                "/a/registry.json" => ok(json!({"extensions": [
                    entry("one", "a-one", b"alpha"),
                    {"id": "py", "runtime": "python",
                        "download_url": format!("{base}/pkg/py.mornye-ext")},
                ]})
                .to_string()),
                "/b/registry.json" => ok(json!({"extensions": [
                    entry("one", "b-one", b"beta"),
                    entry("two", "b-two", b"two"),
                ]})
                .to_string()),
                "/pkg/a-one.mornye-ext" => ok(&b"alpha"[..]),
                "/pkg/b-one.mornye-ext" => ok(&b"beta"[..]),
                "/pkg/b-two.mornye-ext" => ok(&b"two"[..]),
                _ => (404, Vec::new(), Vec::new()),
            }
        });
        *base.lock().unwrap() = server.base.clone();
        let (a, b) = (
            server.url("/a/registry.json"),
            server.url("/b/registry.json"),
        );
        let repository = repository(&directory.path().join("cache"), &network);
        repository
            .set_registry_urls(&[a.clone(), b.clone()])
            .unwrap();
        let read = |id: &str, url: &str| -> Result<Vec<u8>, RepositoryError> {
            let target = tempfile::tempdir().unwrap();
            let path = repository.download(id, target.path(), url)?;
            assert_eq!(path, target.path().join(format!("{id}.mornye-ext")));
            Ok(fs::read(path).unwrap())
        };

        assert_eq!(read("one", "").unwrap(), b"alpha");
        assert_eq!(read("one", &a).unwrap(), b"alpha");
        assert_eq!(read("one", &format!(" {b} ")).unwrap(), b"beta");
        assert_eq!(read("two", "").unwrap(), b"two");
        assert_eq!(
            read("two", &a).unwrap_err().0,
            "extension two not found in repo"
        );
        assert_eq!(
            read("missing", "").unwrap_err().0,
            "extension missing not found in repo"
        );
        assert!(read("py", "").unwrap_err().0.contains("python runtime"));
        let other = "https://example.com/other/registry.json";
        assert_eq!(
            read("one", other).unwrap_err().0,
            format!("registry {other} is not configured")
        );
        assert!(server.requests("/pkg/py.mornye-ext").is_empty());
    }
}
