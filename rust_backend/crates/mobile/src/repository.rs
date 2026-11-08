use crate::manager::ExtensionManager;
use mornye_extensions::repository::{ExtensionRepository as CoreRepository, RepositoryError};
use std::path::Path;
use std::sync::Arc;

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum ExtensionRepositoryError {
    #[error("{0}")]
    Operation(String),
}

impl From<RepositoryError> for ExtensionRepositoryError {
    fn from(error: RepositoryError) -> Self {
        Self::Operation(error.to_string())
    }
}

/// Retains the manager for current installed versions and shares its network
/// policy. Registry and package IO must run on a native background thread.
#[derive(uniffi::Object)]
pub struct ExtensionRepository {
    inner: CoreRepository,
    manager: Arc<ExtensionManager>,
}

#[uniffi::export]
impl ExtensionRepository {
    #[uniffi::constructor]
    pub fn new(
        manager: Arc<ExtensionManager>,
        cache_directory: String,
    ) -> Result<Self, ExtensionRepositoryError> {
        let inner = manager
            .inner
            .environment()
            .repository(Path::new(&cache_directory))?;
        Ok(Self { inner, manager })
    }

    /// Replaces the ordered registry list; an invalid URL changes nothing.
    pub fn set_registry_urls(
        &self,
        registry_urls: Vec<String>,
    ) -> Result<(), ExtensionRepositoryError> {
        self.inner
            .set_registry_urls(&registry_urls)
            .map_err(Into::into)
    }

    /// Resolves user input to a registry URL without changing any state.
    pub fn resolve_registry_url(
        &self,
        registry_url: String,
    ) -> Result<String, ExtensionRepositoryError> {
        self.inner
            .resolve_registry_url(&registry_url)
            .map_err(Into::into)
    }

    /// The catalog JSON of every configured registry.
    pub fn catalog(&self, force_refresh: bool) -> Result<String, ExtensionRepositoryError> {
        let installed = self
            .manager
            .inner
            .installed_versions()
            .map_err(|e| ExtensionRepositoryError::Operation(e.to_string()))?;
        self.inner
            .catalog(force_refresh, &installed)
            .map_err(Into::into)
    }

    /// An empty `registry_url` downloads from the first registry listing the id.
    pub fn download(
        &self,
        extension_id: String,
        destination_directory: String,
        registry_url: String,
    ) -> Result<String, ExtensionRepositoryError> {
        self.inner
            .download(
                &extension_id,
                Path::new(&destination_directory),
                &registry_url,
            )
            .map(|path| path.to_string_lossy().into_owned())
            .map_err(Into::into)
    }

    pub fn shutdown(&self) {
        self.inner.shutdown();
    }
}
