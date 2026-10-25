//! Built-in provider clients and shared lookup services for native app owners.
//!
//! Comments that mention "Go" describe the retired Go backend, whose observable
//! behavior (wire formats, parsing quirks, file layouts) remains a compatibility
//! contract.

mod coalescer;
pub mod deezer;
pub mod lyrics;
pub mod musicbrainz;
pub mod recognition;
pub mod resolver;
