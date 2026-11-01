//! Shared backend logic, independent of mobile bindings and UI runtimes.
//!
//! Comments that mention "Go" describe the retired Go backend, whose observable
//! behavior (wire formats, parsing quirks, file layouts) remains a compatibility
//! contract.

pub mod app_version;
pub mod cancellation;
pub mod clock;
pub mod cover;
pub mod cue;
pub mod downloads;
pub mod filename;
pub mod fs;
pub mod isrc;
pub mod json;
pub mod lyrics;
pub mod matching;
pub mod media;
pub mod metadata;
pub mod music_signature;
pub mod native_audio_analysis;
pub mod native_audio_features;
pub mod native_palette;
pub mod progress;
pub mod resolver;
pub mod tags;
mod text;
pub mod xml;
pub use text::{json_surrogates as normalize_json_surrogates, lower_hex};
