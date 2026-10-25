//! Platform resolver service that resolves URLs and Spotify tracks to other platforms, with caching.

use super::{Check, Metadata, Resolution, Resolver, ResolverError, check_active};
use crate::coalescer::{Coalescer, Flight, Waiter};
use crate::lyrics::{LyricsError, builtin::TrackResolver};
use std::collections::BTreeMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const POSITIVE_TTL: Duration = Duration::from_secs(30 * 60);
const NEGATIVE_TTL: Duration = Duration::from_secs(5 * 60);
const MAX_CACHE: usize = 500;
type Outcome = Result<Resolution, ResolverError>;

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Key {
    generation: u64,
    region: String,
    url: String,
    title: String,
    artist: String,
    cached: bool,
}

struct CacheEntry {
    value: Outcome,
    expires: Instant,
}

struct State {
    region: String,
    generation: u64,
    flights: Coalescer<Key, Outcome>,
    cache: BTreeMap<(String, String), CacheEntry>,
}

struct Inner {
    resolver: Arc<dyn Resolver>,
    closed: AtomicBool,
    state: Mutex<State>,
    idle: Condvar,
}

/// Native owner for the active resolver chain. Spotify availability resolutions
/// retain Go's region-scoped TTLs; arbitrary URL lookups are only coalesced.
pub struct PlatformResolverService {
    inner: Arc<Inner>,
}

impl PlatformResolverService {
    pub fn new(resolver: Arc<dyn Resolver>) -> Self {
        Self {
            inner: Arc::new(Inner {
                resolver,
                closed: AtomicBool::new(false),
                state: Mutex::new(State {
                    region: "US".into(),
                    generation: 0,
                    flights: Coalescer::default(),
                    cache: BTreeMap::new(),
                }),
                idle: Condvar::new(),
            }),
        }
    }

    pub fn set_region(&self, region: &str) -> Result<(), ResolverError> {
        let region = mornye_core::matching::uppercase(region.trim());
        let mut state = self.inner.state.lock().unwrap();
        self.inner.check(&|| Ok(()))?;
        state.region = if region.len() == 2 && region.bytes().all(|byte| byte.is_ascii_uppercase())
        {
            region
        } else {
            "US".into()
        };
        Ok(())
    }

    pub fn clear_cache(&self) -> Result<usize, ResolverError> {
        let mut state = self.inner.state.lock().unwrap();
        self.inner.check(&|| Ok(()))?;
        state.generation = state.generation.wrapping_add(1);
        let count = state.cache.len();
        state.cache.clear();
        Ok(count)
    }

    pub fn resolve_url(&self, url: &str, hint: &Metadata, check: &Check<'_>) -> Outcome {
        self.lookup(url, hint, false, check)
    }

    pub fn resolve_spotify(&self, id: &str, check: &Check<'_>) -> Outcome {
        self.inner.check(check)?;
        let id = id.trim();
        if id.is_empty() {
            return Err(ResolverError::Failed("spotify track ID is empty".into()));
        }
        self.lookup(
            &format!("https://open.spotify.com/track/{id}"),
            &Metadata::default(),
            true,
            check,
        )
    }

    fn lookup(&self, url: &str, hint: &Metadata, cached: bool, check: &Check<'_>) -> Outcome {
        self.inner.check(check)?;
        if url.len() > 64 << 10 || hint.title.len() + hint.artist.len() > 64 << 10 {
            return Err(ResolverError::Failed("resolver input exceeds limit".into()));
        }
        let (key, flight, start) = {
            let mut state = self.inner.state.lock().unwrap();
            self.inner.check(check)?;
            if cached {
                let cache_key = (state.region.clone(), url.to_owned());
                if let Some(entry) = state.cache.get(&cache_key)
                    && Instant::now() <= entry.expires
                {
                    return entry.value.clone().map_err(|_| {
                        ResolverError::Failed("track availability unavailable (cached)".into())
                    });
                }
                state.cache.remove(&cache_key);
            }
            let key = Key {
                generation: state.generation,
                region: state.region.clone(),
                url: url.into(),
                title: hint.title.clone(),
                artist: hint.artist.clone(),
                cached,
            };
            let existing = state.flights.try_join(&key);
            let (flight, start) = if let Some(flight) = existing {
                (flight, false)
            } else {
                if state.flights.is_full() {
                    return Err(ResolverError::Busy);
                }
                let flight = Flight::new(());
                flight.join();
                state.flights.insert(key.clone(), Arc::clone(&flight));
                (flight, true)
            };
            (key, flight, start)
        };
        let _waiter = Waiter::new(Arc::clone(&flight));
        if start {
            let inner = Arc::clone(&self.inner);
            let worker_key = key.clone();
            let worker_flight = Arc::clone(&flight);
            let spawned = std::thread::Builder::new()
                .name("platform-resolver".into())
                .spawn(move || {
                    let check = || {
                        worker_flight.check(
                            &inner.closed,
                            "platform resolver closed",
                            "platform resolution cancelled",
                        )
                    };
                    let result = catch_unwind(AssertUnwindSafe(|| {
                        inner.resolver.resolve(
                            &worker_key.url,
                            &Metadata {
                                title: worker_key.title.clone(),
                                artist: worker_key.artist.clone(),
                            },
                            &check,
                        )
                    }))
                    .unwrap_or_else(|_| {
                        Err(ResolverError::Failed("platform resolver panicked".into()))
                    });
                    // A resolver callback cannot publish success after losing all
                    // waiters, even if it forgot to check immediately before return.
                    let result = check_active(&check).and(result);
                    inner.finish(&worker_key, &worker_flight, result);
                });
            if let Err(error) = spawned {
                self.inner
                    .finish(&key, &flight, Err(ResolverError::Failed(error.to_string())));
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
    }
}

impl Drop for PlatformResolverService {
    fn drop(&mut self) {
        self.shutdown();
    }
}

impl TrackResolver for PlatformResolverService {
    fn deezer_id_from_spotify(&self, id: &str, check: &Check<'_>) -> Result<String, LyricsError> {
        let resolution = self
            .resolve_spotify(id, check)
            .map_err(|error| match error {
                ResolverError::Cancelled(message) => LyricsError::Cancelled(message),
                ResolverError::Closed => LyricsError::Cancelled(error.to_string()),
                _ => LyricsError::Other(error.to_string()),
            })?;
        let link = resolution
            .links
            .get("deezer")
            .ok_or_else(|| LyricsError::Other("track not found on Deezer".into()))?;
        let mut id = link.rsplit('/').next().unwrap_or_default();
        if let Some(index) = id.find('?').filter(|index| *index > 0) {
            id = &id[..index];
        }
        if id.is_empty() {
            return Err(LyricsError::Other("track not found on Deezer".into()));
        }
        Ok(id.into())
    }
}

impl Inner {
    fn check(&self, check: &Check<'_>) -> Result<(), ResolverError> {
        if self.closed.load(Ordering::Acquire) {
            Err(ResolverError::Closed)
        } else {
            check_active(check)
        }
    }

    fn finish(&self, key: &Key, flight: &Arc<Flight<Outcome>>, result: Outcome) {
        let mut state = self.state.lock().unwrap();
        if key.cached
            && key.generation == state.generation
            && !self.closed.load(Ordering::Acquire)
            && !matches!(
                result,
                Err(ResolverError::Cancelled(_) | ResolverError::Closed | ResolverError::Busy)
            )
        {
            let cache_key = (key.region.clone(), key.url.clone());
            if !state.cache.contains_key(&cache_key)
                && state.cache.len() >= MAX_CACHE
                && let Some(oldest) = state
                    .cache
                    .iter()
                    .min_by_key(|(_, entry)| entry.expires)
                    .map(|(key, _)| key.clone())
            {
                state.cache.remove(&oldest);
            }
            let ttl = if result.is_ok() {
                POSITIVE_TTL
            } else {
                NEGATIVE_TTL
            };
            state.cache.insert(
                cache_key,
                CacheEntry {
                    value: result.clone(),
                    expires: Instant::now() + ttl,
                },
            );
        }
        state.flights.finish(key, flight, result, &self.idle);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::coalescer::MAX_FLIGHTS;
    use std::sync::atomic::AtomicUsize;

    #[derive(Default)]
    struct Probe {
        calls: AtomicUsize,
        release: AtomicBool,
        failure: AtomicBool,
    }

    impl Resolver for Probe {
        fn resolve(&self, _: &str, _: &Metadata, check: &Check<'_>) -> Outcome {
            self.calls.fetch_add(1, Ordering::AcqRel);
            while !self.release.load(Ordering::Acquire) {
                check_active(check)?;
                std::thread::sleep(Duration::from_millis(2));
            }
            if self.failure.load(Ordering::Acquire) {
                return Err(ResolverError::Failed("fixture unavailable".into()));
            }
            Ok(Resolution {
                links: BTreeMap::from([(
                    "deezer".into(),
                    "https://www.deezer.com/track/42?source=example".into(),
                )]),
                ..Resolution::default()
            })
        }
    }

    fn until(predicate: impl Fn() -> bool) {
        let started = Instant::now();
        while !predicate() {
            assert!(
                started.elapsed() < Duration::from_secs(3),
                "resolver test wait timed out"
            );
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    #[test]
    fn coalesced_waiters_cancel_independently_and_cache_by_region() {
        let probe = Arc::new(Probe::default());
        let service = Arc::new(PlatformResolverService::new(probe.clone()));
        let cancelled = Arc::new(AtomicBool::new(false));
        let first = {
            let service = service.clone();
            let cancelled = cancelled.clone();
            std::thread::spawn(move || {
                service.resolve_spotify("example", &|| {
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
            std::thread::spawn(move || service.deezer_id_from_spotify("example", &|| Ok(())))
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
        assert_eq!(second.join().unwrap().unwrap(), "42");
        assert_eq!(
            service
                .deezer_id_from_spotify(" example ", &|| Ok(()))
                .unwrap(),
            "42"
        );
        assert_eq!(probe.calls.load(Ordering::Acquire), 1);
        service.set_region("id").unwrap();
        service.resolve_spotify("example", &|| Ok(())).unwrap();
        service.set_region("not a region").unwrap();
        service.resolve_spotify("example", &|| Ok(())).unwrap();
        assert_eq!(probe.calls.load(Ordering::Acquire), 2);
        assert_eq!(service.clear_cache().unwrap(), 2);
    }

    #[test]
    fn last_waiter_and_shutdown_cancel_workers_and_reject_retained_handles() {
        let probe = Arc::new(Probe::default());
        let service = Arc::new(PlatformResolverService::new(probe.clone()));
        let started = Instant::now();
        assert!(matches!(
            service.resolve_spotify(
                "cancel",
                &|| if started.elapsed() >= Duration::from_millis(40) {
                    Err("cancel".into())
                } else {
                    Ok(())
                }
            ),
            Err(ResolverError::Cancelled(_))
        ));
        until(|| service.inner.state.lock().unwrap().flights.active() == 0);
        assert!(service.inner.state.lock().unwrap().cache.is_empty());
        let waiting = {
            let service = service.clone();
            std::thread::spawn(move || service.resolve_spotify("shutdown", &|| Ok(())))
        };
        until(|| probe.calls.load(Ordering::Acquire) == 2);
        service.shutdown();
        assert_eq!(waiting.join().unwrap(), Err(ResolverError::Closed));
        assert_eq!(
            service.resolve_spotify("", &|| Ok(())),
            Err(ResolverError::Closed)
        );
        assert_eq!(service.set_region("ID"), Err(ResolverError::Closed));
        assert_eq!(service.clear_cache(), Err(ResolverError::Closed));
        assert_eq!(service.inner.state.lock().unwrap().flights.active(), 0);
    }

    #[test]
    fn cache_expiry_failures_and_generation_changes_preserve_fresh_state() {
        let probe = Arc::new(Probe::default());
        let service = Arc::new(PlatformResolverService::new(probe.clone()));
        let old = {
            let service = service.clone();
            std::thread::spawn(move || service.resolve_spotify("old", &|| Ok(())))
        };
        until(|| probe.calls.load(Ordering::Acquire) == 1);
        service.clear_cache().unwrap();
        probe.release.store(true, Ordering::Release);
        old.join().unwrap().unwrap();
        assert!(service.inner.state.lock().unwrap().cache.is_empty());
        service.resolve_spotify("old", &|| Ok(())).unwrap();
        probe.failure.store(true, Ordering::Release);
        assert!(service.resolve_spotify("failed", &|| Ok(())).is_err());
        assert_eq!(probe.calls.load(Ordering::Acquire), 3);
        assert!(service.resolve_spotify("failed", &|| Ok(())).is_err());
        assert_eq!(probe.calls.load(Ordering::Acquire), 3);
        {
            let mut state = service.inner.state.lock().unwrap();
            let positive = state
                .cache
                .values()
                .find(|entry| entry.value.is_ok())
                .unwrap();
            let negative = state
                .cache
                .values()
                .find(|entry| entry.value.is_err())
                .unwrap();
            assert!(
                positive.expires.duration_since(negative.expires) > Duration::from_secs(24 * 60)
            );
            for entry in state.cache.values_mut() {
                entry.expires = Instant::now() - Duration::from_secs(1);
            }
        }
        probe.failure.store(false, Ordering::Release);
        service.resolve_spotify("failed", &|| Ok(())).unwrap();
        assert_eq!(probe.calls.load(Ordering::Acquire), 4);
    }

    #[test]
    fn distinct_lookup_and_cache_counts_are_bounded() {
        let probe = Arc::new(Probe::default());
        let service = Arc::new(PlatformResolverService::new(probe.clone()));
        let mut waiters = Vec::new();
        for index in 0..MAX_FLIGHTS {
            let service = service.clone();
            waiters.push(std::thread::spawn(move || {
                service.resolve_spotify(&index.to_string(), &|| Ok(()))
            }));
        }
        until(|| probe.calls.load(Ordering::Acquire) == MAX_FLIGHTS);
        assert_eq!(
            service.resolve_spotify("over-limit", &|| Ok(())),
            Err(ResolverError::Busy)
        );
        probe.release.store(true, Ordering::Release);
        for waiter in waiters {
            waiter.join().unwrap().unwrap();
        }
        service.clear_cache().unwrap();
        for index in 0..MAX_CACHE + 3 {
            service
                .resolve_spotify(&index.to_string(), &|| Ok(()))
                .unwrap();
        }
        assert_eq!(service.inner.state.lock().unwrap().cache.len(), MAX_CACHE);
        assert!(
            !service
                .inner
                .state
                .lock()
                .unwrap()
                .cache
                .contains_key(&("US".into(), "https://open.spotify.com/track/0".into()))
        );
    }
}
