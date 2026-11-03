//! Shared, cancellable HTTP transport for the embedded backend.
//!
//! Comments that mention "Go" describe the retired Go backend, whose observable
//! behavior (wire formats, parsing quirks, file layouts) remains a compatibility
//! contract.

mod client;
mod cookies;
mod dns;
pub mod policy;
pub mod query;
mod tls;
pub mod url;

pub use client::{
    HttpRequest, HttpResponse, HttpStream, MAX_RESPONSE_BYTES, NetworkOptions, NetworkService,
    NetworkSession,
};
pub use dns::{Lookup, LookupFuture, SystemLookup};

/// The app's TLS client configuration (system trust plus the bundled roots),
/// for crates that run their own HTTP client, such as the Cast media relay.
pub fn tls_client_config() -> std::io::Result<rustls::ClientConfig> {
    tls::configuration(&[])
}

/// Shared browser identity for native clients and `utils.randomUserAgent()`.
pub fn random_user_agent() -> String {
    use std::collections::hash_map::RandomState;
    use std::hash::BuildHasher;

    // Keep the existing 26-major-version window, now ending at Chrome 152.
    let random = RandomState::new().hash_one(());
    format!(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{}.0.{}.{} Safari/537.36",
        127 + random % 26,
        6000 + (random >> 8) % 1500,
        100 + (random >> 24) % 200
    )
}
