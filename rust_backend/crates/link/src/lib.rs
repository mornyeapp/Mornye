//! Mornye Link: the desktop app's HTTPS server for the phone app. It speaks
//! OpenSubsonic for the library (`/rest`), Mornye endpoints under
//! `/mornye/v1` forwarded to the app, song files sent by the phone, and a
//! WebSocket for pushes. The contract is
//! `docs/internal/desktop/LINK_CONTRACT.md`.
//!
//! Module owners: L1a `server`, `tls`, `store`, `auth`, `pairing`, `ws`,
//! `mdns`, `api`, `files`; L1b `catalog`, `subsonic`, `xml`, `media`.
//!
//! [`LinkServer`] owns its own Tokio runtime. Start and stop it from a plain
//! thread (the desktop worker pool), not from inside an async task.

pub mod catalog;
pub mod subsonic;
pub mod types;

mod api;
mod auth;
mod files;
mod mdns;
mod pairing;
mod server;
mod store;
mod tls;
mod ws;

pub use catalog::Catalog;
pub use files::received_dir;
pub use server::Tuning;
pub use types::{Device, Host, HostError, LinkConfig, Shared};

use crate::server::{State, TimedHost};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, PoisonError, RwLock};
use std::time::Duration;
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

/// Shown when the app passes no name.
const DEFAULT_NAME: &str = "Mornye";
/// Platform of keys minted for third-party Subsonic apps.
const SUBSONIC_PLATFORM: &str = "subsonic";

/// A running server. Dropping it stops it, like [`LinkServer::stop`].
pub struct LinkServer {
    state: Arc<State>,
    runtime: Option<tokio::runtime::Runtime>,
    advertiser: Option<mdns::Advertiser>,
    discovery_error: Option<String>,
}

impl LinkServer {
    /// Starts with the contract's timers on every interface, advertised over
    /// mDNS.
    pub fn start(config: LinkConfig, host: Arc<dyn Host>) -> Result<Self, String> {
        Self::start_with(config, host, Tuning::default())
    }

    /// Starts with custom timers and binding (tests).
    pub fn start_with(
        mut config: LinkConfig,
        host: Arc<dyn Host>,
        tuning: Tuning,
    ) -> Result<Self, String> {
        let name = config.name.trim();
        config.name = if name.is_empty() {
            DEFAULT_NAME.to_owned()
        } else {
            name.to_owned()
        };
        let store = store::Store::open(&config.state_dir)?;
        let identity = tls::load_or_create(&config.state_dir)?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("mornye-link")
            .enable_all()
            .build()
            .map_err(|error| format!("Cannot start the Mornye Link runtime: {error}"))?;
        let bound = {
            let _context = runtime.enter();
            server::bind(config.port, store.port(), tuning.bind).and_then(|listener| {
                let local = listener.local_addr().map_err(|error| error.to_string())?;
                store.set_server(local.port(), &config.name)?;
                Ok((listener, local))
            })
        };
        let (listener, local) = match bound {
            Ok(bound) => bound,
            Err(error) => {
                runtime.shutdown_background();
                return Err(error);
            }
        };
        config.port = local.port();
        let server_id = store.server_id();
        let shared = Arc::new(Shared {
            config,
            server_id,
            host: Arc::new(TimedHost {
                inner: host,
                timeout: tuning.request_timeout,
            }),
            catalog: RwLock::new(Arc::new(Catalog::empty())),
        });
        let state = Arc::new(State {
            shared,
            store,
            pairing: pairing::Pairing::new(tuning.pairing_ttl, tuning.pair_interval),
            clients: ws::Clients::default(),
            fingerprint: identity.fingerprint,
            local,
            tuning,
            shutdown: CancellationToken::new(),
            tasks: TaskTracker::new(),
            catalog_version: AtomicU64::new(0),
        });
        let acceptor = tokio_rustls::TlsAcceptor::from(identity.config);
        runtime.spawn(server::serve(Arc::clone(&state), listener, acceptor));
        let (advertiser, discovery_error) = if state.tuning.advertise {
            match mdns::advertise(
                state.name(),
                &state.shared.server_id,
                &state.fingerprint,
                local.port(),
            ) {
                Ok(advertiser) => (Some(advertiser), None),
                Err(error) => (None, Some(error)),
            }
        } else {
            (None, None)
        };
        Ok(Self {
            state,
            runtime: Some(runtime),
            advertiser,
            discovery_error,
        })
    }

    /// Stops accepting, closes WebSockets, withdraws the mDNS advertisement
    /// and shuts the runtime down, waiting a few seconds at most.
    pub fn stop(mut self) {
        self.shutdown();
    }

    pub fn port(&self) -> u16 {
        self.state.port()
    }

    pub fn fingerprint(&self) -> &str {
        &self.state.fingerprint
    }

    pub fn server_id(&self) -> &str {
        &self.state.shared.server_id
    }

    /// Why mDNS advertising is unavailable, when it is.
    pub fn discovery_error(&self) -> Option<&str> {
        self.discovery_error.as_deref()
    }

    /// The `linkStart` result:
    /// `{"port","fingerprint","serverId","name","addresses","receivedDir"}`,
    /// where `receivedDir` is the absolute folder of files sent by phones.
    pub fn summary(&self) -> Value {
        json!({
            "port": self.state.port(),
            "fingerprint": self.state.fingerprint,
            "serverId": self.state.shared.server_id,
            "name": self.state.name(),
            "addresses": self.state.addresses(),
            "receivedDir": received_dir(&self.state.shared.config.state_dir).to_string_lossy(),
        })
    }

    /// The `linkStatus` result while running.
    pub fn status(&self) -> Value {
        let mut status = self.summary();
        status["running"] = Value::Bool(true);
        status["clients"] = json!(self.state.clients.list());
        status
    }

    /// Loads the catalog export at `path`, swaps it in and pushes
    /// `catalog.changed` to every client. Returns `{"songs","version"}`.
    pub fn set_catalog(&self, path: &Path) -> Result<Value, String> {
        let catalog = Catalog::load(path)?;
        let songs = catalog.song_count();
        let version = {
            let mut current = self
                .state
                .shared
                .catalog
                .write()
                .unwrap_or_else(PoisonError::into_inner);
            *current = Arc::new(catalog);
            self.state.catalog_version.fetch_add(1, Ordering::SeqCst) + 1
        };
        let message = json!({"type": "catalog.changed", "version": version, "songs": songs});
        self.state.clients.send(None, &message.to_string());
        Ok(json!({"songs": songs, "version": version}))
    }

    /// Opens a pairing window: `{"pin","expiresMs","fingerprint"}`.
    /// `linkPairingEnded {"reason":"expired"}` follows if nobody pairs.
    pub fn begin_pairing(&self) -> Result<Value, String> {
        let opened = self.state.pairing.begin()?;
        if let Some(runtime) = &self.runtime {
            let state = Arc::clone(&self.state);
            let ttl = state.pairing.ttl();
            let generation = opened.generation;
            runtime.spawn(async move {
                tokio::select! {
                    _ = tokio::time::sleep(ttl) => {
                        if state.pairing.expire(generation) {
                            state.emit_pairing_ended(pairing::EXPIRED);
                        }
                    }
                    _ = state.shutdown.cancelled() => {}
                }
            });
        }
        Ok(json!({
            "pin": opened.pin,
            "expiresMs": opened.expires_ms,
            "fingerprint": self.state.fingerprint,
        }))
    }

    /// Closes the pairing window (`linkPairingEnded {"reason":"cancelled"}`
    /// when one was open).
    pub fn end_pairing(&self) {
        if self.state.pairing.end() {
            self.state.emit_pairing_ended(pairing::CANCELLED);
        }
    }

    /// `[{"deviceId","name","platform","pairedMs","lastSeenMs","connected"}]`.
    pub fn devices(&self) -> Value {
        let mut devices = self.state.store.devices();
        devices.sort_by_key(|device| device.paired_ms);
        Value::Array(
            devices
                .iter()
                .map(|device| device.to_json(self.state.clients.is_connected(&device.device_id)))
                .collect(),
        )
    }

    /// Forgets `device_id` and closes its WebSocket. Unknown devices are
    /// ignored.
    pub fn revoke(&self, device_id: &str) -> Result<(), String> {
        self.state.store.remove(device_id)?;
        if self
            .state
            .clients
            .close(device_id, ws::CLOSE_UNAUTHORIZED, "revoked")
        {
            self.state.emit_clients();
        }
        Ok(())
    }

    /// Mints a key for a third-party Subsonic app: `{"deviceId","apiKey"}`.
    pub fn create_key(&self, name: &str) -> Result<Value, String> {
        let name = Some(name.trim())
            .filter(|name| !name.is_empty())
            .unwrap_or("Subsonic app");
        let device_id = store::new_uuid()?;
        let record = self
            .state
            .store
            .upsert(&device_id, name, SUBSONIC_PLATFORM, false)?;
        Ok(json!({"deviceId": record.device_id, "apiKey": record.api_key}))
    }

    /// Pushes `message` to `device_id`, or to every client. Returns how many
    /// clients it was queued for.
    pub fn send(&self, device_id: Option<&str>, message: Value) -> usize {
        self.state.clients.send(device_id, &message.to_string())
    }

    fn shutdown(&mut self) {
        let Some(runtime) = self.runtime.take() else {
            return;
        };
        self.state.shutdown.cancel();
        self.state.clients.close_all();
        self.state.tasks.close();
        if let Some(advertiser) = self.advertiser.take() {
            advertiser.stop();
        }
        if tokio::runtime::Handle::try_current().is_ok() {
            // Blocking inside another runtime would panic.
            runtime.shutdown_background();
            return;
        }
        let tasks = self.state.tasks.clone();
        runtime.block_on(async move {
            let _ = tokio::time::timeout(Duration::from_secs(2), tasks.wait()).await;
        });
        runtime.shutdown_timeout(Duration::from_secs(1));
    }
}

impl Drop for LinkServer {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// `linkDevices` while the server is stopped: the stored devices, none
/// connected.
pub fn stored_devices(state_dir: &Path) -> Result<Value, String> {
    let mut devices = store::stored_devices(state_dir)?;
    devices.sort_by_key(|device| device.paired_ms);
    Ok(Value::Array(
        devices.iter().map(|device| device.to_json(false)).collect(),
    ))
}

/// `linkRevoke` while the server is stopped.
pub fn revoke_stored(state_dir: &Path, device_id: &str) -> Result<(), String> {
    store::revoke_stored(state_dir, device_id)
}
