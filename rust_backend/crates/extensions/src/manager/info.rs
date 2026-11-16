use super::*;

impl ExtensionManager {
    pub fn load_all(&self) -> Result<String, ManagerError> {
        let _metadata = MetadataChange(&self.metadata_revision);
        let _mutation = self.mutation.lock().expect("extension mutation lock");
        self.check()?;
        let mut paths: Vec<_> = fs::read_dir(&self.sources)
            .map_err(|e| cause("failed to read extensions directory", e))?
            .collect::<Result<_, _>>()
            .map_err(|e| cause("failed to read extensions directory", e))?;
        paths.sort_by_key(|entry| entry.file_name());
        let mut loaded = Vec::new();
        let mut errors = Vec::new();
        for path in paths {
            self.check()?;
            let result = if path.file_type().map_err(|e| error(e.to_string()))?.is_dir() {
                if !path.path().join("manifest.json").exists() {
                    continue;
                }
                self.load_directory(&path.path())
            } else if is_package_path(&path.path()) {
                // Reuse the mutation already held instead of entering install().
                ExtensionPackage::open(&path.path())
                    .map_err(|e| error(e.to_string()))
                    .and_then(|package| self.install_or_upgrade(package))
                    .and_then(|value| {
                        serde_json::from_str::<Value>(&value)
                            .map(|value| value["id"].as_str().unwrap().to_owned())
                            .map_err(|e| error(e.to_string()))
                    })
            } else {
                continue;
            };
            match result {
                Ok(id) => loaded.push(id),
                Err(error) => {
                    errors.push(format!("{}: {error}", path.file_name().to_string_lossy()))
                }
            }
        }
        Ok(json!({"loaded":if loaded.is_empty() { Value::Null } else { json!(loaded) },"errors":errors}).to_string())
    }

    fn load_directory(&self, path: &Path) -> Result<String, ManagerError> {
        let manifest_json = read_source(&path.join("manifest.json"), 1024 * 1024)
            .map_err(|e| cause("failed to read manifest.json", e))?;
        let manifest = ExtensionManifest::parse(&manifest_json)
            .map_err(|e| cause("invalid extension manifest", e))?;
        if !path.join("index.js").exists() {
            return Err(error("extension is missing index.js file"));
        }
        if self
            .entries
            .lock()
            .expect("extension manager lock")
            .contains_key(&manifest.name)
        {
            return Ok(manifest.name);
        }
        if path != self.sources.join(&manifest.name) {
            return Err(error(format!(
                "extension directory name must match manifest name {:?}",
                manifest.name
            )));
        }
        // A package is still installed when its private settings cannot be
        // decrypted. Keep it visible for recovery without running its code or
        // replacing the unreadable data with defaults.
        let settings = self.environment.settings(&manifest.name);
        let enabled = settings
            .as_ref()
            .is_ok_and(|values| values.get("_enabled") == Some(&Value::Bool(true)));
        let entry = Arc::new(Installed {
            manifest,
            manifest_json,
            source: path.to_owned(),
            status: RwLock::new(Status {
                enabled,
                error: String::new(),
            }),
            compiled: Mutex::default(),
            engine: EngineLock::default(),
            downloads: Mutex::default(),
        });
        match settings {
            Err(error) => self.failed(&entry, &error_from_environment(error)),
            Ok(_) => {
                if let Err(error) = self.validate(&entry) {
                    self.failed(&entry, &error);
                }
            }
        }
        self.check()?;
        let id = entry.manifest.name.clone();
        self.entries
            .lock()
            .expect("extension manager lock")
            .insert(id.clone(), entry);
        Ok(id)
    }

    pub fn installed(&self) -> Result<String, ManagerError> {
        self.check()?;
        let entries: Vec<_> = self
            .entries
            .lock()
            .expect("extension manager lock")
            .values()
            .cloned()
            .collect();
        Ok(Value::Array(entries.iter().map(|entry| information(entry)).collect()).to_string())
    }

    pub fn installed_versions(&self) -> Result<BTreeMap<String, String>, ManagerError> {
        self.check()?;
        Ok(self
            .entries
            .lock()
            .expect("extension manager lock")
            .values()
            .map(|entry| (entry.manifest.name.clone(), entry.manifest.version.clone()))
            .collect())
    }

    pub fn provider_ids(&self, kind: &str) -> Result<Vec<String>, ManagerError> {
        self.check()?;
        Ok(self
            .entries
            .lock()
            .expect("extension manager lock")
            .values()
            .filter(|entry| {
                let status = entry.status.read().expect("extension status lock");
                entry.manifest.has_type(kind) && status.enabled && status.error.is_empty()
            })
            .map(|entry| entry.manifest.name.clone())
            .collect())
    }
}

pub(super) fn summary(entry: &Installed) -> String {
    json!({"id":entry.manifest.name,"name":entry.manifest.name,"display_name":entry.manifest.display_name,"version":entry.manifest.version,"enabled":entry.status.read().expect("extension status lock").enabled}).to_string()
}
fn asset(root: &Path, name: &str) -> Option<String> {
    if name.is_empty() || name.contains('\\') {
        return None;
    }
    let mut parts = Vec::new();
    for component in Path::new(name).components() {
        match component {
            Component::Normal(part) => parts.push(part),
            Component::CurDir => {}
            Component::ParentDir => {
                parts.pop()?;
            }
            _ => return None,
        }
    }
    let mut path = root.to_owned();
    for part in parts {
        path.push(part);
        if fs::symlink_metadata(&path).ok()?.file_type().is_symlink() {
            return None;
        }
    }
    path.is_file().then(|| path.to_string_lossy().into_owned())
}
fn information(entry: &Installed) -> Value {
    let manifest = &entry.manifest;
    let status = entry.status.read().expect("extension status lock");
    let mut permissions: Vec<String> = manifest
        .permissions
        .network
        .clone()
        .unwrap_or_default()
        .iter()
        .map(|domain| format!("network:{domain}"))
        .collect();
    if manifest.permissions.storage {
        permissions.push("storage:enabled".into());
    }
    if manifest.permissions.file {
        permissions.push("file:enabled".into());
    }
    if manifest.permissions.allow_http {
        permissions.push("network:http".into());
    }
    if manifest.has_capability("rawFfmpeg") {
        permissions.push("ffmpeg:raw".into());
    }
    let mut value = json!({"id":manifest.name,"name":manifest.name,"display_name":manifest.display_name,"version":manifest.version,"description":manifest.description,"types":manifest.types,"enabled":status.enabled,"status":if !status.error.is_empty() {"error"} else if status.enabled {"loaded"} else {"disabled"},"permissions":permissions,"has_metadata_provider":manifest.has_type("metadata_provider"),"has_download_provider":manifest.has_type("download_provider"),"has_lyrics_provider":manifest.has_type("lyrics_provider"),"skip_metadata_enrichment":manifest.skip_metadata_enrichment,"skip_lyrics":manifest.skip_lyrics,"stop_provider_fallback":manifest.stops_provider_fallback()});
    if !status.error.is_empty() {
        value["error_message"] = status.error.clone().into();
    }
    if let Some(icon) =
        asset(&entry.source, &manifest.icon).or_else(|| asset(&entry.source, "icon.png"))
    {
        value["icon_path"] = icon.into();
    }
    let serialized = serde_json::to_value(manifest).expect("manifest serialization");
    for (source, target) in [
        ("homepage", "homepage"),
        ("settings", "settings"),
        ("qualityOptions", "quality_options"),
        ("searchBehavior", "search_behavior"),
        ("trackMatching", "track_matching"),
        ("postProcessing", "post_processing"),
        ("serviceHealth", "service_health"),
        ("capabilities", "capabilities"),
    ] {
        if let Some(field) = serialized.get(source) {
            value[target] = field.clone();
        }
    }
    value
}
