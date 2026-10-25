//! Cached track and album availability checks across streaming platforms, per region.

use super::{
    AlbumAvailability, TrackAvailability, album, deezer_id_from_metadata, from_deezer, from_links,
    resolved_links,
};
use crate::coalescer::{Coalescer, Flight, Waiter};
use crate::deezer::MetadataLookup;
use crate::lyrics::{LyricsError, builtin::TrackResolver};
use crate::resolver::{Check, PlatformResolverService, Resolver, ResolverError};
use std::collections::BTreeMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Kind {
    Availability,
    Links,
}

#[derive(Clone)]
enum Value {
    Availability(Box<TrackAvailability>),
    Links(BTreeMap<String, String>),
}
type Outcome = Result<Value, ResolverError>;

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Key {
    kind: Kind,
    region: String,
    id: String,
    isrc: bool,
}

struct Entry {
    result: Outcome,
    expires: Instant,
}

struct State {
    generation: u64,
    region: String,
    cache: BTreeMap<Key, Entry>,
    flights: Coalescer<(u64, Key), Outcome>,
}

struct Inner {
    resolver: PlatformResolverService,
    metadata: Arc<dyn MetadataLookup>,
    state: Mutex<State>,
    closed: AtomicBool,
    idle: Condvar,
}

/// One native owner for raw resolver work and both application caches.
pub struct AvailabilityService {
    inner: Arc<Inner>,
}

impl AvailabilityService {
    pub fn new(resolver: Arc<dyn Resolver>, metadata: Arc<dyn MetadataLookup>) -> Self {
        Self {
            inner: Arc::new(Inner {
                resolver: PlatformResolverService::new(resolver),
                metadata,
                state: Mutex::new(State {
                    generation: 0,
                    region: "US".into(),
                    cache: BTreeMap::new(),
                    flights: Coalescer::default(),
                }),
                closed: AtomicBool::new(false),
                idle: Condvar::new(),
            }),
        }
    }

    pub fn set_region(&self, region: &str) -> Result<(), ResolverError> {
        let mut state = self.inner.state.lock().unwrap();
        self.inner.check(&|| Ok(()))?;
        let region = mornye_core::matching::uppercase(region.trim());
        state.region = if region.len() == 2 && region.bytes().all(|byte| byte.is_ascii_uppercase())
        {
            region
        } else {
            "US".into()
        };
        Ok(())
    }

    pub fn region(&self) -> Result<String, ResolverError> {
        self.inner.check(&|| Ok(()))?;
        Ok(self.inner.state.lock().unwrap().region.clone())
    }

    pub fn clear_cache(&self) -> Result<usize, ResolverError> {
        let mut state = self.inner.state.lock().unwrap();
        self.inner.check(&|| Ok(()))?;
        state.generation = state.generation.wrapping_add(1);
        let count = state.cache.len();
        state.cache.clear();
        Ok(count)
    }

    pub fn check_track(
        &self,
        spotify_id: &str,
        isrc: &str,
        check: &Check<'_>,
    ) -> Result<TrackAvailability, ResolverError> {
        match self.lookup(Kind::Availability, spotify_id, isrc, check)? {
            Value::Availability(value) => Ok(*value),
            _ => unreachable!("availability cache type"),
        }
    }

    pub fn track_platform_links(
        &self,
        spotify_id: &str,
        isrc: &str,
        check: &Check<'_>,
    ) -> Result<BTreeMap<String, String>, ResolverError> {
        match self.lookup(Kind::Links, spotify_id, isrc, check)? {
            Value::Links(value) => Ok(value),
            _ => unreachable!("links cache type"),
        }
    }

    pub fn check_album(
        &self,
        id: &str,
        check: &Check<'_>,
    ) -> Result<AlbumAvailability, ResolverError> {
        self.with_raw(check, |resolver, check| album(resolver, id, check))
    }

    #[cfg(test)]
    pub(crate) fn check_from_deezer(
        &self,
        id: &str,
        check: &Check<'_>,
    ) -> Result<TrackAvailability, ResolverError> {
        self.with_raw(check, |resolver, check| from_deezer(resolver, id, check))
    }

    pub fn deezer_album_id(&self, id: &str, check: &Check<'_>) -> Result<String, ResolverError> {
        let album = self.check_album(id, check)?;
        if album.deezer && !album.deezer_id.is_empty() {
            Ok(album.deezer_id)
        } else {
            Err(ResolverError::Failed("album not found on Deezer".into()))
        }
    }

    fn with_raw<T>(
        &self,
        check: &Check<'_>,
        work: impl FnOnce(&PlatformResolverService, &Check<'_>) -> Result<T, ResolverError>,
    ) -> Result<T, ResolverError> {
        self.inner.check(check)?;
        let result = work(&self.inner.resolver, &|| {
            self.inner.check(check).map_err(|error| error.to_string())
        });
        self.inner.check(check)?;
        result
    }

    fn lookup(&self, kind: Kind, spotify_id: &str, isrc: &str, check: &Check<'_>) -> Outcome {
        self.inner.check(check)?;
        let spotify_id = spotify_id.trim();
        let isrc = mornye_core::matching::uppercase(isrc.trim());
        let (id, isrc) = if !spotify_id.is_empty() {
            (spotify_id.to_owned(), false)
        } else if !isrc.is_empty() {
            (isrc, true)
        } else {
            return Err(ResolverError::Failed(
                "spotify track ID and ISRC are empty".into(),
            ));
        };
        if id.len() > 64 << 10 {
            return Err(ResolverError::Failed(
                "availability input exceeds limit".into(),
            ));
        }
        let (key, generation, flight, start) = {
            let mut state = self.inner.state.lock().unwrap();
            self.inner.check(check)?;
            let key = Key {
                kind,
                region: state.region.clone(),
                id,
                isrc,
            };
            if let Some(entry) = state.cache.get(&key)
                && Instant::now() <= entry.expires
            {
                return entry.result.clone().map_err(|_| {
                    ResolverError::Failed(
                        if kind == Kind::Availability {
                            "track availability unavailable (cached)"
                        } else {
                            "track platform links unavailable (cached)"
                        }
                        .into(),
                    )
                });
            }
            state.cache.remove(&key);
            let generation = state.generation;
            let flight_key = (generation, key.clone());
            let existing = state.flights.try_join(&flight_key);
            let (flight, start) = if let Some(flight) = existing {
                (flight, false)
            } else {
                if state.flights.is_full() {
                    return Err(ResolverError::Busy);
                }
                let flight = Flight::new(());
                flight.join();
                state.flights.insert(flight_key, flight.clone());
                (flight, true)
            };
            (key, generation, flight, start)
        };
        let _waiter = Waiter::new(flight.clone());
        if start {
            let inner = self.inner.clone();
            let worker_key = key.clone();
            let worker_flight = flight.clone();
            let spawned = std::thread::Builder::new()
                .name("platform-availability".into())
                .spawn(move || {
                    let check = || {
                        worker_flight.check(
                            &inner.closed,
                            "availability service closed",
                            "availability request cancelled",
                        )
                    };
                    let result =
                        catch_unwind(AssertUnwindSafe(|| inner.fetch(&worker_key, &check)))
                            .unwrap_or_else(|_| {
                                Err(ResolverError::Failed("availability worker panicked".into()))
                            });
                    let result = check().map_err(ResolverError::Cancelled).and(result);
                    inner.finish(generation, &worker_key, &worker_flight, result);
                });
            if let Err(error) = spawned {
                self.inner.finish(
                    generation,
                    &key,
                    &flight,
                    Err(ResolverError::Failed(error.to_string())),
                );
            }
        }
        flight.wait(|| self.inner.check(check))?
    }

    pub fn shutdown(&self) {
        self.inner.closed.store(true, Ordering::Release);
        let mut state = self.inner.state.lock().unwrap();
        while state.flights.active() != 0 {
            state = self.inner.idle.wait(state).unwrap();
        }
        state.cache.clear();
        drop(state);
        self.inner.resolver.shutdown();
    }
}

impl Drop for AvailabilityService {
    fn drop(&mut self) {
        self.shutdown();
    }
}

impl TrackResolver for AvailabilityService {
    fn deezer_id_from_spotify(&self, id: &str, check: &Check<'_>) -> Result<String, LyricsError> {
        let track = self
            .check_track(id, "", check)
            .map_err(|error| match error {
                ResolverError::Cancelled(message) => LyricsError::Cancelled(message),
                ResolverError::Closed => LyricsError::Cancelled(error.to_string()),
                ResolverError::Transport(message) => LyricsError::Unavailable(message),
                _ => LyricsError::Other(error.to_string()),
            })?;
        if track.deezer && !track.deezer_id.is_empty() {
            Ok(track.deezer_id)
        } else {
            Err(LyricsError::Other("track not found on Deezer".into()))
        }
    }
}

impl Inner {
    fn check(&self, check: &Check<'_>) -> Result<(), ResolverError> {
        if self.closed.load(Ordering::Acquire) {
            Err(ResolverError::Closed)
        } else {
            check().map_err(ResolverError::Cancelled)
        }
    }

    fn fetch(&self, key: &Key, check: &Check<'_>) -> Outcome {
        let id = if key.isrc {
            let started = Instant::now();
            let track = self.metadata.search_by_isrc(&key.id, &|| {
                check()?;
                if started.elapsed() >= Duration::from_secs(30) {
                    Err("ISRC lookup deadline exceeded".into())
                } else {
                    Ok(())
                }
            })?;
            let id = deezer_id_from_metadata(&track);
            if id.is_empty() {
                return Err(ResolverError::Failed(format!(
                    "failed to resolve Deezer track ID from ISRC {}",
                    key.id
                )));
            }
            id
        } else {
            key.id.clone()
        };
        if key.kind == Kind::Availability && key.isrc {
            return from_deezer(&self.resolver, &id, check)
                .map(|value| Value::Availability(Box::new(value)));
        }
        let url = if key.isrc {
            format!("https://www.deezer.com/track/{id}")
        } else {
            format!("https://open.spotify.com/track/{id}")
        };
        let links = resolved_links(&self.resolver, &url, check)?;
        if key.kind == Kind::Availability {
            return Ok(Value::Availability(Box::new(from_links(&id, &links))));
        }
        let links: BTreeMap<_, _> = links
            .into_iter()
            .filter_map(|(key, value)| {
                let value = value.trim();
                (value.starts_with("https://") || value.starts_with("http://"))
                    .then(|| (key, value.into()))
            })
            .collect();
        if links.is_empty() {
            Err(ResolverError::Failed("no platform links found".into()))
        } else {
            Ok(Value::Links(links))
        }
    }

    fn finish(&self, generation: u64, key: &Key, flight: &Arc<Flight<Outcome>>, result: Outcome) {
        let mut state = self.state.lock().unwrap();
        if generation == state.generation
            && !self.closed.load(Ordering::Acquire)
            && !matches!(
                result,
                Err(ResolverError::Cancelled(_) | ResolverError::Closed | ResolverError::Busy)
            )
        {
            let limit = if key.kind == Kind::Availability {
                500
            } else {
                200
            };
            if !state.cache.contains_key(key)
                && state
                    .cache
                    .keys()
                    .filter(|entry| entry.kind == key.kind)
                    .count()
                    >= limit
                && let Some(oldest) = state
                    .cache
                    .iter()
                    .filter(|(entry, _)| entry.kind == key.kind)
                    .min_by_key(|(_, value)| value.expires)
                    .map(|(key, _)| key.clone())
            {
                state.cache.remove(&oldest);
            }
            let ttl = Duration::from_secs(if result.is_ok() { 30 * 60 } else { 5 * 60 });
            state.cache.insert(
                key.clone(),
                Entry {
                    result: result.clone(),
                    expires: Instant::now() + ttl,
                },
            );
        }
        state
            .flights
            .finish(&(generation, key.clone()), flight, result, &self.idle);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::resolver::{Metadata, Resolution};
    use mornye_core::metadata::TrackMetadata;
    use std::sync::atomic::AtomicUsize;

    #[derive(Default)]
    struct Probe {
        calls: AtomicUsize,
        metadata_calls: AtomicUsize,
        release: AtomicBool,
        metadata_blocked: AtomicBool,
        failed: AtomicBool,
    }

    impl Resolver for Probe {
        fn resolve(
            &self,
            _: &str,
            _: &Metadata,
            check: &Check<'_>,
        ) -> Result<Resolution, ResolverError> {
            self.calls.fetch_add(1, Ordering::AcqRel);
            while !self.release.load(Ordering::Acquire) {
                check().map_err(ResolverError::Cancelled)?;
                std::thread::sleep(Duration::from_millis(2));
            }
            if self.failed.load(Ordering::Acquire) {
                return Err(ResolverError::Failed("fixture failure".into()));
            }
            Ok(Resolution {
                links: BTreeMap::from([(
                    "deezer".into(),
                    "https://www.deezer.com/track/101".into(),
                )]),
                ..Resolution::default()
            })
        }
    }

    impl MetadataLookup for Probe {
        fn search_by_isrc(
            &self,
            _: &str,
            check: &Check<'_>,
        ) -> Result<TrackMetadata, ResolverError> {
            self.metadata_calls.fetch_add(1, Ordering::AcqRel);
            while self.metadata_blocked.load(Ordering::Acquire) {
                check().map_err(ResolverError::Cancelled)?;
                std::thread::sleep(Duration::from_millis(2));
            }
            Ok(TrackMetadata {
                spotify_id: "deezer:42".into(),
                ..TrackMetadata::default()
            })
        }
    }

    fn until(predicate: impl Fn() -> bool) {
        let started = Instant::now();
        while !predicate() {
            assert!(
                started.elapsed() < Duration::from_secs(3),
                "availability test timed out"
            );
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    #[test]
    fn shared_requests_cancel_independently_and_return_owned_cached_responses() {
        let probe = Arc::new(Probe::default());
        let service = Arc::new(AvailabilityService::new(probe.clone(), probe.clone()));
        let cancelled = Arc::new(AtomicBool::new(false));
        let first = {
            let service = service.clone();
            let cancelled = cancelled.clone();
            std::thread::spawn(move || {
                service.check_track("example", "", &|| {
                    if cancelled.load(Ordering::Acquire) {
                        Err("first cancelled".into())
                    } else {
                        Ok(())
                    }
                })
            })
        };
        until(|| probe.calls.load(Ordering::Acquire) == 1);
        let second = {
            let service = service.clone();
            std::thread::spawn(move || service.check_track("example", "", &|| Ok(())))
        };
        until(|| {
            service
                .inner
                .state
                .lock()
                .unwrap()
                .flights
                .values()
                .next()
                .unwrap()
                .waiters()
                == 2
        });
        cancelled.store(true, Ordering::Release);
        assert_eq!(
            first.join().unwrap(),
            Err(ResolverError::Cancelled("first cancelled".into()))
        );
        probe.release.store(true, Ordering::Release);
        let mut track = second.join().unwrap().unwrap();
        track.deezer_id = "caller changed".into();
        assert_eq!(
            service
                .check_track("example", "", &|| Ok(()))
                .unwrap()
                .deezer_id,
            "101"
        );
        assert_eq!(probe.calls.load(Ordering::Acquire), 1);
        let mut links = service
            .track_platform_links("example", "", &|| Ok(()))
            .unwrap();
        links.insert("deezer".into(), "changed".into());
        assert_ne!(
            service
                .track_platform_links("example", "", &|| Ok(()))
                .unwrap(),
            links
        );
        assert_eq!(probe.calls.load(Ordering::Acquire), 2);
        assert_eq!(
            service
                .check_track("", "usaa00000001", &|| Ok(()))
                .unwrap()
                .deezer_id,
            "42"
        );
        service
            .track_platform_links("", "USAA00000001", &|| Ok(()))
            .unwrap();
        service
            .check_track("", " USAA00000001 ", &|| Ok(()))
            .unwrap();
        assert_eq!(probe.metadata_calls.load(Ordering::Acquire), 2);
    }

    #[test]
    fn shutdown_cancels_isrc_and_uncached_calls_and_rejects_retained_apis() {
        let probe = Arc::new(Probe::default());
        probe.metadata_blocked.store(true, Ordering::Release);
        let service = Arc::new(AvailabilityService::new(probe.clone(), probe.clone()));
        let pending = {
            let service = service.clone();
            std::thread::spawn(move || service.check_track("", "USAA00000001", &|| Ok(())))
        };
        until(|| probe.metadata_calls.load(Ordering::Acquire) == 1);
        let raw = {
            let service = service.clone();
            std::thread::spawn(move || service.check_album("example", &|| Ok(())))
        };
        until(|| probe.calls.load(Ordering::Acquire) == 1);
        service.shutdown();
        assert_eq!(pending.join().unwrap(), Err(ResolverError::Closed));
        assert_eq!(raw.join().unwrap(), Err(ResolverError::Closed));
        assert_eq!(
            service.check_track("", "", &|| Ok(())),
            Err(ResolverError::Closed)
        );
        assert_eq!(
            service.track_platform_links("", "", &|| Ok(())),
            Err(ResolverError::Closed)
        );
        assert_eq!(
            service.check_from_deezer("", &|| Ok(())),
            Err(ResolverError::Closed)
        );
        assert_eq!(service.set_region("ID"), Err(ResolverError::Closed));
        assert_eq!(service.region(), Err(ResolverError::Closed));
        assert_eq!(service.clear_cache(), Err(ResolverError::Closed));
        assert_eq!(service.inner.state.lock().unwrap().flights.active(), 0);
    }

    #[test]
    fn cache_clear_and_expiry_keep_stale_and_cancelled_results_out() {
        let probe = Arc::new(Probe::default());
        let service = Arc::new(AvailabilityService::new(probe.clone(), probe.clone()));
        let pending = {
            let service = service.clone();
            std::thread::spawn(move || service.check_track("old", "", &|| Ok(())))
        };
        until(|| probe.calls.load(Ordering::Acquire) == 1);
        service.clear_cache().unwrap();
        probe.release.store(true, Ordering::Release);
        pending.join().unwrap().unwrap();
        assert!(service.inner.state.lock().unwrap().cache.is_empty());
        service.check_track("old", "", &|| Ok(())).unwrap();
        probe.failed.store(true, Ordering::Release);
        assert!(
            service
                .track_platform_links("failed", "", &|| Ok(()))
                .is_err()
        );
        assert!(
            service
                .track_platform_links("failed", "", &|| Ok(()))
                .is_err()
        );
        assert_eq!(probe.calls.load(Ordering::Acquire), 3);
        {
            let mut state = service.inner.state.lock().unwrap();
            let positive = state
                .cache
                .values()
                .find(|entry| entry.result.is_ok())
                .unwrap();
            let negative = state
                .cache
                .values()
                .find(|entry| entry.result.is_err())
                .unwrap();
            assert!(
                positive.expires.duration_since(negative.expires) > Duration::from_secs(24 * 60)
            );
            for entry in state.cache.values_mut() {
                entry.expires = Instant::now() - Duration::from_secs(1);
            }
        }
        probe.failed.store(false, Ordering::Release);
        service
            .track_platform_links("failed", "", &|| Ok(()))
            .unwrap();
        assert_eq!(probe.calls.load(Ordering::Acquire), 4);
        probe.release.store(false, Ordering::Release);
        let started = Instant::now();
        assert!(matches!(
            service.check_track(
                "cancel",
                "",
                &|| if started.elapsed() >= Duration::from_millis(40) {
                    Err("cancel".into())
                } else {
                    Ok(())
                }
            ),
            Err(ResolverError::Cancelled(_))
        ));
        until(|| service.inner.state.lock().unwrap().flights.active() == 0);
        assert!(
            !service
                .inner
                .state
                .lock()
                .unwrap()
                .cache
                .keys()
                .any(|key| key.id == "cancel")
        );
    }

    #[test]
    fn independent_cache_limits_region_keys_and_lookup_limit_are_enforced() {
        let probe = Arc::new(Probe::default());
        let service = Arc::new(AvailabilityService::new(probe.clone(), probe.clone()));
        let mut waiters = Vec::new();
        for index in 0..64 {
            let service = service.clone();
            waiters.push(std::thread::spawn(move || {
                service.check_track(&index.to_string(), "", &|| Ok(()))
            }));
        }
        until(|| service.inner.state.lock().unwrap().flights.active() == 64);
        assert_eq!(
            service.check_track("over-limit", "", &|| Ok(())),
            Err(ResolverError::Busy)
        );
        probe.release.store(true, Ordering::Release);
        for waiter in waiters {
            waiter.join().unwrap().unwrap();
        }
        service.clear_cache().unwrap();
        for index in 0..503 {
            service
                .check_track(&index.to_string(), "", &|| Ok(()))
                .unwrap();
        }
        for index in 0..203 {
            service
                .track_platform_links(&index.to_string(), "", &|| Ok(()))
                .unwrap();
        }
        {
            let state = service.inner.state.lock().unwrap();
            assert_eq!(
                state
                    .cache
                    .keys()
                    .filter(|key| key.kind == Kind::Availability)
                    .count(),
                500
            );
            assert_eq!(
                state
                    .cache
                    .keys()
                    .filter(|key| key.kind == Kind::Links)
                    .count(),
                200
            );
            assert!(!state.cache.keys().any(|key| key.id == "0"));
        }
        service.set_region("id").unwrap();
        service.check_track("502", "", &|| Ok(())).unwrap();
        service.set_region("bad region").unwrap();
        assert_eq!(service.region().unwrap(), "US");
        assert!(
            service
                .inner
                .state
                .lock()
                .unwrap()
                .cache
                .keys()
                .any(|key| key.region == "ID")
        );
    }
}
