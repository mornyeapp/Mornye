//! Mornye Link: the desktop app's HTTPS server for the phone app. It speaks
//! OpenSubsonic for the library (`/rest`), Mornye endpoints under
//! `/mornye/v1` forwarded to the app, and a WebSocket for pushes. The
//! contract is `docs/internal/desktop/LINK_CONTRACT.md`.
//!
//! Module owners: L1a `server`, `tls`, `store`, `auth`, `pairing`, `ws`,
//! `mdns`, `api`; L1b `catalog`, `subsonic`, `xml`, `media`.

pub mod catalog;
pub mod subsonic;
pub mod types;

pub use catalog::Catalog;
pub use types::{Device, Host, HostError, LinkConfig, Shared};
