#[cfg(feature = "uniffi")]
use crate::cancellation::RequestLease;
use mornye_extensions::ExtensionError;
use mornye_extensions::environment::{EnvironmentError, ExtensionEnvironment as CoreEnvironment};
#[cfg(feature = "uniffi")]
use mornye_extensions::{ExtensionRuntime, RuntimeLimits};
use std::path::Path;
use std::sync::{Arc, Mutex};

/// Keeps operation directories accessible until native finalization finishes.
/// Explicit close and object destruction both release only these grants.
#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct DownloadDirectoryScope {
    grants: Mutex<Option<Vec<mornye_extensions::files::TemporaryGrant>>>,
}

#[cfg_attr(feature = "uniffi", uniffi::export)]
impl DownloadDirectoryScope {
    pub fn release(&self) {
        self.grants
            .lock()
            .expect("download directory scope lock")
            .take();
    }
}

#[derive(Debug, thiserror::Error)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Error))]
#[cfg_attr(feature = "uniffi", uniffi(flat_error))]
pub enum JsExtensionError {
    #[error("extension runtime closed")]
    Closed,
    #[error("extension runtime busy")]
    Busy,
    #[error("execution timeout exceeded")]
    Timeout,
    #[error("{0}")]
    Cancelled(String),
    #[error("extension did not call registerExtension()")]
    NotRegistered,
    #[error("extension function not found: {0}")]
    MissingFunction(String),
    #[error("invalid extension input: {0}")]
    InvalidInput(String),
    #[error("{0}")]
    Script(String),
    #[error("extension environment closed")]
    EnvironmentClosed,
    #[error("{0}")]
    Storage(String),
    #[error("{0}")]
    Manifest(String),
    #[error("{0}")]
    Gate(String),
    #[error("{0}")]
    Network(String),
    #[error("{0}")]
    Auth(String),
    #[error("{0}")]
    Index(String),
}

impl From<EnvironmentError> for JsExtensionError {
    fn from(error: EnvironmentError) -> Self {
        match error {
            EnvironmentError::Closed => Self::EnvironmentClosed,
            EnvironmentError::Runtime(error) => error.into(),
            EnvironmentError::Storage(error) => Self::Storage(error.to_string()),
            EnvironmentError::Manifest(error) => Self::Manifest(error.to_string()),
            EnvironmentError::Gate(message) => Self::Gate(message),
            EnvironmentError::Network(error) => Self::Network(error.to_string()),
            EnvironmentError::Auth(error) => Self::Auth(error),
            EnvironmentError::Index(error) => Self::Index(error),
        }
    }
}

impl From<ExtensionError> for JsExtensionError {
    fn from(error: ExtensionError) -> Self {
        match error {
            ExtensionError::Closed => Self::Closed,
            ExtensionError::Busy => Self::Busy,
            ExtensionError::Timeout => Self::Timeout,
            ExtensionError::Cancelled(error) => Self::Cancelled(error.to_string()),
            ExtensionError::NotRegistered => Self::NotRegistered,
            ExtensionError::MissingFunction(method) => Self::MissingFunction(method),
            ExtensionError::InvalidInput(message) => Self::InvalidInput(message),
            ExtensionError::Script(message) => Self::Script(message),
        }
    }
}

/// Standalone runtime for a single extension script. Used by instrumentation
/// tests; the app routes through `ExtensionManager`. Calls must run off the UI
/// thread.
#[cfg(feature = "uniffi")]
#[derive(uniffi::Object)]
pub struct JsExtension {
    inner: Arc<ExtensionRuntime>,
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
impl JsExtension {
    pub fn download_state(&self) -> Arc<crate::progress::DownloadState> {
        Arc::new(crate::progress::DownloadState {
            inner: self.inner.download_state(),
        })
    }

    #[uniffi::constructor]
    pub fn new(
        source: String,
        settings_json: String,
        timeout_ms: u64,
    ) -> Result<Self, JsExtensionError> {
        let limits = RuntimeLimits {
            timeout_ms: if timeout_ms == 0 { 30_000 } else { timeout_ms },
            ..RuntimeLimits::default()
        };
        Ok(Self {
            inner: Arc::new(ExtensionRuntime::load(&source, &settings_json, limits)?),
        })
    }

    pub fn call(
        &self,
        method: String,
        arguments_json: String,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
    ) -> Result<String, JsExtensionError> {
        let lease = lease.map(|lease| Arc::clone(&lease.inner));
        self.inner
            .call(&method, &arguments_json, lease, timeout_ms)
            .map_err(Into::into)
    }

    pub fn shutdown(&self) {
        self.inner.shutdown();
    }
}

#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct ExtensionEnvironment {
    pub(crate) inner: Arc<CoreEnvironment>,
}

#[cfg_attr(feature = "uniffi", uniffi::export)]
impl ExtensionEnvironment {
    pub fn log_buffer(&self) -> Arc<crate::logging::LogBuffer> {
        Arc::new(crate::logging::LogBuffer {
            inner: self.inner.log_buffer(),
        })
    }

    pub fn ffmpeg_commands(&self) -> Arc<crate::ffmpeg::FfmpegCommands> {
        Arc::new(crate::ffmpeg::FfmpegCommands {
            inner: self.inner.ffmpeg_commands(),
        })
    }

    pub fn download_state(&self) -> Arc<crate::progress::DownloadState> {
        Arc::new(crate::progress::DownloadState {
            inner: self.inner.download_state(),
        })
    }

    #[cfg_attr(feature = "uniffi", uniffi::constructor)]
    pub fn new(
        data_directory: String,
        master_key: String,
        app_version: String,
    ) -> Result<Self, JsExtensionError> {
        let master_key = zeroize::Zeroizing::new(master_key);
        Ok(Self {
            inner: Arc::new(CoreEnvironment::new(
                Path::new(&data_directory),
                &master_key,
                &app_version,
            )?),
        })
    }

    pub fn settings(&self, extension_id: String) -> Result<String, JsExtensionError> {
        Ok(serde_json::Value::Object(self.inner.settings(&extension_id)?).to_string())
    }

    pub fn set_allow_private_network(&self, allow: bool) -> Result<(), JsExtensionError> {
        self.inner
            .set_allow_private_network(allow)
            .map_err(Into::into)
    }

    pub fn set_network_compatibility_options(
        &self,
        allow_http: bool,
        insecure_tls: bool,
    ) -> Result<(), JsExtensionError> {
        // Accepted for binding compatibility and ignored: TLS verification is never disabled.
        let _ = insecure_tls;
        self.inner
            .set_network_compatibility_options(allow_http)
            .map_err(Into::into)
    }

    pub fn cleanup_connections(&self) -> Result<(), JsExtensionError> {
        self.inner.cleanup_connections().map_err(Into::into)
    }

    pub fn set_allowed_download_directories(
        &self,
        directories: Vec<String>,
    ) -> Result<(), JsExtensionError> {
        self.inner
            .set_allowed_download_directories(
                &directories
                    .into_iter()
                    .map(std::path::PathBuf::from)
                    .collect::<Vec<_>>(),
            )
            .map_err(Into::into)
    }

    pub fn grant_download_directories(
        &self,
        directories: Vec<String>,
    ) -> Result<Arc<DownloadDirectoryScope>, JsExtensionError> {
        let grants = directories
            .iter()
            .map(|path| {
                self.inner
                    .grant_temporary_download_directory(Path::new(path))
            })
            .collect::<Result<Vec<_>, _>>()
            .map_err(JsExtensionError::Storage)?;
        Ok(Arc::new(DownloadDirectoryScope {
            grants: Mutex::new(Some(grants)),
        }))
    }

    pub fn set_runtime_state(&self, raw: String) -> Result<(), JsExtensionError> {
        self.inner.set_runtime_state(&raw).map_err(Into::into)
    }

    pub fn set_session_grant(
        &self,
        extension_id: String,
        grant: String,
    ) -> Result<(), JsExtensionError> {
        let grant = zeroize::Zeroizing::new(grant);
        self.inner
            .set_session_grant(&extension_id, &grant)
            .map_err(Into::into)
    }

    pub fn resolve_callback_state(&self, state: String) -> Result<String, JsExtensionError> {
        self.inner
            .resolve_callback_state(&state, false)
            .map_err(Into::into)
    }

    pub fn consume_callback_state(&self, state: String) -> Result<String, JsExtensionError> {
        self.inner
            .resolve_callback_state(&state, true)
            .map_err(Into::into)
    }

    pub fn set_auth_code(
        &self,
        extension_id: String,
        code: String,
    ) -> Result<(), JsExtensionError> {
        let code = zeroize::Zeroizing::new(code);
        self.inner
            .set_auth_code(&extension_id, &code)
            .map_err(Into::into)
    }

    pub fn shutdown(&self) {
        self.inner.shutdown();
    }
}
