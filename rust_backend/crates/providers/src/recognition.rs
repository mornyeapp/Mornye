//! Recognizes a song from microphone audio with Shazam's tagging endpoint.
//!
//! The endpoint is unofficial and may change or refuse requests at any time,
//! so every failure maps to a small set of kinds the app can explain. Only a
//! fingerprint of spectral peaks is sent (see `mornye_core::music_signature`).
//! Requests carry the device locale and time zone; no location is sent.

#[cfg(test)]
mod tests;

use mornye_core::music_signature::{
    SIGNATURE_SAMPLE_RATE, Signature, rms_dbfs, signature_from_pcm16,
};
use mornye_network::{HttpRequest, NetworkService, NetworkSession};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const ENDPOINT: &str = "https://amp.shazam.com/discovery/v5";
const QUERY: &str =
    "sync=true&webv3=true&sampling=true&connected=&shazamapiversion=v3&sharehub=true&video=v3";
/// The endpoint serves the Android client; a fixed, ordinary identity.
const USER_AGENT: &str = "Dalvik/2.1.0 (Linux; U; Android 14; Pixel 8 Build/AP2A.240905.003)";
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
/// The fingerprint needs about three seconds before it can match anything.
pub const MIN_SECONDS: usize = 3;
/// Quieter than this, the microphone heard a room rather than music.
pub const QUIET_DBFS: f64 = -60.0;
/// Fewer peaks than this cannot match; louder noise without tones ends here.
pub const MIN_PEAKS: usize = 24;
const POLL: Duration = Duration::from_millis(25);

pub type Check<'a> = dyn Fn() -> Result<(), String> + Sync + 'a;

/// The device locale for the path and `Content-Language`, or en/US when it
/// is not a plain language and region pair.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecognitionLocale {
    pub language: String,
    pub country: String,
}

impl RecognitionLocale {
    pub fn new(language: &str, country: &str) -> Self {
        let language = language.trim().to_ascii_lowercase();
        let country = country.trim().to_ascii_uppercase();
        let valid_language =
            (2..=3).contains(&language.len()) && language.bytes().all(|b| b.is_ascii_lowercase());
        let valid_country = country.len() == 2 && country.bytes().all(|b| b.is_ascii_uppercase());
        if valid_language && valid_country {
            Self { language, country }
        } else {
            Self {
                language: "en".into(),
                country: "US".into(),
            }
        }
    }

    pub fn content_language(&self) -> String {
        format!("{}-{}", self.language, self.country)
    }
}

/// An IANA zone name such as `Europe/Paris` or `Etc/GMT-7`, else `UTC`.
pub fn normalize_timezone(timezone: &str) -> String {
    let timezone = timezone.trim();
    let valid = !timezone.is_empty()
        && timezone.len() <= 64
        && timezone.as_bytes()[0].is_ascii_alphabetic()
        && timezone
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"/_+-".contains(&b));
    if valid { timezone.into() } else { "UTC".into() }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct RecognizedSong {
    pub key: String,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub cover_url: Option<String>,
    pub release: Option<String>,
    pub genre: Option<String>,
    pub label: Option<String>,
    pub isrc: Option<String>,
    pub web_url: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecognitionOutcome {
    Match(Box<RecognizedSong>),
    NoMatch,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum RecognitionError {
    #[error("recognition rate limited")]
    RateLimited,
    #[error("recognition unavailable: {0}")]
    Unavailable(String),
    #[error("recognition network error: {0}")]
    Network(String),
    #[error("{0}")]
    Cancelled(String),
}

impl RecognitionError {
    /// The stable name Flutter switches on; never shown to people.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::RateLimited => "rate_limited",
            Self::Unavailable(_) => "unavailable",
            Self::Network(_) => "network",
            Self::Cancelled(_) => "cancelled",
        }
    }
}

/// Why captured audio was not sent.
#[derive(Debug, PartialEq)]
pub enum Prepared {
    Ready(Signature),
    TooShort,
    Quiet,
}

/// Fingerprints captured 16 kHz mono audio unless it is too short or too
/// quiet to be worth a request.
pub fn prepare(samples: &[i16], check: &Check<'_>) -> Result<Prepared, String> {
    if samples.len() < MIN_SECONDS * SIGNATURE_SAMPLE_RATE {
        return Ok(Prepared::TooShort);
    }
    if rms_dbfs(samples) < QUIET_DBFS {
        return Ok(Prepared::Quiet);
    }
    let signature = signature_from_pcm16(samples, check)?;
    if signature.peak_count() < MIN_PEAKS {
        return Ok(Prepared::Quiet);
    }
    Ok(Prepared::Ready(signature))
}

pub fn request_url(locale: &RecognitionLocale, first_id: &str, second_id: &str) -> String {
    format!(
        "{ENDPOINT}/{}/{}/android/-/tag/{first_id}/{second_id}?{QUERY}",
        locale.language, locale.country
    )
}

pub fn request_body(signature: &Signature, timezone: &str, timestamp_ms: u64) -> String {
    json!({
        "signature": {
            "samplems": signature.sample_ms(),
            "timestamp": timestamp_ms,
            "uri": signature.data_uri(),
        },
        "timestamp": timestamp_ms,
        "timezone": timezone,
    })
    .to_string()
}

pub fn request_headers(locale: &RecognitionLocale) -> BTreeMap<String, String> {
    BTreeMap::from([
        ("Content-Type".into(), "application/json".into()),
        ("Content-Language".into(), locale.content_language()),
    ])
}

/// Maps a finished response. A 404 or a body without a track means the
/// service heard nothing it knows; lyrics are never read.
pub fn parse_response(status: u16, body: &[u8]) -> Result<RecognitionOutcome, RecognitionError> {
    match status {
        404 => return Ok(RecognitionOutcome::NoMatch),
        429 => return Err(RecognitionError::RateLimited),
        200..=299 => {}
        _ => return Err(RecognitionError::Unavailable(format!("status {status}"))),
    }
    let value: Value = serde_json::from_slice(body)
        .map_err(|_| RecognitionError::Unavailable("invalid response".into()))?;
    let Some(track) = value.get("track").filter(|track| track.is_object()) else {
        return Ok(RecognitionOutcome::NoMatch);
    };
    let (Some(title), Some(artist)) = (text(track, &["title"]), text(track, &["subtitle"])) else {
        return Ok(RecognitionOutcome::NoMatch);
    };
    let details = SongDetails::read(track);
    Ok(RecognitionOutcome::Match(Box::new(RecognizedSong {
        key: text(track, &["key"]).unwrap_or_default(),
        title,
        artist,
        album: details.album,
        cover_url: web_link(track, &["images", "coverarthq"])
            .or_else(|| web_link(track, &["images", "coverart"])),
        release: details.release.or_else(|| text(track, &["releasedate"])),
        genre: text(track, &["genres", "primary"]),
        label: details.label,
        isrc: text(track, &["isrc"]).map(|isrc| isrc.to_ascii_uppercase()),
        web_url: web_link(track, &["url"]).or_else(|| web_link(track, &["share", "href"])),
    })))
}

/// Album, label and release from the song section. Its titles follow the
/// request language ("Released" reads "Veröffentlicht:" in German), so an
/// unknown title falls back to the section's order: album, label, year.
struct SongDetails {
    album: Option<String>,
    label: Option<String>,
    release: Option<String>,
}

impl SongDetails {
    fn read(track: &Value) -> Self {
        let entries: Vec<(String, String)> = track
            .get("sections")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|section| section.get("type").and_then(Value::as_str) == Some("SONG"))
            .filter_map(|section| section.get("metadata")?.as_array())
            .flatten()
            .filter_map(|entry| Some((text(entry, &["title"])?, text(entry, &["text"])?)))
            .collect();
        let named = |name: &str| {
            entries
                .iter()
                .find(|(title, _)| title.trim_end_matches(':').eq_ignore_ascii_case(name))
                .map(|(_, value)| value.clone())
        };
        let release = named("Released").or_else(|| {
            entries
                .iter()
                .rev()
                .map(|(_, value)| value)
                .find(|value| looks_like_release(value))
                .cloned()
        });
        let others: Vec<&String> = entries
            .iter()
            .map(|(_, value)| value)
            .filter(|value| Some(*value) != release.as_ref())
            .collect();
        let positional = others.len() == 2;
        Self {
            album: named("Album").or_else(|| positional.then(|| others[0].clone())),
            label: named("Label").or_else(|| positional.then(|| others[1].clone())),
            release,
        }
    }
}

/// A year, or a date that starts with one.
fn looks_like_release(value: &str) -> bool {
    value.len() <= 10
        && value
            .get(..4)
            .and_then(|year| year.parse::<u16>().ok())
            .is_some_and(|year| (1900..=2100).contains(&year))
        && value[4..].bytes().all(|b| b.is_ascii_digit() || b == b'-')
}

fn text(value: &Value, path: &[&str]) -> Option<String> {
    let found = path
        .iter()
        .try_fold(value, |value, key| value.get(key))?
        .as_str()?
        .trim();
    (!found.is_empty()).then(|| found.to_owned())
}

fn web_link(value: &Value, path: &[&str]) -> Option<String> {
    text(value, path).filter(|link| link.starts_with("https://") || link.starts_with("http://"))
}

/// One POST; returns the status and body, or a transport failure.
pub trait Transport {
    fn post(
        &self,
        url: &str,
        headers: BTreeMap<String, String>,
        body: String,
        check: &Check<'_>,
    ) -> Result<(u16, Vec<u8>), String>;
}

pub struct NetworkTransport {
    session: Arc<NetworkSession>,
}

impl NetworkTransport {
    pub fn new(network: &Arc<NetworkService>) -> Self {
        Self {
            session: network.native_session(REQUEST_TIMEOUT),
        }
    }
}

impl Transport for NetworkTransport {
    fn post(
        &self,
        url: &str,
        headers: BTreeMap<String, String>,
        body: String,
        check: &Check<'_>,
    ) -> Result<(u16, Vec<u8>), String> {
        let response = self.session.request(
            HttpRequest {
                url: url.into(),
                method: "POST".into(),
                body,
                headers,
                default_json: false,
                user_agent: USER_AGENT.into(),
            },
            check,
        )?;
        Ok((response.status, response.body))
    }
}

/// How one recognition retries: a single retry after a rate limit, a
/// server error, or a connection failure that happened quickly. A request
/// that timed out is not repeated.
#[derive(Clone, Debug)]
pub struct RetryPolicy {
    pub rate_limit_delay: Duration,
    pub retry_delay: Duration,
    pub quick_failure: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            rate_limit_delay: Duration::from_secs(2),
            retry_delay: Duration::from_secs(1),
            quick_failure: Duration::from_secs(5),
        }
    }
}

pub struct Recognizer<'a> {
    pub transport: &'a dyn Transport,
    pub policy: RetryPolicy,
    /// Fresh request IDs, two per attempt.
    pub new_id: fn() -> String,
    pub now_ms: fn() -> u64,
}

impl<'a> Recognizer<'a> {
    pub fn new(transport: &'a dyn Transport) -> Self {
        Self {
            transport,
            policy: RetryPolicy::default(),
            new_id: uuid,
            now_ms: unix_ms,
        }
    }

    pub fn recognize(
        &self,
        signature: &Signature,
        locale: &RecognitionLocale,
        timezone: &str,
        check: &Check<'_>,
    ) -> Result<RecognitionOutcome, RecognitionError> {
        let timezone = normalize_timezone(timezone);
        let mut attempt = 0;
        loop {
            check().map_err(RecognitionError::Cancelled)?;
            let url = request_url(locale, &(self.new_id)(), &(self.new_id)());
            let body = request_body(signature, &timezone, (self.now_ms)());
            let started = Instant::now();
            let failure = match self
                .transport
                .post(&url, request_headers(locale), body, check)
            {
                Ok((status, body)) => match parse_response(status, &body) {
                    Ok(outcome) => return Ok(outcome),
                    Err(error) => {
                        let delay = match (&error, status) {
                            (RecognitionError::RateLimited, _) => self.policy.rate_limit_delay,
                            (_, 500..=599) => self.policy.retry_delay,
                            _ => return Err(error),
                        };
                        (error, delay)
                    }
                },
                Err(message) => {
                    check().map_err(RecognitionError::Cancelled)?;
                    let error = RecognitionError::Network(message);
                    if started.elapsed() >= self.policy.quick_failure {
                        return Err(error);
                    }
                    (error, self.policy.retry_delay)
                }
            };
            if attempt == 1 {
                return Err(failure.0);
            }
            attempt += 1;
            wait(failure.1, check)?;
        }
    }
}

fn wait(delay: Duration, check: &Check<'_>) -> Result<(), RecognitionError> {
    let started = Instant::now();
    while started.elapsed() < delay {
        check().map_err(RecognitionError::Cancelled)?;
        std::thread::sleep(delay.saturating_sub(started.elapsed()).min(POLL));
    }
    check().map_err(RecognitionError::Cancelled)
}

/// A random RFC 4122 version 4 UUID in upper case.
pub fn uuid() -> String {
    let mut bytes = [0u8; 16];
    if getrandom::fill(&mut bytes).is_err() {
        // Request IDs only need to differ between requests.
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        bytes = nanos.to_le_bytes();
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02X}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
