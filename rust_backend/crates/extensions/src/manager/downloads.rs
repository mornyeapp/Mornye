//! Extension manager download support: request types, preflight checks, and the download engine pool.

use super::*;
use serde::Deserialize;

#[derive(Default)]
pub(super) struct Pool {
    pub active: Vec<Arc<ExtensionRuntime>>,
    idle: Option<Arc<ExtensionRuntime>>,
    generation: u64,
    settings: Option<Map<String, Value>>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
pub struct ProviderDownloadRequest {
    pub track_id: String,
    pub quality: String,
    pub output_path: String,
    pub item_id: String,
    pub prepared_context: Option<Map<String, Value>>,
}

struct Borrowed<'a> {
    manager: &'a ExtensionManager,
    entry: Arc<Installed>,
    runtime: Arc<ExtensionRuntime>,
    generation: u64,
    healthy: bool,
}

impl Drop for Borrowed<'_> {
    fn drop(&mut self) {
        let mut pool = self.entry.downloads.lock().expect("download pool lock");
        // Environment settings access may create an absent store. Check manager
        // ownership first so a late borrower cannot resurrect uninstalled data.
        let reusable = self.healthy
            && !self.runtime.is_closed()
            && self.manager.current(&self.entry)
            && self
                .entry
                .status
                .read()
                .expect("extension status lock")
                .enabled;
        let settings_match = reusable
            && self
                .manager
                .environment
                .settings(&self.entry.manifest.name)
                .is_ok_and(|mut settings| {
                    settings.retain(|key, _| !key.starts_with('_'));
                    pool.settings.as_ref() == Some(&settings)
                });
        pool.active
            .retain(|runtime| !Arc::ptr_eq(runtime, &self.runtime));
        if reusable && pool.generation == self.generation && pool.idle.is_none() && settings_match {
            pool.idle = Some(Arc::clone(&self.runtime));
        } else if !self.runtime.is_closed() {
            self.manager.teardown_runtime(&self.runtime);
        } else {
            self.runtime.shutdown();
        }
    }
}

impl ExtensionManager {
    pub(crate) fn download_manifest(&self, id: &str) -> Result<ExtensionManifest, ManagerError> {
        let entry = self.get(id)?;
        let status = entry.status.read().expect("extension status lock");
        if !status.enabled || !status.error.is_empty() {
            return Err(error(format!("extension '{id}' is unavailable")));
        }
        Ok(entry.manifest.clone())
    }

    /// Extensions may opt into account-owned downloads using a declared setting.
    /// That mode owns authentication and must never enter shared-account fallback.
    pub(crate) fn account_download_enabled(&self, id: &str) -> Result<bool, ManagerError> {
        let entry = self.get(id)?;
        if !entry
            .manifest
            .capabilities
            .contains_key("accountDownloadMode")
        {
            return Ok(false);
        }
        let settings = self
            .environment
            .settings(&entry.manifest.name)
            .map_err(error_from_environment)?;
        Ok(entry.manifest.account_download_enabled(&settings))
    }

    pub(crate) fn preflight_download(
        &self,
        id: &str,
        lease: Arc<RequestLease>,
    ) -> Result<bool, ManagerError> {
        self.preflight_session(id, lease, true)
    }

    pub(crate) fn preflight_auth(
        &self,
        id: &str,
        lease: Arc<RequestLease>,
    ) -> Result<bool, ManagerError> {
        self.preflight_session(id, lease, false)
    }

    fn preflight_session(
        &self,
        id: &str,
        lease: Arc<RequestLease>,
        download_only: bool,
    ) -> Result<bool, ManagerError> {
        let Ok(entry) = self.get(id) else {
            self.check()?;
            return Ok(false);
        };
        if !entry.status.read().expect("extension status lock").enabled
            || (download_only && !entry.manifest.has_type("download_provider"))
            || entry.manifest.signed_session.is_none()
        {
            return Ok(false);
        }
        if self.account_download_enabled(id)? {
            return Ok(false);
        }
        let runtime = {
            let mut engine = self.download_engine(&entry, Some(&lease))?;
            if !self.current(&entry) || !entry.status.read().expect("extension status lock").enabled
            {
                return Err(error("extension is disabled or no longer installed"));
            }
            self.ready_with_lease(&entry, &mut engine, true, Some(lease.clone()))?
        };
        runtime
            .preflight_signed_session(Some(lease), 30_000)
            .map_err(|failure| error(failure.to_string()))
    }

    pub(super) fn download_engine<'a>(
        &self,
        entry: &'a Installed,
        lease: Option<&Arc<RequestLease>>,
    ) -> Result<EngineGuard<'a>, ManagerError> {
        entry.engine.wait(
            || {
                self.check()?;
                if let Some(lease) = lease {
                    lease
                        .check_active()
                        .map_err(|failure| error(failure.to_string()))?;
                }
                Ok(())
            },
            lease,
        )
    }

    pub(super) fn invalidate_download_pool(&self, pool: &mut Pool) -> u64 {
        pool.generation = pool.generation.wrapping_add(1);
        pool.settings = None;
        if let Some(runtime) = pool.idle.take() {
            self.teardown_runtime(&runtime);
            1
        } else {
            0
        }
    }

    /// Memory pressure releases idle heaps. Borrowed workers may finish but
    /// cannot repopulate the pool created before this request.
    pub fn release_idle_download_runtimes(&self) -> Result<u64, ManagerError> {
        self.check()?;
        let entries: Vec<_> = self
            .entries
            .lock()
            .expect("extension manager lock")
            .values()
            .cloned()
            .collect();
        let mut released = 0;
        for entry in entries {
            let mut pool = entry.downloads.lock().expect("download pool lock");
            released += self.invalidate_download_pool(&mut pool);
        }
        Ok(released)
    }

    fn borrow_download(
        &self,
        entry: Arc<Installed>,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<Borrowed<'_>, ManagerError> {
        let mut engine = self.download_engine(&entry, lease.as_ref())?;
        if !self.current(&entry) || !entry.status.read().expect("extension status lock").enabled {
            return Err(error("extension is disabled or no longer installed"));
        }
        let primary = self.ready_with_lease(&entry, &mut engine, true, lease)?;
        let mut settings = self
            .environment
            .settings(&entry.manifest.name)
            .map_err(error_from_environment)?;
        settings.retain(|key, _| !key.starts_with('_'));
        let mut pool = entry.downloads.lock().expect("download pool lock");
        if pool.settings.as_ref() != Some(&settings) {
            self.invalidate_download_pool(&mut pool);
            pool.settings = Some(settings.clone());
        }
        let idle = pool.idle.take();
        let generation = pool.generation;
        // Initialization runs extension code. Pressure may invalidate this
        // borrow while it initializes, without cancelling the operation.
        drop(pool);
        let runtime = match idle {
            Some(runtime) if !runtime.is_closed() => runtime,
            _ => {
                let runtime = self
                    .environment
                    .load_isolated(
                        &entry.manifest_json,
                        engine.source.as_ref().expect("initialized source"),
                        self.limits.clone(),
                        &primary,
                    )
                    .map_err(error_from_environment)?;
                if !settings.is_empty()
                    && let Err(error) =
                        self.lifecycle(&runtime, "initialize", &json!([settings]).to_string())
                {
                    self.teardown_runtime(&runtime);
                    return Err(error);
                }
                runtime
            }
        };
        entry
            .downloads
            .lock()
            .expect("download pool lock")
            .active
            .push(Arc::clone(&runtime));
        drop(engine);
        Ok(Borrowed {
            manager: self,
            entry,
            runtime,
            generation,
            healthy: false,
        })
    }

    /// Execute the installed provider's download contract in an isolated worker.
    /// File placement, post-processing and finalization remain caller-owned.
    pub fn download(
        &self,
        id: &str,
        request: ProviderDownloadRequest,
        resolution_timeout_ms: u64,
    ) -> Result<String, ManagerError> {
        self.download_with_lease(id, request, resolution_timeout_ms, None)
    }

    pub(crate) fn download_with_lease(
        &self,
        id: &str,
        request: ProviderDownloadRequest,
        resolution_timeout_ms: u64,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ManagerError> {
        let entry = self.get(id)?;
        if !entry.manifest.has_type("download_provider") {
            return Err(error(format!(
                "extension '{id}' is not a download provider"
            )));
        }
        if !entry.status.read().expect("extension status lock").enabled {
            return Err(error(format!("extension '{id}' is disabled")));
        }
        let mut borrowed = match self.borrow_download(entry, lease.clone()) {
            Ok(borrowed) => borrowed,
            Err(error) => return Ok(failure("init_error", &error.to_string())),
        };
        let allowance = if resolution_timeout_ms == 0 {
            60_000
        } else {
            resolution_timeout_ms.min(300_000)
        };
        let mut options = json!({"resolutionTimeoutMs":allowance});
        if let Some(context) = request
            .prepared_context
            .filter(|context| !context.is_empty())
        {
            options["preparedContext"] = context.into();
        }
        // This marker belongs to one VM and one invocation, never to a previous
        // download that returned its worker to the idle pool.
        borrowed.runtime.take_verification_url();
        let response = borrowed.runtime.call_download_provider(
            &json!([
                request.track_id,
                request.quality,
                request.output_path,
                options
            ])
            .to_string(),
            &request.item_id,
            allowance,
            lease,
        );
        let response = match response {
            Ok(response) => response,
            Err((ExtensionError::Cancelled(cause), _)) => return Err(error(cause.to_string())),
            Err((ExtensionError::Timeout, resolution)) => {
                return Ok(failure(
                    "timeout",
                    if resolution {
                        "stream resolution timeout: extension took too long to resolve an audio stream"
                    } else {
                        "download timeout: extension took too long to complete"
                    },
                ));
            }
            Err((error, _)) => return Ok(failure("script_error", &error.to_string())),
        };
        let mut response: Value = serde_json::from_str(&response)
            .map_err(|error| cause("invalid download result", error))?;
        if let Some(error) = response.get("parseError").and_then(Value::as_str) {
            return Ok(failure("script_error", error));
        }
        borrowed.healthy = true;
        let mut value = response["value"].take();
        if value.is_null() {
            return Ok(failure("not_implemented", "download returned null"));
        }
        normalize_decryption(&mut value);
        if value["success"] != true
            && !borrowed.runtime.take_verification_url().is_empty()
            && !value["error_type"]
                .as_str()
                .unwrap_or("")
                .eq_ignore_ascii_case("verification_required")
        {
            value["error_type"] = "verification_required".into();
            if value["error_message"].as_str().unwrap_or("").is_empty() {
                value["error_message"] = "Verification required".into();
            }
        }
        Ok(value.to_string())
    }
}

fn failure(kind: &str, message: &str) -> String {
    json!({"success":false,"error_type":kind,"error_message":message}).to_string()
}

fn normalize_decryption(value: &mut Value) {
    const MOV: &str = "ffmpeg.mov_key";
    let legacy = value["decryption_key"]
        .as_str()
        .unwrap_or("")
        .trim()
        .to_owned();
    let mut info = value
        .as_object_mut()
        .unwrap()
        .remove("decryption")
        .and_then(|info| info.as_object().cloned());
    if info.is_none() && !legacy.is_empty() {
        info = Some(Map::new());
    }
    if let Some(info) = &mut info {
        for key in ["strategy", "key", "iv", "input_format", "output_extension"] {
            if let Some(value) = info.get_mut(key) {
                *value = value.as_str().unwrap_or("").trim().into();
            }
        }
        let strategy = info.get("strategy").and_then(Value::as_str).unwrap_or("");
        let strategy = match mornye_core::matching::lowercase(strategy).as_str() {
            ""
            | MOV
            | "ffmpeg_mov_key"
            | "mov_decryption_key"
            | "mp4_decryption_key"
            | "ffmpeg.mp4_decryption_key" => MOV.to_owned(),
            _ => strategy.to_owned(),
        };
        info.insert("strategy".into(), strategy.clone().into());
        if info
            .get("key")
            .and_then(Value::as_str)
            .unwrap_or("")
            .is_empty()
            && !legacy.is_empty()
        {
            info.insert("key".into(), legacy.clone().into());
        }
        if strategy == MOV
            && info
                .get("input_format")
                .and_then(Value::as_str)
                .unwrap_or("")
                .is_empty()
        {
            info.insert("input_format".into(), "mov".into());
        }
        info.retain(|_, value| value != "");
    }
    if info.as_ref().is_some_and(|info| {
        info.get("strategy").and_then(Value::as_str) == Some(MOV)
            && info
                .get("key")
                .and_then(Value::as_str)
                .unwrap_or("")
                .is_empty()
    }) {
        info = None;
    }
    let key = info
        .as_ref()
        .filter(|info| info.get("strategy").and_then(Value::as_str) == Some(MOV))
        .and_then(|info| info.get("key"))
        .and_then(Value::as_str)
        .unwrap_or(&legacy)
        .to_owned();
    let value = value.as_object_mut().unwrap();
    value.remove("decryption_key");
    if !key.is_empty() {
        value.insert("decryption_key".into(), key.into());
    }
    if let Some(info) = info {
        value.insert("decryption".into(), info.into());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_download_mode_is_declared_and_selected_by_settings() {
        let directory = tempfile::tempdir().unwrap();
        let sources = directory.path().join("sources");
        let manager = ExtensionManager::new(
            &sources,
            &directory.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            RuntimeLimits::default(),
        )
        .unwrap();
        let source = sources.join("example.account");
        fs::create_dir(&source).unwrap();
        fs::write(source.join("manifest.json"), json!({"name":"example.account","version":"1",
            "description":"Generic account mode fixture","type":["download_provider"],
            "permissions":{"storage":true,"network":["accounts.example.test"]},
            "signedSession":{"namespace":"example-account","baseUrl":"https://accounts.example.test","appVersion":"1","platform":"extension",
                "endpoints":{"bootstrap":"/bootstrap","challenge":"/challenge","exchange":"/exchange","refresh":"/refresh"}},
            "capabilities":{"accountDownloadMode":{"setting":"accountMode","value":"personal"}}}).to_string()).unwrap();
        fs::write(
            source.join("index.js"),
            "registerExtension({download(){return {success:false}}});",
        )
        .unwrap();
        manager.load_all().unwrap();
        manager.set_enabled("example.account", true).unwrap();
        assert!(!manager.account_download_enabled("example.account").unwrap());
        manager
            .update_settings(
                "example.account",
                serde_json::from_value(json!({"accountMode":"personal"})).unwrap(),
            )
            .unwrap();
        assert!(manager.account_download_enabled("example.account").unwrap());
        // No signed-session service is contacted in personal account mode.
        let lease = Arc::new(
            manager
                .environment
                .download_state()
                .acquire("test-account")
                .unwrap(),
        );
        assert!(
            !manager
                .preflight_download("example.account", lease)
                .unwrap()
        );
        manager
            .update_settings(
                "example.account",
                serde_json::from_value(json!({"accountMode":"community"})).unwrap(),
            )
            .unwrap();
        assert!(!manager.account_download_enabled("example.account").unwrap());
    }

    #[test]
    fn returning_a_borrow_after_uninstall_cannot_recreate_extension_data() {
        let directory = tempfile::tempdir().unwrap();
        let sources = directory.path().join("sources");
        let data = directory.path().join("data");
        let manager = ExtensionManager::new(
            &sources,
            &data,
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            RuntimeLimits::default(),
        )
        .unwrap();
        let source = sources.join("example.pool");
        fs::create_dir(&source).unwrap();
        fs::write(source.join("manifest.json"), json!({"name":"example.pool","version":"1","description":"Generic pool ownership test","type":["download_provider"],"permissions":{"storage":true}}).to_string()).unwrap();
        fs::write(
            source.join("index.js"),
            "registerExtension({download(){return {success:true}}});",
        )
        .unwrap();
        manager.load_all().unwrap();
        manager.set_enabled("example.pool", true).unwrap();
        let mut borrowed = manager
            .borrow_download(manager.get("example.pool").unwrap(), None)
            .unwrap();
        borrowed.healthy = true;
        manager.remove("example.pool").unwrap();
        assert!(!data.join("example.pool").exists());
        drop(borrowed);
        assert!(!data.join("example.pool").exists());
    }
}
