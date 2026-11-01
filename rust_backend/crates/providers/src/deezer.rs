//! Deezer metadata used by native lookups, browsing and platform resolution.

mod browse;
mod cache;
mod extended;

use crate::resolver::{Check, ResolverError, http::ResolverHttp};
use mornye_core::{
    lyrics,
    metadata::{
        TrackMetadata,
        deezer::{Track, Tracks},
    },
};
use mornye_network::NetworkService;
use serde::de::DeserializeOwned;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

pub trait MetadataLookup: Send + Sync + 'static {
    /// Observe `check` during HTTP calls and retry waits so native shutdown can
    /// wait for outstanding metadata requests to release their resources.
    fn search_by_isrc(&self, isrc: &str, check: &Check<'_>)
    -> Result<TrackMetadata, ResolverError>;
}

pub struct DeezerClient {
    http: ResolverHttp,
    language: Mutex<String>,
    cache: Mutex<cache::Cache>,
    flights: Mutex<BTreeMap<String, Arc<cache::Flight>>>,
}

impl DeezerClient {
    pub fn new(network: &Arc<NetworkService>) -> Self {
        Self::with_endpoint(network, "https://api.deezer.com").expect("default Deezer endpoint")
    }

    pub fn with_endpoint(
        network: &Arc<NetworkService>,
        endpoint: &str,
    ) -> Result<Self, ResolverError> {
        Ok(Self {
            http: ResolverHttp::new(
                network,
                BTreeMap::from([("https://api.deezer.com".into(), endpoint.into())]),
                Duration::from_secs(25),
            )?,
            language: Mutex::new(String::new()),
            cache: Mutex::new(cache::Cache::default()),
            flights: Mutex::new(BTreeMap::new()),
        })
    }

    pub fn set_language(&self, tag: &str) {
        *self.language.lock().unwrap() = tag.trim().into();
    }

    pub fn get_track(&self, id: &str, check: &Check<'_>) -> Result<TrackMetadata, ResolverError> {
        let track: Track =
            self.get_json(&format!("https://api.deezer.com/2.0/track/{id}"), check)?;
        Ok(track.metadata())
    }

    fn get_json<T: DeserializeOwned>(
        &self,
        endpoint: &str,
        check: &Check<'_>,
    ) -> Result<T, ResolverError> {
        if endpoint.len() > 64 << 10 {
            return Err(ResolverError::Failed("metadata URL exceeds limit".into()));
        }
        let mut retry_after = Duration::ZERO;
        for attempt in 0..3 {
            if attempt > 0 {
                let delay = if retry_after.is_zero() {
                    Duration::from_millis(500 << (attempt - 1))
                } else {
                    retry_after
                };
                let started = Instant::now();
                while started.elapsed() < delay {
                    check().map_err(ResolverError::Cancelled)?;
                    std::thread::sleep(
                        delay
                            .saturating_sub(started.elapsed())
                            .min(Duration::from_millis(25)),
                    );
                }
            }
            check().map_err(ResolverError::Cancelled)?;
            let language = self.language.lock().unwrap().clone();
            let language = if language.is_empty() || language.to_ascii_lowercase().starts_with("en")
            {
                "en-US,en;q=0.9".into()
            } else {
                format!("{language},en;q=0.8")
            };
            let response = match self.http.metadata(endpoint, &language, check) {
                Ok(response) => response,
                Err(ResolverError::Transport(_)) if attempt < 2 => {
                    retry_after = Duration::ZERO;
                    continue;
                }
                Err(error) => return Err(error),
            };
            if response.status == 200 {
                let result = lyrics::decode_document(&response.body);
                check().map_err(ResolverError::Cancelled)?;
                return result.map_err(|error| ResolverError::Failed(error.to_string()));
            }
            if attempt < 2 && (response.status == 429 || response.status >= 500) {
                retry_after = response
                    .headers
                    .get("retry-after")
                    .and_then(|values| values.first())
                    .map(|value| retry_delay(value, SystemTime::now()))
                    .unwrap_or_default();
                continue;
            }
            return Err(ResolverError::Failed(format!(
                "deezer API returned status {}: {}",
                response.status,
                lyrics::text_from_bytes(&response.body)
            )));
        }
        unreachable!("last metadata attempt returns its result")
    }
}

impl MetadataLookup for DeezerClient {
    fn search_by_isrc(
        &self,
        isrc: &str,
        check: &Check<'_>,
    ) -> Result<TrackMetadata, ResolverError> {
        let track = self.get_json::<Track>(
            &format!("https://api.deezer.com/2.0/track/isrc:{isrc}"),
            check,
        );
        let track = match track {
            Ok(track) if track.id != 0 => track,
            Ok(_) => {
                return Err(ResolverError::Failed(format!(
                    "no track found for ISRC: {isrc}"
                )));
            }
            Err(error @ ResolverError::Cancelled(_)) => return Err(error),
            Err(_) => {
                let tracks: Tracks = self.get_json(
                    &format!("https://api.deezer.com/2.0/search/track?q=isrc:{isrc}&limit=1"),
                    check,
                )?;
                tracks
                    .data
                    .unwrap_or_default()
                    .into_iter()
                    .next()
                    .ok_or_else(|| {
                        ResolverError::Failed(format!("no track found for ISRC: {isrc}"))
                    })?
            }
        };
        Ok(self.playable_release(track, isrc, check)?.metadata())
    }
}

impl DeezerClient {
    /// Deezer can answer an ISRC with a release nobody can play, such as a
    /// withdrawn compilation, and which one it picks differs by region.
    /// Download providers resolve the song through this ID, so a release of
    /// the same recording that plays is looked for by title and artist.
    fn playable_release(
        &self,
        track: Track,
        isrc: &str,
        check: &Check<'_>,
    ) -> Result<Track, ResolverError> {
        if track.readable != Some(false) {
            return Ok(track);
        }
        let mut url = url::Url::parse("https://api.deezer.com/2.0/search/track")
            .expect("static Deezer search URL");
        url.query_pairs_mut()
            .append_pair("q", &format!("{} {}", track.artist.name, track.title))
            .append_pair("limit", "10");
        let found = match self.get_json::<Tracks>(url.as_str(), check) {
            Ok(found) => found,
            Err(error @ ResolverError::Cancelled(_)) => return Err(error),
            Err(_) => return Ok(track),
        };
        let candidates = found
            .data
            .unwrap_or_default()
            .into_iter()
            .filter(|candidate| candidate.id != track.id && candidate.readable == Some(true));
        // Search results carry no ISRC, so each candidate is confirmed.
        for candidate in candidates.take(5) {
            match self.get_json::<Track>(
                &format!("https://api.deezer.com/2.0/track/{}", candidate.id),
                check,
            ) {
                Ok(release)
                    if release.isrc.eq_ignore_ascii_case(isrc)
                        && release.readable != Some(false) =>
                {
                    return Ok(release);
                }
                Err(error @ ResolverError::Cancelled(_)) => return Err(error),
                _ => {}
            }
        }
        Ok(track)
    }
}

pub fn retry_delay(value: &str, now: SystemTime) -> Duration {
    if let Ok(seconds) = value.parse::<isize>() {
        let nanos = (seconds as i64)
            .wrapping_mul(1_000_000_000)
            .min(120_000_000_000);
        return Duration::from_nanos(nanos.max(0) as u64);
    }
    httpdate::parse_http_date(value)
        .ok()
        .and_then(|date| date.duration_since(now).ok())
        .unwrap_or_default()
        .min(Duration::from_secs(120))
}

fn context(error: ResolverError, message: &str) -> ResolverError {
    match error {
        ResolverError::Cancelled(_) | ResolverError::Closed | ResolverError::Busy => error,
        _ => ResolverError::Failed(format!("{message}: {error}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retry_after_preserves_integer_overflow_dates_and_two_minute_cap() {
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        for (input, expected) in [
            ("", 0),
            ("0", 0),
            ("1", 1),
            ("+2", 2),
            ("-1", 0),
            ("121", 120),
            (" 1", 0),
            ("9223372036854775807", 0),
        ] {
            assert_eq!(
                retry_delay(input, now),
                Duration::from_secs(expected),
                "{input}"
            );
        }
        assert_eq!(
            retry_delay(&httpdate::fmt_http_date(now + Duration::from_secs(30)), now),
            Duration::from_secs(30)
        );
        assert_eq!(
            retry_delay(
                &httpdate::fmt_http_date(now + Duration::from_secs(300)),
                now
            ),
            Duration::from_secs(120)
        );
        assert_eq!(
            retry_delay(&httpdate::fmt_http_date(now - Duration::from_secs(30)), now),
            Duration::ZERO
        );
    }
}
