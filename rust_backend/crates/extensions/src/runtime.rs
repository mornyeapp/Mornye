//! Extension runtime: loads extension sources into a worker VM and runs calls under resource limits.

use mornye_core::cancellation::{CancellationError, RequestLease};
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::{self, SyncSender, TrySendError};
use std::sync::{Arc, Condvar, Mutex, OnceLock, Weak};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

mod control;
mod json_input;
#[cfg(test)]
mod tests;
mod vm;

pub(crate) use control::Control;
use vm::{CompiledSource, run_worker};

const MAX_INPUT_BYTES: usize = 8 * 1024 * 1024;
const MAX_TIMEOUT_MS: u64 = 300_000;
const QUEUE_CAPACITY: usize = 8;
const IDLE_GC_DELAY: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum LoadMode {
    Initialize,
    Register,
    Validate,
}

/// Hosts granted by the trusted extension manager after permission validation.
#[derive(Clone)]
pub struct ExtensionServices {
    pub legacy_backend: bool,
    pub(crate) lyrics: Weak<mornye_providers::lyrics::LyricsService>,
    pub(crate) lyrics_node: mornye_providers::lyrics::CallNode,
    pub(crate) lyrics_parent: Option<mornye_providers::lyrics::CallNode>,
    pub legacy_files: Option<Arc<crate::files::ExtensionFiles>>,
    pub isrc: Arc<mornye_core::isrc::IndexCache>,
    pub logs: Arc<crate::logging::LogBuffer>,
    pub extension_id: String,
    pub ffmpeg: Arc<crate::ffmpeg::CommandRegistry>,
    pub raw_ffmpeg_stub: bool,
    pub downloads: Arc<mornye_core::downloads::DownloadState>,
    pub storage: Option<Arc<crate::storage::ExtensionStore>>,
    pub files: Option<Arc<crate::files::ExtensionFiles>>,
    pub transfer_policy: crate::transfer_policy::DownloadTransferPolicy,
    pub network: Option<Arc<mornye_network::NetworkSession>>,
    pub auth: Option<Arc<crate::auth::ExtensionAuth>>,
    pub(crate) auth_registry: Option<Arc<crate::auth::AuthRegistry>>,
    pub session: Option<Arc<crate::signed_session::SignedSessionClient>>,
    pub app_version: mornye_core::app_version::AppVersion,
    pub(crate) parent_closed: Option<Arc<AtomicBool>>,
    pub(crate) startup_lease: Option<Arc<RequestLease>>,
    pub(crate) initialize_empty_settings: bool,
    pub(crate) load_mode: LoadMode,
    pub(crate) compiled_source: Option<Arc<CompiledSource>>,
}

impl Default for ExtensionServices {
    fn default() -> Self {
        Self {
            legacy_backend: false,
            lyrics: Weak::new(),
            lyrics_node: mornye_providers::lyrics::CallGraph::default().node(),
            lyrics_parent: None,
            legacy_files: None,
            isrc: Arc::new(mornye_core::isrc::IndexCache::default()),
            logs: Arc::new(crate::logging::LogBuffer::default()),
            extension_id: String::new(),
            ffmpeg: Arc::new(crate::ffmpeg::CommandRegistry::default()),
            raw_ffmpeg_stub: false,
            downloads: Arc::new(mornye_core::downloads::DownloadState::default()),
            storage: None,
            files: None,
            transfer_policy: crate::transfer_policy::DownloadTransferPolicy::default(),
            network: None,
            auth: None,
            auth_registry: None,
            session: None,
            app_version: Default::default(),
            parent_closed: None,
            startup_lease: None,
            initialize_empty_settings: true,
            load_mode: LoadMode::Initialize,
            compiled_source: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ExtensionError {
    #[error("extension runtime closed")]
    Closed,
    #[error("extension runtime busy")]
    Busy,
    #[error("execution timeout exceeded")]
    Timeout,
    #[error("{0}")]
    Cancelled(CancellationError),
    #[error("extension did not call registerExtension()")]
    NotRegistered,
    #[error("extension function not found: {0}")]
    MissingFunction(String),
    #[error("invalid extension input: {0}")]
    InvalidInput(String),
    #[error("{0}")]
    Script(String),
}

#[derive(Clone, Debug)]
pub struct RuntimeLimits {
    pub memory_bytes: usize,
    pub stack_bytes: usize,
    pub timeout_ms: u64,
}

impl Default for RuntimeLimits {
    fn default() -> Self {
        Self {
            memory_bytes: 64 * 1024 * 1024,
            stack_bytes: 512 * 1024,
            timeout_ms: 30_000,
        }
    }
}

impl RuntimeLimits {
    fn validate(&self) -> Result<(), ExtensionError> {
        if !(1024 * 1024..=256 * 1024 * 1024).contains(&self.memory_bytes)
            || !(64 * 1024..=1024 * 1024).contains(&self.stack_bytes)
        {
            return Err(ExtensionError::InvalidInput(
                "memory must be 1–256 MiB and stack must be 64–1024 KiB".to_owned(),
            ));
        }
        Ok(())
    }

    fn timeout(&self, requested_ms: u64) -> Duration {
        let milliseconds = if requested_ms == 0 {
            self.timeout_ms.max(1)
        } else {
            requested_ms
        };
        Duration::from_millis(milliseconds.min(MAX_TIMEOUT_MS))
    }
}

#[derive(Clone)]
struct Operation {
    item_id: String,
    deadline: Instant,
    lease: Option<Arc<RequestLease>>,
    resolution: Option<Arc<crate::resolution::ResolutionBudget>>,
}

impl Operation {
    fn check(&self) -> Result<(), ExtensionError> {
        if let Some(lease) = &self.lease {
            lease.check_active().map_err(ExtensionError::Cancelled)?;
        }
        if Instant::now() >= self.deadline
            || self
                .resolution
                .as_ref()
                .is_some_and(|budget| budget.remaining().is_zero())
        {
            return Err(ExtensionError::Timeout);
        }
        Ok(())
    }
}

type Reply = SyncSender<Result<String, ExtensionError>>;

#[derive(Clone, Copy)]
enum CallKind {
    Function,
    Lifecycle,
    Action,
    Provider,
    DownloadProvider,
    PostProcess,
}

enum Command {
    Call {
        method: String,
        arguments: String,
        operation: Operation,
        started: SyncSender<()>,
        reply: Reply,
        kind: CallKind,
    },
    #[cfg(test)]
    InspectHeap(SyncSender<(i64, u64)>),
    Stop,
}

/// A stateful VM owned by one dedicated worker. No QuickJS value crosses threads.
///
/// Calls are serialized and bounded, including queue time, JS jobs, and host
/// utilities. An interrupted VM is retired: callers must reload the extension
/// rather than letting pending callbacks escape into a subsequent request.
pub struct ExtensionRuntime {
    pub(crate) compiled_source: Arc<CompiledSource>,
    lyrics_node: mornye_providers::lyrics::CallNode,
    lyrics_parent: Option<mornye_providers::lyrics::CallNode>,
    downloads: Arc<mornye_core::downloads::DownloadState>,
    sender: SyncSender<Command>,
    control: Arc<Control>,
    worker: Mutex<Option<JoinHandle<()>>>,
    limits: RuntimeLimits,
    session: Option<Arc<crate::signed_session::SignedSessionClient>>,
    network: Option<Arc<mornye_network::NetworkSession>>,
    native_calls: Mutex<usize>,
    native_idle: Condvar,
}

impl ExtensionRuntime {
    pub(crate) fn shared_source(&self) -> Arc<str> {
        Arc::clone(&self.compiled_source.source)
    }

    pub fn load(
        source: &str,
        settings_json: &str,
        limits: RuntimeLimits,
    ) -> Result<Self, ExtensionError> {
        Self::load_with_services(source, settings_json, limits, ExtensionServices::default())
    }

    pub fn load_with_services(
        source: &str,
        settings_json: &str,
        limits: RuntimeLimits,
        mut services: ExtensionServices,
    ) -> Result<Self, ExtensionError> {
        limits.validate()?;
        validate_size(source)?;
        let compiled_source = services
            .compiled_source
            .take()
            .filter(|cached| cached.source.as_ref() == source)
            .unwrap_or_else(|| {
                Arc::new(CompiledSource {
                    source: source.into(),
                    bytecode: OnceLock::new(),
                })
            });
        services.compiled_source = Some(Arc::clone(&compiled_source));
        let settings = validate_json(settings_json)?;
        if !settings.is_object() {
            return Err(ExtensionError::InvalidInput(
                "settings must be an object".to_owned(),
            ));
        }
        let control = Arc::new(Control {
            parent_closed: services.parent_closed.clone(),
            ..Control::default()
        });
        *control.operation.lock().expect("extension operation lock") = Some(Operation {
            item_id: String::new(),
            deadline: Instant::now() + limits.timeout(0),
            lease: services.startup_lease.clone(),
            resolution: None,
        });
        let (sender, receiver) = mpsc::sync_channel(QUEUE_CAPACITY);
        let (ready, result) = mpsc::sync_channel(1);
        let worker_control = Arc::clone(&control);
        let worker_limits = limits.clone();
        let source = Arc::clone(&compiled_source.source);
        let settings = settings_json.to_owned();
        let session = services.session.clone();
        let network = services.network.clone();
        let downloads = Arc::clone(&services.downloads);
        let lyrics_node = services.lyrics_node.clone();
        let lyrics_parent = services.lyrics_parent.clone();
        // Isolated VM loading happens while its primary manager engine is held.
        let _dependency = lyrics_parent
            .as_ref()
            .map(|parent| parent.wait_for(&lyrics_node))
            .transpose()
            .map_err(ExtensionError::Script)?;
        let worker = thread::Builder::new()
            .name("extension-js".to_owned())
            .stack_size(4 * 1024 * 1024)
            .spawn(move || {
                run_worker(
                    receiver,
                    ready,
                    &worker_control,
                    &worker_limits,
                    &source,
                    &settings,
                    &services,
                );
                worker_control.close();
            })
            .map_err(|error| ExtensionError::Script(format!("start extension worker: {error}")))?;
        let runtime = Self {
            compiled_source,
            lyrics_node,
            lyrics_parent,
            downloads,
            sender,
            control,
            worker: Mutex::new(Some(worker)),
            limits,
            session,
            network,
            native_calls: Mutex::new(0),
            native_idle: Condvar::new(),
        };
        result.recv().unwrap_or(Err(ExtensionError::Closed))?;
        Ok(runtime)
    }

    pub fn call(
        &self,
        method: &str,
        arguments_json: &str,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
    ) -> Result<String, ExtensionError> {
        self.call_with_operation(
            method,
            arguments_json,
            Operation {
                item_id: String::new(),
                deadline: Instant::now() + self.limits.timeout(timeout_ms),
                lease,
                resolution: None,
            },
            CallKind::Function,
        )
    }

    pub(crate) fn managed_call(
        &self,
        method: &str,
        arguments: &str,
        action: bool,
        timeout_ms: u64,
    ) -> Result<String, ExtensionError> {
        self.managed_call_with_lease(method, arguments, action, timeout_ms, None)
    }

    pub(crate) fn managed_call_with_lease(
        &self,
        method: &str,
        arguments: &str,
        action: bool,
        timeout_ms: u64,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionError> {
        // Initialize/cleanup of a pooled VM also holds the primary engine.
        // Its regular download call runs without this dependency.
        let _dependency = self
            .lyrics_parent
            .as_ref()
            .map(|parent| parent.wait_for(&self.lyrics_node))
            .transpose()
            .map_err(ExtensionError::Script)?;
        self.call_with_operation(
            method,
            arguments,
            Operation {
                item_id: String::new(),
                deadline: Instant::now() + self.limits.timeout(timeout_ms),
                lease,
                resolution: None,
            },
            if action {
                CallKind::Action
            } else {
                CallKind::Lifecycle
            },
        )
    }

    /// Read typed provider fields in the owning VM. Go's provider wrappers do
    /// not await a returned Promise; the provider object itself is parsed.
    pub(crate) fn call_provider_operation(
        &self,
        method: &str,
        arguments: &str,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
        item_id: String,
    ) -> Result<String, ExtensionError> {
        self.call_with_operation(
            method,
            arguments,
            Operation {
                item_id,
                deadline: Instant::now() + self.limits.timeout(timeout_ms),
                lease,
                resolution: None,
            },
            CallKind::Provider,
        )
    }

    pub(crate) fn is_closed(&self) -> bool {
        self.control.is_closed()
    }

    pub(crate) fn call_post_process(
        &self,
        arguments: &str,
        timeout_ms: u64,
        item_id: &str,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionError> {
        self.call_with_operation(
            "postProcessV2",
            arguments,
            Operation {
                item_id: item_id.into(),
                deadline: Instant::now()
                    + self
                        .limits
                        .timeout(if timeout_ms == 0 { 120_000 } else { timeout_ms }),
                lease,
                resolution: None,
            },
            CallKind::PostProcess,
        )
    }

    pub(crate) fn network_session(&self) -> Option<Arc<mornye_network::NetworkSession>> {
        self.network.clone()
    }

    pub(crate) fn call_download_provider(
        &self,
        arguments: &str,
        item_id: &str,
        resolution_timeout_ms: u64,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, (ExtensionError, bool)> {
        let lease = match lease {
            Some(lease) => lease,
            None => Arc::new(
                self.downloads
                    .acquire(item_id)
                    .map_err(|error| (ExtensionError::Cancelled(error), false))?,
            ),
        };
        if !item_id.is_empty() {
            let _ = self.downloads.progress.preparing(item_id, "");
        }
        let allowance = if resolution_timeout_ms == 0 {
            60_000
        } else {
            resolution_timeout_ms.min(MAX_TIMEOUT_MS)
        };
        let budget = crate::resolution::ResolutionBudget::new(Duration::from_millis(allowance));
        self.call_with_operation(
            "download",
            arguments,
            Operation {
                item_id: item_id.to_owned(),
                deadline: Instant::now() + Duration::from_secs(24 * 60 * 60),
                lease: Some(lease),
                resolution: Some(Arc::clone(&budget)),
            },
            CallKind::DownloadProvider,
        )
        .map_err(|error| (error, budget.remaining().is_zero()))
    }

    /// Native provider-manager entry point. Resolver/callback/retry time shares
    /// one allowance; established native media reads pause only that allowance.
    // Public only for the integration tests in `tests/`; the download manager
    // uses `call_download_provider`.
    #[doc(hidden)]
    pub fn call_download(
        &self,
        method: &str,
        arguments_json: &str,
        lease: Option<Arc<RequestLease>>,
        resolution_timeout_ms: u64,
    ) -> Result<String, ExtensionError> {
        self.call_download_operation(
            method,
            arguments_json,
            lease,
            resolution_timeout_ms,
            String::new(),
        )
    }

    pub fn download_state(&self) -> Arc<mornye_core::downloads::DownloadState> {
        Arc::clone(&self.downloads)
    }

    fn call_download_operation(
        &self,
        method: &str,
        arguments_json: &str,
        lease: Option<Arc<RequestLease>>,
        resolution_timeout_ms: u64,
        item_id: String,
    ) -> Result<String, ExtensionError> {
        let allowance = if resolution_timeout_ms == 0 {
            60_000
        } else {
            resolution_timeout_ms.min(MAX_TIMEOUT_MS)
        };
        self.call_with_operation(
            method,
            arguments_json,
            Operation {
                item_id,
                deadline: Instant::now() + Duration::from_secs(24 * 60 * 60),
                lease,
                resolution: Some(crate::resolution::ResolutionBudget::new(
                    Duration::from_millis(allowance),
                )),
            },
            CallKind::Function,
        )
    }

    fn call_with_operation(
        &self,
        method: &str,
        arguments_json: &str,
        operation: Operation,
        kind: CallKind,
    ) -> Result<String, ExtensionError> {
        if self.control.is_closed() {
            return Err(ExtensionError::Closed);
        }
        let arguments = validate_json(arguments_json)?;
        if !arguments.is_array() {
            return Err(ExtensionError::InvalidInput(
                "arguments must be an array".to_owned(),
            ));
        }
        validate_size(method)?;
        operation.check()?;
        let (started, waiting) = mpsc::sync_channel(0);
        let (reply, result) = mpsc::sync_channel(1);
        let command = Command::Call {
            method: method.to_owned(),
            arguments: arguments_json.to_owned(),
            operation: operation.clone(),
            started,
            reply,
            kind,
        };
        self.sender.try_send(command).map_err(|error| match error {
            TrySendError::Full(_) => ExtensionError::Busy,
            TrySendError::Disconnected(_) => ExtensionError::Closed,
        })?;
        loop {
            if self.control.is_closed() {
                return Err(ExtensionError::Closed);
            }
            operation.check()?;
            let remaining = operation.deadline.saturating_duration_since(Instant::now());
            match waiting.recv_timeout(remaining.min(Duration::from_millis(50))) {
                Ok(()) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => return Err(ExtensionError::Closed),
            }
        }
        // The rendezvous transfers responsibility for interruption to the VM.
        // Active calls must finish cleanup and retire the VM before returning.
        result.recv().unwrap_or(Err(ExtensionError::Closed))
    }

    /// Session preflight touches thread-safe hosts without occupying the VM.
    pub fn preflight_signed_session(
        &self,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
    ) -> Result<bool, ExtensionError> {
        let mut pending = self
            .native_calls
            .lock()
            .expect("extension native calls lock");
        if self.control.is_closed() {
            return Err(ExtensionError::Closed);
        }
        *pending += 1;
        drop(pending);
        let _operation = NativeOperation(self);
        let deadline = Instant::now() + self.limits.timeout(timeout_ms);
        let check = || {
            if self.control.is_closed() {
                return Err(ExtensionError::Closed);
            }
            if let Some(lease) = &lease {
                lease.check_active().map_err(ExtensionError::Cancelled)?;
            }
            if Instant::now() >= deadline {
                return Err(ExtensionError::Timeout);
            }
            Ok(())
        };
        check()?;
        let result = self.session.as_ref().map_or(Ok(false), |session| {
            session.preflight(|| check().map_err(|error| error.to_string()))
        });
        check()?;
        result.map_err(ExtensionError::Script)
    }

    pub fn take_verification_url(&self) -> String {
        self.session
            .as_ref()
            .map_or_else(String::new, |session| session.take_verification_url())
    }

    /// Terminal, idempotent interruption, including queued work. Does not run JS.
    /// A manager should call the extension's cleanup hook before orderly shutdown.
    pub fn shutdown(&self) {
        self.control.close();
        let _ = self.sender.try_send(Command::Stop);
        if let Some(worker) = self.worker.lock().expect("extension worker lock").take() {
            let _ = worker.join();
        }
        let mut pending = self
            .native_calls
            .lock()
            .expect("extension native calls lock");
        while *pending > 0 {
            pending = self
                .native_idle
                .wait(pending)
                .expect("extension native calls idle");
        }
    }
}

struct NativeOperation<'a>(&'a ExtensionRuntime);
impl Drop for NativeOperation<'_> {
    fn drop(&mut self) {
        let mut pending = self
            .0
            .native_calls
            .lock()
            .expect("extension native calls lock");
        *pending -= 1;
        self.0.native_idle.notify_all();
    }
}

impl Drop for ExtensionRuntime {
    fn drop(&mut self) {
        self.shutdown();
    }
}

pub(crate) fn lifecycle_result(
    method: &str,
    output: Result<String, ExtensionError>,
) -> Result<(), ExtensionError> {
    let result: serde_json::Value = serde_json::from_str(&output?)
        .map_err(|error| ExtensionError::Script(error.to_string()))?;
    if result["success"] == false {
        return Err(ExtensionError::Script(format!(
            "{method} failed: {}",
            result["error"].as_str().unwrap_or("unknown error")
        )));
    }
    Ok(())
}

fn validate_size(value: &str) -> Result<(), ExtensionError> {
    if value.len() > MAX_INPUT_BYTES {
        return Err(ExtensionError::InvalidInput(
            "input exceeds 8 MiB".to_owned(),
        ));
    }
    Ok(())
}

fn validate_json(value: &str) -> Result<json_input::Shape, ExtensionError> {
    validate_size(value)?;
    serde_json::from_str(value).map_err(|error| ExtensionError::InvalidInput(error.to_string()))
}
