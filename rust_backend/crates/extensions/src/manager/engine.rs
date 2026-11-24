//! Engine lock whose release wakes the callers waiting for a busy extension.

use super::{Engine, ManagerError, error};
use mornye_core::cancellation::RequestLease;
use std::ops::{Deref, DerefMut};
use std::sync::{Arc, LockResult, Mutex, MutexGuard, PoisonError, TryLockError};
use std::thread::{self, Thread};
use std::time::Duration;

// Releases and lease cancellations wake waiters. Manager shutdown does not,
// so waiters still look at it this often.
const CLOSE_CHECK: Duration = Duration::from_millis(50);

type Waiters = Mutex<Vec<Arc<Thread>>>;

#[derive(Default)]
pub(super) struct EngineLock {
    engine: Mutex<Engine>,
    waiters: Waiters,
    #[cfg(test)]
    pub(super) attempts: std::sync::atomic::AtomicUsize,
}

pub(super) struct EngineGuard<'a> {
    guard: Option<MutexGuard<'a, Engine>>,
    waiters: &'a Waiters,
}

impl EngineLock {
    pub(super) fn lock(&self) -> LockResult<EngineGuard<'_>> {
        match self.engine.lock() {
            Ok(guard) => Ok(self.guard(guard)),
            Err(poisoned) => Err(PoisonError::new(self.guard(poisoned.into_inner()))),
        }
    }

    /// Wait for the engine while `check` passes, without sleep polling.
    pub(super) fn wait(
        &self,
        check: impl Fn() -> Result<(), ManagerError>,
        lease: Option<&Arc<RequestLease>>,
    ) -> Result<EngineGuard<'_>, ManagerError> {
        check()?;
        if let Some(guard) = self.try_guard()? {
            return Ok(guard);
        }
        let current = Arc::new(thread::current());
        let _waiting = Waiting::new(&self.waiters, &current);
        if let Some(lease) = lease {
            lease.observe_thread(&current);
        }
        // Subscribed before this recheck, so a release in between leaves
        // an unpark token and the park below returns at once.
        loop {
            check()?;
            if let Some(guard) = self.try_guard()? {
                return Ok(guard);
            }
            thread::park_timeout(CLOSE_CHECK);
        }
    }

    fn try_guard(&self) -> Result<Option<EngineGuard<'_>>, ManagerError> {
        #[cfg(test)]
        self.attempts
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        match self.engine.try_lock() {
            Ok(guard) => Ok(Some(self.guard(guard))),
            Err(TryLockError::WouldBlock) => Ok(None),
            Err(TryLockError::Poisoned(_)) => Err(error("extension engine lock poisoned")),
        }
    }

    fn guard<'a>(&'a self, guard: MutexGuard<'a, Engine>) -> EngineGuard<'a> {
        EngineGuard {
            guard: Some(guard),
            waiters: &self.waiters,
        }
    }
}

impl Deref for EngineGuard<'_> {
    type Target = Engine;

    fn deref(&self) -> &Engine {
        self.guard.as_ref().expect("held extension engine")
    }
}

impl DerefMut for EngineGuard<'_> {
    fn deref_mut(&mut self) -> &mut Engine {
        self.guard.as_mut().expect("held extension engine")
    }
}

impl Drop for EngineGuard<'_> {
    fn drop(&mut self) {
        // Unlock first: a waiter woken while the lock is still held could
        // fail its retry and park again after the last wake.
        drop(self.guard.take());
        for waiter in self
            .waiters
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
        {
            waiter.unpark();
        }
    }
}

struct Waiting<'a> {
    waiters: &'a Waiters,
    thread: Arc<Thread>,
}

impl<'a> Waiting<'a> {
    fn new(waiters: &'a Waiters, thread: &Arc<Thread>) -> Self {
        waiters
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(Arc::clone(thread));
        Self {
            waiters,
            thread: Arc::clone(thread),
        }
    }
}

impl Drop for Waiting<'_> {
    fn drop(&mut self) {
        self.waiters
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .retain(|waiter| !Arc::ptr_eq(waiter, &self.thread));
    }
}
