use super::*;

impl ExtensionManager {
    fn prepare_with_lease(
        &self,
        entry: &Installed,
        lease: Option<Arc<RequestLease>>,
        mode: LoadMode,
    ) -> Result<(Arc<ExtensionRuntime>, Arc<str>), ManagerError> {
        let source: Arc<str> = read_source(&entry.source.join("index.js"), 8 * 1024 * 1024)
            .map_err(|e| cause("failed to read index.js", e))?
            .into();
        let compiled = entry
            .compiled
            .lock()
            .expect("extension compile lock")
            .clone();
        let runtime = self
            .environment
            .load_registered_with_lease(
                &entry.manifest_json,
                &source,
                self.limits.clone(),
                mode,
                lease,
                compiled,
            )
            .map_err(|error| match error {
                crate::environment::EnvironmentError::Runtime(ExtensionError::Script(message)) => {
                    cause(
                        if message.starts_with("SyntaxError:") {
                            "failed to compile extension code"
                        } else {
                            "failed to execute extension code"
                        },
                        message,
                    )
                }
                other => self
                    .check()
                    .err()
                    .unwrap_or_else(|| error_from_environment(other)),
            })?;
        // Disabled packages are validated without keeping their compile.
        if mode == LoadMode::Register || entry.status.read().expect("extension status lock").enabled
        {
            *entry.compiled.lock().expect("extension compile lock") =
                Some(Arc::clone(&runtime.compiled_source));
        }
        // Keep the same source allocation as the VM/isolated-worker cache.
        // The loader copied the input into its owned CompiledSource.
        let source = runtime.shared_source();
        Ok((runtime, source))
    }

    pub(super) fn validate(&self, entry: &Installed) -> Result<(), ManagerError> {
        let (runtime, _) = self.prepare_with_lease(entry, None, LoadMode::Validate)?;
        // The worker already ran cleanup; join it before publishing the package.
        runtime.shutdown();
        Ok(())
    }

    pub(super) fn lifecycle(
        &self,
        runtime: &ExtensionRuntime,
        method: &str,
        arguments: &str,
    ) -> Result<(), ManagerError> {
        self.lifecycle_with_lease(runtime, method, arguments, None)
    }

    fn lifecycle_with_lease(
        &self,
        runtime: &ExtensionRuntime,
        method: &str,
        arguments: &str,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<(), ManagerError> {
        lifecycle_result(
            method,
            runtime.managed_call_with_lease(
                method,
                arguments,
                false,
                self.limits.timeout_ms,
                lease,
            ),
        )
        .map_err(|e| error(e.to_string()))
    }

    pub(super) fn teardown_runtime(&self, runtime: &ExtensionRuntime) {
        if let Err(error) = self.lifecycle(runtime, "cleanup", "[]") {
            let _ = self
                .environment
                .log_buffer()
                .backend(&format!("[Extension] Cleanup error: {error}"));
        }
        runtime.shutdown();
    }

    pub(super) fn teardown(&self, entry: &Installed, engine: &mut Engine) {
        let mut pool = entry.downloads.lock().expect("download pool lock");
        self.invalidate_download_pool(&mut pool);
        for runtime in pool.active.drain(..) {
            // Join every native operation before source/data can be removed.
            runtime.shutdown();
        }
        drop(pool);
        if let Some(runtime) = engine.runtime.take() {
            self.teardown_runtime(&runtime);
        }
        engine.initialized = false;
        engine.source = None;
        entry
            .compiled
            .lock()
            .expect("extension compile lock")
            .take();
    }

    pub(super) fn failed(&self, entry: &Installed, failure: &ManagerError) {
        let mut status = entry.status.write().expect("extension status lock");
        status.enabled = false;
        status.error = failure.to_string();
    }

    pub(super) fn ready(
        &self,
        entry: &Installed,
        engine: &mut Engine,
        settings: bool,
    ) -> Result<Arc<ExtensionRuntime>, ManagerError> {
        self.ready_with_lease(entry, engine, settings, None)
    }

    pub(super) fn ready_with_lease(
        &self,
        entry: &Installed,
        engine: &mut Engine,
        settings: bool,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<Arc<ExtensionRuntime>, ManagerError> {
        // Go rechecks gates even when a VM already exists. A version change
        // disables an incompatible provider on its next managed call.
        let version = self
            .environment
            .get_app_version()
            .map_err(error_from_environment)?;
        validate_gates(&entry.manifest, &version, &SUPPORTED_RUNTIME_FEATURES)
            .map_err(error)
            .inspect_err(|failure| self.failed(entry, failure))?;
        if engine
            .runtime
            .as_ref()
            .is_some_and(|runtime| runtime.is_closed())
        {
            self.invalidate_download_pool(&mut entry.downloads.lock().expect("download pool lock"));
            engine.runtime = None;
            engine.initialized = false;
            engine.source = None;
        }
        if engine.runtime.is_none() {
            let (runtime, source) =
                self.prepare_with_lease(entry, lease.clone(), LoadMode::Register)?;
            engine.runtime = Some(runtime);
            engine.source = Some(source);
        }
        let runtime = Arc::clone(engine.runtime.as_ref().unwrap());
        if settings && !engine.initialized {
            let mut values = self
                .environment
                .settings(&entry.manifest.name)
                .map_err(error_from_environment)?;
            values.retain(|key, _| !key.starts_with('_'));
            if !values.is_empty()
                && let Err(error) = self.lifecycle_with_lease(
                    &runtime,
                    "initialize",
                    &json!([values]).to_string(),
                    lease.clone(),
                )
            {
                if lease
                    .as_ref()
                    .is_some_and(|lease| lease.check_active().is_err())
                {
                    runtime.shutdown();
                    engine.runtime = None;
                    engine.initialized = false;
                    engine.source = None;
                } else {
                    self.teardown(entry, engine);
                }
                return Err(error);
            }
            engine.initialized = true;
        }
        entry
            .status
            .write()
            .expect("extension status lock")
            .error
            .clear();
        Ok(runtime)
    }
}
