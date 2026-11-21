use mornye_core::cancellation as core;
use std::sync::Arc;

#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum CancellationDomain {
    Download,
    ExtensionRequest,
}

#[derive(Debug, thiserror::Error)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Error))]
#[cfg_attr(feature = "uniffi", uniffi(flat_error))]
pub enum CancellationError {
    #[error("download cancelled")]
    DownloadCancelled,
    #[error("extension request cancelled")]
    ExtensionRequestCancelled,
    #[error("cancellation registry closed")]
    RegistryClosed,
    #[error("request lease released")]
    LeaseReleased,
}

impl From<core::CancellationError> for CancellationError {
    fn from(error: core::CancellationError) -> Self {
        match error {
            core::CancellationError::DownloadCancelled => Self::DownloadCancelled,
            core::CancellationError::ExtensionRequestCancelled => Self::ExtensionRequestCancelled,
            core::CancellationError::RegistryClosed => Self::RegistryClosed,
            core::CancellationError::LeaseReleased => Self::LeaseReleased,
        }
    }
}

#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct CancellationRegistry {
    inner: core::CancellationRegistry,
}

#[cfg_attr(feature = "uniffi", uniffi::export)]
impl CancellationRegistry {
    #[cfg_attr(feature = "uniffi", uniffi::constructor)]
    pub fn new(domain: CancellationDomain) -> Self {
        let domain = match domain {
            CancellationDomain::Download => core::CancellationDomain::Download,
            CancellationDomain::ExtensionRequest => core::CancellationDomain::ExtensionRequest,
        };
        Self {
            inner: core::CancellationRegistry::new(domain),
        }
    }

    pub fn acquire(&self, id: String) -> Result<Arc<RequestLease>, CancellationError> {
        Ok(Arc::new(RequestLease {
            inner: Arc::new(self.inner.acquire(&id)?),
        }))
    }

    pub fn cancel(&self, id: String) -> Result<(), CancellationError> {
        self.inner.cancel(&id).map_err(Into::into)
    }

    pub fn is_cancelled(&self, id: String) -> Result<bool, CancellationError> {
        self.inner.is_cancelled(&id).map_err(Into::into)
    }

    pub fn shutdown(&self) {
        self.inner.shutdown();
    }
}

#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct RequestLease {
    pub(crate) inner: Arc<core::RequestLease>,
}

#[cfg_attr(feature = "uniffi", uniffi::export)]
impl RequestLease {
    pub fn is_cancelled(&self) -> Result<bool, CancellationError> {
        self.inner.is_cancelled().map_err(Into::into)
    }

    pub fn release(&self) {
        self.inner.release();
    }
}
