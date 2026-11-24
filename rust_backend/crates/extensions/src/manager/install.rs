use super::info::summary;
use super::*;

impl ExtensionManager {
    pub fn install(&self, path: &Path) -> Result<String, ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        self.check()?;
        let package = ExtensionPackage::open(path).map_err(|e| error(e.to_string()))?;
        self.install_or_upgrade(package)
    }

    pub(super) fn install_or_upgrade(
        &self,
        package: ExtensionPackage,
    ) -> Result<String, ManagerError> {
        let existing = self
            .entries
            .lock()
            .expect("extension manager lock")
            .get(&package.manifest.name)
            .cloned();
        if let Some(existing) = existing {
            match compare_versions(&package.manifest.version, &existing.manifest.version) {
                Comparison::Greater => return self.upgrade_package(package, existing),
                Comparison::Equal => {
                    return Err(error(format!(
                        "extension '{}' v{} is already installed",
                        existing.manifest.display_name, existing.manifest.version
                    )));
                }
                Comparison::Less => {
                    return Err(error(format!(
                        "cannot downgrade '{}' from v{} to v{}",
                        existing.manifest.display_name,
                        existing.manifest.version,
                        package.manifest.version
                    )));
                }
            }
        }
        self.install_package(package)
    }

    fn stage(
        &self,
        package: &mut ExtensionPackage,
        kind: &str,
    ) -> Result<tempfile::TempDir, ManagerError> {
        let stage = tempfile::Builder::new()
            .prefix(&format!(".{}-{kind}-", package.manifest.name))
            .tempdir_in(&self.sources)
            .map_err(|e| cause("failed to create extension staging directory", e))?;
        package
            .extract(stage.path(), &|| self.check().map_err(|e| e.to_string()))
            .map_err(|e| error(e.to_string()))?;
        Ok(stage)
    }

    fn candidate(&self, package: &ExtensionPackage, path: &Path, enabled: bool) -> Arc<Installed> {
        Arc::new(Installed {
            manifest: package.manifest.clone(),
            manifest_json: package.manifest_json.clone(),
            source: path.to_owned(),
            status: RwLock::new(Status {
                enabled,
                error: String::new(),
            }),
            compiled: Mutex::default(),
            engine: EngineLock::default(),
            downloads: Mutex::default(),
        })
    }

    fn install_package(&self, mut package: ExtensionPackage) -> Result<String, ManagerError> {
        let target = self.sources.join(&package.manifest.name);
        if fs::symlink_metadata(&target).is_ok() {
            return Err(error(format!(
                "extension directory already exists for {:?}",
                package.manifest.name
            )));
        }
        let stage = self.stage(&mut package, "install")?;
        let mut candidate = self.candidate(&package, stage.path(), true);
        if let Err(error) = self.validate(&candidate) {
            self.failed(&candidate, &error);
        }
        self.check()?;
        fs::rename(stage.path(), &target).map_err(|e| cause("failed to activate extension", e))?;
        Arc::get_mut(&mut candidate)
            .expect("unpublished extension")
            .source = target;
        let enabled = candidate
            .status
            .read()
            .expect("extension status lock")
            .enabled;
        if let Err(error) =
            self.environment
                .set_setting(&candidate.manifest.name, "_enabled", enabled.into())
        {
            self.failed(&candidate, &cause("failed to persist enabled state", error));
        }
        self.entries
            .lock()
            .expect("extension manager lock")
            .insert(candidate.manifest.name.clone(), Arc::clone(&candidate));
        Ok(summary(&candidate))
    }

    pub fn remove(&self, id: &str) -> Result<(), ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        let entry = self.get(id)?;
        if entry.source != self.sources.join(id) {
            return Err(error(
                "refusing to remove extension outside the managed source directory",
            ));
        }
        self.unload_locked(id)?;
        // Attempt both roots even if one fails. Keep a disabled registry entry
        // on partial removal so the native caller can retry the same operation.
        let source =
            remove_directory(&entry.source).map_err(|e| cause("failed to remove source dir", e));
        let data = self
            .environment
            .remove_data(id)
            .map_err(error_from_environment);
        let failures: Vec<_> = [source, data].into_iter().filter_map(Result::err).collect();
        if failures.is_empty() {
            Ok(())
        } else {
            let failure = error(
                failures
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join("; "),
            );
            self.failed(&entry, &failure);
            self.entries
                .lock()
                .expect("extension manager lock")
                .insert(id.to_owned(), entry);
            Err(failure)
        }
    }

    pub fn upgrade(&self, path: &Path) -> Result<String, ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        self.check()?;
        let package = ExtensionPackage::open(path).map_err(|e| error(e.to_string()))?;
        let existing = self.get(&package.manifest.name).map_err(|_| {
            error(format!(
                "extension '{}' is not installed; use install instead of upgrade",
                package.manifest.display_name
            ))
        })?;
        self.upgrade_package(package, existing)
    }

    fn upgrade_package(
        &self,
        mut package: ExtensionPackage,
        existing: Arc<Installed>,
    ) -> Result<String, ManagerError> {
        match compare_versions(&package.manifest.version, &existing.manifest.version) {
            Comparison::Less => {
                return Err(error(format!(
                    "cannot downgrade extension: current version: {}, new version: {}",
                    existing.manifest.version, package.manifest.version
                )));
            }
            Comparison::Equal => {
                return Err(error(format!(
                    "extension is already at version {}",
                    existing.manifest.version
                )));
            }
            Comparison::Greater => {}
        }
        let target = self.sources.join(&existing.manifest.name);
        let stage = self.stage(&mut package, "upgrade")?;
        let enabled = existing
            .status
            .read()
            .expect("extension status lock")
            .enabled;
        let mut candidate = self.candidate(&package, stage.path(), enabled);
        let valid = if enabled {
            self.ready(
                &candidate,
                &mut candidate.engine.lock().expect("extension engine lock"),
                true,
            )
            .map(|_| ())
        } else {
            self.validate(&candidate)
        };
        if let Err(error) = valid {
            return Err(cause("upgraded extension failed validation", error));
        }
        let backup = (|| {
            self.check()?;
            let backup = tempfile::Builder::new()
                .prefix(&format!(".{}-backup-", existing.manifest.name))
                .tempdir_in(&self.sources)
                .map_err(|e| cause("failed to prepare upgrade backup", e))?;
            fs::remove_dir(backup.path())
                .map_err(|e| cause("failed to prepare upgrade backup", e))?;
            Ok(backup)
        })()
        .inspect_err(|_: &ManagerError| {
            self.teardown(
                &candidate,
                &mut candidate.engine.lock().expect("extension engine lock"),
            );
        })?;
        if let Err(error) = fs::rename(&target, backup.path()) {
            self.teardown(
                &candidate,
                &mut candidate.engine.lock().expect("extension engine lock"),
            );
            return Err(cause("failed to preserve current extension", error));
        }
        if let Err(error) = fs::rename(stage.path(), &target) {
            let restored = fs::rename(backup.path(), &target);
            self.teardown(
                &candidate,
                &mut candidate.engine.lock().expect("extension engine lock"),
            );
            if let Err(rollback) = restored {
                let path = backup.keep();
                return Err(error_from_rollback(error, rollback, &path));
            }
            return Err(cause("failed to activate upgraded extension", error));
        }
        Arc::get_mut(&mut candidate)
            .expect("unpublished extension")
            .source = target;
        existing
            .status
            .write()
            .expect("extension status lock")
            .enabled = false;
        self.teardown(
            &existing,
            &mut existing.engine.lock().expect("extension engine lock"),
        );
        self.entries
            .lock()
            .expect("extension manager lock")
            .insert(candidate.manifest.name.clone(), Arc::clone(&candidate));
        Ok(summary(&candidate))
    }

    pub fn check_upgrade(&self, path: &Path) -> Result<String, ManagerError> {
        self.check()?;
        let package = ExtensionPackage::open(path).map_err(|e| {
            if e.0.starts_with("cannot open extension file:") {
                error("cannot open extension file")
            } else {
                error(e.to_string())
            }
        })?;
        let entries = self.entries.lock().expect("extension manager lock");
        let existing = entries.get(&package.manifest.name);
        Ok(json!({"extension_id":package.manifest.name,"current_version":existing.map_or("", |entry| entry.manifest.version.as_str()),"new_version":package.manifest.version,"is_installed":existing.is_some(),"can_upgrade":existing.is_some_and(|entry| compare_versions(&package.manifest.version, &entry.manifest.version)==Comparison::Greater)}).to_string())
    }
}

fn error_from_rollback(
    error: std::io::Error,
    rollback: std::io::Error,
    path: &Path,
) -> ManagerError {
    cause(
        "failed to activate upgraded extension",
        format!(
            "{error}; restore failed: {rollback}; previous source preserved at {}",
            path.display()
        ),
    )
}
fn remove_directory(path: &Path) -> std::io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}
