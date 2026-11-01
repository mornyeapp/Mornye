//! Single-flight request coalescing shared by the lyrics, MusicBrainz, resolver and
//! availability services.
//!
//! The flight table lives inside each service's own state mutex, so cache lookups,
//! flight joins and [`Coalescer::finish`] stay atomic with that service's cache and
//! generation. Services keep their own key, caching and worker rules; this module
//! owns waiter accounting, cancellation once the last waiter leaves, the poll loop,
//! the `MAX_FLIGHTS` bound and idle notification.

use std::borrow::Borrow;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

/// Caller checks are opaque callbacks, so waiters poll them while a flight runs.
const POLL: Duration = Duration::from_millis(25);
/// Upper bound on concurrently running workers per service.
pub(crate) const MAX_FLIGHTS: usize = 64;

/// One shared in-flight request. `T` carries per-service data fixed at creation.
pub(crate) struct Flight<V, T = ()> {
    tag: T,
    waiters: AtomicUsize,
    result: Mutex<Option<V>>,
    ready: Condvar,
}

impl<V, T> Flight<V, T> {
    pub(crate) fn new(tag: T) -> Arc<Self> {
        Arc::new(Self {
            tag,
            waiters: AtomicUsize::new(0),
            result: Mutex::new(None),
            ready: Condvar::new(),
        })
    }

    pub(crate) fn tag(&self) -> &T {
        &self.tag
    }

    pub(crate) fn waiters(&self) -> usize {
        self.waiters.load(Ordering::Acquire)
    }

    /// Registers the first waiter of a new flight under the service lock.
    /// Existing flights use [`Coalescer::try_join`] to avoid reviving abandoned work.
    pub(crate) fn join(&self) {
        self.waiters.fetch_add(1, Ordering::AcqRel);
    }

    /// Worker-side liveness: fails once the owner closes or every waiter has left.
    pub(crate) fn check(
        &self,
        closed: &AtomicBool,
        closed_message: &str,
        cancelled_message: &str,
    ) -> Result<(), String> {
        if closed.load(Ordering::Acquire) {
            Err(closed_message.into())
        } else if self.waiters() == 0 {
            Err(cancelled_message.into())
        } else {
            Ok(())
        }
    }

    /// Blocks until the flight finishes, running the caller's `check` before every
    /// poll and once more after the shared result is cloned.
    pub(crate) fn wait<E>(&self, check: impl Fn() -> Result<(), E>) -> Result<V, E>
    where
        V: Clone,
    {
        loop {
            check()?;
            let result = self.result.lock().expect("flight lock");
            if let Some(value) = result.as_ref() {
                let value = value.clone();
                drop(result);
                check()?;
                return Ok(value);
            }
            drop(self.ready.wait_timeout(result, POLL).expect("flight lock"));
        }
    }
}

/// Drop guard for one registered waiter. Dropping the last guard makes
/// [`Flight::check`] fail, which cancels the detached worker.
pub(crate) struct Waiter<V, T = ()>(Arc<Flight<V, T>>);

impl<V, T> Waiter<V, T> {
    pub(crate) fn new(flight: Arc<Flight<V, T>>) -> Self {
        Self(flight)
    }
}

impl<V, T> Drop for Waiter<V, T> {
    fn drop(&mut self) {
        self.0.waiters.fetch_sub(1, Ordering::AcqRel);
    }
}

/// Flight table and running-worker count, kept inside a service's state mutex.
pub(crate) struct Coalescer<K, V, T = ()> {
    flights: BTreeMap<K, Arc<Flight<V, T>>>,
    active: usize,
}

impl<K, V, T> Default for Coalescer<K, V, T> {
    fn default() -> Self {
        Self {
            flights: BTreeMap::new(),
            active: 0,
        }
    }
}

impl<K: Ord, V, T> Coalescer<K, V, T> {
    /// Workers started and not yet finished; shutdown waits on `idle` until zero.
    pub(crate) fn active(&self) -> usize {
        self.active
    }

    pub(crate) fn is_full(&self) -> bool {
        self.active >= MAX_FLIGHTS
    }

    /// Joins a flight for `key` only while its waiter count is still nonzero,
    /// so an abandoned flight is never revived between the check and the join.
    pub(crate) fn try_join<Q>(&self, key: &Q) -> Option<Arc<Flight<V, T>>>
    where
        K: Borrow<Q>,
        Q: Ord + ?Sized,
    {
        self.flights
            .get(key)
            .filter(|flight| {
                flight
                    .waiters
                    .try_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                        (count > 0).then_some(count + 1)
                    })
                    .is_ok()
            })
            .cloned()
    }

    /// Records a new flight and counts its worker as active. Check
    /// [`Coalescer::is_full`] first.
    pub(crate) fn insert(&mut self, key: K, flight: Arc<Flight<V, T>>) {
        self.flights.insert(key, flight);
        self.active += 1;
    }

    /// Whether `flight` is still the table entry for `key`.
    pub(crate) fn is_current<Q>(&self, key: &Q, flight: &Arc<Flight<V, T>>) -> bool
    where
        K: Borrow<Q>,
        Q: Ord + ?Sized,
    {
        self.flights
            .get(key)
            .is_some_and(|current| Arc::ptr_eq(current, flight))
    }

    /// Publishes `result` to the flight's waiters, removes the flight if it is
    /// still current, and wakes shutdown. Call under the service lock after any
    /// service-specific caching.
    pub(crate) fn finish<Q>(
        &mut self,
        key: &Q,
        flight: &Arc<Flight<V, T>>,
        result: V,
        idle: &Condvar,
    ) where
        K: Borrow<Q>,
        Q: Ord + ?Sized,
    {
        *flight.result.lock().expect("flight lock") = Some(result);
        flight.ready.notify_all();
        if self.is_current(key, flight) {
            self.flights.remove(key);
        }
        self.active -= 1;
        idle.notify_all();
    }

    #[cfg(test)]
    pub(crate) fn get<Q>(&self, key: &Q) -> Option<&Arc<Flight<V, T>>>
    where
        K: Borrow<Q>,
        Q: Ord + ?Sized,
    {
        self.flights.get(key)
    }

    #[cfg(test)]
    pub(crate) fn values(&self) -> impl Iterator<Item = &Arc<Flight<V, T>>> {
        self.flights.values()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    type Outcome = Result<u32, String>;

    #[derive(Default)]
    struct State {
        flights: Coalescer<String, Outcome>,
        cache: BTreeMap<String, u32>,
    }

    /// Minimal service following the same flow as the four production owners.
    #[derive(Default)]
    struct Service {
        state: Mutex<State>,
        idle: Condvar,
        closed: AtomicBool,
        calls: AtomicUsize,
        release: AtomicBool,
        worker_errors: Mutex<Vec<String>>,
    }

    impl Service {
        fn lookup(
            self: &Arc<Self>,
            key: &str,
            check: &(dyn Fn() -> Result<(), String> + Sync),
        ) -> Outcome {
            let (flight, start) = {
                let mut state = self.state.lock().unwrap();
                if let Some(value) = state.cache.get(key) {
                    return Ok(*value);
                }
                let (flight, start) = if let Some(flight) = state.flights.try_join(key) {
                    (flight, false)
                } else {
                    if state.flights.is_full() {
                        return Err("busy".into());
                    }
                    let flight = Flight::new(());
                    flight.join();
                    state.flights.insert(key.into(), Arc::clone(&flight));
                    (flight, true)
                };
                (flight, start)
            };
            let _waiter = Waiter::new(Arc::clone(&flight));
            if start {
                let service = Arc::clone(self);
                let worker_flight = Arc::clone(&flight);
                let worker_key = key.to_owned();
                std::thread::spawn(move || {
                    let check = || worker_flight.check(&service.closed, "closed", "cancelled");
                    service.calls.fetch_add(1, Ordering::AcqRel);
                    let result = loop {
                        if let Err(error) = check() {
                            service.worker_errors.lock().unwrap().push(error.clone());
                            break Err(error);
                        }
                        if service.release.load(Ordering::Acquire) {
                            break Ok(7);
                        }
                        std::thread::sleep(Duration::from_millis(2));
                    };
                    let mut state = service.state.lock().unwrap();
                    if let Ok(value) = result {
                        state.cache.insert(worker_key.clone(), value);
                    }
                    state.flights.finish(
                        worker_key.as_str(),
                        &worker_flight,
                        result,
                        &service.idle,
                    );
                });
            }
            flight.wait(check)?
        }
    }

    fn until(condition: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(3);
        while !condition() {
            assert!(Instant::now() < deadline, "coalescer test timed out");
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    fn waiters(service: &Service) -> usize {
        let state = service.state.lock().unwrap();
        state.flights.values().map(|flight| flight.waiters()).sum()
    }

    #[test]
    fn one_flight_serves_every_waiter_and_finish_caches() {
        let service = Arc::new(Service::default());
        let threads: Vec<_> = (0..8)
            .map(|_| {
                let service = Arc::clone(&service);
                std::thread::spawn(move || service.lookup("key", &|| Ok(())))
            })
            .collect();
        until(|| waiters(&service) == 8 && service.calls.load(Ordering::Acquire) == 1);
        std::thread::sleep(Duration::from_millis(10));
        assert_eq!(service.calls.load(Ordering::Acquire), 1);
        service.release.store(true, Ordering::Release);
        for thread in threads {
            assert_eq!(thread.join().unwrap(), Ok(7));
        }
        let state = service.state.lock().unwrap();
        assert_eq!(state.flights.active(), 0);
        assert!(state.flights.get("key").is_none());
        assert_eq!(state.cache.get("key"), Some(&7));
        drop(state);
        assert_eq!(service.lookup("key", &|| Ok(())), Ok(7));
        assert_eq!(service.calls.load(Ordering::Acquire), 1);
    }

    #[test]
    fn last_waiter_leaving_cancels_the_worker() {
        let service = Arc::new(Service::default());
        let cancelled = Arc::new(AtomicBool::new(false));
        let caller = {
            let service = Arc::clone(&service);
            let cancelled = Arc::clone(&cancelled);
            std::thread::spawn(move || {
                service.lookup("key", &|| {
                    if cancelled.load(Ordering::Acquire) {
                        Err("caller cancelled".into())
                    } else {
                        Ok(())
                    }
                })
            })
        };
        until(|| waiters(&service) == 1);
        cancelled.store(true, Ordering::Release);
        assert_eq!(caller.join().unwrap(), Err("caller cancelled".into()));
        until(|| service.state.lock().unwrap().flights.active() == 0);
        assert_eq!(*service.worker_errors.lock().unwrap(), ["cancelled"]);
        let state = service.state.lock().unwrap();
        assert!(state.cache.is_empty());
        assert!(state.flights.get("key").is_none());
    }

    #[test]
    fn closed_owner_is_reported_before_cancellation() {
        let flight: Arc<Flight<Outcome>> = Flight::new(());
        let closed = AtomicBool::new(true);
        assert_eq!(
            flight.check(&closed, "closed", "cancelled"),
            Err("closed".into())
        );
        closed.store(false, Ordering::Release);
        assert_eq!(
            flight.check(&closed, "closed", "cancelled"),
            Err("cancelled".into())
        );
        flight.join();
        assert_eq!(flight.check(&closed, "closed", "cancelled"), Ok(()));
    }

    #[test]
    fn running_flights_are_bounded() {
        let service = Arc::new(Service::default());
        let threads: Vec<_> = (0..MAX_FLIGHTS)
            .map(|index| {
                let service = Arc::clone(&service);
                std::thread::spawn(move || service.lookup(&index.to_string(), &|| Ok(())))
            })
            .collect();
        until(|| service.state.lock().unwrap().flights.active() == MAX_FLIGHTS);
        assert!(service.state.lock().unwrap().flights.is_full());
        assert_eq!(service.lookup("over", &|| Ok(())), Err("busy".into()));
        service.release.store(true, Ordering::Release);
        for thread in threads {
            assert_eq!(thread.join().unwrap(), Ok(7));
        }
        assert!(!service.state.lock().unwrap().flights.is_full());
        assert_eq!(service.lookup("over", &|| Ok(())), Ok(7));
    }

    #[test]
    fn abandoned_flights_are_not_joined_and_stale_finish_keeps_replacement() {
        let idle = Condvar::new();
        let mut flights: Coalescer<String, Outcome> = Coalescer::default();
        let stale = Flight::new(());
        flights.insert("key".into(), Arc::clone(&stale));
        assert!(flights.try_join("key").is_none());
        assert_eq!(stale.waiters(), 0);
        let current = Flight::new(());
        current.join();
        flights.insert("key".into(), Arc::clone(&current));
        assert!(flights.try_join("key").is_some());
        assert_eq!(current.waiters(), 2);
        assert!(!flights.is_current("key", &stale));
        flights.finish("key", &stale, Ok(1), &idle);
        assert_eq!(stale.wait(|| Ok::<_, String>(())), Ok(Ok(1)));
        assert!(flights.is_current("key", &current));
        assert_eq!(flights.active(), 1);
        flights.finish("key", &current, Ok(2), &idle);
        assert!(flights.get("key").is_none());
        assert_eq!(flights.active(), 0);
    }

    #[test]
    fn last_waiter_can_leave_while_the_service_lock_is_held() {
        let flight: Arc<Flight<Outcome>> = Flight::new(());
        flight.join();
        let waiter = Waiter::new(Arc::clone(&flight));
        let mut flights: Coalescer<String, Outcome> = Coalescer::default();
        flights.insert("key".into(), Arc::clone(&flight));
        let table = Mutex::new(flights);
        let locked = table.lock().unwrap();
        // Holding the service lock does not keep a lookup's observed waiter
        // count live: cancellation releases its guard independently.
        assert_eq!(locked.get("key").unwrap().waiters(), 1);
        std::thread::spawn(move || drop(waiter)).join().unwrap();
        assert_eq!(
            flight.check(&AtomicBool::new(false), "closed", "cancelled"),
            Err("cancelled".into())
        );
        assert!(locked.try_join("key").is_none());
        assert_eq!(flight.waiters(), 0);
    }

    #[test]
    fn finish_wakes_shutdown_waiting_for_idle() {
        let service = Arc::new(Service::default());
        let flight = Flight::new(());
        service
            .state
            .lock()
            .unwrap()
            .flights
            .insert("key".into(), Arc::clone(&flight));
        let shutdown = {
            let service = Arc::clone(&service);
            std::thread::spawn(move || {
                let mut state = service.state.lock().unwrap();
                while state.flights.active() != 0 {
                    state = service.idle.wait(state).unwrap();
                }
            })
        };
        std::thread::sleep(Duration::from_millis(20));
        assert!(!shutdown.is_finished());
        service
            .state
            .lock()
            .unwrap()
            .flights
            .finish("key", &flight, Ok(1), &service.idle);
        shutdown.join().unwrap();
    }
}
