//! SSDP as UPnP Device Architecture 1.1 section 1 defines it: M-SEARCH sent
//! from every Wi-Fi or Ethernet address, answered by unicast, and NOTIFY
//! alive and byebye heard on the multicast group. Searches leave from each
//! LAN address on purpose: the default route can be a VPN or mobile data,
//! which no renderer listens on.

use socket2::{Domain, Protocol, Socket, Type};
use std::collections::BTreeSet;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4};
use std::time::Duration;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub(crate) const GROUP: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::new(239, 255, 255, 250), 1900);
/// SSDP messages fit one datagram; longer ones are cut and read as far as
/// they go.
const MAX_DATAGRAM: usize = 4096;
/// Devices spread their answers over up to this many seconds.
const MX: u64 = 2;
/// UPnP asks for a multicast TTL of 2 by default.
const TTL: u32 = 2;
/// How long one search listens for answers.
pub(crate) const WINDOW: Duration = Duration::from_secs(MX + 2);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Announce {
    Alive,
    ByeBye,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Message {
    pub(crate) announce: Announce,
    /// `ST` of a search answer, `NT` of a notification.
    pub(crate) target: String,
    pub(crate) usn: String,
    pub(crate) location: Option<String>,
    pub(crate) max_age: Option<u64>,
    pub(crate) from: IpAddr,
}

impl Message {
    /// The device's UDN, the part of the USN before `::`.
    pub(crate) fn udn(&self) -> &str {
        self.usn.split("::").next().unwrap_or_default().trim()
    }
}

/// A search answer or a notification; `None` for anything else, such as
/// other control points' searches.
pub(crate) fn parse(datagram: &[u8], from: IpAddr) -> Option<Message> {
    let text = String::from_utf8_lossy(datagram);
    let mut lines = text.lines();
    let start = lines.next()?.trim();
    let notify = if start.eq_ignore_ascii_case("NOTIFY * HTTP/1.1") {
        true
    } else if start.starts_with("HTTP/1.") && start.split_whitespace().nth(1) == Some("200") {
        false
    } else {
        return None;
    };
    let mut message = Message {
        announce: Announce::Alive,
        target: String::new(),
        usn: String::new(),
        location: None,
        max_age: None,
        from,
    };
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        match name.trim().to_ascii_uppercase().as_str() {
            "ST" if !notify => message.target = value.into(),
            "NT" if notify => message.target = value.into(),
            "NTS" if notify && value.eq_ignore_ascii_case("ssdp:byebye") => {
                message.announce = Announce::ByeBye;
            }
            "USN" => message.usn = value.into(),
            "LOCATION" => message.location = Some(value.into()),
            "CACHE-CONTROL" => message.max_age = max_age(value),
            _ => {}
        }
    }
    (!message.usn.is_empty() && !message.target.is_empty()).then_some(message)
}

fn max_age(value: &str) -> Option<u64> {
    let lower = value.to_ascii_lowercase();
    let after = lower.split("max-age").nth(1)?.trim_start();
    let digits: String = after
        .strip_prefix('=')?
        .trim_start()
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    digits.parse().ok()
}

pub(crate) fn search_request(target: &str) -> String {
    format!(
        "M-SEARCH * HTTP/1.1\r\nHOST: {GROUP}\r\nMAN: \"ssdp:discover\"\r\nMX: {MX}\r\n\
         ST: {target}\r\nUSER-AGENT: {}/1.0 UPnP/1.1 Mornye/1.0\r\n\r\n",
        std::env::consts::OS
    )
}

/// The IPv4 addresses of this device's LAN interfaces: no loopback, no
/// point-to-point links (VPN tunnels), only private and link-local ranges.
pub(crate) fn lan_addresses() -> Vec<Ipv4Addr> {
    let interfaces = if_addrs::get_if_addrs().unwrap_or_default();
    let addresses: BTreeSet<Ipv4Addr> = interfaces
        .iter()
        .filter(|interface| !interface.is_loopback() && !interface.is_p2p())
        .filter_map(|interface| match &interface.addr {
            if_addrs::IfAddr::V4(address) => Some(address.ip),
            if_addrs::IfAddr::V6(_) => None,
        })
        .filter(|ip| ip.is_private() || ip.is_link_local())
        .collect();
    addresses.into_iter().collect()
}

fn udp(bind: SocketAddrV4, shared: bool) -> io::Result<UdpSocket> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    if shared {
        socket.set_reuse_address(true)?;
        #[cfg(unix)]
        socket.set_reuse_port(true)?;
    }
    socket.set_nonblocking(true)?;
    socket.bind(&SocketAddr::V4(bind).into())?;
    UdpSocket::from_std(socket.into())
}

/// Sends one search from each of `addresses` to `destination` (the group,
/// or a test's device) and passes on what answers within `window`.
pub(crate) async fn search(
    addresses: &[Ipv4Addr],
    destination: SocketAddrV4,
    target: &str,
    window: Duration,
    found: &mpsc::Sender<Message>,
) {
    let request = search_request(target);
    let mut sockets = Vec::new();
    for address in addresses {
        let Ok(socket) = udp(SocketAddrV4::new(*address, 0), false) else {
            continue;
        };
        if destination.ip().is_multicast() {
            let sock = socket2::SockRef::from(&socket);
            let _ = sock.set_multicast_if_v4(address);
            let _ = sock.set_multicast_ttl_v4(TTL);
        }
        sockets.push(socket);
    }
    let listen = sockets.iter().map(|socket| async {
        // UDP is lossy: the search goes out twice, as UPnP suggests.
        for attempt in 0..2 {
            if attempt > 0 {
                tokio::time::sleep(Duration::from_millis(300)).await;
            }
            let _ = socket.send_to(request.as_bytes(), destination).await;
        }
        receive(socket, found).await;
    });
    let _ = tokio::time::timeout(window, futures_util::future::join_all(listen)).await;
}

async fn receive(socket: &UdpSocket, found: &mpsc::Sender<Message>) {
    let mut buffer = vec![0u8; MAX_DATAGRAM];
    while let Ok((len, from)) = socket.recv_from(&mut buffer).await {
        if let Some(message) = parse(&buffer[..len], from.ip()) {
            // A full queue drops the message; the next search repeats it.
            let _ = found.try_send(message);
        }
    }
}

/// Hears notifications on the SSDP port until `stop`. Best effort: the port
/// can be taken, and some phones only pass multicast to apps that ask.
pub(crate) async fn listen(found: mpsc::Sender<Message>, stop: CancellationToken) {
    let Ok(socket) = udp(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, GROUP.port()), true) else {
        return;
    };
    let mut joined = BTreeSet::new();
    let mut rejoin = tokio::time::interval(Duration::from_secs(15));
    let mut buffer = vec![0u8; MAX_DATAGRAM];
    loop {
        tokio::select! {
            () = stop.cancelled() => return,
            _ = rejoin.tick() => {
                // Interfaces come and go with Wi-Fi; join the new ones.
                for address in lan_addresses() {
                    if !joined.contains(&address)
                        && socket.join_multicast_v4(*GROUP.ip(), address).is_ok()
                    {
                        joined.insert(address);
                    }
                }
            }
            received = socket.recv_from(&mut buffer) => {
                let Ok((len, from)) = received else { return };
                if let Some(message) = parse(&buffer[..len], from.ip()) {
                    let _ = found.try_send(message);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn from() -> IpAddr {
        "192.0.2.20".parse().unwrap()
    }

    #[test]
    fn search_answers_and_notifications_parse_with_any_header_case() {
        let answer = b"HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age = 1800\r\nEXT:\r\n\
            location: http://192.0.2.20:49152/description.xml\r\nSERVER: Linux UPnP/1.0\r\n\
            st: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\
            Usn: uuid:4d696e69-0001::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n";
        let message = parse(answer, from()).unwrap();
        assert_eq!(message.announce, Announce::Alive);
        assert_eq!(message.max_age, Some(1800));
        assert_eq!(message.udn(), "uuid:4d696e69-0001");
        assert_eq!(
            message.location.as_deref(),
            Some("http://192.0.2.20:49152/description.xml")
        );

        let bye = b"NOTIFY * HTTP/1.1\nHOST: 239.255.255.250:1900\nNT: urn:schemas-upnp-org:device:MediaRenderer:1\n\
            NTS: ssdp:byebye\nUSN: uuid:4d696e69-0001::urn:schemas-upnp-org:device:MediaRenderer:1\n\n";
        let message = parse(bye, from()).unwrap();
        assert_eq!(message.announce, Announce::ByeBye);
        assert_eq!(
            message.target,
            "urn:schemas-upnp-org:device:MediaRenderer:1"
        );

        let search = search_request("ssdp:all");
        assert!(
            parse(search.as_bytes(), from()).is_none(),
            "other searches are ignored"
        );
        assert!(parse(b"HTTP/1.1 404 Not Found\r\nUSN: x\r\nST: y\r\n\r\n", from()).is_none());
        assert!(parse(b"HTTP/1.1 200 OK\r\nST: y\r\n\r\n", from()).is_none());
        assert!(parse(&[0xff, 0xfe, b'\n'], from()).is_none());
    }

    #[test]
    fn searches_follow_the_upnp_format() {
        let request = search_request("urn:schemas-upnp-org:device:MediaRenderer:1");
        assert!(request.starts_with("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"));
        assert!(request.contains("MAN: \"ssdp:discover\"\r\nMX: 2\r\n"));
        assert!(request.ends_with("\r\n\r\n"));
    }

    #[tokio::test]
    async fn a_search_hears_unicast_answers() {
        let device = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let SocketAddr::V4(destination) = device.local_addr().unwrap() else {
            unreachable!()
        };
        tokio::spawn(async move {
            let mut buffer = [0u8; 1024];
            let (len, from) = device.recv_from(&mut buffer).await.unwrap();
            assert!(buffer[..len].starts_with(b"M-SEARCH"));
            let answer = "HTTP/1.1 200 OK\r\nST: urn:x\r\nUSN: uuid:a::urn:x\r\n\
                LOCATION: http://127.0.0.1:1/d.xml\r\n\r\n";
            device.send_to(answer.as_bytes(), from).await.unwrap();
        });
        let (found, mut messages) = mpsc::channel(8);
        let loopback = [Ipv4Addr::LOCALHOST];
        search(
            &loopback,
            destination,
            "urn:x",
            Duration::from_millis(500),
            &found,
        )
        .await;
        let message = messages.try_recv().unwrap();
        assert_eq!(
            (message.udn(), message.from),
            ("uuid:a", IpAddr::from(Ipv4Addr::LOCALHOST))
        );
    }
}
