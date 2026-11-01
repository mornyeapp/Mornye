use super::{ExtensionError, MAX_TIMEOUT_MS, Operation};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Default)]
pub(crate) struct Control {
    pub(super) closed: AtomicBool,
    pub(super) parent_closed: Option<Arc<AtomicBool>>,
    pub(super) operation: Mutex<Option<Operation>>,
    pub(super) waiter: Mutex<Option<Arc<thread::Thread>>>,
    #[cfg(test)]
    pub(super) checks: std::sync::atomic::AtomicUsize,
}

pub(crate) struct ControlWait<'a>(&'a Control);

impl Drop for ControlWait<'_> {
    fn drop(&mut self) {
        self.0.waiter.lock().expect("extension waiter lock").take();
    }
}

impl Control {
    pub(crate) fn watch_thread(&self) -> ControlWait<'_> {
        let thread = Arc::new(thread::current());
        *self.waiter.lock().expect("extension waiter lock") = Some(Arc::clone(&thread));
        if let Some(lease) = self
            .operation
            .lock()
            .expect("extension operation lock")
            .as_ref()
            .and_then(|operation| operation.lease.as_ref())
        {
            lease.observe_thread(&thread);
        }
        ControlWait(self)
    }

    pub(crate) fn close(&self) {
        self.closed.store(true, Ordering::Release);
        if let Some(thread) = self.waiter.lock().expect("extension waiter lock").as_ref() {
            thread.unpark();
        }
    }

    pub(crate) fn deadline_remaining(&self) -> Duration {
        self.operation
            .lock()
            .expect("extension operation lock")
            .as_ref()
            .map_or(Duration::from_millis(MAX_TIMEOUT_MS), |operation| {
                operation.deadline.saturating_duration_since(Instant::now())
            })
    }

    pub(crate) fn request_cancelled(&self) -> bool {
        self.operation
            .lock()
            .expect("extension operation lock")
            .as_ref()
            .and_then(|operation| operation.lease.as_ref())
            .is_some_and(|lease| lease.active_request_cancelled())
    }

    pub(crate) fn item_id(&self) -> String {
        self.operation
            .lock()
            .expect("extension operation lock")
            .as_ref()
            .map_or_else(String::new, |operation| operation.item_id.clone())
    }

    pub(crate) fn check(&self) -> Result<(), ExtensionError> {
        #[cfg(test)]
        self.checks.fetch_add(1, Ordering::Relaxed);
        if self.is_closed() {
            return Err(ExtensionError::Closed);
        }
        if let Some(operation) = &*self.operation.lock().expect("extension operation lock") {
            operation.check()?;
        }
        Ok(())
    }

    pub(crate) fn resolution(&self) -> Option<Arc<crate::resolution::ResolutionBudget>> {
        self.operation
            .lock()
            .expect("extension operation lock")
            .as_ref()
            .and_then(|operation| operation.resolution.clone())
    }

    pub(super) fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
            || self
                .parent_closed
                .as_ref()
                .is_some_and(|closed| closed.load(Ordering::Acquire))
    }

    pub(crate) fn sleep(&self, duration: Duration) -> bool {
        let started = Instant::now();
        loop {
            if self.check().is_err() {
                return false;
            }
            let remaining = duration.saturating_sub(started.elapsed());
            if remaining.is_zero() {
                return true;
            }
            // Core leases and shutdown can be signalled from native threads.
            // A short heartbeat also observes deadlines while in a host call.
            thread::sleep(remaining.min(Duration::from_millis(10)));
        }
    }
}
