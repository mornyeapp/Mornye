//! mDNS browses: Google Cast receivers (`_googlecast._tcp`, TXT `id` is a
//! stable device id, `fn` the name the owner gave it, `md` the model) and
//! FCast receivers (`_fcast._tcp`, named by their instance name).

use crate::discovery::{Device, Kind, Registry};
use mdns_sd::{IfKind, ResolvedService, ServiceDaemon, ServiceEvent};
use std::collections::BTreeMap;
use std::net::IpAddr;
use std::time::Duration;

pub(crate) struct Service {
    ty: &'static str,
    /// The device a resolved instance stands for, `None` to skip it.
    parse: fn(&ResolvedService) -> Option<Device>,
}

pub(crate) const GOOGLE_CAST: Service = Service {
    ty: "_googlecast._tcp.local.",
    parse: google_cast,
};

pub(crate) const FCAST: Service = Service {
    ty: "_fcast._tcp.local.",
    parse: crate::fcast::device,
};

/// A running browse; dropping it stops the mDNS daemon.
pub(crate) struct Browse {
    daemon: ServiceDaemon,
    ty: &'static str,
}

impl Browse {
    pub(crate) fn start(service: &Service, registry: Registry) -> Result<Self, String> {
        let fail = |error: mdns_sd::Error| format!("Device discovery failed: {error}");
        let daemon = ServiceDaemon::new().map_err(fail)?;
        // Receivers answer on IPv4; link-local IPv6 answers only add
        // addresses a sender cannot always route to.
        let _ = daemon.disable_interface(vec![IfKind::IPv6, IfKind::LoopbackV4]);
        let events = match daemon.browse(service.ty) {
            Ok(events) => events,
            Err(error) => {
                let _ = daemon.shutdown();
                return Err(fail(error));
            }
        };
        let parse = service.parse;
        let spawned = std::thread::Builder::new()
            .name("mornye-cast-discovery".into())
            .spawn(move || {
                // Fullname to device id, for removals that carry only the name.
                let mut names = BTreeMap::<String, String>::new();
                while let Ok(event) = events.recv() {
                    match event {
                        ServiceEvent::ServiceResolved(service) => {
                            if let Some(device) = parse(&service) {
                                names.insert(service.fullname.clone(), device.id.clone());
                                registry.upsert(device);
                            }
                        }
                        ServiceEvent::ServiceRemoved(_, fullname) => {
                            if let Some(id) = names.remove(&fullname) {
                                registry.remove(&id);
                            }
                        }
                        ServiceEvent::SearchStopped(_) => break,
                        _ => {}
                    }
                }
            });
        if let Err(error) = spawned {
            let _ = daemon.shutdown();
            return Err(format!("Device discovery failed: {error}"));
        }
        Ok(Self {
            daemon,
            ty: service.ty,
        })
    }
}

impl Drop for Browse {
    fn drop(&mut self) {
        let _ = self.daemon.stop_browse(self.ty);
        if let Ok(done) = self.daemon.shutdown() {
            let _ = done.recv_timeout(Duration::from_millis(250));
        }
    }
}

pub(crate) fn txt(service: &ResolvedService, key: &str) -> String {
    service
        .txt_properties
        .get_property_val_str(key)
        .unwrap_or_default()
        .to_owned()
}

pub(crate) fn ipv4(service: &ResolvedService) -> Option<IpAddr> {
    service
        .addresses
        .iter()
        .map(|address| address.to_ip_addr())
        .find(IpAddr::is_ipv4)
}

/// The instance label of `name.<service type>`.
pub(crate) fn instance(service: &ResolvedService) -> &str {
    service
        .fullname
        .strip_suffix(service.ty_domain.as_str())
        .map_or(service.fullname.as_str(), |name| name.trim_end_matches('.'))
}

fn google_cast(service: &ResolvedService) -> Option<Device> {
    let host = ipv4(service)?;
    let id = Some(txt(service, "id")).filter(|id| !id.is_empty())?;
    let name = Some(txt(service, "fn"))
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| instance(service).to_owned());
    Some(Device::new(
        Kind::Cast,
        &id,
        &name,
        &txt(service, "md"),
        host,
        service.port,
    ))
}
