//! Finds receivers advertising `_googlecast._tcp.local.` on the local
//! network. TXT records carry `id` (a stable device id), `fn` (the name the
//! owner gave it) and `md` (the model).

use mdns_sd::{IfKind, ServiceDaemon, ServiceEvent};
use serde::Serialize;
use std::collections::BTreeMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

const SERVICE_TYPE: &str = "_googlecast._tcp.local.";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub model: String,
    pub host: IpAddr,
    pub port: u16,
}

type Devices = Arc<Mutex<BTreeMap<String, Device>>>;

/// A running browse; dropping it stops the mDNS daemon.
pub(crate) struct Discovery {
    daemon: ServiceDaemon,
}

impl Discovery {
    /// Browses until dropped, calling `changed` with every device list
    /// change. `devices` keeps the latest list.
    pub(crate) fn start(
        devices: Devices,
        changed: impl Fn(Vec<Device>) + Send + 'static,
    ) -> Result<Self, String> {
        let fail = |error: mdns_sd::Error| format!("Cast discovery failed: {error}");
        let daemon = ServiceDaemon::new().map_err(fail)?;
        // Receivers answer on IPv4; link-local IPv6 answers only add
        // addresses a sender cannot always route to.
        let _ = daemon.disable_interface(vec![IfKind::IPv6, IfKind::LoopbackV4]);
        let events = match daemon.browse(SERVICE_TYPE) {
            Ok(events) => events,
            Err(error) => {
                let _ = daemon.shutdown();
                return Err(fail(error));
            }
        };
        std::thread::Builder::new()
            .name("mornye-cast-discovery".into())
            .spawn(move || {
                // Fullname to device id, for removals that carry only the name.
                let mut names = BTreeMap::<String, String>::new();
                while let Ok(event) = events.recv() {
                    let update = match event {
                        ServiceEvent::ServiceResolved(service) => {
                            let txt = |key: &str| {
                                service
                                    .txt_properties
                                    .get_property_val_str(key)
                                    .unwrap_or_default()
                                    .to_owned()
                            };
                            let host = service
                                .addresses
                                .iter()
                                .map(|address| address.to_ip_addr())
                                .find(IpAddr::is_ipv4);
                            let id = txt("id");
                            match host {
                                Some(host) if !id.is_empty() => {
                                    let name = Some(txt("fn"))
                                        .filter(|name| !name.is_empty())
                                        .unwrap_or_else(|| {
                                            service
                                                .fullname
                                                .split("._googlecast")
                                                .next()
                                                .unwrap_or_default()
                                                .to_owned()
                                        });
                                    names.insert(service.fullname.clone(), id.clone());
                                    let device = Device {
                                        id: id.clone(),
                                        name,
                                        model: txt("md"),
                                        host,
                                        port: service.port,
                                    };
                                    let mut list = devices.lock().expect("cast devices");
                                    (list.get(&id) != Some(&device))
                                        .then(|| list.insert(id, device))
                                        .is_some()
                                }
                                _ => false,
                            }
                        }
                        ServiceEvent::ServiceRemoved(_, fullname) => {
                            names.remove(&fullname).is_some_and(|id| {
                                devices.lock().expect("cast devices").remove(&id).is_some()
                            })
                        }
                        ServiceEvent::SearchStopped(_) => break,
                        _ => false,
                    };
                    if update {
                        changed(
                            devices
                                .lock()
                                .expect("cast devices")
                                .values()
                                .cloned()
                                .collect(),
                        );
                    }
                }
            })
            .map_err(|error| format!("Cast discovery failed: {error}"))?;
        Ok(Self { daemon })
    }
}

impl Drop for Discovery {
    fn drop(&mut self) {
        let _ = self.daemon.stop_browse(SERVICE_TYPE);
        if let Ok(done) = self.daemon.shutdown() {
            let _ = done.recv_timeout(Duration::from_secs(1));
        }
    }
}
