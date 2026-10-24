//! The pairing window (contract section 3). The desktop shows a 6-digit PIN;
//! the phone proves it knows the PIN and saw this server's certificate:
//! `proof = hex(HMAC-SHA256(key = PIN, message = "mornye-link-pair-v1:" +
//! fingerprint + ":" + deviceId))`. A relaying attacker presents another
//! certificate, so its proof fails. Five bad proofs end the window.

use crate::auth::{constant_time_eq, hex};
use crate::store::{now_ms, random_bytes};
use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const MAX_ATTEMPTS: u32 = 5;
const PROOF_CONTEXT: &str = "mornye-link-pair-v1:";

/// Why a pairing window ended (`linkPairingEnded.reason`).
pub(crate) const PAIRED: &str = "paired";
pub(crate) const EXPIRED: &str = "expired";
pub(crate) const ATTEMPTS: &str = "attempts";
pub(crate) const CANCELLED: &str = "cancelled";

/// A rejected `POST /mornye/v1/pair`.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum PairError {
    /// More than one request per interval from the same address (429).
    RateLimited,
    /// No open window (403 `pairing_closed`).
    Closed,
    /// The proof does not match (403 `bad_proof`).
    BadProof,
    /// The device could not be stored (500).
    Failed(String),
}

/// An open window, as `linkBeginPairing` reports it.
pub(crate) struct Opened {
    pub(crate) pin: String,
    pub(crate) expires_ms: i64,
    pub(crate) generation: u64,
}

struct Window {
    pin: String,
    expires_at: Instant,
    attempts: u32,
    generation: u64,
}

#[derive(Default)]
struct State {
    window: Option<Window>,
    generation: u64,
    /// Last accepted request time per address, for the rate limit.
    recent: HashMap<IpAddr, Instant>,
}

pub(crate) struct Pairing {
    state: Mutex<State>,
    ttl: Duration,
    interval: Duration,
}

impl Pairing {
    pub(crate) fn new(ttl: Duration, interval: Duration) -> Self {
        Self {
            state: Mutex::default(),
            ttl,
            interval,
        }
    }

    /// Opens a new window with a fresh PIN, replacing any open one.
    pub(crate) fn begin(&self) -> Result<Opened, String> {
        let pin = new_pin()?;
        let mut state = self.state.lock().expect("link pairing");
        state.generation += 1;
        let generation = state.generation;
        state.window = Some(Window {
            pin: pin.clone(),
            expires_at: Instant::now() + self.ttl,
            attempts: 0,
            generation,
        });
        Ok(Opened {
            pin,
            expires_ms: now_ms() + self.ttl.as_millis() as i64,
            generation,
        })
    }

    pub(crate) fn ttl(&self) -> Duration {
        self.ttl
    }

    /// Closes the window. Returns whether one was open.
    pub(crate) fn end(&self) -> bool {
        self.state
            .lock()
            .expect("link pairing")
            .window
            .take()
            .is_some()
    }

    /// Closes the window opened as `generation` when it is still open (the
    /// expiry timer). Returns whether it was.
    pub(crate) fn expire(&self, generation: u64) -> bool {
        let mut state = self.state.lock().expect("link pairing");
        if state
            .window
            .as_ref()
            .is_some_and(|window| window.generation == generation)
        {
            state.window = None;
            return true;
        }
        false
    }

    pub(crate) fn is_open(&self) -> bool {
        self.state
            .lock()
            .expect("link pairing")
            .window
            .as_ref()
            .is_some_and(|window| Instant::now() < window.expires_at)
    }

    /// Checks one pairing request from `peer`. When `proof` is valid,
    /// `store` runs while the window is still held; the window closes only
    /// when it succeeds. Also returns the reason to report when this request
    /// ended the window.
    pub(crate) fn attempt<T>(
        &self,
        peer: IpAddr,
        fingerprint: &str,
        device_id: &str,
        proof: &str,
        store: impl FnOnce() -> Result<T, String>,
    ) -> (Result<T, PairError>, Option<&'static str>) {
        let now = Instant::now();
        let mut state = self.state.lock().expect("link pairing");
        let interval = self.interval;
        state
            .recent
            .retain(|_, at| now.duration_since(*at) < interval);
        if state.recent.contains_key(&peer) {
            return (Err(PairError::RateLimited), None);
        }
        if !interval.is_zero() {
            state.recent.insert(peer, now);
        }
        let Some(window) = state.window.as_mut() else {
            return (Err(PairError::Closed), None);
        };
        if now >= window.expires_at {
            state.window = None;
            return (Err(PairError::Closed), Some(EXPIRED));
        }
        let expected = self::proof(&window.pin, fingerprint, device_id);
        if !constant_time_eq(
            expected.as_bytes(),
            proof.trim().to_ascii_lowercase().as_bytes(),
        ) {
            window.attempts += 1;
            if window.attempts >= MAX_ATTEMPTS {
                state.window = None;
                return (Err(PairError::BadProof), Some(ATTEMPTS));
            }
            return (Err(PairError::BadProof), None);
        }
        match store() {
            Ok(value) => {
                state.window = None;
                (Ok(value), Some(PAIRED))
            }
            Err(error) => (Err(PairError::Failed(error)), None),
        }
    }
}

/// The proof a phone sends for `pin`, `fingerprint` and `device_id`.
pub(crate) fn proof(pin: &str, fingerprint: &str, device_id: &str) -> String {
    let mut mac =
        <Hmac<Sha256> as KeyInit>::new_from_slice(pin.as_bytes()).expect("HMAC takes any key");
    mac.update(format!("{PROOF_CONTEXT}{fingerprint}:{device_id}").as_bytes());
    hex(&mac.finalize().into_bytes())
}

/// Six uniformly random digits.
fn new_pin() -> Result<String, String> {
    // The largest multiple of 1e6 below 2^32, so every PIN is equally likely.
    const LIMIT: u32 = 4_294_000_000;
    loop {
        let value = u32::from_le_bytes(random_bytes::<4>()?);
        if value < LIMIT {
            return Ok(format!("{:06}", value % 1_000_000));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    const PEER: IpAddr = IpAddr::V4(Ipv4Addr::LOCALHOST);

    fn try_pair(pairing: &Pairing, proof: &str) -> (Result<(), PairError>, Option<&'static str>) {
        pairing.attempt(PEER, "fp", "phone", proof, || Ok(()))
    }

    #[test]
    fn matches_the_reference_proof() {
        // HMAC-SHA256(key = "123456", message = "mornye-link-pair-v1:ab:dev").
        assert_eq!(
            proof("123456", "ab", "dev"),
            hex(&{
                let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(b"123456").unwrap();
                mac.update(b"mornye-link-pair-v1:ab:dev");
                mac.finalize().into_bytes()
            })
        );
        let pin = new_pin().unwrap();
        assert_eq!(pin.len(), 6);
        assert!(pin.chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn pairs_once_with_a_valid_proof() {
        let pairing = Pairing::new(Duration::from_secs(60), Duration::ZERO);
        assert_eq!(try_pair(&pairing, "x").0, Err(PairError::Closed));
        let opened = pairing.begin().unwrap();
        assert!(pairing.is_open());
        let good = proof(&opened.pin, "fp", "phone");
        assert_eq!(
            try_pair(&pairing, &good.to_ascii_uppercase()),
            (Ok(()), Some(PAIRED))
        );
        assert!(!pairing.is_open());
        assert_eq!(try_pair(&pairing, &good).0, Err(PairError::Closed));
    }

    #[test]
    fn keeps_the_window_when_storing_fails() {
        let pairing = Pairing::new(Duration::from_secs(60), Duration::ZERO);
        let opened = pairing.begin().unwrap();
        let good = proof(&opened.pin, "fp", "phone");
        let (result, ended) = pairing.attempt(PEER, "fp", "phone", &good, || {
            Err::<(), _>("disk full".to_owned())
        });
        assert_eq!(result, Err(PairError::Failed("disk full".to_owned())));
        assert_eq!(ended, None);
        assert!(pairing.is_open());
    }

    #[test]
    fn ends_after_five_bad_proofs() {
        let pairing = Pairing::new(Duration::from_secs(60), Duration::ZERO);
        pairing.begin().unwrap();
        for _ in 0..4 {
            assert_eq!(try_pair(&pairing, "bad"), (Err(PairError::BadProof), None));
        }
        assert_eq!(
            try_pair(&pairing, "bad"),
            (Err(PairError::BadProof), Some(ATTEMPTS))
        );
        assert_eq!(try_pair(&pairing, "bad").0, Err(PairError::Closed));
    }

    #[test]
    fn expires_and_rate_limits() {
        let pairing = Pairing::new(Duration::ZERO, Duration::from_secs(60));
        let opened = pairing.begin().unwrap();
        assert!(!pairing.is_open());
        let good = proof(&opened.pin, "fp", "phone");
        assert_eq!(
            try_pair(&pairing, &good),
            (Err(PairError::Closed), Some(EXPIRED))
        );
        assert_eq!(try_pair(&pairing, &good).0, Err(PairError::RateLimited));
        assert!(!pairing.expire(opened.generation));
        let next = pairing.begin().unwrap();
        assert!(pairing.expire(next.generation));
        assert!(!pairing.end());
    }
}
