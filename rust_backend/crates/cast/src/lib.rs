//! Google Cast for the app: the media server receivers stream from, and a
//! sender for platforms without Google's Cast SDK (iOS and desktop).

mod discovery;
pub mod media;
mod proto;
mod sender;
#[cfg(test)]
mod sender_tests;
mod service;

pub use discovery::Device;
pub use media::MediaServer;
pub use service::CastService;
