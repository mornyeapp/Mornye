use mornye_extensions::logging::{LogBuffer as CoreLogBuffer, LogClosed};
use std::sync::Arc;

#[derive(Debug, thiserror::Error)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Error))]
#[cfg_attr(feature = "uniffi", uniffi(flat_error))]
pub enum LogError {
    #[error("log buffer closed")]
    Closed,
}

impl From<LogClosed> for LogError {
    fn from(_: LogClosed) -> Self {
        Self::Closed
    }
}

#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct LogBuffer {
    pub(crate) inner: Arc<CoreLogBuffer>,
}

#[cfg_attr(feature = "uniffi", uniffi::export)]
impl LogBuffer {
    #[cfg_attr(feature = "uniffi", uniffi::constructor)]
    pub fn new() -> Self {
        Self {
            inner: Arc::new(CoreLogBuffer::default()),
        }
    }

    pub fn set_enabled(&self, enabled: bool) -> Result<(), LogError> {
        self.inner.set_enabled(enabled).map_err(Into::into)
    }
    pub fn is_enabled(&self) -> Result<bool, LogError> {
        self.inner.is_enabled().map_err(Into::into)
    }
    pub fn add(&self, level: String, tag: String, message: String) -> Result<(), LogError> {
        self.inner.add(&level, &tag, &message).map_err(Into::into)
    }
    pub fn backend(&self, message: String) -> Result<(), LogError> {
        self.inner.backend(&message).map_err(Into::into)
    }
    pub fn all(&self) -> Result<String, LogError> {
        self.inner.all().map_err(Into::into)
    }
    pub fn since(&self, index: i64) -> Result<String, LogError> {
        self.inner.since(index).map_err(Into::into)
    }
    pub fn clear(&self) -> Result<(), LogError> {
        self.inner.clear().map_err(Into::into)
    }
    pub fn count(&self) -> Result<u64, LogError> {
        self.inner.count().map_err(Into::into)
    }
    pub fn shutdown(&self) {
        self.inner.shutdown();
    }
}

impl Default for LogBuffer {
    fn default() -> Self {
        Self::new()
    }
}
