//! Installed packages and runtime lifecycle belong to one native owner.

mod downloads;
mod info;
mod install;
mod lifecycle;
mod metadata;
mod postprocess;
mod providers;
#[cfg(test)]
mod tests;

pub use downloads::ProviderDownloadRequest;
pub use metadata::ProviderAvailabilityRequest;
pub use postprocess::PostProcessInput;

use crate::environment::{
    ExtensionEnvironment, SUPPORTED_RUNTIME_FEATURES, compare_versions, validate_gates,
};
use crate::manifest::ExtensionManifest;
use crate::package::{ExtensionPackage, is_package_path};
use crate::runtime::{LoadMode, lifecycle_result};
use crate::{ExtensionError, ExtensionRuntime, RuntimeLimits};
use mornye_core::cancellation::RequestLease;
use mornye_core::fs::{DirBuilderPortableExt, OpenOptionsPortableExt};
use serde_json::{Map, Value, json};
use std::cmp::Ordering as Comparison;
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct ManagerError(pub String);

fn error(message: impl Into<String>) -> ManagerError {
    ManagerError(message.into())
}
fn cause(context: &str, error: impl std::fmt::Display) -> ManagerError {
    ManagerError(format!("{context}: {error}"))
}

#[derive(Default)]
struct Status {
    enabled: bool,
    error: String,
}
#[derive(Default)]
struct Engine {
    runtime: Option<Arc<ExtensionRuntime>>,
    initialized: bool,
    source: Option<Arc<str>>,
}
struct Installed {
    manifest: ExtensionManifest,
    manifest_json: String,
    source: PathBuf,
    status: RwLock<Status>,
    engine: Mutex<Engine>,
    // Pool maintenance must not wait for a primary VM running post-processing.
    // Code needing both locks takes engine before downloads.
    downloads: Mutex<downloads::Pool>,
}

struct MetadataChange<'a>(&'a AtomicU64);
impl Drop for MetadataChange<'_> {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::AcqRel);
    }
}

pub struct ExtensionManager {
    environment: Arc<ExtensionEnvironment>,
    sources: PathBuf,
    limits: RuntimeLimits,
    entries: Mutex<BTreeMap<String, Arc<Installed>>>,
    mutation: Mutex<()>,
    closed: AtomicBool,
    directory_locks: Mutex<Option<Vec<File>>>,
    priorities: Mutex<providers::Priorities>,
    metadata_revision: AtomicU64,
}

impl ExtensionManager {
    pub fn new(
        sources: &Path,
        data: &Path,
        master_key: &str,
        app_version: &str,
        limits: RuntimeLimits,
    ) -> Result<Self, ManagerError> {
        let environment = ExtensionEnvironment::new(data, master_key, app_version)
            .map_err(|e| error(e.to_string()))?;
        Self::with_environment(sources, environment, limits)
    }

    pub(crate) fn with_environment(
        sources: &Path,
        environment: ExtensionEnvironment,
        limits: RuntimeLimits,
    ) -> Result<Self, ManagerError> {
        let environment = Arc::new(environment);
        environment.attach_manager();
        if sources.as_os_str().is_empty() {
            return Err(error("extension directory is not configured"));
        }
        fs::DirBuilder::new()
            .recursive(true)
            .unix_mode(0o700)
            .create(sources)
            .map_err(|e| cause("failed to create extensions directory", e))?;
        let sources = fs::canonicalize(sources)
            .map_err(|e| cause("failed to inspect extensions directory", e))?;
        let data = environment.data_directory();
        if sources.starts_with(data) || data.starts_with(&sources) {
            return Err(error(
                "extension source and data directories must be separate",
            ));
        }
        let mut locks = Vec::new();
        for directory in [&sources, data] {
            let lock = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .unix_mode(0o600)
                .nofollow_nonblock()
                .open(directory.join(".backend-manager.lock"))
                .map_err(|e| cause("failed to lock extension directory", e))?;
            if !lock
                .metadata()
                .map_err(|e| cause("failed to inspect directory lock", e))?
                .is_file()
            {
                return Err(error("extension directory lock must be a regular file"));
            }
            lock.try_lock()
                .map_err(|_| error("extension directories are already managed"))?;
            locks.push(lock);
        }
        Ok(Self {
            environment,
            sources,
            limits,
            entries: Mutex::default(),
            mutation: Mutex::new(()),
            closed: AtomicBool::new(false),
            directory_locks: Mutex::new(Some(locks)),
            priorities: Mutex::default(),
            metadata_revision: AtomicU64::new(0),
        })
    }

    pub fn environment(&self) -> Arc<ExtensionEnvironment> {
        Arc::clone(&self.environment)
    }

    fn check(&self) -> Result<(), ManagerError> {
        if self.closed.load(Ordering::Acquire) || self.environment.is_closed() {
            Err(error("extension manager closed"))
        } else {
            Ok(())
        }
    }

    fn get(&self, id: &str) -> Result<Arc<Installed>, ManagerError> {
        self.check()?;
        self.entries
            .lock()
            .expect("extension manager lock")
            .get(id)
            .cloned()
            .ok_or_else(|| error("extension not found"))
    }

    fn current(&self, entry: &Arc<Installed>) -> bool {
        !self.closed.load(Ordering::Acquire)
            && self
                .entries
                .lock()
                .expect("extension manager lock")
                .get(&entry.manifest.name)
                .is_some_and(|value| Arc::ptr_eq(value, entry))
    }

    pub(crate) fn health_manifest(&self, id: &str) -> Result<ExtensionManifest, ManagerError> {
        // The explicit health API also accepts disabled installed extensions.
        Ok(self.get(id)?.manifest.clone())
    }

    pub fn set_enabled(&self, id: &str, enabled: bool) -> Result<(), ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        let entry = self.get(id)?;
        {
            let mut status = entry.status.write().expect("extension status lock");
            status.enabled = enabled;
            if !enabled {
                status.error.clear();
            }
        }
        let mut engine = entry.engine.lock().expect("extension engine lock");
        if enabled {
            if let Err(error) = self.ready(&entry, &mut engine, true) {
                self.failed(&entry, &error);
                let _ = self.environment.set_setting(id, "_enabled", false.into());
                return Err(error);
            }
        } else {
            self.teardown(&entry, &mut engine);
        }
        if let Err(error) = self.environment.set_setting(id, "_enabled", enabled.into()) {
            let _ = self.environment.log_buffer().backend(&format!(
                "[Extension] Failed to persist enabled state for {id}: {error}"
            ));
        }
        Ok(())
    }

    pub fn update_settings(
        &self,
        id: &str,
        settings: Map<String, Value>,
    ) -> Result<(), ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        let entry = self.get(id)?;
        self.environment
            .replace_settings(id, settings.clone())
            .map_err(error_from_environment)?;
        // A runtime that is already loaded keeps its session; refresh its grants.
        if let Some(network) = entry
            .engine
            .lock()
            .expect("extension engine lock")
            .runtime
            .as_ref()
            .and_then(|runtime| runtime.network_session())
        {
            network.set_grants(entry.manifest.network_grants(&settings));
        }
        self.initialize(id, settings)
    }

    pub fn initialize(&self, id: &str, settings: Map<String, Value>) -> Result<(), ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let entry = self.get(id)?;
        let mut engine = entry.engine.lock().expect("extension engine lock");
        if !self.current(&entry) {
            return Err(error("extension is no longer installed"));
        }
        self.invalidate_download_pool(&mut entry.downloads.lock().expect("download pool lock"));
        let result = self.ready(&entry, &mut engine, false).and_then(|runtime| {
            self.lifecycle(&runtime, "initialize", &json!([settings]).to_string())
        });
        if let Err(error) = &result {
            self.failed(&entry, error);
        } else {
            engine.initialized = true;
        }
        result
    }

    pub fn cleanup(&self, id: &str) -> Result<(), ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let entry = self.get(id)?;
        let engine = entry.engine.lock().expect("extension engine lock");
        if !self.current(&entry) {
            return Err(error("extension is no longer installed"));
        }
        engine
            .runtime
            .as_ref()
            .map_or(Ok(()), |runtime| self.lifecycle(runtime, "cleanup", "[]"))
    }

    pub fn invoke_action(&self, id: &str, action: &str) -> Result<String, ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let entry = self.get(id).map_err(|e| {
            if e.0 == "extension not found" {
                error(format!("extension not found: {id}"))
            } else {
                e
            }
        })?;
        if !entry.status.read().expect("extension status lock").enabled {
            return Err(error("extension is disabled"));
        }
        let mut engine = entry.engine.lock().expect("extension engine lock");
        if !self.current(&entry) || !entry.status.read().expect("extension status lock").enabled {
            return Err(error("extension is disabled or no longer installed"));
        }
        let runtime = self
            .ready(&entry, &mut engine, true)
            .inspect_err(|e| self.failed(&entry, e))?;
        let timeout = entry.manifest.action_timeout_ms(self.limits.timeout_ms);
        runtime
            .managed_call(action, "[]", true, timeout)
            .map_err(|e| cause("action failed", e))
    }

    pub fn call(
        &self,
        id: &str,
        method: &str,
        arguments: &str,
        lease: Option<Arc<mornye_core::cancellation::RequestLease>>,
        timeout_ms: u64,
    ) -> Result<String, ManagerError> {
        let entry = self.get(id)?;
        if !entry.status.read().expect("extension status lock").enabled {
            return Err(error("extension is disabled"));
        }
        let mut engine = entry.engine.lock().expect("extension engine lock");
        if !self.current(&entry) || !entry.status.read().expect("extension status lock").enabled {
            return Err(error("extension is disabled or no longer installed"));
        }
        let runtime = self
            .ready(&entry, &mut engine, true)
            .inspect_err(|e| self.failed(&entry, e))?;
        runtime
            .call(method, arguments, lease, timeout_ms)
            .map_err(|e| error(e.to_string()))
    }

    fn unload_locked(&self, id: &str) -> Result<(), ManagerError> {
        self.check()?;
        let entry = self
            .entries
            .lock()
            .expect("extension manager lock")
            .remove(id)
            .ok_or_else(|| error("extension not found"))?;
        entry.status.write().expect("extension status lock").enabled = false;
        self.teardown(
            &entry,
            &mut entry.engine.lock().expect("extension engine lock"),
        );
        Ok(())
    }

    /// Emergency shutdown interrupts workers; orderly unload runs cleanup first.
    pub fn shutdown(&self) {
        self.closed.store(true, Ordering::Release);
        self.environment.shutdown();
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        self.entries.lock().expect("extension manager lock").clear();
        if let Some(locks) = self
            .directory_locks
            .lock()
            .expect("extension directory locks")
            .take()
        {
            // A subprocess can inherit the descriptor between fork and exec.
            // Closing our copy alone may leave the old owner's lock held.
            for lock in locks {
                let _ = lock.unlock();
            }
        }
    }
}

impl Drop for ExtensionManager {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn error_from_environment(error: crate::environment::EnvironmentError) -> ManagerError {
    ManagerError(error.to_string())
}
fn read_source(path: &Path, limit: u64) -> std::io::Result<String> {
    let mut file = OpenOptions::new()
        .read(true)
        .nofollow_nonblock()
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(std::io::Error::other(
            "extension source must be a regular file",
        ));
    }
    let mut bytes = Vec::new();
    (&mut file).take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(std::io::Error::other(
            "extension source exceeds its size limit",
        ));
    }
    Ok(crate::host::decode_go_utf8(&bytes))
}
