//! Mobile `ExtensionManager` object: install and lifecycle, downloads, post-processing, metadata
//! search, provider calls and priorities, URL handlers, and pending auth.

use crate::cancellation::RequestLease;
use crate::extensions::ExtensionEnvironment;
use mornye_extensions::RuntimeLimits;
use mornye_extensions::backend::Backend as CoreManager;
use mornye_extensions::manager::ManagerError;
use std::path::Path;
use std::sync::Arc;

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum ExtensionManagerError {
    #[error("{0}")]
    Operation(String),
}

impl From<ManagerError> for ExtensionManagerError {
    fn from(error: ManagerError) -> Self {
        Self::Operation(error.to_string())
    }
}

/// Owns installed source, data, and JavaScript workers. Use a background native
/// thread for operations that read packages or run extension code.
#[derive(uniffi::Object)]
pub struct ExtensionManager {
    pub(crate) inner: CoreManager,
}

#[uniffi::export]
impl ExtensionManager {
    #[uniffi::constructor]
    pub fn new(
        source_directory: String,
        data_directory: String,
        master_key: String,
        app_version: String,
        timeout_ms: u64,
    ) -> Result<Self, ExtensionManagerError> {
        Self::with_lyrics_settings(
            source_directory,
            data_directory,
            master_key,
            app_version,
            timeout_ms,
            "[]".into(),
            "{}".into(),
        )
    }

    #[uniffi::constructor]
    pub fn with_lyrics_settings(
        source_directory: String,
        data_directory: String,
        master_key: String,
        app_version: String,
        timeout_ms: u64,
        providers_json: String,
        options_json: String,
    ) -> Result<Self, ExtensionManagerError> {
        let key = zeroize::Zeroizing::new(master_key);
        let limits = RuntimeLimits {
            timeout_ms: if timeout_ms == 0 { 30_000 } else { timeout_ms },
            ..RuntimeLimits::default()
        };
        Ok(Self {
            inner: CoreManager::with_lyrics_settings(
                Path::new(&source_directory),
                Path::new(&data_directory),
                &key,
                &app_version,
                limits,
                &providers_json,
                &options_json,
            )?,
        })
    }

    pub fn environment(&self) -> Arc<ExtensionEnvironment> {
        Arc::new(ExtensionEnvironment {
            inner: self.inner.environment(),
        })
    }

    pub fn install(&self, package_path: String) -> Result<String, ExtensionManagerError> {
        self.inner
            .install(Path::new(&package_path))
            .map_err(Into::into)
    }

    pub fn upgrade(&self, package_path: String) -> Result<String, ExtensionManagerError> {
        self.inner
            .upgrade(Path::new(&package_path))
            .map_err(Into::into)
    }

    pub fn check_upgrade(&self, package_path: String) -> Result<String, ExtensionManagerError> {
        self.inner
            .check_upgrade(Path::new(&package_path))
            .map_err(Into::into)
    }

    pub fn installed(&self) -> Result<String, ExtensionManagerError> {
        self.inner.installed().map_err(Into::into)
    }

    pub fn load_all(&self) -> Result<String, ExtensionManagerError> {
        self.inner.load_all().map_err(Into::into)
    }

    pub fn set_enabled(
        &self,
        extension_id: String,
        enabled: bool,
    ) -> Result<(), ExtensionManagerError> {
        self.inner
            .set_enabled(&extension_id, enabled)
            .map_err(Into::into)
    }

    pub fn initialize(
        &self,
        extension_id: String,
        settings_json: String,
    ) -> Result<(), ExtensionManagerError> {
        let settings = serde_json::from_str(&settings_json).map_err(|error| {
            ExtensionManagerError::Operation(format!("invalid settings: {error}"))
        })?;
        self.inner
            .initialize(&extension_id, settings)
            .map_err(Into::into)
    }

    pub fn cleanup(&self, extension_id: String) -> Result<(), ExtensionManagerError> {
        self.inner.cleanup(&extension_id).map_err(Into::into)
    }

    pub fn update_settings(
        &self,
        extension_id: String,
        settings_json: String,
    ) -> Result<(), ExtensionManagerError> {
        let settings = serde_json::from_str(&settings_json).map_err(|error| {
            ExtensionManagerError::Operation(format!("invalid settings: {error}"))
        })?;
        self.inner
            .update_settings(&extension_id, settings)
            .map_err(Into::into)
    }

    pub fn download_by_strategy(
        &self,
        request_json: String,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .download_by_strategy(&request_json, &|| Ok(()))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn resolve_stream_url(
        &self,
        request_json: String,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .resolve_stream_source(&request_json, &|| Ok(()))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn check_extension_health_json(
        &self,
        extension_id: String,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .check_extension_health_json(&extension_id, &|| Ok(()))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn download(
        &self,
        extension_id: String,
        request_json: String,
        resolution_timeout_ms: u64,
    ) -> Result<String, ExtensionManagerError> {
        let request = serde_json::from_str(&request_json).map_err(|error| {
            ExtensionManagerError::Operation(format!("invalid download request: {error}"))
        })?;
        self.inner
            .download(&extension_id, request, resolution_timeout_ms)
            .map_err(Into::into)
    }

    pub fn release_memory(&self, under_pressure: bool) -> Result<(), ExtensionManagerError> {
        self.inner
            .release_memory(under_pressure)
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn post_process(
        &self,
        extension_id: String,
        input_json: String,
        metadata_json: String,
        hook_id: String,
        timeout_ms: u64,
    ) -> Result<String, ExtensionManagerError> {
        let input = serde_json::from_str(&input_json).map_err(|error| {
            ExtensionManagerError::Operation(format!("invalid post-process input: {error}"))
        })?;
        let metadata = serde_json::from_str(&metadata_json).map_err(|error| {
            ExtensionManagerError::Operation(format!("invalid post-process metadata: {error}"))
        })?;
        self.inner
            .post_process(&extension_id, input, metadata, &hook_id, timeout_ms)
            .map_err(Into::into)
    }

    pub fn run_post_processing(
        &self,
        input_json: String,
        metadata_json: String,
        timeout_ms: u64,
    ) -> Result<String, ExtensionManagerError> {
        // Preserve the permissive Go JSON wrapper used by PlatformBridge.
        self.inner
            .run_post_processing(
                serde_json::from_str(&input_json).unwrap_or_default(),
                serde_json::from_str(&metadata_json).unwrap_or_default(),
                timeout_ms,
            )
            .map_err(Into::into)
    }

    pub fn search_metadata_provider(
        &self,
        extension_id: String,
        query: String,
        limit: i64,
        timeout_ms: u64,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .search_metadata_provider(&extension_id, &query, limit as isize, timeout_ms)
            .map_err(Into::into)
    }

    pub fn search_metadata_providers(
        &self,
        query: String,
        limit: i64,
        include_extensions: bool,
        item_id: String,
        timeout_ms: u64,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .search_metadata_providers(
                &query,
                limit as isize,
                include_extensions,
                &item_id,
                timeout_ms,
            )
            .map_err(Into::into)
    }

    pub fn invoke_action(
        &self,
        extension_id: String,
        action: String,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .invoke_action(&extension_id, &action)
            .map_err(Into::into)
    }

    pub fn call(
        &self,
        extension_id: String,
        method: String,
        arguments_json: String,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .call(
                &extension_id,
                &method,
                &arguments_json,
                lease.map(|lease| Arc::clone(&lease.inner)),
                timeout_ms,
            )
            .map_err(Into::into)
    }

    pub fn provider_call(
        &self,
        extension_id: String,
        method: String,
        arguments_json: String,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .provider_call(
                &extension_id,
                &method,
                &arguments_json,
                lease.map(|lease| Arc::clone(&lease.inner)),
                timeout_ms,
            )
            .map_err(Into::into)
    }

    pub fn set_provider_priority(
        &self,
        kind: String,
        ids: Vec<String>,
    ) -> Result<(), ExtensionManagerError> {
        self.inner
            .set_provider_priority(&kind, ids)
            .map_err(Into::into)
    }

    pub fn set_fallback_providers(
        &self,
        ids: Option<Vec<String>>,
    ) -> Result<(), ExtensionManagerError> {
        self.inner.set_fallback_providers(ids).map_err(Into::into)
    }

    pub fn provider_priorities(&self) -> Result<String, ExtensionManagerError> {
        self.inner.provider_priorities().map_err(Into::into)
    }

    pub fn find_url_handler(&self, url: String) -> Result<Option<String>, ExtensionManagerError> {
        self.inner.find_url_handler(&url).map_err(Into::into)
    }

    pub fn get_extension_pending_auth_json(
        &self,
        extension_id: String,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .get_extension_pending_auth_json(&extension_id)
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn remove(&self, extension_id: String) -> Result<(), ExtensionManagerError> {
        self.inner.remove(&extension_id).map_err(Into::into)
    }

    pub fn shutdown(&self) {
        self.inner.shutdown();
    }
}
