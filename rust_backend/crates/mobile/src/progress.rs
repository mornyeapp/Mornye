use crate::cancellation::{CancellationError, RequestLease};
use mornye_core::downloads::DownloadState as CoreState;
use mornye_core::progress::{ProgressError, ProgressSubscription};
use std::sync::Arc;

#[derive(Debug, thiserror::Error)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Error))]
#[cfg_attr(feature = "uniffi", uniffi(flat_error))]
pub enum DownloadProgressError {
    #[error("download progress registry closed")]
    Closed,
    #[error("download progress subscription closed")]
    SubscriptionClosed,
}

impl From<ProgressError> for DownloadProgressError {
    fn from(error: ProgressError) -> Self {
        match error {
            ProgressError::Closed => Self::Closed,
            ProgressError::SubscriptionClosed => Self::SubscriptionClosed,
        }
    }
}

/// Share one instance between the native download manager and its listeners.
#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct DownloadState {
    pub(crate) inner: Arc<CoreState>,
}

#[cfg_attr(feature = "uniffi", uniffi::export)]
impl DownloadState {
    #[cfg_attr(feature = "uniffi", uniffi::constructor)]
    pub fn new() -> Self {
        Self {
            inner: Arc::new(CoreState::default()),
        }
    }

    pub fn acquire(&self, item_id: String) -> Result<Arc<RequestLease>, CancellationError> {
        Ok(Arc::new(RequestLease {
            inner: Arc::new(self.inner.acquire(&item_id)?),
        }))
    }

    pub fn cancel_download(&self, item_id: String) -> Result<(), CancellationError> {
        self.inner.cancel(&item_id).map_err(Into::into)
    }

    pub fn cancel_downloads(&self, item_ids: Vec<String>) -> Result<(), CancellationError> {
        self.inner.cancel_many(&item_ids).map_err(Into::into)
    }

    pub fn cancel_active_downloads(&self) -> Result<Vec<String>, CancellationError> {
        self.inner.cancel_active().map_err(Into::into)
    }

    pub fn reset_download_cancel(&self, item_id: String) -> Result<(), CancellationError> {
        self.inner
            .cancellation
            .reset_if_idle(&item_id)
            .map_err(Into::into)
    }

    pub fn reset_download_cancels(&self, item_ids: Vec<String>) -> Result<(), CancellationError> {
        self.inner
            .cancellation
            .reset_many_if_idle(item_ids.iter().map(String::as_str))
            .map_err(Into::into)
    }

    pub fn is_cancelled(&self, item_id: String) -> Result<bool, CancellationError> {
        self.inner
            .cancellation
            .is_cancelled(&item_id)
            .map_err(Into::into)
    }

    pub fn init_item_progress(&self, item_id: String) -> Result<(), DownloadProgressError> {
        self.inner.progress.start(&item_id).map_err(Into::into)
    }

    pub fn clear_item_progress(&self, item_id: String) -> Result<(), DownloadProgressError> {
        self.inner.progress.remove(&item_id).map_err(Into::into)
    }

    pub fn set_progress(
        &self,
        item_id: String,
        progress: f64,
        received: i64,
        total: i64,
    ) -> Result<(), DownloadProgressError> {
        self.inner
            .progress
            .set_progress(&item_id, progress, received, total)
            .map_err(Into::into)
    }

    pub fn all_progress(&self) -> Result<String, DownloadProgressError> {
        self.inner.progress.snapshot().map_err(Into::into)
    }

    pub fn subscribe_progress(
        &self,
    ) -> Result<Arc<DownloadProgressSubscription>, DownloadProgressError> {
        Ok(Arc::new(DownloadProgressSubscription {
            inner: self.inner.progress.subscribe()?,
        }))
    }

    pub fn shutdown(&self) {
        self.inner.shutdown();
    }
}

impl Default for DownloadState {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancel_batch_keeps_other_attempts_and_clears_selected_progress() {
        let state = DownloadState::new();
        let active = state.acquire("active".into()).unwrap();
        let keep = state.acquire("keep".into()).unwrap();
        let anonymous = state.acquire("".into()).unwrap();
        for id in ["active", "queued", "keep", ""] {
            state.init_item_progress(id.into()).unwrap();
        }
        state
            .cancel_downloads(vec![
                "active".into(),
                "queued".into(),
                "queued".into(),
                "".into(),
            ])
            .unwrap();
        assert!(active.is_cancelled().unwrap());
        assert!(!keep.is_cancelled().unwrap());
        assert!(!anonymous.is_cancelled().unwrap());
        assert!(
            state
                .acquire("queued".into())
                .unwrap()
                .is_cancelled()
                .unwrap()
        );
        let progress: serde_json::Value =
            serde_json::from_str(&state.all_progress().unwrap()).unwrap();
        assert_eq!(progress["items"].as_object().unwrap().len(), 1);
        assert!(progress["items"].get("keep").is_some());
        state.reset_download_cancels(vec!["active".into()]).unwrap();
        assert!(active.is_cancelled().unwrap());
        active.release();
        assert!(
            !state
                .acquire("active".into())
                .unwrap()
                .is_cancelled()
                .unwrap()
        );
        state.shutdown();
        assert!(matches!(
            state.cancel_downloads(vec!["late".into()]),
            Err(CancellationError::RegistryClosed)
        ));
    }

    #[test]
    fn cancel_batch_keeps_best_effort_cleanup_when_one_registry_is_closed() {
        let state = DownloadState::new();
        state.init_item_progress("a".into()).unwrap();
        state.inner.cancellation.shutdown();
        assert!(state.cancel_downloads(vec!["a".into()]).is_err());
        assert_eq!(state.all_progress().unwrap(), "{\"items\":{}}");
        let state = DownloadState::new();
        let active = state.acquire("a".into()).unwrap();
        state.inner.progress.shutdown();
        state.cancel_downloads(vec!["a".into()]).unwrap();
        assert!(active.is_cancelled().unwrap());
    }

    #[test]
    fn reset_batch_uses_the_same_download_owner_and_keeps_active_cancelled() {
        let state = DownloadState::new();
        let active = state.acquire("active".into()).unwrap();
        for id in ["active", "idle", "keep"] {
            state.cancel_download(id.into()).unwrap();
        }
        state
            .reset_download_cancels(vec!["active".into(), "idle".into()])
            .unwrap();
        assert!(active.is_cancelled().unwrap());
        assert!(!state.is_cancelled("idle".into()).unwrap());
        assert!(state.is_cancelled("keep".into()).unwrap());
        active.release();
        assert!(
            !state
                .acquire("active".into())
                .unwrap()
                .is_cancelled()
                .unwrap()
        );
        state.shutdown();
        assert!(matches!(
            state.reset_download_cancels(vec!["keep".into()]),
            Err(CancellationError::RegistryClosed)
        ));
    }
}

#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct DownloadProgressSubscription {
    inner: ProgressSubscription,
}

#[cfg_attr(feature = "uniffi", uniffi::export)]
impl DownloadProgressSubscription {
    pub fn wait_delta(&self, since: i64, timeout_ms: i64) -> Result<String, DownloadProgressError> {
        self.inner.wait_delta(since, timeout_ms).map_err(Into::into)
    }

    pub fn stop(&self) {
        self.inner.close();
    }
}
