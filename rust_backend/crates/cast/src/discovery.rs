//! The receivers on the local network, of every kind the app asked for. Each
//! kind browses on its own (mDNS for Google Cast and FCast, SSDP for DLNA)
//! into one shared list, and one kind failing to start leaves the others.

use crate::{dlna, mdns};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use tokio::runtime::Handle;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Cast,
    Dlna,
    Fcast,
    Roku,
}

impl Kind {
    pub(crate) const ALL: [Self; 4] = [Self::Cast, Self::Dlna, Self::Fcast, Self::Roku];

    pub(crate) fn parse(name: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|kind| kind.name().eq_ignore_ascii_case(name))
    }

    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Cast => "cast",
            Self::Dlna => "dlna",
            Self::Fcast => "fcast",
            Self::Roku => "roku",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Device {
    /// Google Cast ids as the receiver gives them; other kinds are prefixed
    /// with their kind (`dlna:<UDN>`, `fcast:<name>`).
    pub id: String,
    pub name: String,
    pub model: String,
    pub host: IpAddr,
    pub port: u16,
    pub kind: Kind,
    /// Where a DLNA renderer's description lives.
    #[serde(skip)]
    pub(crate) location: Option<String>,
}

impl Device {
    pub(crate) fn new(
        kind: Kind,
        id: &str,
        name: &str,
        model: &str,
        host: IpAddr,
        port: u16,
    ) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            model: model.into(),
            host,
            port,
            kind,
            location: None,
        }
    }
}

type Devices = Arc<Mutex<BTreeMap<String, Device>>>;
type Changed = Arc<dyn Fn(Vec<Device>) + Send + Sync>;

/// The shared device list and the app's change callback.
#[derive(Clone)]
pub(crate) struct Registry {
    devices: Devices,
    changed: Changed,
}

impl Registry {
    pub(crate) fn new(
        devices: Devices,
        changed: impl Fn(Vec<Device>) + Send + Sync + 'static,
    ) -> Self {
        Self {
            devices,
            changed: Arc::new(changed),
        }
    }

    pub(crate) fn upsert(&self, device: Device) {
        let changed = {
            let mut list = self.devices.lock().expect("cast devices");
            (list.get(&device.id) != Some(&device))
                .then(|| list.insert(device.id.clone(), device))
                .is_some()
        };
        if changed {
            self.notify();
        }
    }

    pub(crate) fn remove(&self, id: &str) {
        let removed = self
            .devices
            .lock()
            .expect("cast devices")
            .remove(id)
            .is_some();
        if removed {
            self.notify();
        }
    }

    pub(crate) fn retain(&self, keep: impl Fn(&Device) -> bool) {
        let removed = {
            let mut list = self.devices.lock().expect("cast devices");
            let before = list.len();
            list.retain(|_, device| keep(device));
            list.len() != before
        };
        if removed {
            self.notify();
        }
    }

    fn notify(&self) {
        let list = self
            .devices
            .lock()
            .expect("cast devices")
            .values()
            .cloned()
            .collect();
        (self.changed)(list);
    }
}

/// The running browses; dropping one stops it.
pub(crate) struct Discovery {
    registry: Registry,
    running: BTreeMap<Kind, Box<dyn Send>>,
}

impl Discovery {
    pub(crate) fn new(registry: Registry) -> Self {
        Self {
            registry,
            running: BTreeMap::new(),
        }
    }

    /// Browses for exactly `kinds`. Fails only when nothing could start.
    pub(crate) fn set(&mut self, kinds: &BTreeSet<Kind>, runtime: &Handle) -> Result<(), String> {
        self.running.retain(|kind, _| kinds.contains(kind));
        self.registry.retain(|device| kinds.contains(&device.kind));
        let mut failures = Vec::new();
        for &kind in kinds {
            if self.running.contains_key(&kind) {
                continue;
            }
            let registry = self.registry.clone();
            let started: Result<Box<dyn Send>, String> = match kind {
                Kind::Cast => mdns::Browse::start(&mdns::GOOGLE_CAST, registry).map(boxed),
                Kind::Fcast => mdns::Browse::start(&mdns::FCAST, registry).map(boxed),
                Kind::Dlna => dlna::Browse::start(runtime, registry).map(boxed),
                // Roku documents no way for another device to play a URL.
                Kind::Roku => continue,
            };
            match started {
                Ok(browse) => {
                    self.running.insert(kind, browse);
                }
                Err(error) => failures.push(error),
            }
        }
        match failures.into_iter().next() {
            Some(error) if self.running.is_empty() => Err(error),
            _ => Ok(()),
        }
    }
}

fn boxed(browse: impl Send + 'static) -> Box<dyn Send> {
    Box::new(browse)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_have_the_contract_names() {
        assert_eq!(Kind::parse("DLNA"), Some(Kind::Dlna));
        assert_eq!(Kind::parse("airplay"), None);
        let device = Device::new(
            Kind::Fcast,
            "fcast:Den",
            "Den",
            "FCast",
            "192.0.2.4".parse().unwrap(),
            46899,
        );
        assert_eq!(
            serde_json::to_value(&device).unwrap(),
            serde_json::json!({"id": "fcast:Den", "name": "Den", "model": "FCast",
                "host": "192.0.2.4", "port": 46899, "kind": "fcast"})
        );
        // Google Cast devices say their kind too.
        let cast = Device::new(Kind::Cast, "abc", "Hall", "", device.host, 8009);
        assert_eq!(serde_json::to_value(&cast).unwrap()["kind"], "cast");
    }

    #[test]
    fn the_registry_tells_the_app_only_about_changes() {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let seen = Arc::clone(&calls);
        let registry = Registry::new(Arc::default(), move |list: Vec<Device>| {
            seen.lock().unwrap().push(list.len());
        });
        let host = "192.0.2.4".parse().unwrap();
        let device = Device::new(Kind::Dlna, "dlna:uuid:1", "Den", "", host, 80);
        registry.upsert(device.clone());
        registry.upsert(device);
        registry.upsert(Device::new(Kind::Cast, "c1", "Hall", "", host, 8009));
        registry.retain(|device| device.kind == Kind::Cast);
        registry.remove("missing");
        assert_eq!(*calls.lock().unwrap(), [1, 2, 1]);
    }
}
