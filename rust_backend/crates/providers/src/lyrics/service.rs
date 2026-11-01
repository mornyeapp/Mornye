//! Lyrics service: runs the ordered provider list for a search request, coalesces identical
//! in-flight requests, and caches negative results.

use super::{CallGraph, CallNode, Check, LyricsError, cache::LyricsCache};
use crate::coalescer::{Coalescer, Flight, Waiter};
use mornye_core::lyrics::{LyricsResponse, config, config::FetchOptions, matching};
use mornye_core::matching::lowercase;
use std::collections::BTreeMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::{Duration, Instant, SystemTime};

const POLL: Duration = Duration::from_millis(25);
const NEGATIVE_TTL: Duration = Duration::from_secs(5 * 60);
// Share a short recovery window across downloads, then retry the lookup once.
// A transient outage must not disable lyrics for the rest of an album.
const UNAVAILABLE_COOLDOWN: Duration = Duration::from_secs(2);
const RATE_LIMIT_COOLDOWN: Duration = Duration::from_secs(60);
const PRIORITY_GRACE: Duration = Duration::from_secs(5);
const MAX_NEGATIVE: usize = 500;

#[derive(Clone, Debug, Default)]
pub struct SearchRequest {
    pub spotify_id: String,
    pub track: String,
    pub artist: String,
    pub duration: f64,
    pub options: FetchOptions,
    /// Native wait dependency, replaced by the service's flight before dispatch.
    pub caller: Option<CallNode>,
}

/// Built-in clients and the installed extension manager implement this boundary.
/// Calls execute on native workers. Implementations must observe `check` during
/// blocking work and must not reenter the same JavaScript VM from a lyrics call.
pub trait LyricsFetcher: Send + Sync + 'static {
    fn call_graph(&self) -> Option<CallGraph> {
        None
    }

    /// Pure owner-liveness check, also applied before cached/heuristic results.
    /// This can run while the service state is locked; do not block or call a VM.
    fn check(&self) -> Result<(), LyricsError> {
        Ok(())
    }

    fn extensions(&self) -> Vec<String> {
        Vec::new()
    }

    fn fetch(
        &self,
        provider: &str,
        request: &SearchRequest,
        check: &Check<'_>,
    ) -> Result<LyricsResponse, LyricsError>;
}

type FetchResult = Result<LyricsResponse, LyricsError>;
/// Each flight carries the call-graph node its worker runs under.
type LyricsFlight = Flight<FetchResult, CallNode>;

#[derive(Default)]
struct State {
    // Retain an empty selection separately from the effective default order.
    providers: Vec<String>,
    options: FetchOptions,
    generation: u64,
    negative: BTreeMap<String, Instant>,
    health: BTreeMap<String, Instant>,
    flights: Coalescer<(u64, String), FetchResult, CallNode>,
}

struct Inner {
    fetcher: Arc<dyn LyricsFetcher>,
    calls: CallGraph,
    state: Mutex<State>,
    idle: Condvar,
    closed: AtomicBool,
    cache: LyricsCache,
}

pub struct LyricsService {
    inner: Arc<Inner>,
}

impl LyricsService {
    pub fn new(fetcher: Arc<dyn LyricsFetcher>) -> Self {
        let calls = fetcher.call_graph().unwrap_or_default();
        Self {
            inner: Arc::new(Inner {
                fetcher,
                calls,
                state: Mutex::default(),
                idle: Condvar::new(),
                closed: AtomicBool::new(false),
                cache: LyricsCache::default(),
            }),
        }
    }

    pub fn providers(&self) -> Vec<String> {
        config::provider_order(
            &self
                .inner
                .state
                .lock()
                .expect("lyrics service lock")
                .providers,
        )
    }

    pub fn set_providers(&self, providers: &[String]) -> Result<(), LyricsError> {
        let normalized = config::normalize_provider_order(providers);
        let mut state = self.inner.state.lock().expect("lyrics service lock");
        self.inner.check(&|| Ok(()))?;
        state.health.clear();
        if state.providers != normalized {
            state.providers = normalized;
            state.generation = state.generation.wrapping_add(1);
            self.inner.cache.clear();
        }
        Ok(())
    }

    pub fn options(&self) -> FetchOptions {
        self.inner
            .state
            .lock()
            .expect("lyrics service lock")
            .options
            .clone()
    }

    pub fn set_options(&self, mut options: FetchOptions) -> Result<(), LyricsError> {
        options.normalize();
        let mut state = self.inner.state.lock().expect("lyrics service lock");
        self.inner.check(&|| Ok(()))?;
        if state.options != options {
            state.options = options;
            state.generation = state.generation.wrapping_add(1);
            self.inner.cache.clear();
        }
        Ok(())
    }

    pub fn set_persistence_path(&self, path: &Path) -> Result<(), LyricsError> {
        let _state = self.inner.state.lock().expect("lyrics service lock");
        self.inner.check(&|| Ok(()))?;
        self.inner
            .cache
            .set_persistence_path(path, SystemTime::now());
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn cache_size(&self) -> usize {
        self.inner.cache.len()
    }

    pub fn clear_cache(&self) -> Result<usize, LyricsError> {
        let mut state = self.inner.state.lock().expect("lyrics service lock");
        self.inner.check(&|| Ok(()))?;
        state.generation = state.generation.wrapping_add(1);
        Ok(self.inner.cache.clear())
    }

    pub fn drop_memory(&self) -> Result<usize, LyricsError> {
        let mut state = self.inner.state.lock().expect("lyrics service lock");
        self.inner.check(&|| Ok(()))?;
        state.generation = state.generation.wrapping_add(1);
        state.negative.clear();
        state.health.clear();
        Ok(self.inner.cache.drop_memory())
    }

    pub fn fetch(&self, mut request: SearchRequest, check: &Check<'_>) -> FetchResult {
        self.inner.check(check)?;
        let extensions = self.inner.fetcher.extensions();
        let (flight, start, flight_key, providers, _dependency, _waiter) = {
            let mut state = self.inner.state.lock().expect("lyrics service lock");
            self.inner.check(check)?;
            request.options = state.options.clone();
            let providers = config::provider_order(&state.providers);
            let key = config::cache_key(
                &request.spotify_id,
                &request.track,
                &request.artist,
                request.duration,
                &providers,
                &extensions,
                &request.options,
            );
            let now = Instant::now();
            if state.negative.get(&key).is_some_and(|expiry| now < *expiry) {
                return Err(LyricsError::NotFound("lyrics not found (cached)".into()));
            }
            state.negative.remove(&key);
            let flight_key = (state.generation, key);
            let existing = state.flights.try_join(&flight_key);
            let (flight, start) = if let Some(flight) = existing {
                (flight, false)
            } else {
                if state.flights.is_full() {
                    return Err(LyricsError::Other(
                        "too many concurrent lyrics searches".into(),
                    ));
                }
                let flight = Flight::new(self.inner.calls.node());
                flight.join();
                (flight, true)
            };
            // Dependency validation can reject a joined flight. Release that
            // registration too, including when it was the final live waiter.
            let waiter = Waiter::new(Arc::clone(&flight));
            let dependency = request
                .caller
                .as_ref()
                .map(|caller| caller.wait_for(flight.tag()))
                .transpose()
                .map_err(LyricsError::Recursive)?;
            if start {
                state
                    .flights
                    .insert(flight_key.clone(), Arc::clone(&flight));
            }
            request.caller = Some(flight.tag().clone());
            (flight, start, flight_key, providers, dependency, waiter)
        };
        if start {
            let inner = Arc::clone(&self.inner);
            let worker_flight = Arc::clone(&flight);
            let worker_key = flight_key.clone();
            let spawned = std::thread::Builder::new()
                .name("lyrics-search".into())
                .spawn(move || {
                    let check = || {
                        worker_flight.check(
                            &inner.closed,
                            "lyrics service is closed",
                            "lyrics request cancelled",
                        )
                    };
                    let result = catch_unwind(AssertUnwindSafe(|| {
                        inner.fetch_uncached(
                            &request,
                            &providers,
                            &extensions,
                            worker_key.0,
                            &check,
                        )
                    }))
                    .unwrap_or_else(|_| Err(LyricsError::Other("lyrics provider panicked".into())));
                    inner.finish(&worker_key, &worker_flight, result);
                });
            if let Err(error) = spawned {
                self.inner.finish(
                    &flight_key,
                    &flight,
                    Err(LyricsError::Other(error.to_string())),
                );
            }
        }
        flight.wait(|| self.inner.check(check))?
    }

    /// Asks one enabled provider directly, for a user choosing between
    /// providers. Skips the cache, negative results, coalescing and the
    /// priority race, so the answer is always that provider's own.
    pub fn fetch_from(
        &self,
        provider: &str,
        mut request: SearchRequest,
        check: &Check<'_>,
    ) -> FetchResult {
        self.inner.check(check)?;
        let extensions = self.inner.fetcher.extensions();
        let configured = {
            let state = self.inner.state.lock().expect("lyrics service lock");
            request.options = state.options.clone();
            config::provider_order(&state.providers)
        };
        let provider = lowercase(provider.trim());
        if !config::resolve_order(&configured, &extensions).contains(&provider) {
            return Err(LyricsError::Other(format!(
                "lyrics provider {provider} is not enabled"
            )));
        }
        let node = self.inner.calls.node();
        let _dependency = request
            .caller
            .as_ref()
            .map(|caller| caller.wait_for(&node))
            .transpose()
            .map_err(LyricsError::Recursive)?;
        request.caller = Some(node);
        let check = || self.inner.check(check).map_err(|error| error.to_string());
        let result = catch_unwind(AssertUnwindSafe(|| {
            self.inner.fetcher.fetch(&provider, &request, &check)
        }))
        .unwrap_or_else(|_| Err(LyricsError::Other("lyrics provider panicked".into())));
        self.inner.check(&check)?;
        if result.as_ref().is_ok_and(LyricsResponse::has_usable_text) {
            self.inner
                .state
                .lock()
                .expect("lyrics service lock")
                .health
                .remove(&provider);
        }
        result
    }

    /// The enabled providers in priority order, including installed lyrics
    /// extensions as `extension:<id>`.
    pub fn enabled_providers(&self) -> Vec<String> {
        let configured = self.providers();
        config::resolve_order(&configured, &self.inner.fetcher.extensions())
    }

    /// Cancel workers, wait for their HTTP/extension calls to unwind, then flush
    /// successful data. Native owners call this before releasing the service.
    pub fn shutdown(&self) -> Result<(), String> {
        self.inner.closed.store(true, Ordering::Release);
        let mut state = self.inner.state.lock().expect("lyrics service lock");
        while state.flights.active() > 0 {
            state = self.inner.idle.wait(state).expect("lyrics service lock");
        }
        drop(state);
        self.inner.cache.flush()
    }
}

impl Drop for LyricsService {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}

impl Inner {
    fn check(&self, check: &Check<'_>) -> Result<(), LyricsError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(LyricsError::Cancelled("lyrics service is closed".into()));
        }
        check().map_err(LyricsError::Cancelled)?;
        self.fetcher.check()
    }

    fn finish(&self, key: &(u64, String), flight: &Arc<LyricsFlight>, result: FetchResult) {
        let mut state = self.state.lock().expect("lyrics service lock");
        if state.generation == key.0 && !self.closed.load(Ordering::Acquire) {
            // Network and malformed-response failures do not prove absence.
            if matches!(&result, Err(LyricsError::NotFound(_))) {
                let now = Instant::now();
                state.negative.retain(|_, expiry| now < *expiry);
                while state.negative.len() >= MAX_NEGATIVE {
                    state.negative.pop_first();
                }
                state.negative.insert(key.1.clone(), now + NEGATIVE_TTL);
            } else if result.is_ok() {
                state.negative.remove(&key.1);
            }
        }
        state.flights.finish(key, flight, result, &self.idle);
    }

    fn fetch_uncached(
        &self,
        request: &SearchRequest,
        providers: &[String],
        extensions: &[String],
        generation: u64,
        check: &Check<'_>,
    ) -> FetchResult {
        self.check(check)?;
        let key = config::cache_key(
            "",
            &request.track,
            &request.artist,
            request.duration,
            providers,
            extensions,
            &request.options,
        );
        if matching::is_likely_instrumental(&request.track) {
            let result = LyricsResponse {
                instrumental: true,
                source: "Heuristic: Instrumental".into(),
                ..LyricsResponse::default()
            };
            self.store(generation, key, &result, check)?;
            return Ok(result);
        }
        let providers = config::resolve_order(providers, extensions);
        let mut fallback = None;
        if let Some(mut cached) = self.cache.get(&key, SystemTime::now()) {
            let extension = cached.source.strip_prefix("Extension:");
            let selected = extension.is_some_and(|id| {
                providers.contains(&format!("extension:{}", lowercase(id.trim())))
            });
            let has_extensions = providers.iter().any(|name| name.starts_with("extension:"));
            if (extension.is_none() && !has_extensions) || selected {
                cached.source.push_str(" (cached)");
                return Ok(cached);
            }
            if extension.is_none() {
                fallback = Some(cached);
            }
        }
        let mut result = self.search(&providers, request, generation, check, PRIORITY_GRACE);
        if fallback.is_none()
            && matches!(
                &result,
                Err(LyricsError::Unavailable(_) | LyricsError::Other(_))
            )
        {
            let deadline = Instant::now() + UNAVAILABLE_COOLDOWN;
            loop {
                self.check(check)?;
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    break;
                }
                std::thread::sleep(POLL.min(remaining));
            }
            result = self.search(&providers, request, generation, check, PRIORITY_GRACE);
        }
        self.check(check)?;
        let result = match result {
            Err(error @ LyricsError::Cancelled(_)) => return Err(error),
            Ok(lyrics) if lyrics.has_usable_text() => {
                self.store(generation, key, &lyrics, check)?;
                return Ok(lyrics);
            }
            other => other,
        };
        if let Some(mut cached) = fallback {
            cached.source.push_str(" (cached fallback)");
            return Ok(cached);
        }
        result.and_then(|_| {
            Err(LyricsError::NotFound(
                "lyrics not found from any source".into(),
            ))
        })
    }

    fn store(
        &self,
        generation: u64,
        key: String,
        response: &LyricsResponse,
        check: &Check<'_>,
    ) -> Result<(), LyricsError> {
        let state = self.state.lock().expect("lyrics service lock");
        self.check(check)?;
        if state.generation == generation {
            self.cache.set(key, response, SystemTime::now());
        }
        Ok(())
    }

    fn search(
        &self,
        providers: &[String],
        request: &SearchRequest,
        generation: u64,
        check: &Check<'_>,
        grace: Duration,
    ) -> FetchResult {
        let (candidates, cooling): (Vec<_>, bool) = {
            let mut state = self.state.lock().expect("lyrics service lock");
            let now = Instant::now();
            state.health.retain(|_, expiry| now < *expiry);
            let candidates: Vec<_> = providers
                .iter()
                .enumerate()
                .filter(|(_, name)| !state.health.contains_key(*name))
                .collect();
            let cooling = candidates.len() < providers.len();
            (candidates, cooling)
        };
        let stopped = AtomicBool::new(false);
        let next = AtomicUsize::new(0);
        let control = || {
            if stopped.load(Ordering::Acquire) {
                Err("lyrics provider search cancelled".into())
            } else {
                check()
            }
        };
        std::thread::scope(|scope| {
            let (sender, receiver) = mpsc::channel();
            for _ in 0..candidates.len().min(3) {
                let sender = sender.clone();
                let candidates = &candidates;
                let control = &control;
                let next = &next;
                scope.spawn(move || {
                    loop {
                        if control().is_err() {
                            break;
                        }
                        let Some(&(index, name)) =
                            candidates.get(next.fetch_add(1, Ordering::AcqRel))
                        else {
                            break;
                        };
                        let result = catch_unwind(AssertUnwindSafe(|| {
                            self.fetcher.fetch(name, request, control)
                        }))
                        .unwrap_or_else(|_| {
                            Err(LyricsError::Other("lyrics provider panicked".into()))
                        });
                        if control().is_ok() {
                            let mut state = self.state.lock().expect("lyrics service lock");
                            if state.generation == generation {
                                match &result {
                                    Ok(lyrics) if lyrics.has_usable_text() => {
                                        state.health.remove(name);
                                    }
                                    Err(LyricsError::Unavailable(message)) => {
                                        // The HTTP client reports status failures in this form.
                                        // A rate limit needs a longer pause than a transport failure.
                                        let cooldown = if message == "HTTP 429" {
                                            RATE_LIMIT_COOLDOWN
                                        } else {
                                            UNAVAILABLE_COOLDOWN
                                        };
                                        state
                                            .health
                                            .insert(name.clone(), Instant::now() + cooldown);
                                    }
                                    _ => {}
                                }
                            }
                        }
                        if sender.send((index, result)).is_err() {
                            break;
                        }
                    }
                });
            }
            drop(sender);
            let mut completed = vec![false; providers.len()];
            let mut best: Option<(usize, LyricsResponse)> = None;
            let mut deadline = None;
            let mut last_error = None;
            let mut other_error = None;
            let mut recursive = None;
            let mut unavailable = cooling.then(|| {
                LyricsError::Unavailable("lyrics providers are temporarily unavailable".into())
            });
            let result = loop {
                if let Err(error) = self.check(check) {
                    break Err(error);
                }
                if let Some((index, _)) = &best {
                    let pending = candidates
                        .iter()
                        .any(|(earlier, _)| earlier < index && !completed[*earlier]);
                    if !pending || deadline.is_some_and(|limit| Instant::now() >= limit) {
                        break Ok(best.take().expect("best lyrics result").1);
                    }
                }
                match receiver.recv_timeout(POLL) {
                    Ok((index, result)) => {
                        completed[index] = true;
                        if let Err(error @ LyricsError::Recursive(_)) = &result {
                            recursive = Some(error.clone());
                        }
                        if let Err(error @ LyricsError::Unavailable(_)) = &result {
                            unavailable = Some(error.clone());
                        }
                        if let Err(error @ (LyricsError::Other(_) | LyricsError::Cancelled(_))) =
                            &result
                        {
                            other_error = Some(error.clone());
                        }
                        if let Err(error) = &result {
                            last_error = Some(error.clone());
                        }
                        if let Ok(lyrics) = result
                            && lyrics.has_usable_text()
                            && best.as_ref().is_none_or(|(current, _)| index < *current)
                        {
                            best = Some((index, lyrics));
                            deadline = Some(Instant::now() + grace);
                        }
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        break best.map(|(_, lyrics)| lyrics).ok_or_else(|| {
                            recursive
                                .or(unavailable)
                                .or(other_error)
                                .or(last_error)
                                .unwrap_or_else(|| {
                                    LyricsError::NotFound("lyrics not found from any source".into())
                                })
                        });
                    }
                }
            };
            stopped.store(true, Ordering::Release);
            result
        })
    }
}

#[cfg(test)]
mod tests;
