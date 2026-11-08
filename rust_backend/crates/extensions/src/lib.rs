//! Extension JavaScript execution and host services, isolated from mobile UI code.
//!
//! Comments that mention "Go" describe the retired Go backend, whose observable
//! behavior (wire formats, parsing quirks, file layouts) remains a compatibility
//! contract.

pub mod auth;
pub mod backend;
mod binary;
pub mod crypto;
mod crypto_host;
mod download;
mod download_host;
pub mod environment;
pub mod ffmpeg;
mod ffmpeg_host;
mod file_host;
mod file_transform;
pub mod files;
mod host;
mod legacy_host;
pub mod logging;
pub mod lyrics;
pub mod manager;
pub mod manifest;
mod network_host;
pub mod package;
mod provider;
mod redact;
pub mod repository;
mod resolution;
mod runtime;
mod session_host;
pub mod signed_session;
pub mod storage;
pub mod stream_capture;
pub mod transfer_policy;
mod url_host;
mod utility_host;
// Pure path checks, so host tests cover them on every platform.
#[cfg(any(not(unix), test))]
mod windows_path;

pub use runtime::{ExtensionError, ExtensionRuntime, ExtensionServices, RuntimeLimits};
