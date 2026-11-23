//! Casting for the app: the media server receivers stream from, and senders
//! for Google Cast (on platforms without Google's Cast SDK), DLNA renderers
//! and FCast receivers, behind one service.

mod discovery;
mod dlna;
#[cfg(test)]
mod dlna_tests;
mod fcast;
#[cfg(test)]
mod fcast_tests;
mod http;
mod mdns;
pub mod media;
mod proto;
mod sender;
#[cfg(test)]
mod sender_tests;
mod service;
mod session;
mod ssdp;
mod status;
mod xml;

pub use discovery::{Device, Kind};
pub use media::MediaServer;
pub use service::CastService;
