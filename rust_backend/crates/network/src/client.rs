//! HTTP client service with connection pooling, network options, and bounded response handling.

mod headers;
mod pool;
mod stream;
#[cfg(test)]
mod tests;

pub use stream::HttpStream;

use crate::cookies::CookieJar;
use crate::dns::{Dns, Lookup, Resolver, SystemLookup};
use crate::policy::{GrantedOrigin, NetworkPermissions, private_literal_or_local};
use crate::url::UrlParts;
use async_compression::tokio::bufread::GzipDecoder;
use bytes::Bytes;
use futures_util::{TryStreamExt, future::BoxFuture};
use http::{HeaderMap, HeaderName, HeaderValue, Method, Request, Uri, header};
use http_body_util::{BodyExt, Full};
use hyper_rustls::{HttpsConnector, HttpsConnectorBuilder};
use hyper_util::client::legacy::{Client, connect::HttpConnector};
use hyper_util::rt::{TokioExecutor, TokioTimer};
use serde::Deserialize;
use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock, Weak};
use std::task::{Context, Poll, Wake, Waker};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncReadExt, BufReader};
use tokio::runtime::{Builder, Runtime};
use tokio::sync::{Notify, OwnedSemaphorePermit, Semaphore};
use tokio_util::io::StreamReader;
use tower_service::Service;

use headers::{canonical_header, forward_sensitive_headers, update_explicit_cookies};
use pool::Pool;
use stream::ResponseBody;

pub const MAX_RESPONSE_BYTES: usize = 16 << 20;
type Transport = HttpsConnector<HttpConnector<Resolver>>;
type BoxError = Box<dyn std::error::Error + Send + Sync>;
// `hyper` is not a direct dependency; name its response through the client.
type HyperResponse =
    <Client<pool::Connector, Full<Bytes>> as Service<Request<Full<Bytes>>>>::Response;

/// These options belong to the native backend, never to extension JavaScript.
pub struct NetworkOptions {
    pub extra_root_pem: Vec<u8>,
    pub lookup: Arc<dyn Lookup>,
    pub doh_upstreams: Vec<String>,
}

impl Default for NetworkOptions {
    fn default() -> Self {
        Self {
            extra_root_pem: Vec::new(),
            lookup: Arc::new(SystemLookup),
            doh_upstreams: vec![
                "https://1.1.1.1/dns-query".into(),
                "https://8.8.8.8/dns-query".into(),
            ],
        }
    }
}

/// A shared pool and resolver with bounded executor threads. Sessions isolate
/// cookies and permissions while reusing TCP/TLS connections across extensions.
pub struct NetworkService {
    runtime: Option<Runtime>,
    tls: rustls::ClientConfig,
    dns: Arc<Dns>,
    pool: Mutex<Arc<Pool>>,
    generation: AtomicU64,
    checks: Arc<CheckWake>,
}

#[derive(Default)]
struct CheckWake(Notify);

impl Wake for CheckWake {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.0.notify_waiters();
    }
}

impl NetworkService {
    fn run<T>(
        &self,
        generation: u64,
        timeout: Duration,
        check: impl Fn() -> Result<(), String>,
        operation: impl Future<Output = Result<T, String>>,
    ) -> Result<T, String> {
        check()?;
        if tokio::runtime::Handle::try_current().is_ok() {
            return Err("blocking HTTP host called from async executor".into());
        }
        self.runtime
            .as_ref()
            .expect("network runtime")
            .block_on(async {
                tokio::pin!(operation);
                let timeout = tokio::time::sleep(timeout);
                tokio::pin!(timeout);
                // The first check runs below; an immediate first tick would
                // only repeat it before the operation is polled.
                let period = Duration::from_millis(10);
                let mut heartbeat =
                    tokio::time::interval_at(tokio::time::Instant::now() + period, period);
                loop {
                    // Create before checking: notify_waiters also reaches a Notified
                    // future that has not been polled yet, closing the lost-wake gap.
                    let changed = self.checks.0.notified();
                    check()?;
                    if self.generation.load(Ordering::Acquire) != generation {
                        return Err("network policy changed".into());
                    }
                    tokio::select! {
                        biased;
                        _ = changed => {}
                        _ = heartbeat.tick() => {}
                        _ = &mut timeout => return Err("HTTP request timeout exceeded".into()),
                        result = &mut operation => { check()?; return result; }
                    }
                }
            })
    }

    /// Recheck active HTTP calls when the owner's cancellation state changes.
    /// Waking does not itself cancel anything or retain the network runtime.
    pub fn cancellation_waker(&self) -> Waker {
        Waker::from(Arc::clone(&self.checks))
    }

    pub fn new() -> io::Result<Arc<Self>> {
        Self::with_options(NetworkOptions::default())
    }

    pub fn with_options(options: NetworkOptions) -> io::Result<Arc<Self>> {
        let roots = rustls_pemfile::certs(&mut options.extra_root_pem.as_slice())
            .collect::<Result<Vec<_>, _>>()?;
        if !options.extra_root_pem.is_empty() && roots.is_empty() {
            return Err(io::Error::other("no certificates in extra root PEM"));
        }
        let tls = crate::tls::configuration(&roots)?;
        let runtime = Builder::new_multi_thread()
            .worker_threads(2)
            .max_blocking_threads(16)
            .thread_name("extension-network")
            .enable_all()
            .build()?;
        let (dns, pool) = {
            let _entered = runtime.enter();
            let dns = Arc::new(Dns::new(
                tls.clone(),
                options.lookup,
                &options.doh_upstreams,
            )?);
            let pool = Arc::new(Pool::new(tls.clone(), Arc::clone(&dns), false, false));
            (dns, pool)
        };
        Ok(Arc::new(Self {
            runtime: Some(runtime),
            tls,
            dns,
            pool: Mutex::new(pool),
            generation: AtomicU64::new(0),
            checks: Arc::default(),
        }))
    }

    /// Called only for the app's explicit private-network preference. Replacing
    /// the pool prevents old private connections surviving a policy change.
    pub fn set_allow_private_network(&self, allow: bool) {
        let mut pool = self.pool.lock().expect("HTTP pool lock");
        if pool.allow_private == allow {
            return;
        }
        let _entered = self.runtime.as_ref().expect("network runtime").enter();
        *pool = Arc::new(Pool::new(
            self.tls.clone(),
            Arc::clone(&self.dns),
            allow,
            pool.allow_http_fallback,
        ));
        self.generation.fetch_add(1, Ordering::AcqRel);
        drop(pool);
        self.checks.0.notify_waiters();
    }

    /// Native compatibility requests may retry HTTPS over HTTP. Extension
    /// sessions retain their manifest policy. TLS verification is never disabled.
    pub fn set_network_compatibility_options(&self, allow_http: bool) {
        let mut pool = self.pool.lock().expect("HTTP pool lock");
        if pool.allow_http_fallback == allow_http {
            return;
        }
        let _entered = self.runtime.as_ref().expect("network runtime").enter();
        *pool = Arc::new(Pool::new(
            self.tls.clone(),
            Arc::clone(&self.dns),
            pool.allow_private,
            allow_http,
        ));
        // As with Go's transport update, active requests retain their options.
        // In particular this must not cancel unrelated extension downloads.
    }

    pub fn reset_connections(&self) {
        let mut pool = self.pool.lock().expect("HTTP pool lock");
        let _entered = self.runtime.as_ref().expect("network runtime").enter();
        *pool = Arc::new(Pool::new(
            self.tls.clone(),
            Arc::clone(&self.dns),
            pool.allow_private,
            pool.allow_http_fallback,
        ));
        // Existing requests retain their pool; a reconnect is not a policy
        // change and must not cancel unrelated in-flight downloads.
    }

    pub fn session(
        self: &Arc<Self>,
        permissions: NetworkPermissions,
        timeout: Duration,
    ) -> Arc<NetworkSession> {
        Arc::new(NetworkSession {
            service: Arc::clone(self),
            permissions: Some(permissions),
            native_media: false,
            follow_redirects: true,
            timeout,
            cookies: Mutex::default(),
            grants: Arc::default(),
        })
    }

    /// App-owned HTTPS requests, such as the extension registry. This is never
    /// exposed to JavaScript; extension sessions always retain their allowlist.
    pub fn native_session(self: &Arc<Self>, timeout: Duration) -> Arc<NetworkSession> {
        Arc::new(NetworkSession {
            service: Arc::clone(self),
            permissions: None,
            native_media: false,
            follow_redirects: true,
            timeout,
            cookies: Mutex::default(),
            grants: Arc::default(),
        })
    }

    /// Provider artwork uses explicit HTTP or HTTPS URLs and no cookie jar,
    /// matching the native media client. DNS/private-network policy and the
    /// connection pool are still shared. Never exposed to extension JavaScript.
    pub fn native_media_session(self: &Arc<Self>, timeout: Duration) -> Arc<NetworkSession> {
        Arc::new(NetworkSession {
            service: Arc::clone(self),
            permissions: None,
            native_media: true,
            follow_redirects: true,
            timeout,
            cookies: Mutex::default(),
            grants: Arc::default(),
        })
    }
}

impl Drop for NetworkService {
    fn drop(&mut self) {
        // libc DNS calls cannot be interrupted. Futures are cancelled promptly;
        // do not make native teardown wait for a stalled OS resolver thread.
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown_background();
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct HttpRequest {
    pub url: String,
    #[serde(default)]
    pub method: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    #[serde(default)]
    pub default_json: bool,
    #[serde(default = "default_user_agent")]
    pub user_agent: String,
}

fn default_user_agent() -> String {
    "Mornye-Extension/1.0".to_owned()
}

#[derive(Debug)]
pub struct HttpResponse {
    pub status: u16,
    pub status_text: String,
    pub url: String,
    pub headers: BTreeMap<String, Vec<String>>,
    pub body: Vec<u8>,
}

pub struct NetworkSession {
    service: Arc<NetworkService>,
    permissions: Option<NetworkPermissions>,
    native_media: bool,
    follow_redirects: bool,
    timeout: Duration,
    cookies: Mutex<CookieJar>,
    /// Shared with `direct_media` copies so a settings change reaches them.
    grants: Arc<RwLock<Vec<GrantedOrigin>>>,
}

impl NetworkSession {
    /// Replaces the hosts granted by the extension's `grantsNetwork` settings.
    pub fn set_grants(&self, grants: Vec<GrantedOrigin>) {
        *self.grants.write().expect("network grants lock") = grants;
    }

    /// Account-owned media must not carry metadata cookies or follow a redirect
    /// outside its descriptor. Keep the original manifest/DNS/TLS permissions.
    pub fn direct_media(&self) -> Self {
        Self {
            service: Arc::clone(&self.service),
            permissions: self.permissions.clone(),
            native_media: true,
            follow_redirects: false,
            timeout: self.timeout,
            cookies: Mutex::default(),
            grants: Arc::clone(&self.grants),
        }
    }

    pub fn reset_connections(&self) {
        self.service.reset_connections();
    }

    /// Browser authorization endpoints need HTTPS and private-address checks,
    /// but may use an identity provider outside the extension API allowlist.
    pub fn validate_auth_url(
        &self,
        input: &str,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<UrlParts, String> {
        check()?;
        let url = UrlParts::parse(input).ok_or_else(|| "invalid auth URL".to_owned())?;
        if url.scheme != "https" {
            return Err("invalid auth URL: only https is allowed".into());
        }
        if url.hostname.is_empty() {
            return Err("invalid auth URL: hostname is required".into());
        }
        if url.has_credentials {
            return Err("invalid auth URL: embedded credentials are not allowed".into());
        }
        let (allow, generation) = {
            let pool = self.service.pool.lock().expect("HTTP pool lock");
            (
                pool.allow_private,
                self.service.generation.load(Ordering::Acquire),
            )
        };
        if !allow {
            let uri = url.request_uri()?;
            let private = private_literal_or_local(&url.hostname)
                || uri.host().is_some_and(private_literal_or_local);
            let private = private
                || self.service.run(generation, self.timeout, check, async {
                    Ok(self.service.dns.has_private_address(&url.hostname).await)
                })?;
            if private {
                return Err("invalid auth URL: private/local network is not allowed".into());
            }
        }
        Ok(url)
    }

    pub fn clear_cookies(&self) {
        self.cookies.lock().expect("cookie jar lock").clear();
    }

    pub fn validate_url(&self, url: &str) -> Result<(), String> {
        let allow = self
            .service
            .pool
            .lock()
            .expect("HTTP pool lock")
            .allow_private;
        self.validate_target(url, allow, false).map(|_| ())
    }

    fn validate_target(
        &self,
        input: &str,
        allow_private: bool,
        redirect: bool,
    ) -> Result<UrlParts, String> {
        if let Some(permissions) = &self.permissions {
            let grants = self.grants.read().expect("network grants lock");
            return permissions.validate_with_grants(input, allow_private, redirect, &grants);
        }
        let url = UrlParts::parse(input).ok_or_else(|| "invalid URL".to_owned())?;
        NetworkPermissions {
            domains: vec![url.hostname],
            allow_http: self.native_media,
        }
        .validate(input, allow_private, redirect)
    }

    /// Blocking host call, run from the dedicated JS worker or a native worker.
    /// The heartbeat observes cancellation while DNS, TLS, headers or body wait.
    pub fn request(
        &self,
        request: HttpRequest,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<HttpResponse, String> {
        check()?;
        if tokio::runtime::Handle::try_current().is_ok() {
            return Err("blocking HTTP host called from async executor".into());
        }
        let (pool, generation) = {
            let pool = self.service.pool.lock().expect("HTTP pool lock");
            (
                Arc::clone(&pool),
                self.service.generation.load(Ordering::Acquire),
            )
        };
        self.service.run(
            generation,
            self.timeout,
            check,
            self.execute(request, &pool),
        )
    }

    /// Streaming downloads share DNS, TLS, cookies, redirects and connection
    /// limits with API requests, but preserve identity content encoding and use
    /// the native transfer's wall-clock/stall limits rather than API timeout.
    pub fn open_stream(
        &self,
        request: HttpRequest,
        timeout: Duration,
        stall_timeout: Duration,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<HttpStream, String> {
        self.open_stream_with_encoding(request, timeout, stall_timeout, false, &check)
    }

    /// API-style gzip decoding with pull-based reads. The caller enforces its
    /// own decoded-body size limit without raising the buffered API limit.
    pub fn open_response_stream(
        &self,
        request: HttpRequest,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<HttpStream, String> {
        self.open_stream_with_encoding(request, self.timeout, self.timeout, true, &check)
    }

    fn open_stream_with_encoding(
        &self,
        request: HttpRequest,
        timeout: Duration,
        stall_timeout: Duration,
        compression: bool,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<HttpStream, String> {
        let started = Instant::now();
        let (pool, generation) = {
            let pool = self.service.pool.lock().expect("HTTP pool lock");
            (
                Arc::clone(&pool),
                self.service.generation.load(Ordering::Acquire),
            )
        };
        let (response, body) = self.service.run(
            generation,
            timeout.min(stall_timeout),
            check,
            self.execute_stream(request, &pool, compression),
        )?;
        Ok(HttpStream {
            response,
            body: Some(body),
            service: Arc::clone(&self.service),
            _pool: pool,
            generation,
            started,
            last_progress: started,
            timeout,
            stall_timeout,
            failure: None,
        })
    }

    async fn execute(&self, request: HttpRequest, pool: &Pool) -> Result<HttpResponse, String> {
        let (mut response, body) = self.execute_stream(request, pool, true).await?;
        body.reader
            .take((MAX_RESPONSE_BYTES + 1) as u64)
            .read_to_end(&mut response.body)
            .await
            .map_err(|error| error.to_string())?;
        if response.body.len() > MAX_RESPONSE_BYTES {
            return Err(format!(
                "response body exceeds {MAX_RESPONSE_BYTES} byte limit; use file.download for large media"
            ));
        }
        Ok(response)
    }

    async fn execute_stream(
        &self,
        request: HttpRequest,
        pool: &Pool,
        compression: bool,
    ) -> Result<(HttpResponse, ResponseBody), String> {
        let PreparedRequest {
            mut url,
            original,
            mut method,
            mut body,
            mut headers,
            explicit_referer,
        } = self.prepare_request(request, pool)?;
        for redirects in 0..10 {
            let uri = url.request_uri()?;
            let permit = pool.acquire(&uri).await;
            let (outgoing, gzip) = self.outgoing_headers(&headers, &url, &method, compression)?;
            let (permit, response, response_url) = self
                .send(pool, &url, uri, &method, &body, permit, outgoing)
                .await?;
            if !self.native_media {
                self.cookies
                    .lock()
                    .expect("cookie jar lock")
                    .store(&url, response.headers());
            }
            let status = response.status();
            if !self.follow_redirects && matches!(status.as_u16(), 301 | 302 | 303 | 307 | 308) {
                return Err("media redirect blocked: request a fresh descriptor".into());
            }
            if matches!(status.as_u16(), 301 | 302 | 303 | 307 | 308)
                && let Some(location) = response
                    .headers()
                    .get(header::LOCATION)
                    .filter(|value| !value.is_empty())
            {
                let target = self.redirect_target(&url, location, pool)?;
                if redirects < 9 {
                    update_explicit_cookies(&mut headers, response.headers());
                    if matches!(status.as_u16(), 301..=303) {
                        if method != Method::GET && method != Method::HEAD {
                            method = Method::GET;
                        }
                        body = Bytes::new();
                        for name in [
                            header::CONTENT_ENCODING,
                            header::CONTENT_LANGUAGE,
                            header::CONTENT_LOCATION,
                            header::CONTENT_TYPE,
                        ] {
                            headers.remove(name);
                        }
                    }
                    if !forward_sensitive_headers(&original.hostname, &target.hostname) {
                        for name in [
                            header::AUTHORIZATION,
                            header::WWW_AUTHENTICATE,
                            header::COOKIE,
                            header::PROXY_AUTHORIZATION,
                            header::PROXY_AUTHENTICATE,
                        ] {
                            headers.remove(name);
                        }
                        headers.remove("cookie2");
                    }
                    if url.scheme == "https" && target.scheme == "http" {
                        headers.remove(header::REFERER);
                    } else if let Some(value) = &explicit_referer {
                        headers.insert(header::REFERER, value.clone());
                    } else if let Ok(value) = url.display_url().parse() {
                        headers.insert(header::REFERER, value);
                    }
                    url = target;
                    release_redirect_body(response).await;
                    continue;
                }
            }
            let (response_headers, small_http1, reader) = response_reader(response, gzip);
            let headers = canonical_headers(&response_headers);
            return Ok((
                HttpResponse {
                    status: status.as_u16(),
                    status_text: status.canonical_reason().unwrap_or("").into(),
                    url: response_url.display_url(),
                    headers,
                    body: Vec::new(),
                },
                ResponseBody {
                    reader,
                    small_http1,
                    _permit: permit,
                },
            ));
        }
        unreachable!("last redirect returns its response")
    }

    fn prepare_request(
        &self,
        request: HttpRequest,
        pool: &Pool,
    ) -> Result<PreparedRequest, String> {
        let url = self.validate_target(&request.url, pool.allow_private, false)?;
        let original = url.clone();
        let method = Method::from_bytes(if request.method.is_empty() {
            b"GET"
        } else {
            request.method.as_bytes()
        })
        .map_err(|_| format!("net/http: invalid method {:?}", request.method))?;
        let body = Bytes::from(request.body);
        let mut headers = HeaderMap::new();
        for (name, value) in request.headers {
            let name =
                HeaderName::from_bytes(name.as_bytes()).map_err(|error| error.to_string())?;
            if name == header::HOST
                || name == header::CONTENT_LENGTH
                || name == header::TRANSFER_ENCODING
            {
                continue;
            }
            headers.insert(
                name,
                HeaderValue::from_str(&value).map_err(|error| error.to_string())?,
            );
        }
        if headers
            .get(header::USER_AGENT)
            .is_none_or(|value| value.is_empty())
        {
            headers.insert(
                header::USER_AGENT,
                request
                    .user_agent
                    .parse()
                    .map_err(|error: http::header::InvalidHeaderValue| error.to_string())?,
            );
        }
        if request.default_json
            && headers
                .get(header::CONTENT_TYPE)
                .is_none_or(|value| value.is_empty())
        {
            headers.insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("application/json"),
            );
        }
        let explicit_referer = headers
            .get(header::REFERER)
            .filter(|value| !value.is_empty())
            .cloned();
        Ok(PreparedRequest {
            url,
            original,
            method,
            body,
            headers,
            explicit_referer,
        })
    }

    /// Per-attempt headers: the session cookie jar and, for API-style
    /// requests, gzip negotiation. The returned flag records that negotiation.
    fn outgoing_headers(
        &self,
        headers: &HeaderMap,
        url: &UrlParts,
        method: &Method,
        compression: bool,
    ) -> Result<(HeaderMap, bool), String> {
        let mut outgoing = headers.clone();
        let cookies = if self.native_media {
            String::new()
        } else {
            self.cookies.lock().expect("cookie jar lock").header(url)
        };
        if !cookies.is_empty() {
            let value = outgoing
                .get(header::COOKIE)
                .and_then(|value| value.to_str().ok())
                .filter(|value| !value.is_empty())
                .map_or_else(|| cookies.clone(), |value| format!("{value}; {cookies}"));
            outgoing.insert(
                header::COOKIE,
                value
                    .parse()
                    .map_err(|error: http::header::InvalidHeaderValue| error.to_string())?,
            );
        }
        let gzip = compression
            && outgoing
                .get(header::ACCEPT_ENCODING)
                .is_none_or(|value| value.is_empty())
            && outgoing
                .get(header::RANGE)
                .is_none_or(|value| value.is_empty())
            && method != Method::HEAD;
        if gzip {
            outgoing.insert(header::ACCEPT_ENCODING, HeaderValue::from_static("gzip"));
        }
        Ok((outgoing, gzip))
    }

    /// Send one attempt. A native session with the compatibility fallback
    /// retries a failed HTTPS attempt once over HTTP, on a fresh origin permit.
    /// Returns the permit held for the response and the URL it came from.
    #[allow(clippy::too_many_arguments)]
    async fn send(
        &self,
        pool: &Pool,
        url: &UrlParts,
        uri: Uri,
        method: &Method,
        body: &Bytes,
        mut permit: OwnedSemaphorePermit,
        outgoing: HeaderMap,
    ) -> Result<(OwnedSemaphorePermit, HyperResponse, UrlParts), String> {
        let mut req = Request::builder()
            .method(method.clone())
            .uri(uri)
            .body(Full::new(body.clone()))
            .map_err(|error| error.to_string())?;
        *req.headers_mut() = outgoing.clone();
        let response = tokio::time::timeout(Duration::from_secs(45), pool.client.request(req))
            .await
            .map_err(|_| "HTTP response header timeout exceeded".to_owned())
            .and_then(|result| result.map_err(|error| error_chain(&error)));
        let mut response_url = url.clone();
        // Nonempty bodies are buffered and can be replayed, as Go's GetBody
        // permits. Treat an empty body like a nil Go request body.
        let can_replay = matches!(
            *method,
            Method::GET | Method::HEAD | Method::OPTIONS | Method::DELETE
        ) || !body.is_empty();
        let response = match response {
            Err(_)
                if pool.allow_http_fallback
                    && self.permissions.is_none()
                    && url.scheme == "https"
                    && can_replay =>
            {
                response_url.scheme = "http".into();
                let uri = response_url.request_uri()?;
                // The hostname is unchanged; the shared connector still
                // resolves and checks every destination against private-IP policy.
                drop(permit);
                permit = pool.acquire(&uri).await;
                let mut retry = Request::builder()
                    .method(method.clone())
                    .uri(uri)
                    .body(Full::new(body.clone()))
                    .map_err(|error| error.to_string())?;
                *retry.headers_mut() = outgoing;
                tokio::time::timeout(Duration::from_secs(45), pool.client.request(retry))
                    .await
                    .map_err(|_| "HTTP response header timeout exceeded".to_owned())?
                    .map_err(|error| error_chain(&error))?
            }
            result => result?,
        };
        Ok((permit, response, response_url))
    }

    fn redirect_target(
        &self,
        url: &UrlParts,
        location: &HeaderValue,
        pool: &Pool,
    ) -> Result<UrlParts, String> {
        let location = location.to_str().map_err(|error| error.to_string())?;
        let target = url
            .resolve(location)
            .ok_or_else(|| "invalid redirect URL".to_owned())?;
        if target.has_credentials {
            return Err("invalid URL: embedded credentials are not allowed".into());
        }
        self.validate_target(&target.display_url(), pool.allow_private, true)?;
        Ok(target)
    }
}

/// Request state that `execute_stream` carries and rewrites across redirects.
struct PreparedRequest {
    url: UrlParts,
    original: UrlParts,
    method: Method,
    body: Bytes,
    headers: HeaderMap,
    explicit_referer: Option<HeaderValue>,
}

async fn release_redirect_body(response: HyperResponse) {
    // A small HTTP/1.1 redirect body can return this connection
    // to the pool. Never wait for an unbounded/slow body or drain
    // HTTP/2 streams, whose connections are already multiplexed.
    if response.version() == http::Version::HTTP_11
        && response
            .headers()
            .get(header::CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<usize>().ok())
            .is_some_and(|length| length <= 2048)
    {
        let mut body = response.into_body();
        let _ = tokio::time::timeout(Duration::from_millis(20), async {
            let mut received = 0;
            while let Some(Ok(frame)) = body.frame().await {
                received += frame.data_ref().map_or(0, Bytes::len);
                if received > 2048 {
                    break;
                }
            }
        })
        .await;
    }
}

/// Response headers, the `HttpStream::discard` eligibility flag and the body
/// reader, gzip-decoded when this attempt negotiated gzip.
fn response_reader(
    response: HyperResponse,
    gzip: bool,
) -> (HeaderMap, bool, Box<dyn AsyncRead + Unpin + Send>) {
    let mut response_headers = response.headers().clone();
    let decompress = gzip
        && response_headers
            .get(header::CONTENT_ENCODING)
            .is_some_and(|value| value.as_bytes().eq_ignore_ascii_case(b"gzip"));
    // Same bound as redirect bodies: only an uncompressed HTTP/1.1
    // body of at most 2 KiB may be finished by `HttpStream::discard`.
    let small_http1 = !decompress
        && response.version() == http::Version::HTTP_11
        && response_headers
            .get(header::CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<usize>().ok())
            .is_some_and(|length| length <= 2048);
    let stream = response
        .into_body()
        .into_data_stream()
        .map_err(io::Error::other);
    let reader = StreamReader::new(stream);
    let reader: Box<dyn AsyncRead + Unpin + Send> = if decompress {
        response_headers.remove(header::CONTENT_ENCODING);
        response_headers.remove(header::CONTENT_LENGTH);
        let mut decoder = GzipDecoder::new(BufReader::new(reader));
        decoder.multiple_members(true);
        Box::new(decoder)
    } else {
        Box::new(reader)
    };
    (response_headers, small_http1, reader)
}

fn canonical_headers(response_headers: &HeaderMap) -> BTreeMap<String, Vec<String>> {
    let mut headers = BTreeMap::new();
    for name in response_headers.keys() {
        headers.insert(
            canonical_header(name.as_str()),
            response_headers
                .get_all(name)
                .iter()
                .map(|value| String::from_utf8_lossy(value.as_bytes()).into_owned())
                .collect(),
        );
    }
    headers
}

fn error_chain(error: &dyn std::error::Error) -> String {
    let mut message = error.to_string();
    if let Some(source) = error.source() {
        message.push_str(": ");
        message.push_str(&error_chain(source));
    }
    message
}
