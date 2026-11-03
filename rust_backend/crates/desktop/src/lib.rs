//! Desktop (macOS, Linux, Windows) C ABI over the Rust backend, for Flutter's
//! `dart:ffi`. The contract lives in `docs/internal/desktop/FFI_CONTRACT.md`:
//! one callback, JSON method dispatch with the MethodChannel method names and
//! argument shapes, a worker pool per call, pushed event streams, and an
//! FFmpeg command pump that runs the bundled `ffmpeg` executable. Desktop OS
//! services live here too: keep-awake during downloads, Discord Rich
//! Presence over local IPC, library folder watching, a panic log, the
//! Mornye Link server for the phone app, and Google Cast output.

mod backend;
mod call;
mod callback_url;
mod cast;
mod crash_log;
mod discord;
mod dispatch;
mod events;
mod ffi;
mod ffmpeg;
mod keep_awake;
mod link;
mod paths;
mod pool;
mod runtime;
mod watcher;

pub use call::{Args, BYTES_KEY, CallError, Reply};
pub use ffi::{
    mornye_call, mornye_cancel, mornye_free, mornye_init, mornye_subscribe, mornye_unsubscribe,
};
pub use runtime::{Config, MornyeCallback};

/// Callback kinds (see the contract table).
pub mod kind {
    pub const RESULT: i32 = 0;
    pub const ERROR: i32 = 1;
    pub const BINARY_RESULT: i32 = 2;
    pub const DOWNLOAD_PROGRESS: i32 = 10;
    pub const LIBRARY_SCAN_PROGRESS: i32 = 11;
    pub const INBOUND_CALL: i32 = 12;
    pub const LOG: i32 = 13;
}

/// Every method desktop implements, in table order. Other methods answer
/// `unimplemented`.
pub fn implemented_methods() -> Vec<&'static str> {
    dispatch::METHODS.iter().map(|entry| entry.name).collect()
}
