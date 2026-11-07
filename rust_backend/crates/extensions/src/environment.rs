//! Platform-owned storage and lifecycle context for managed extension runtimes.

mod index;

use crate::auth::{AuthRegistry, ExtensionAuth, PendingAuthRequest};
use crate::manifest::{ExtensionManifest, ManifestError};
use crate::runtime::LoadMode;
use crate::signed_session::SignedRegistry;
use crate::storage::{
    ExtensionStore, StorageError, StorageMasterKey, StoreKind, valid_extension_id,
};
use crate::{ExtensionError, ExtensionRuntime, ExtensionServices, RuntimeLimits};
use mornye_core::app_version::AppVersion;
use mornye_core::cancellation::{CancellationDomain, CancellationRegistry};
use mornye_core::downloads::DownloadState;
use mornye_core::progress::ProgressRegistry;
use mornye_network::{NetworkService, policy::NetworkPermissions};
use mornye_providers::lyrics::{CallGraph, CallNode, LyricsService};
use serde_json::{Map, Value};
use std::cmp::Ordering as Comparison;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, LazyLock, Mutex, OnceLock, Weak};
use std::time::Duration;

// Keep these contract versions aligned with Go's supportedRuntimeFeatures.
pub(crate) static SUPPORTED_RUNTIME_FEATURES: LazyLock<BTreeMap<String, isize>> =
    LazyLock::new(|| {
        [
            ("signedSession", 3),
            ("sessionRefresh", 1),
            ("sessionGrant", 1),
            ("globalAction", 1),
            ("webviewAuth", 1),
            ("downloadSegments", 1),
            ("patternedFileTransform", 1),
            ("preparedContext", 1),
            ("accountForms", 1),
            ("accountDownloadMode", 1),
            ("directMedia", 1),
            ("deferredPreview", 1),
        ]
        .into_iter()
        .map(|(name, version)| (name.to_owned(), version))
        .collect()
    });

#[derive(Debug, thiserror::Error)]
pub enum EnvironmentError {
    #[error("extension environment closed")]
    Closed,
    #[error("{0}")]
    Storage(#[from] StorageError),
    #[error("{0}")]
    Manifest(#[from] ManifestError),
    #[error("{0}")]
    Runtime(#[from] ExtensionError),
    #[error("{0}")]
    Gate(String),
    #[error("network initialization failed: {0}")]
    Network(#[from] std::io::Error),
    #[error("{0}")]
    Auth(String),
    #[error("{0}")]
    Index(String),
}

#[derive(Default)]
struct State {
    pending: usize,
    runtimes: Vec<Weak<ExtensionRuntime>>,
    stores: BTreeMap<String, Arc<ExtensionStore>>,
    lyrics_nodes: BTreeMap<String, CallNode>,
}

/// The master key comes from the native Keychain/Keystore adapter. The directory
/// must belong to this backend, which is the only owner of the live data.
pub struct ExtensionEnvironment {
    logs: Arc<crate::logging::LogBuffer>,
    ffmpeg: Arc<crate::ffmpeg::CommandRegistry>,
    downloads: Arc<mornye_core::downloads::DownloadState>,
    data_directory: PathBuf,
    data_directory_alias: PathBuf,
    master_key: Arc<StorageMasterKey>,
    app_version: AppVersion,
    network: Arc<NetworkService>,
    auth: Arc<AuthRegistry>,
    sessions: Arc<SignedRegistry>,
    files: Arc<crate::files::FileRegistry>,
    isrc: Arc<mornye_core::isrc::IndexCache>,
    closed: Arc<AtomicBool>,
    state: Mutex<State>,
    idle: Condvar,
    shutdown_lock: Mutex<()>,
    manager_owned: AtomicBool,
    calls: CallGraph,
    lyrics: OnceLock<Weak<LyricsService>>,
}

impl ExtensionEnvironment {
    pub fn new(
        data_directory: &Path,
        master_key: &str,
        app_version: &str,
    ) -> Result<Self, EnvironmentError> {
        // Validate the key before initializing any platform services or files.
        StorageMasterKey::from_base64(master_key)?;
        Self::with_network(
            data_directory,
            master_key,
            app_version,
            NetworkService::new()?,
        )
    }

    pub fn with_network(
        data_directory: &Path,
        master_key: &str,
        app_version: &str,
        network: Arc<NetworkService>,
    ) -> Result<Self, EnvironmentError> {
        let master_key = Arc::new(StorageMasterKey::from_base64(master_key)?);
        if data_directory.as_os_str().is_empty() {
            return Err(StorageError::InvalidPath.into());
        }
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(data_directory).map_err(StorageError::from)?;
        let data_directory_alias =
            crate::files::clean(&std::path::absolute(data_directory).map_err(StorageError::from)?);
        let data_directory = fs::canonicalize(data_directory).map_err(StorageError::from)?;
        let auth = Arc::new(AuthRegistry::persistent(&data_directory, &master_key));
        let sessions = SignedRegistry::new(&data_directory, Arc::clone(&auth));
        Ok(Self {
            logs: Arc::new(crate::logging::LogBuffer::default()),
            ffmpeg: Arc::new(crate::ffmpeg::CommandRegistry::default()),
            downloads: Arc::new(DownloadState {
                progress: Arc::new(ProgressRegistry::new()),
                cancellation: Arc::new(CancellationRegistry::with_waker(
                    CancellationDomain::Download,
                    network.cancellation_waker(),
                )),
            }),
            data_directory,
            data_directory_alias,
            master_key,
            app_version: app_version.into(),
            network,
            auth,
            sessions,
            files: Arc::new(crate::files::FileRegistry::default()),
            isrc: Arc::new(mornye_core::isrc::IndexCache::default()),
            closed: Arc::new(AtomicBool::new(false)),
            state: Mutex::default(),
            idle: Condvar::new(),
            shutdown_lock: Mutex::new(()),
            manager_owned: AtomicBool::new(false),
            calls: CallGraph::default(),
            lyrics: OnceLock::new(),
        })
    }

    fn enter(&self) -> Result<Operation<'_>, EnvironmentError> {
        let mut state = self.state.lock().expect("extension environment lock");
        if self.closed.load(Ordering::Acquire) {
            return Err(EnvironmentError::Closed);
        }
        state.pending += 1;
        Ok(Operation(self))
    }

    fn store(&self, id: &str) -> Result<Arc<ExtensionStore>, EnvironmentError> {
        if !valid_extension_id(id) {
            return Err(StorageError::InvalidExtensionId.into());
        }
        let path = self.data_directory.join(id);
        let mut state = self.state.lock().expect("extension environment lock");
        match fs::symlink_metadata(&path) {
            Ok(metadata) if !metadata.is_dir() => return Err(StorageError::InvalidPath.into()),
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                return Err(StorageError::from(error).into());
            }
            _ => {}
        }
        if let Some(store) = state.stores.get(id) {
            return Ok(Arc::clone(store));
        }
        let store = Arc::new(ExtensionStore::open(
            &path,
            id,
            Some(Arc::clone(&self.master_key)),
        )?);
        state.stores.insert(id.to_owned(), Arc::clone(&store));
        Ok(store)
    }

    pub fn settings(&self, id: &str) -> Result<Map<String, Value>, EnvironmentError> {
        let _operation = self.enter()?;
        Ok(self.store(id)?.all(StoreKind::Settings)?)
    }

    pub fn set_setting(&self, id: &str, key: &str, value: Value) -> Result<(), EnvironmentError> {
        let _operation = self.enter()?;
        Ok(self.store(id)?.set(StoreKind::Settings, key, value)?)
    }

    pub fn set_allow_private_network(&self, allow: bool) -> Result<(), EnvironmentError> {
        let _operation = self.enter()?;
        self.network.set_allow_private_network(allow);
        Ok(())
    }

    pub fn set_network_compatibility_options(
        &self,
        allow_http: bool,
    ) -> Result<(), EnvironmentError> {
        let _operation = self.enter()?;
        self.network.set_network_compatibility_options(allow_http);
        Ok(())
    }

    /// Recycle connections without cancelling active requests or changing policy.
    pub fn cleanup_connections(&self) -> Result<(), EnvironmentError> {
        let _operation = self.enter()?;
        self.network.reset_connections();
        Ok(())
    }

    /// Trusted native composition reuses the same transport and network policy.
    pub fn network_service(&self) -> Result<Arc<NetworkService>, EnvironmentError> {
        let _operation = self.enter()?;
        Ok(Arc::clone(&self.network))
    }

    pub fn get_app_version(&self) -> Result<String, EnvironmentError> {
        let _operation = self.enter()?;
        Ok(self.app_version.get())
    }

    pub(crate) fn shared_app_version(&self) -> AppVersion {
        self.app_version.clone()
    }

    pub fn set_allowed_download_directories(
        &self,
        directories: &[PathBuf],
    ) -> Result<(), EnvironmentError> {
        let _operation = self.enter()?;
        self.files
            .set_allowed_directories(directories)
            .map_err(StorageError::from)?;
        Ok(())
    }

    pub fn replace_settings(
        &self,
        id: &str,
        values: Map<String, Value>,
    ) -> Result<(), EnvironmentError> {
        let _operation = self.enter()?;
        Ok(self.store(id)?.replace(StoreKind::Settings, values)?)
    }

    pub fn load(
        &self,
        manifest_json: &str,
        source: &str,
        limits: RuntimeLimits,
    ) -> Result<Arc<ExtensionRuntime>, EnvironmentError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(EnvironmentError::Closed);
        }
        if self.manager_owned.load(Ordering::Acquire) {
            return Err(EnvironmentError::Gate(
                "installed runtimes must be loaded through their extension manager".into(),
            ));
        }
        self.load_internal(
            manifest_json,
            source,
            limits,
            LoadMode::Initialize,
            None,
            None,
        )
    }

    pub(crate) fn load_registered_with_lease(
        &self,
        manifest_json: &str,
        source: &str,
        limits: RuntimeLimits,
        mode: LoadMode,
        lease: Option<Arc<mornye_core::cancellation::RequestLease>>,
    ) -> Result<Arc<ExtensionRuntime>, EnvironmentError> {
        self.load_internal(manifest_json, source, limits, mode, None, lease)
    }

    pub(crate) fn load_isolated(
        &self,
        manifest_json: &str,
        source: &str,
        limits: RuntimeLimits,
        primary: &ExtensionRuntime,
    ) -> Result<Arc<ExtensionRuntime>, EnvironmentError> {
        self.load_internal(
            manifest_json,
            source,
            limits,
            LoadMode::Register,
            Some(primary),
            None,
        )
    }

    fn load_internal(
        &self,
        manifest_json: &str,
        source: &str,
        limits: RuntimeLimits,
        load_mode: LoadMode,
        primary: Option<&ExtensionRuntime>,
        startup_lease: Option<Arc<mornye_core::cancellation::RequestLease>>,
    ) -> Result<Arc<ExtensionRuntime>, EnvironmentError> {
        let _operation = self.enter()?;
        if manifest_json.len() > 1024 * 1024 {
            return Err(EnvironmentError::Gate(
                "invalid extension package: manifest.json is too large".to_owned(),
            ));
        }
        let manifest = ExtensionManifest::parse(manifest_json)?;
        validate_gates(
            &manifest,
            &self.app_version.get(),
            &SUPPORTED_RUNTIME_FEATURES,
        )
        .map_err(EnvironmentError::Gate)?;
        let store = self.store(&manifest.name)?;
        let mut settings = store.all(StoreKind::Settings)?;
        settings.retain(|key, _| !key.starts_with('_'));
        let isolated = primary.is_some();
        let compiled_source = primary.map(|runtime| Arc::clone(&runtime.compiled_source));
        let network = primary
            .and_then(ExtensionRuntime::network_session)
            .unwrap_or_else(|| {
                self.network.session(
                    NetworkPermissions {
                        domains: manifest.permissions.network.clone().unwrap_or_default(),
                        allow_http: manifest.permissions.allow_http,
                    },
                    network_timeout(manifest.capabilities.get("networkTimeoutSeconds")),
                )
            });
        network.set_grants(manifest.network_grants(&settings));
        // Legacy metadata helpers do not require the general file permission.
        // They receive read access to this sandbox and native-granted roots.
        let legacy_files = self
            .files
            .extension_with_alias(
                &self.data_directory.join(&manifest.name),
                &self.data_directory_alias.join(&manifest.name),
            )
            .map_err(StorageError::from)?;
        let services = ExtensionServices {
            legacy_backend: true,
            lyrics: self.lyrics.get().cloned().unwrap_or_default(),
            lyrics_node: self.lyrics_node(&manifest.name, isolated),
            lyrics_parent: isolated.then(|| self.lyrics_node(&manifest.name, false)),
            legacy_files: Some(Arc::clone(&legacy_files)),
            isrc: Arc::clone(&self.isrc),
            logs: Arc::clone(&self.logs),
            extension_id: manifest.name.clone(),
            ffmpeg: Arc::clone(&self.ffmpeg),
            raw_ffmpeg_stub: manifest
                .capabilities
                .get("rawFfmpeg")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            downloads: Arc::clone(&self.downloads),
            transfer_policy: crate::transfer_policy::DownloadTransferPolicy::from_capabilities(
                &manifest.capabilities,
            ),
            storage: manifest.permissions.storage.then_some(store),
            files: manifest.permissions.file.then_some(legacy_files),
            auth: manifest.permissions.storage.then(|| {
                Arc::new(ExtensionAuth::new(
                    &manifest.name,
                    Arc::clone(&self.auth),
                    Arc::clone(&network),
                    self.app_version.clone(),
                ))
            }),
            auth_registry: Some(Arc::clone(&self.auth)),
            session: manifest
                .signed_session
                .clone()
                .map(|config| {
                    self.sessions
                        .session(&manifest.name, config, Arc::clone(&network))
                })
                .transpose()
                .map_err(EnvironmentError::Auth)?,
            network: Some(network),
            app_version: self.app_version.clone(),
            parent_closed: Some(Arc::clone(&self.closed)),
            startup_lease,
            initialize_empty_settings: false,
            load_mode,
            compiled_source,
        };
        let runtime = Arc::new(ExtensionRuntime::load_with_services(
            source,
            &Value::Object(settings).to_string(),
            limits,
            services,
        )?);
        let mut state = self.state.lock().expect("extension environment lock");
        if self.closed.load(Ordering::Acquire) {
            drop(state);
            runtime.shutdown();
            return Err(EnvironmentError::Closed);
        }
        state.runtimes.retain(|runtime| runtime.strong_count() > 0);
        state.runtimes.push(Arc::downgrade(&runtime));
        Ok(runtime)
    }

    /// Interrupt every child and in-progress initialization, then join workers.
    /// Manager-driven normal unloading should run cleanup before this operation.
    pub fn shutdown(&self) {
        self.closed.store(true, Ordering::Release);
        self.app_version.close();
        self.logs.shutdown();
        self.ffmpeg.shutdown();
        self.downloads.shutdown();
        self.auth.shutdown();
        self.sessions.shutdown();
        let _shutdown = self.shutdown_lock.lock().expect("extension shutdown lock");
        let runtimes = {
            let mut state = self.state.lock().expect("extension environment lock");
            std::mem::take(&mut state.runtimes)
        };
        for runtime in runtimes.into_iter().filter_map(|runtime| runtime.upgrade()) {
            runtime.shutdown();
        }
        let mut state = self.state.lock().expect("extension environment lock");
        while state.pending > 0 {
            state = self.idle.wait(state).expect("extension environment idle");
        }
        state.lyrics_nodes.clear();
        self.isrc.clear();
    }
}

impl ExtensionEnvironment {
    pub(crate) fn attach_lyrics(&self, lyrics: &Arc<LyricsService>) {
        self.lyrics
            .set(Arc::downgrade(lyrics))
            .expect("lyrics owner already configured");
    }

    pub(crate) fn lyrics_calls(&self) -> CallGraph {
        self.calls.clone()
    }

    pub(crate) fn lyrics_node(&self, id: &str, isolated: bool) -> CallNode {
        if isolated {
            return self.calls.node();
        }
        self.state
            .lock()
            .expect("extension environment lock")
            .lyrics_nodes
            .entry(id.to_owned())
            .or_insert_with(|| self.calls.node())
            .clone()
    }

    pub(crate) fn attach_manager(&self) {
        self.manager_owned.store(true, Ordering::Release);
    }

    pub(crate) fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }

    pub(crate) fn closed_flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.closed)
    }
    pub(crate) fn data_directory(&self) -> &Path {
        &self.data_directory
    }

    /// Trusted root operations share download grants without widening any VM's
    /// sandbox. Relative native paths resolve inside the application's data root.
    pub(crate) fn native_files(&self) -> Result<Arc<crate::files::ExtensionFiles>, String> {
        if self.is_closed() {
            return Err("extension environment closed".into());
        }
        self.files
            .extension_with_alias(&self.data_directory, &self.data_directory_alias)
            .map_err(|error| error.to_string())
    }

    /// Trusted native callers retain this grant until finalization completes.
    pub fn grant_temporary_download_directory(
        &self,
        path: &Path,
    ) -> Result<crate::files::TemporaryGrant, String> {
        let _operation = self.enter().map_err(|error| error.to_string())?;
        self.files
            .grant_temporary_directory(path)
            .map_err(|error| error.to_string())
    }

    pub(crate) fn validate_post_process_path(
        &self,
        id: &str,
        input: &str,
        path: &str,
    ) -> Result<(), String> {
        let mut bases = vec![self.data_directory.join(id)];
        // Native platforms may supply a trusted alias such as /var/... while
        // the store owns /private/var/.... Accept that spelling only while it
        // still resolves to this extension's actual data directory.
        let alias = self.data_directory_alias.join(id);
        if alias != bases[0] && fs::canonicalize(&alias).is_ok_and(|path| path == bases[0]) {
            bases.push(alias);
        }
        if !input.is_empty() {
            let input = crate::files::clean(Path::new(input));
            bases.insert(
                0,
                input
                    .parent()
                    .filter(|path| !path.as_os_str().is_empty())
                    .unwrap_or(Path::new("."))
                    .into(),
            );
        }
        self.files.validate_native_replacement(path, &bases)
    }

    pub(crate) fn remove_data(&self, id: &str) -> Result<(), EnvironmentError> {
        let _operation = self.enter()?;
        if !valid_extension_id(id) {
            return Err(StorageError::InvalidExtensionId.into());
        }
        let mut state = self.state.lock().expect("extension environment lock");
        if let Some(store) = state.stores.remove(id) {
            store.close();
        }
        self.auth.clear(id);
        self.sessions.forget_extension(id);
        let path = self.data_directory.join(id);
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.is_dir() => {
                fs::remove_dir_all(path).map_err(StorageError::from)?
            }
            Ok(_) => fs::remove_file(path).map_err(StorageError::from)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(StorageError::from(error).into()),
        }
        Ok(())
    }

    pub fn log_buffer(&self) -> Arc<crate::logging::LogBuffer> {
        Arc::clone(&self.logs)
    }

    pub fn repository(
        &self,
        directory: &Path,
    ) -> Result<crate::repository::ExtensionRepository, crate::repository::RepositoryError> {
        let _operation = self
            .enter()
            .map_err(|e| crate::repository::RepositoryError(e.to_string()))?;
        crate::repository::ExtensionRepository::with_network(directory, Arc::clone(&self.network))
            .map(|repository| repository.attach_environment(Arc::clone(&self.closed)))
    }

    pub fn ffmpeg_commands(&self) -> Arc<crate::ffmpeg::CommandRegistry> {
        Arc::clone(&self.ffmpeg)
    }

    pub fn download_state(&self) -> Arc<mornye_core::downloads::DownloadState> {
        Arc::clone(&self.downloads)
    }

    pub fn set_runtime_state(&self, raw: &str) -> Result<(), EnvironmentError> {
        let _operation = self.enter()?;
        self.sessions
            .set_runtime_state(raw)
            .map_err(EnvironmentError::Auth)
    }

    pub fn set_session_grant(&self, id: &str, grant: &str) -> Result<(), EnvironmentError> {
        let _operation = self.enter()?;
        self.sessions
            .set_grant(id, grant)
            .map_err(EnvironmentError::Auth)
    }

    pub fn pending_auth(&self, id: &str) -> Result<Option<PendingAuthRequest>, EnvironmentError> {
        let _operation = self.enter()?;
        Ok(self.auth.pending(id.trim()))
    }

    pub fn resolve_callback_state(
        &self,
        state: &str,
        consume: bool,
    ) -> Result<String, EnvironmentError> {
        let _operation = self.enter()?;
        self.auth
            .resolve_callback(state, consume)
            .map_err(EnvironmentError::Auth)
    }

    pub fn set_auth_code(&self, id: &str, code: &str) -> Result<(), EnvironmentError> {
        let _operation = self.enter()?;
        self.auth.set_code(id, code).map_err(EnvironmentError::Auth)
    }
}

fn network_timeout(value: Option<&Value>) -> Duration {
    let seconds = match value {
        Some(Value::String(value)) => value.trim().parse::<i64>().unwrap_or(0),
        Some(Value::Number(value)) => value.as_f64().unwrap_or(0.0) as i64,
        _ => 0,
    };
    Duration::from_secs(if seconds <= 0 {
        30
    } else {
        seconds.clamp(5, 300) as u64
    })
}

impl Drop for ExtensionEnvironment {
    fn drop(&mut self) {
        self.shutdown();
    }
}

struct Operation<'a>(&'a ExtensionEnvironment);
impl Drop for Operation<'_> {
    fn drop(&mut self) {
        let mut state = self.0.state.lock().expect("extension environment lock");
        state.pending -= 1;
        self.0.idle.notify_all();
    }
}

pub fn validate_gates(
    manifest: &ExtensionManifest,
    app_version: &str,
    features: &BTreeMap<String, isize>,
) -> Result<(), String> {
    let minimum = manifest.min_app_version.trim();
    let installed = app_version.trim();
    if !minimum.is_empty() && !installed.is_empty() && compare_versions(installed, minimum).is_lt()
    {
        return Err(format!(
            "requires app {minimum} or later (installed: {installed})"
        ));
    }
    for raw in &manifest.required_runtime_features {
        let mut name = raw.trim();
        if name.is_empty() {
            continue;
        }
        let mut wanted = 1;
        if let Some((feature, version)) = name.rsplit_once('@')
            && !feature.is_empty()
        {
            wanted = version
                .parse::<isize>()
                .ok()
                .filter(|version| *version > 0)
                .unwrap_or(1);
            name = feature;
        }
        let Some(provided) = features.get(name) else {
            return Err(format!(
                "requires runtime feature {} this app build does not provide",
                serde_json::to_string(name).expect("JSON string")
            ));
        };
        if *provided < wanted {
            return Err(format!(
                "requires runtime feature {name}@{wanted} (app provides @{provided})"
            ));
        }
    }
    Ok(())
}

pub fn compare_versions(first: &str, second: &str) -> Comparison {
    fn parts(version: &str) -> impl Iterator<Item = isize> + '_ {
        version
            .strip_prefix('v')
            .unwrap_or(version)
            .split('.')
            .map(|part| {
                part.parse()
                    .unwrap_or_else(|error: std::num::ParseIntError| match error.kind() {
                        std::num::IntErrorKind::PosOverflow => isize::MAX,
                        std::num::IntErrorKind::NegOverflow => isize::MIN,
                        _ => 0,
                    })
            })
    }
    let mut first = parts(first);
    let mut second = parts(second);
    loop {
        let (left, right) = (first.next(), second.next());
        if left.is_none() && right.is_none() {
            return Comparison::Equal;
        }
        let result = left.unwrap_or(0).cmp(&right.unwrap_or(0));
        if !result.is_eq() {
            return result;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deferred_preview_extensions_require_this_app_build() {
        let manifest = ExtensionManifest::parse(
            &serde_json::json!({
                "name":"generic-media","version":"1.0.0","description":"Generic fixture",
                "type":["metadata_provider"],"minAppVersion":"5.3.0",
                "requiredRuntimeFeatures":["deferredPreview@1"]
            })
            .to_string(),
        )
        .unwrap();
        assert!(validate_gates(&manifest, "5.3.0", &SUPPORTED_RUNTIME_FEATURES).is_ok());
        let without = BTreeMap::new();
        assert!(validate_gates(&manifest, "5.3.0", &without).is_err());
    }
}
