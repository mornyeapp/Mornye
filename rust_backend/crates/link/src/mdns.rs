//! Discovery (contract section 2): advertises `_mornye._tcp.local.` with the
//! server name as the instance name and TXT `v=1`, `id=<serverId>`,
//! `fp=<fingerprint>` on every interface. Advertising is best effort; the
//! server works without it when the phone knows the address.

use mdns_sd::{ServiceDaemon, ServiceInfo};
use std::time::Duration;

const SERVICE_TYPE: &str = "_mornye._tcp.local.";

pub(crate) struct Advertiser {
    daemon: ServiceDaemon,
    fullname: String,
}

/// Starts advertising; the error explains why discovery is unavailable.
pub(crate) fn advertise(
    name: &str,
    server_id: &str,
    fingerprint: &str,
    port: u16,
) -> Result<Advertiser, String> {
    let fail = |error: mdns_sd::Error| format!("mDNS advertising failed: {error}");
    let daemon = ServiceDaemon::new().map_err(fail)?;
    let short_id: String = server_id
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(8)
        .collect();
    let host = format!("mornye-{short_id}.local.");
    let properties = [("v", "1"), ("id", server_id), ("fp", fingerprint)];
    let info = ServiceInfo::new(SERVICE_TYPE, name, &host, (), port, &properties[..])
        .map_err(fail)?
        .enable_addr_auto();
    let fullname = info.get_fullname().to_owned();
    if let Err(error) = daemon.register(info) {
        let _ = daemon.shutdown();
        return Err(fail(error));
    }
    Ok(Advertiser { daemon, fullname })
}

impl Advertiser {
    /// Sends the goodbye announcement and stops the daemon thread.
    pub(crate) fn stop(self) {
        if let Ok(receiver) = self.daemon.unregister(&self.fullname) {
            let _ = receiver.recv_timeout(Duration::from_secs(1));
        }
        if let Ok(receiver) = self.daemon.shutdown() {
            let _ = receiver.recv_timeout(Duration::from_secs(1));
        }
    }
}
