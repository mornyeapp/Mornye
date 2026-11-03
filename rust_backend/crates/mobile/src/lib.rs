//! UniFFI mobile API. This crate is the only backend and routes the app on
//! Android and iOS.
//!
//! Comments that mention "Go" describe the retired Go backend, whose observable
//! behavior (wire formats, parsing quirks, file layouts) remains a compatibility
//! contract.

mod cancellation;
mod data_jobs;
mod extensions;
mod ffmpeg;
mod filename;
mod hires;
mod library_metadata;
mod logging;
mod lyrics;
mod manager;
mod metadata;
mod native_autoplay_taste;
mod native_backup;
mod native_cache;
mod native_collections;
mod native_directory_stats;
mod native_id3;
mod native_library;
mod native_listing;
mod native_lyrics;
mod native_lyrics_translation;
mod native_playlist_write;
mod native_playlists;
mod native_recognition;
mod network_tags;
mod progress;
mod repository;
mod tags;
mod usb_audio;

uniffi::setup_scaffolding!();

// Plain Rust surface for the desktop C ABI crate (`crates/desktop`), which
// dispatches the same calls without a UniFFI foreign binding.
pub use cancellation::{CancellationDomain, CancellationError, CancellationRegistry, RequestLease};
pub use data_jobs::run_native_data_job;
pub use extensions::{DownloadDirectoryScope, ExtensionEnvironment, JsExtensionError};
pub use ffmpeg::FfmpegCommands;
pub use filename::build_filename;
pub use hires::check_hires_authenticity;
pub use logging::LogBuffer;
pub use lyrics::LyricsRequest;
pub use manager::{ExtensionManager, ExtensionManagerError};
pub use progress::{DownloadProgressSubscription, DownloadState};
pub use repository::ExtensionRepository;
pub use tags::read_file_metadata;

#[uniffi::export]
pub fn sanitize_filename(filename: String) -> String {
    mornye_core::filename::sanitize_filename(&filename)
}
