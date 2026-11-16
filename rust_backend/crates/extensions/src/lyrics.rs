//! Lyrics service adapter for installed providers and the shared built-in clients.

use crate::manager::ExtensionManager;
use mornye_core::cancellation::{CancellationDomain, CancellationRegistry};
use mornye_core::lyrics::LyricsResponse;
use mornye_core::matching::lowercase;
use mornye_providers::lyrics::{
    CallGraph, Check, LyricsError, LyricsFetcher, SearchRequest, builtin::BuiltinLyricsClient,
};
use serde_json::json;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak, mpsc};
use std::time::Duration;

/// The native owner retains the manager and service separately. A weak manager
/// reference allows that owner to keep this adapter without a reference cycle.
/// Lyrics flights register their wait on the manager VM before queueing work.
/// A host call back into the service can then reject recursive dependencies.
pub struct InstalledLyricsFetcher {
    manager: Weak<ExtensionManager>,
    closed: Arc<AtomicBool>,
    builtin: BuiltinLyricsClient,
    calls: CallGraph,
}

impl InstalledLyricsFetcher {
    pub fn new(manager: &Arc<ExtensionManager>, builtin: BuiltinLyricsClient) -> Self {
        Self {
            manager: Arc::downgrade(manager),
            closed: manager.environment().closed_flag(),
            builtin,
            calls: manager.environment().lyrics_calls(),
        }
    }
}

impl LyricsFetcher for InstalledLyricsFetcher {
    fn call_graph(&self) -> Option<CallGraph> {
        Some(self.calls.clone())
    }

    fn check(&self) -> Result<(), LyricsError> {
        if self.closed.load(Ordering::Acquire) || self.manager.strong_count() == 0 {
            Err(LyricsError::Cancelled("extension manager closed".into()))
        } else {
            Ok(())
        }
    }

    fn extensions(&self) -> Vec<String> {
        self.manager
            .upgrade()
            .and_then(|manager| manager.provider_ids("lyrics_provider").ok())
            .unwrap_or_default()
            .into_iter()
            .map(|id| lowercase(id.trim()))
            .collect()
    }

    fn fetch(
        &self,
        provider: &str,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError> {
        check().map_err(LyricsError::Cancelled)?;
        let manager = self
            .manager
            .upgrade()
            .ok_or_else(|| LyricsError::Cancelled("extension manager closed".into()))?;
        let environment = manager.environment();
        let check = || {
            check()?;
            if environment.is_closed() {
                Err("extension manager closed".into())
            } else {
                Ok(())
            }
        };
        check().map_err(LyricsError::Cancelled)?;
        let Some(id) = provider.strip_prefix("extension:") else {
            return self.builtin.fetch(provider, request, &check);
        };
        let id = manager
            .provider_ids("lyrics_provider")
            .map_err(|error| LyricsError::Other(error.to_string()))?
            .into_iter()
            .find(|candidate| lowercase(candidate.trim()) == id)
            .ok_or_else(|| LyricsError::Other(format!("lyrics provider unavailable: {id}")))?;
        let arguments = json!([request.track, request.artist, "", request.duration]).to_string();
        let _dependency = request
            .caller
            .as_ref()
            .map(|caller| caller.wait_for(&environment.lyrics_node(&id, false)))
            .transpose()
            .map_err(LyricsError::Recursive)?;
        let cancellation = CancellationRegistry::new(CancellationDomain::ExtensionRequest);
        let lease = Arc::new(
            cancellation
                .acquire("")
                .expect("new lyrics cancellation lease"),
        );
        let result = std::thread::scope(|scope| {
            let (done, completion) = mpsc::channel::<()>();
            let worker_lease = &lease;
            let worker = std::thread::Builder::new()
                .name("installed-lyrics".into())
                .spawn_scoped(scope, move || {
                    let _done = done;
                    manager.provider_call(
                        &id,
                        "fetchLyrics",
                        &arguments,
                        Some(worker_lease.clone()),
                        30_000,
                    )
                })
                .map_err(|error| LyricsError::Other(error.to_string()))?;
            let mut cancelled = None;
            loop {
                if let Err(message) = check() {
                    cancelled = Some(message);
                    lease.release();
                    break;
                }
                if !matches!(
                    completion.recv_timeout(Duration::from_millis(5)),
                    Err(mpsc::RecvTimeoutError::Timeout)
                ) {
                    break;
                }
            }
            let result = worker
                .join()
                .map_err(|_| LyricsError::Other("installed lyrics provider panicked".into()))?;
            if let Some(message) = cancelled {
                return Err(LyricsError::Cancelled(message));
            }
            check().map_err(LyricsError::Cancelled)?;
            let response = result.map_err(|error| LyricsError::Other(error.to_string()))?;
            serde_json::from_str(&response).map_err(|error| LyricsError::Other(error.to_string()))
        });
        lease.release();
        result
    }
}
