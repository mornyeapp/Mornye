//! Owner state of the Rust backend, ported once from the mobile hosts
//! (`ios/Runner/CoreBackend.swift` `RustCoreBackend`, Android
//! `SelectedCoreBackend.kt` `RustCoreBackend`). Desktop uses plain paths, so
//! there is no SAF or security-scoped access here.

use crate::call::{Args, CallError, OrFail};
use crate::paths::{self, RemoveOnDrop};
use crate::runtime::Config;
use mornye_mobile::{
    CancellationDomain, CancellationRegistry, DownloadDirectoryScope, DownloadProgressSubscription,
    ExtensionManager, ExtensionRepository, RequestLease,
};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

#[derive(Clone, PartialEq, Eq)]
struct Identity {
    sources: String,
    data: String,
    key_hash: String,
}

#[derive(Default)]
struct Owner {
    manager: Option<Arc<ExtensionManager>>,
    repository: Option<Arc<ExtensionRepository>>,
    requests: Option<Arc<CancellationRegistry>>,
    identity: Option<Identity>,
    logging_enabled: bool,
    allow_private_network: bool,
    allow_http_fallback: bool,
    fallback_providers: Option<Vec<String>>,
    directory_scopes: HashMap<String, Arc<DownloadDirectoryScope>>,
    library_cover_scope: Option<Arc<DownloadDirectoryScope>>,
    allowed_directories: Vec<String>,
}

/// One extension callback URL waiting for `processPendingExtensionCallbacks`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CallbackRoute {
    pub(crate) code: String,
    pub(crate) state: String,
    pub(crate) session_grant: bool,
}

const MAX_PENDING_CALLBACKS: usize = 16;

pub(crate) struct Backend {
    /// Private staging root (iOS: `Caches/rust-core-pilot`).
    root: PathBuf,
    app_version: String,
    owner: Mutex<Owner>,
    data_jobs: CancellationRegistry,
    active_data_jobs: Mutex<HashMap<String, usize>>,
    callbacks: Mutex<VecDeque<CallbackRoute>>,
}

/// Releases a directory grant when dropped (`CoreDirectoryScope.close`).
pub(crate) struct ScopeGuard(Arc<DownloadDirectoryScope>);

impl Drop for ScopeGuard {
    fn drop(&mut self) {
        self.0.release();
    }
}

fn failure(message: &str) -> CallError {
    CallError::failure(message)
}

fn not_initialized() -> CallError {
    failure("Rust backend is not initialized")
}

fn overlaps(path: &Path, storage: &Path) -> bool {
    path == storage || path.starts_with(storage) || storage.starts_with(path)
}

impl Backend {
    pub(crate) fn new(config: &Config) -> Self {
        Self {
            root: config.temp_dir.join("mornye-rust-core"),
            app_version: config.app_version.clone(),
            owner: Mutex::new(Owner::default()),
            data_jobs: CancellationRegistry::new(CancellationDomain::ExtensionRequest),
            active_data_jobs: Mutex::new(HashMap::new()),
            callbacks: Mutex::new(VecDeque::new()),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Owner> {
        self.owner.lock().expect("backend owner lock")
    }

    fn files(&self) -> PathBuf {
        self.root.join("files")
    }

    fn prepare_private_files(&self) -> Result<PathBuf, CallError> {
        let owner = self.lock();
        let manager = owner.manager.as_ref().ok_or_else(not_initialized)?;
        let files = self.files();
        if files.is_dir() {
            return Ok(files);
        }
        fs::create_dir_all(&files).or_fail()?;
        // Cache clearing can unlink an open directory. Reopen the configured
        // grants so new writes use its replacement, including on Linux.
        manager
            .environment()
            .set_allowed_download_directories(owner.allowed_directories.clone())
            .or_fail()?;
        Ok(files)
    }

    fn files_aliases(&self) -> Vec<String> {
        let files = self.files();
        let resolved = paths::resolve_string(&files.to_string_lossy());
        let standardized = paths::standardize(&files).to_string_lossy().into_owned();
        let mut aliases = vec![resolved];
        if !aliases.contains(&standardized) {
            aliases.push(standardized);
        }
        aliases
    }

    pub(crate) fn owner(&self) -> Result<Arc<ExtensionManager>, CallError> {
        self.lock().manager.clone().ok_or_else(not_initialized)
    }

    pub(crate) fn manager_snapshot(&self) -> Option<Arc<ExtensionManager>> {
        self.lock().manager.clone()
    }

    pub(crate) fn repository(&self) -> Result<Arc<ExtensionRepository>, CallError> {
        self.lock()
            .repository
            .clone()
            .ok_or_else(|| failure("Extension repository is not initialized"))
    }

    pub(crate) fn source_directory(&self) -> Option<String> {
        self.lock()
            .identity
            .as_ref()
            .map(|identity| identity.sources.clone())
    }

    fn requests_locked(owner: &mut Owner) -> Arc<CancellationRegistry> {
        Arc::clone(owner.requests.get_or_insert_with(|| {
            Arc::new(CancellationRegistry::new(
                CancellationDomain::ExtensionRequest,
            ))
        }))
    }

    pub(crate) fn cancel_request(&self, id: &str) -> Result<(), CallError> {
        let registry = Self::requests_locked(&mut self.lock());
        registry.cancel(id.to_owned()).or_fail()
    }

    pub(crate) fn acquire_request(
        &self,
        id: &str,
    ) -> Result<(Arc<ExtensionManager>, Arc<RequestLease>), CallError> {
        let mut owner = self.lock();
        let manager = owner.manager.clone().ok_or_else(not_initialized)?;
        let lease = Self::requests_locked(&mut owner)
            .acquire(id.to_owned())
            .or_fail()?;
        Ok((manager, lease))
    }

    /// `directoryAliases`: the resolved path, plus its original spelling.
    fn directory_aliases(value: &str, identity: &Identity) -> Result<Vec<String>, CallError> {
        if !paths::is_absolute(value) {
            return Err(failure("Output directories must be absolute"));
        }
        let path = paths::resolve(value);
        if path.parent().is_none()
            || overlaps(&path, Path::new(&identity.sources))
            || overlaps(&path, Path::new(&identity.data))
        {
            return Err(failure("Output directory overlaps extension storage"));
        }
        let resolved = path.to_string_lossy().into_owned();
        let original = paths::standardize(Path::new(value))
            .to_string_lossy()
            .into_owned();
        Ok(if resolved == original {
            vec![resolved]
        } else {
            vec![resolved, original]
        })
    }

    fn open_download_directory_locked(
        owner: &Owner,
        path: &str,
    ) -> Result<Arc<DownloadDirectoryScope>, CallError> {
        let (Some(manager), Some(identity)) = (&owner.manager, &owner.identity) else {
            return Err(not_initialized());
        };
        let aliases = Self::directory_aliases(path, identity)?;
        manager
            .environment()
            .grant_download_directories(aliases)
            .or_fail()
    }

    pub(crate) fn initialize_owner(&self, args: &Args) -> Result<(), CallError> {
        let (Some(source_path), Some(data_path), Some(key)) = (
            args.opt_string("extensions_dir"),
            args.opt_string("data_dir"),
            args.opt_string("master_key"),
        ) else {
            return Err(failure("Extension storage arguments are required"));
        };
        if !paths::is_absolute(source_path) || !paths::is_absolute(data_path) {
            return Err(failure("Extension storage directories must be absolute"));
        }
        let requested = Identity {
            sources: paths::resolve_string(source_path),
            data: paths::resolve_string(data_path),
            key_hash: Sha256::digest(key.as_bytes())
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect(),
        };
        let mut owner = self.lock();
        fs::create_dir_all(self.files()).or_fail()?;
        let directories = match args.string_list("allowed_directories") {
            None => Vec::new(),
            Some(Ok(directories)) => directories,
            Some(Err(())) => return Err(failure("Invalid output directories")),
        };
        let mut allowed = self.files_aliases();
        for value in directories {
            for alias in Self::directory_aliases(&value, &requested)? {
                if !allowed.contains(&alias) {
                    allowed.push(alias);
                }
            }
        }
        if let Some(manager) = &owner.manager {
            if owner.identity.as_ref() != Some(&requested) {
                return Err(failure(
                    "Rust backend is already initialized with different storage",
                ));
            }
            manager
                .environment()
                .set_allowed_download_directories(allowed.clone())
                .or_fail()?;
            owner.allowed_directories = allowed;
            return Ok(());
        }
        let created = ExtensionManager::with_lyrics_settings(
            requested.sources.clone(),
            requested.data.clone(),
            key.to_owned(),
            self.app_version.clone(),
            30_000,
            args.string("lyrics_providers_json", "[]"),
            args.string("lyrics_options_json", "{}"),
        )
        .or_fail()?;
        let configured = (|| {
            let environment = created.environment();
            environment
                .set_allowed_download_directories(allowed.clone())
                .or_fail()?;
            environment
                .set_allow_private_network(owner.allow_private_network)
                .or_fail()?;
            environment
                .set_network_compatibility_options(owner.allow_http_fallback, false)
                .or_fail()?;
            environment
                .log_buffer()
                .set_enabled(owner.logging_enabled)
                .or_fail()?;
            created
                .set_fallback_providers(owner.fallback_providers.clone())
                .or_fail()
        })();
        if let Err(error) = configured {
            created.shutdown();
            return Err(error);
        }
        owner.identity = Some(requested);
        owner.manager = Some(Arc::new(created));
        owner.allowed_directories = allowed;
        Ok(())
    }

    pub(crate) fn shutdown_owner(&self) {
        let mut owner = self.lock();
        if let Some(requests) = owner.requests.take() {
            requests.shutdown();
        }
        if let Some(repository) = owner.repository.take() {
            repository.shutdown();
        }
        if let Some(manager) = owner.manager.take() {
            manager.shutdown();
        }
        for (_, scope) in owner.directory_scopes.drain() {
            scope.release();
        }
        if let Some(scope) = owner.library_cover_scope.take() {
            scope.release();
        }
        owner.identity = None;
        owner.allowed_directories.clear();
    }

    pub(crate) fn initialize_repository(&self, cache_path: &str) -> Result<(), CallError> {
        let mut owner = self.lock();
        let manager = owner.manager.clone().ok_or_else(not_initialized)?;
        if owner.repository.is_some() {
            return Ok(());
        }
        if !paths::is_absolute(cache_path) {
            return Err(failure("Repository cache directory must be absolute"));
        }
        let repository =
            ExtensionRepository::new(manager, paths::resolve_string(cache_path)).or_fail()?;
        owner.repository = Some(Arc::new(repository));
        Ok(())
    }

    pub(crate) fn set_download_directory(&self, path: &str) -> Result<(), CallError> {
        let mut owner = self.lock();
        let (Some(manager), Some(identity)) = (&owner.manager, &owner.identity) else {
            return Err(not_initialized());
        };
        let mut allowed = self.files_aliases();
        if !path.is_empty() {
            allowed.extend(Self::directory_aliases(path, identity)?);
        }
        manager
            .environment()
            .set_allowed_download_directories(allowed.clone())
            .or_fail()?;
        owner.allowed_directories = allowed;
        Ok(())
    }

    pub(crate) fn acquire_download_directory(&self, path: &str) -> Result<String, CallError> {
        let mut owner = self.lock();
        let scope = Self::open_download_directory_locked(&owner, path)?;
        let token = paths::uuid();
        owner.directory_scopes.insert(token.clone(), scope);
        Ok(token)
    }

    pub(crate) fn release_download_directory(&self, token: &str) {
        let scope = self.lock().directory_scopes.remove(token);
        if let Some(scope) = scope {
            scope.release();
        }
    }

    pub(crate) fn update_settings(
        &self,
        apply: impl FnOnce(&mut OwnerSettings<'_>) -> Result<(), CallError>,
    ) -> Result<(), CallError> {
        let mut owner = self.lock();
        let owner = &mut *owner;
        apply(&mut OwnerSettings {
            manager: owner.manager.as_deref(),
            logging_enabled: &mut owner.logging_enabled,
            allow_private_network: &mut owner.allow_private_network,
            allow_http_fallback: &mut owner.allow_http_fallback,
            fallback_providers: &mut owner.fallback_providers,
        })
    }

    /// `withLibraryDirectories`: grants the directories for one operation.
    pub(crate) fn with_library_directories<T>(
        &self,
        directories: &[String],
        block: impl FnOnce(&ExtensionManager) -> Result<T, CallError>,
    ) -> Result<T, CallError> {
        let (manager, _scope) = {
            let owner = self.lock();
            let (Some(manager), Some(identity)) = (&owner.manager, &owner.identity) else {
                return Err(not_initialized());
            };
            let mut aliases = Vec::new();
            let mut seen = HashSet::new();
            for directory in directories {
                for alias in Self::directory_aliases(directory, identity)? {
                    if seen.insert(alias.clone()) {
                        aliases.push(alias);
                    }
                }
            }
            let grant = manager
                .environment()
                .grant_download_directories(aliases)
                .or_fail()?;
            (Arc::clone(manager), ScopeGuard(grant))
        };
        // Progress and cancellation must remain available while this runs.
        block(&manager)
    }

    /// `withMediaFiles`: grants the parent directory of each non-empty path.
    pub(crate) fn with_media_files<T>(
        &self,
        files: &[&str],
        block: impl FnOnce(&ExtensionManager) -> Result<T, CallError>,
    ) -> Result<T, CallError> {
        let mut directories = Vec::new();
        for path in files.iter().filter(|path| !path.is_empty()) {
            if !paths::is_absolute(path) {
                return Err(failure("Media paths must be absolute"));
            }
            let parent = paths::standardize(Path::new(path))
                .parent()
                .map(|parent| parent.to_string_lossy().into_owned())
                .unwrap_or_else(|| "/".into());
            if !directories.contains(&parent) {
                directories.push(parent);
            }
        }
        self.with_library_directories(&directories, block)
    }

    pub(crate) fn set_library_cover_cache_directory(&self, path: &str) -> Result<(), CallError> {
        let mut owner = self.lock();
        let manager = owner.manager.clone().ok_or_else(not_initialized)?;
        if !path.is_empty() && !paths::is_absolute(path) {
            return Err(failure("Library cover directory must be absolute"));
        }
        let directory = (!path.is_empty()).then(|| paths::resolve_string(path));
        if let Some(directory) = &directory {
            fs::create_dir_all(directory).or_fail()?;
        }
        let next = match &directory {
            Some(directory) => Some(Self::open_download_directory_locked(&owner, directory)?),
            None => None,
        };
        if let Err(error) =
            manager.set_library_cover_cache_directory(directory.clone().unwrap_or_default())
        {
            if let Some(next) = next {
                next.release();
            }
            return Err(CallError::failure(error));
        }
        if let Some(previous) = owner.library_cover_scope.take() {
            previous.release();
        }
        owner.library_cover_scope = next;
        Ok(())
    }

    pub(crate) fn scan_library_folder_to_ndjson_file(
        &self,
        folder: &str,
        output: &str,
    ) -> Result<u64, CallError> {
        let is_ndjson = Path::new(output)
            .extension()
            .is_some_and(|extension| extension.eq_ignore_ascii_case("ndjson"));
        if !paths::is_absolute(output) || !is_ndjson {
            return Err(failure(
                "Library scan output must be an absolute NDJSON path",
            ));
        }
        self.with_library_directories(&[folder.to_owned()], |manager| {
            // Application support also contains extension storage. Stage in
            // the private root instead of granting that whole directory.
            let staged = self
                .prepare_private_files()?
                .join(format!("library_scan_{}.ndjson", paths::uuid()));
            let _cleanup = RemoveOnDrop(staged.clone());
            let count = manager
                .scan_library_folder_to_ndjson_file(
                    paths::resolve_string(folder),
                    paths::resolve_string(&staged.to_string_lossy()),
                    None,
                )
                .or_fail()?;
            paths::publish(&staged, Path::new(output)).or_fail()?;
            Ok(count)
        })
    }

    pub(crate) fn library_scan_progress(&self) -> Result<String, CallError> {
        match self.manager_snapshot() {
            Some(manager) => manager.get_library_scan_progress().or_fail(),
            None => Ok("{}".into()),
        }
    }

    pub(crate) fn parse_cue_sheet(
        &self,
        path: &str,
        audio_directory: &str,
    ) -> Result<String, CallError> {
        let cue = paths::resolve(path);
        let audio = if audio_directory.is_empty() {
            cue.parent().map(Path::to_path_buf).unwrap_or_default()
        } else {
            paths::resolve(audio_directory)
        };
        let cue_directory = cue
            .parent()
            .map(|parent| parent.to_string_lossy().into_owned())
            .unwrap_or_default();
        let audio = audio.to_string_lossy().into_owned();
        self.with_library_directories(&[cue_directory, audio.clone()], |manager| {
            manager
                .parse_cue_file_json(cue.to_string_lossy().into_owned(), audio, None)
                .or_fail()
        })
    }

    pub(crate) fn create_temporary_media_file(
        &self,
        prefix: &str,
        suffix: &str,
    ) -> Result<PathBuf, CallError> {
        let files = self.prepare_private_files()?;
        let file = files.join(format!("{prefix}{}{suffix}", paths::uuid()));
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&file)
            .or_fail()?;
        Ok(file)
    }

    pub(crate) fn open_download_progress(
        &self,
    ) -> Result<Arc<DownloadProgressSubscription>, CallError> {
        self.owner()?
            .environment()
            .download_state()
            .subscribe_progress()
            .or_fail()
    }

    // Native data jobs (iOS `prepareApplicationArguments`/`runDataJob`).

    pub(crate) fn acquire_data_job(&self, id: &str) -> Result<Arc<RequestLease>, CallError> {
        let mut active = self.active_data_jobs.lock().expect("data jobs lock");
        let lease = self.data_jobs.acquire(id.to_owned()).or_fail()?;
        *active.entry(id.to_owned()).or_default() += 1;
        Ok(lease)
    }

    pub(crate) fn finish_data_job(&self, id: &str, lease: &RequestLease) {
        let mut active = self.active_data_jobs.lock().expect("data jobs lock");
        lease.release();
        let remaining = active.get(id).copied().unwrap_or(1).saturating_sub(1);
        if remaining > 0 {
            active.insert(id.to_owned(), remaining);
        } else {
            active.remove(id);
        }
    }

    pub(crate) fn cancel_data_job(&self, id: &str) -> Result<(), CallError> {
        let active = self.active_data_jobs.lock().expect("data jobs lock");
        if active.contains_key(id) {
            self.data_jobs.cancel(id.to_owned()).or_fail()?;
        }
        Ok(())
    }

    pub(crate) fn run_data_job(
        &self,
        args: &Args,
        lease: Arc<RequestLease>,
    ) -> Result<String, CallError> {
        let raw = args
            .opt_string("request_json")
            .ok_or_else(|| failure("Missing native data job request"))?;
        let bytes = args.bytes("bytes").unwrap_or_default().to_vec();
        // Fast pass-through when Dart supplies the operation name and no host
        // path rewriting is required, avoiding full JSON parse + re-encode.
        if let Some(operation) = args.opt_string("operation")
            && operation != "library_scan_incremental"
        {
            return mornye_mobile::run_native_data_job(raw.to_owned(), bytes, Some(lease))
                .or_fail();
        }
        let mut request: Value = serde_json::from_str(raw).or_fail()?;
        if !request.is_object() {
            return Err(failure("Missing native data job request"));
        }
        if request["operation"].as_str() != Some("library_scan_incremental") {
            return mornye_mobile::run_native_data_job(raw.to_owned(), bytes, Some(lease))
                .or_fail();
        }
        let folder = request["folder_path"]
            .as_str()
            .ok_or_else(|| failure("Missing library folder"))?
            .to_owned();
        self.with_library_directories(std::slice::from_ref(&folder), |manager| {
            let staged = self
                .prepare_private_files()?
                .join(format!("library_snapshot_{}.tsv", paths::uuid()));
            let _cleanup = RemoveOnDrop(staged.clone());
            if let Some(snapshot) = request["snapshot_path"]
                .as_str()
                .filter(|path| !path.is_empty())
            {
                fs::copy(snapshot, &staged).or_fail()?;
                request["snapshot_path"] = staged.to_string_lossy().into_owned().into();
            }
            request["folder_path"] = paths::resolve_string(&folder).into();
            manager
                .run_native_data_job(request.to_string(), bytes, Some(lease))
                .or_fail()
        })
    }

    // Extension callback inbox (Android `extensionAuthCallbacks`).

    pub(crate) fn queue_callback(&self, route: CallbackRoute) -> bool {
        let mut pending = self.callbacks.lock().expect("callbacks lock");
        if pending.contains(&route) {
            return false;
        }
        if pending.len() == MAX_PENDING_CALLBACKS {
            pending.pop_front();
        }
        pending.push_back(route);
        true
    }

    pub(crate) fn take_callbacks(&self) -> Vec<CallbackRoute> {
        self.callbacks
            .lock()
            .expect("callbacks lock")
            .drain(..)
            .collect()
    }
}

/// Settings the hosts cache so they survive a later `initExtensionSystem`.
pub(crate) struct OwnerSettings<'a> {
    pub(crate) manager: Option<&'a ExtensionManager>,
    pub(crate) logging_enabled: &'a mut bool,
    pub(crate) allow_private_network: &'a mut bool,
    pub(crate) allow_http_fallback: &'a mut bool,
    pub(crate) fallback_providers: &'a mut Option<Vec<String>>,
}

/// `requireSuccessfulExtensionAction`.
pub(crate) fn require_successful_extension_action(
    extension_id: &str,
    action: &str,
    response: &str,
) -> Result<(), CallError> {
    let prefix: String = response.chars().take(240).collect();
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(response) else {
        return Err(CallError::failure(format!(
            "Extension {action} for {extension_id} returned invalid JSON: {prefix}"
        )));
    };
    if object.get("success") == Some(&Value::Bool(true)) {
        return Ok(());
    }
    let error = ["error", "message"]
        .iter()
        .find_map(|key| object.get(*key).and_then(Value::as_str))
        .map(|text| text.trim().to_owned())
        .unwrap_or(prefix);
    Err(CallError::failure(format!(
        "Extension {action} failed for {extension_id}: {error}"
    )))
}

pub(crate) fn complete_session_grant(
    manager: &ExtensionManager,
    id: &str,
    grant: &str,
) -> Result<(), CallError> {
    manager
        .environment()
        .set_session_grant(id.to_owned(), grant.to_owned())
        .or_fail()?;
    let response = manager
        .invoke_action(id.to_owned(), "completeGrant".into())
        .or_fail()?;
    require_successful_extension_action(id, "completeGrant", &response)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn initialized_backend(root: &Path) -> Backend {
        let backend = Backend::new(&Config {
            temp_dir: root.join("temp"),
            ..Config::default()
        });
        let arguments = json!({
            "extensions_dir": root.join("extensions"),
            "data_dir": root.join("data"),
            "master_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        });
        backend
            .initialize_owner(&Args::decode(arguments.to_string().as_bytes(), None).unwrap())
            .unwrap();
        backend
    }

    #[test]
    fn library_scan_recovers_after_private_cache_removal() {
        let root = tempfile::tempdir().unwrap();
        let backend = initialized_backend(root.path());
        let music = root.path().join("music");
        fs::create_dir_all(&music).unwrap();
        let output = root.path().join("scan.ndjson");
        for clear_cache in [false, true] {
            if clear_cache {
                fs::remove_dir_all(backend.files()).unwrap();
            }
            assert_eq!(
                backend
                    .scan_library_folder_to_ndjson_file(
                        music.to_str().unwrap(),
                        output.to_str().unwrap(),
                    )
                    .unwrap(),
                0,
            );
            assert_eq!(fs::read(&output).unwrap(), b"");
        }
        backend.shutdown_owner();
    }

    #[test]
    fn cover_output_recovers_after_private_cache_removal() {
        let root = tempfile::tempdir().unwrap();
        let backend = initialized_backend(root.path());
        fs::remove_dir_all(backend.files()).unwrap();
        let output = backend
            .create_temporary_media_file("cover_", ".jpg")
            .unwrap();
        let error = backend
            .owner()
            .unwrap()
            .download_cover_to_file_sized(
                "invalid-cover-url".into(),
                output.to_string_lossy().into_owned(),
                0,
                None,
            )
            .unwrap_err()
            .to_string();
        assert!(error.contains("invalid URL"), "{error}");
        backend.shutdown_owner();
    }
}
