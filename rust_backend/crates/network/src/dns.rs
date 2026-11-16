use crate::policy::is_private_ip;
use bytes::Bytes;
use futures_util::future::BoxFuture;
use hickory_proto::op::{Message, MessageType, OpCode, Query, ResponseCode};
use hickory_proto::rr::{Name, RData, RecordType};
use http_body_util::{BodyExt, Full};
use hyper_rustls::{HttpsConnector, HttpsConnectorBuilder};
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::{HttpConnector, dns};
use hyper_util::rt::{TokioExecutor, TokioTimer};
use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use tower_service::Service;

pub type LookupFuture = BoxFuture<'static, io::Result<Vec<IpAddr>>>;

/// Trusted platform resolver injection. JavaScript cannot supply DNS answers.
pub trait Lookup: Send + Sync {
    fn lookup(&self, hostname: &str) -> LookupFuture;
}

pub struct SystemLookup;

impl Lookup for SystemLookup {
    fn lookup(&self, hostname: &str) -> LookupFuture {
        let hostname = hostname.to_owned();
        Box::pin(async move {
            Ok(tokio::net::lookup_host((hostname, 0))
                .await?
                .map(|address| address.ip())
                .collect())
        })
    }
}

type DohClient = Client<HttpsConnector<HttpConnector>, Full<Bytes>>;

/// How long a host the system resolver failed for, and DoH answered, uses
/// its cached DoH answer without asking the system resolver. Short, so a
/// recovered network is used again quickly.
const SYSTEM_FAILURE_TTL: Duration = Duration::from_secs(15);

struct Cached {
    addresses: Vec<IpAddr>,
    expires: Instant,
}

pub(crate) struct Dns {
    lookup: Arc<dyn Lookup>,
    doh: DohClient,
    upstreams: Vec<http::Uri>,
    cache: Mutex<HashMap<String, Cached>>,
    system_failures: Mutex<HashMap<String, Instant>>,
}

impl Dns {
    pub(crate) async fn has_private_address(&self, hostname: &str) -> bool {
        self.lookup
            .lookup(hostname)
            .await
            .is_ok_and(|addresses| addresses.into_iter().any(is_private_ip))
    }

    pub(crate) fn new(
        tls: rustls::ClientConfig,
        lookup: Arc<dyn Lookup>,
        upstreams: &[String],
    ) -> io::Result<Self> {
        let upstreams = upstreams
            .iter()
            .map(|url| {
                let uri = url.parse::<http::Uri>().map_err(io::Error::other)?;
                // Literal HTTPS endpoints avoid recursively resolving the resolver.
                if uri.scheme_str() != Some("https")
                    || uri
                        .host()
                        .and_then(|host| host.trim_matches(['[', ']']).parse::<IpAddr>().ok())
                        .is_none()
                {
                    return Err(io::Error::other(
                        "DoH upstream must use HTTPS and an IP literal",
                    ));
                }
                Ok(uri)
            })
            .collect::<io::Result<Vec<_>>>()?;
        let mut http = HttpConnector::new();
        http.enforce_http(false);
        http.set_connect_timeout(Some(Duration::from_secs(5)));
        http.set_nodelay(true);
        let connector = HttpsConnectorBuilder::new()
            .with_tls_config(tls)
            .https_only()
            .enable_http1()
            .enable_http2()
            .wrap_connector(http);
        let doh = Client::builder(TokioExecutor::new())
            .pool_timer(TokioTimer::new())
            .pool_idle_timeout(Duration::from_secs(60))
            .pool_max_idle_per_host(2)
            .build(connector);
        Ok(Self {
            lookup,
            doh,
            upstreams,
            cache: Mutex::default(),
            system_failures: Mutex::default(),
        })
    }

    pub(crate) async fn resolve(
        &self,
        host: &str,
        allow_private: bool,
    ) -> io::Result<Vec<SocketAddr>> {
        let key = host.to_lowercase();
        let recent_failure = self
            .system_failures
            .lock()
            .expect("system DNS failure lock")
            .get(&key)
            .is_some_and(|expires| Instant::now() < *expires);
        // Only a still-valid DoH answer replaces the system resolver; anything
        // else goes to the system resolver first, as without the window.
        let skipped = recent_failure
            .then(|| {
                self.cache
                    .lock()
                    .expect("DNS cache lock")
                    .get(&key)
                    .filter(|entry| Instant::now() < entry.expires && !entry.addresses.is_empty())
                    .map(|entry| entry.addresses.clone())
            })
            .flatten();
        let addresses = match skipped {
            Some(addresses) => addresses,
            None => match self.lookup.lookup(host).await {
                Ok(addresses) => addresses,
                Err(original) => {
                    if self.upstreams.is_empty() {
                        return Err(original);
                    }
                    let addresses = self.fallback(host).await?;
                    let mut failures = self
                        .system_failures
                        .lock()
                        .expect("system DNS failure lock");
                    if failures.len() >= 256 {
                        failures.retain(|_, expires| Instant::now() < *expires);
                        if failures.len() >= 256 {
                            failures.clear();
                        }
                    }
                    failures.insert(key, Instant::now() + SYSTEM_FAILURE_TTL);
                    addresses
                }
            },
        };
        let addresses: Vec<_> = addresses
            .into_iter()
            .filter(|address| allow_private || !is_private_ip(*address))
            .map(|address| SocketAddr::new(address, 0))
            .collect();
        if addresses.is_empty() {
            return Err(io::Error::other(format!(
                "network access denied: no permitted DNS addresses for '{host}'"
            )));
        }
        Ok(addresses)
    }

    async fn fallback(&self, host: &str) -> io::Result<Vec<IpAddr>> {
        let key = host.to_lowercase();
        if let Some(entry) = self
            .cache
            .lock()
            .expect("DNS cache lock")
            .get(&key)
            .filter(|entry| Instant::now() < entry.expires)
        {
            return if entry.addresses.is_empty() {
                Err(io::Error::other("cached DNS lookup failure"))
            } else {
                Ok(entry.addresses.clone())
            };
        }
        let mut result = Err(io::Error::other("DNS-over-HTTPS lookup failed"));
        for upstream in &self.upstreams {
            result = self.query(upstream, host, RecordType::A).await;
            if matches!(&result, Ok((addresses, _)) if addresses.is_empty()) {
                result = self.query(upstream, host, RecordType::AAAA).await;
            }
            if matches!(&result, Ok((addresses, _)) if !addresses.is_empty()) {
                break;
            }
        }
        let (addresses, seconds) = match &result {
            Ok((addresses, ttl)) if !addresses.is_empty() => {
                (addresses.clone(), u64::from((*ttl).clamp(60, 1800)))
            }
            _ => (Vec::new(), 30),
        };
        let mut cache = self.cache.lock().expect("DNS cache lock");
        if cache.len() >= 256 {
            cache.retain(|_, entry| Instant::now() < entry.expires);
            if cache.len() >= 256 {
                cache.clear();
            }
        }
        cache.insert(
            key,
            Cached {
                addresses: addresses.clone(),
                expires: Instant::now() + Duration::from_secs(seconds),
            },
        );
        if addresses.is_empty() {
            Err(io::Error::other("DNS-over-HTTPS returned no addresses"))
        } else {
            Ok(addresses)
        }
    }

    async fn query(
        &self,
        upstream: &http::Uri,
        host: &str,
        kind: RecordType,
    ) -> io::Result<(Vec<IpAddr>, u32)> {
        let mut message = Message::new(0, MessageType::Query, OpCode::Query);
        message.metadata.recursion_desired = true;
        message.queries.push(Query::query(
            Name::from_ascii(host).map_err(io::Error::other)?,
            kind,
        ));
        let request = http::Request::post(upstream.clone())
            .header("Content-Type", "application/dns-message")
            .header("Accept", "application/dns-message")
            .body(Full::new(Bytes::from(
                message.to_vec().map_err(io::Error::other)?,
            )))
            .map_err(io::Error::other)?;
        tokio::time::timeout(Duration::from_secs(10), async {
            let response = self.doh.request(request).await.map_err(io::Error::other)?;
            if !response.status().is_success() {
                return Err(io::Error::other("DoH HTTP failure"));
            }
            let mut body = http_body_util::Limited::new(response.into_body(), 65536);
            let mut bytes = Vec::new();
            while let Some(frame) = body.frame().await {
                if let Ok(data) = frame.map_err(io::Error::other)?.into_data() {
                    bytes.extend_from_slice(&data);
                }
            }
            let response = Message::from_vec(&bytes).map_err(io::Error::other)?;
            if response.metadata.response_code != ResponseCode::NoError
                || response.metadata.message_type != MessageType::Response
            {
                return Err(io::Error::other("DoH DNS failure"));
            }
            let mut addresses = Vec::new();
            let mut ttl = u32::MAX;
            for record in response.answers {
                let address = match record.data {
                    RData::A(address) => IpAddr::V4(address.0),
                    RData::AAAA(address) => IpAddr::V6(address.0),
                    _ => continue,
                };
                addresses.push(address);
                ttl = ttl.min(record.ttl);
            }
            Ok((addresses, ttl))
        })
        .await
        .map_err(io::Error::other)?
    }
}

#[derive(Clone)]
pub(crate) struct Resolver {
    pub dns: Arc<Dns>,
    pub allow_private: bool,
}

impl Service<dns::Name> for Resolver {
    type Response = std::vec::IntoIter<SocketAddr>;
    type Error = io::Error;
    type Future = BoxFuture<'static, io::Result<Self::Response>>;

    fn poll_ready(&mut self, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, name: dns::Name) -> Self::Future {
        let resolver = self.clone();
        Box::pin(async move {
            Ok(resolver
                .dns
                .resolve(name.as_str(), resolver.allow_private)
                .await?
                .into_iter())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    /// A system resolver that fails until it is marked recovered.
    #[derive(Default)]
    struct System {
        calls: AtomicUsize,
        recovered: AtomicBool,
    }

    impl Lookup for System {
        fn lookup(&self, _: &str) -> LookupFuture {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let recovered = self.recovered.load(Ordering::SeqCst);
            Box::pin(async move {
                if recovered {
                    Ok(vec![SYSTEM_ADDRESS])
                } else {
                    Err(io::Error::other("system DNS failure"))
                }
            })
        }
    }

    const HOST: &str = "blocked.example.com";
    const ADDRESS: IpAddr = IpAddr::V4(std::net::Ipv4Addr::new(93, 184, 216, 34));
    const SYSTEM_ADDRESS: IpAddr = IpAddr::V4(std::net::Ipv4Addr::new(93, 184, 216, 35));

    /// A resolver whose DoH answer for `HOST` is already cached, so no test
    /// reaches the network.
    fn dns(doh: Vec<IpAddr>) -> (Arc<System>, Dns) {
        let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_root_certificates(rustls::RootCertStore::empty())
        .with_no_client_auth();
        let lookup = Arc::new(System::default());
        let dns = Dns::new(tls, lookup.clone(), &["https://192.0.2.1/dns-query".into()]).unwrap();
        dns.cache.lock().unwrap().insert(
            HOST.into(),
            Cached {
                addresses: doh,
                expires: Instant::now() + Duration::from_secs(60),
            },
        );
        (lookup, dns)
    }

    #[tokio::test]
    async fn a_host_the_system_resolver_failed_for_goes_straight_to_doh() {
        let (lookup, dns) = dns(vec![ADDRESS]);
        for _ in 0..3 {
            let addresses = dns.resolve(HOST, false).await.unwrap();
            assert_eq!(addresses, vec![SocketAddr::new(ADDRESS, 0)]);
        }
        assert_eq!(lookup.calls.load(Ordering::SeqCst), 1);
        // Once the short window ends, the system resolver is asked again.
        *dns.system_failures.lock().unwrap().get_mut(HOST).unwrap() = Instant::now();
        dns.resolve(HOST, false).await.unwrap();
        assert_eq!(lookup.calls.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn a_failure_doh_cannot_answer_keeps_asking_the_system_resolver() {
        let (lookup, dns) = dns(Vec::new());
        for _ in 0..3 {
            assert!(dns.resolve(HOST, false).await.is_err());
        }
        assert_eq!(lookup.calls.load(Ordering::SeqCst), 3);
        assert!(dns.system_failures.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn an_expired_doh_answer_inside_the_window_asks_the_system_resolver_first() {
        let (lookup, dns) = dns(vec![ADDRESS]);
        dns.resolve(HOST, false).await.unwrap();
        dns.cache.lock().unwrap().get_mut(HOST).unwrap().expires = Instant::now();
        lookup.recovered.store(true, Ordering::SeqCst);
        // Asking DoH first would wait for the unreachable upstream.
        let addresses = tokio::time::timeout(Duration::from_secs(1), dns.resolve(HOST, false))
            .await
            .expect("system resolver asked before DoH")
            .unwrap();
        assert_eq!(addresses, vec![SocketAddr::new(SYSTEM_ADDRESS, 0)]);
        assert_eq!(lookup.calls.load(Ordering::SeqCst), 2);
    }
}
