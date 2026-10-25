use super::coordinator::SignedSessionClient;
use super::protocol::{self, ErrorContract};
use serde_json::Value;
use std::collections::BTreeMap;

impl SignedSessionClient {
    pub fn signed_fetch(
        &self,
        method: &str,
        path: &str,
        body: &str,
        headers: &BTreeMap<String, String>,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<Value, String> {
        self.check(&check)?;
        let method = method.trim().to_uppercase();
        let mut record = {
            let state = self.scope.lock().expect("signed session coordinator lock");
            let mut record = self.load()?;
            let error = if record.session_id.is_empty() || record.session_secret.is_empty() {
                Some("signed session is not authenticated")
            } else if protocol::parse_time(&record.expires_at)
                .is_some_and(|expires| self.registry.auth.now() > expires)
            {
                record.clear();
                let _ = self.store.save(&record);
                Some("signed session expired")
            } else {
                None
            };
            if let Some(error) = error {
                drop(state);
                let url = match self.bootstrap(&check) {
                    Ok(url) => url,
                    Err(_) => {
                        return on_mint_failure(
                            || self.check(&check),
                            || self.verification_required(String::new()),
                        );
                    }
                };
                return if url.is_empty() {
                    Err(error.into())
                } else {
                    Ok(self.verification_required(url))
                };
            }
            if state.blocked(&record) {
                drop(state);
                let url = match self.bootstrap(&check) {
                    Ok(url) => url,
                    Err(_) => {
                        return on_mint_failure(
                            || self.check(&check),
                            || self.verification_required(String::new()),
                        );
                    }
                };
                if !url.is_empty() {
                    return Ok(self.verification_required(url));
                }
                let state = self.scope.lock().expect("signed session coordinator lock");
                record = self.load()?;
                if !record.usable(self.registry.auth.now()) || state.blocked(&record) {
                    return on_mint_failure(
                        || self.check(&check),
                        || self.verification_required(String::new()),
                    );
                }
            }
            record
        };
        if record.refresh_due(&self.config, self.registry.auth.now()) {
            let _ = self.refresh(&check);
            self.check(&check)?;
            let state = self.scope.lock().expect("signed session coordinator lock");
            let latest = self.load()?;
            if !latest.usable(self.registry.auth.now()) || state.blocked(&latest) {
                drop(state);
                let url = self.bootstrap(&check)?;
                return if url.is_empty() {
                    Err("signed session is not authenticated".into())
                } else {
                    Ok(self.verification_required(url))
                };
            }
            record = latest;
        }
        let mut session_retries = 0;
        let mut provider_retries = 0;
        let mut request_auth_retry = false;
        loop {
            let response = self.signed_request(&record, &method, path, body, headers, &check)?;
            let contract = ErrorContract::parse(&response.body);
            if contract.provider_retry(response.status) {
                if provider_retries >= 2 {
                    return Ok(protocol::response_value(response, self.registry.auth.now()));
                }
                provider_retries += 1;
                self.wait(
                    protocol::provider_delay(&response, &contract, self.registry.auth.now()),
                    &check,
                )?;
                continue;
            }
            if contract.request_auth_invalid(response.status) {
                let _state = self.scope.lock().expect("signed session coordinator lock");
                let latest = self.load()?;
                if !request_auth_retry
                    && latest.usable(self.registry.auth.now())
                    && !latest.same_session(&record)
                {
                    request_auth_retry = true;
                    record = latest;
                    continue;
                }
                return Ok(protocol::response_value(response, self.registry.auth.now()));
            }
            let action = contract.gateway_action(response.status);
            if action.is_empty() {
                return Ok(protocol::response_value(response, self.registry.auth.now()));
            }
            let mut state = self.scope.lock().expect("signed session coordinator lock");
            let mut latest = self.load()?;
            if latest.usable(self.registry.auth.now()) && !latest.same_session(&record) {
                if session_retries >= 1 {
                    return Err("signed-session retry limit reached".into());
                }
                session_retries += 1;
                record = latest;
                continue;
            }
            if action == "bootstrap_session" && latest.same_session(&record) {
                state.blocked_generation.clear();
                latest.clear();
                self.store.save(&latest)?;
            } else if action == "verify" && latest.same_session(&record) {
                state.blocked_generation = record.generation();
            }
            drop(state);
            let url = self.bootstrap(&check)?;
            if !url.is_empty() {
                return Ok(self.verification_required(url));
            }
            let _state = self.scope.lock().expect("signed session coordinator lock");
            let bootstrapped = self.load()?;
            if bootstrapped.usable(self.registry.auth.now())
                && !bootstrapped.same_session(&record)
                && session_retries < 1
            {
                session_retries += 1;
                record = bootstrapped;
                continue;
            }
            return Ok(protocol::response_value(response, self.registry.auth.now()));
        }
    }
}

fn on_mint_failure<T>(
    recheck: impl FnOnce() -> Result<(), String>,
    verification: impl FnOnce() -> T,
) -> Result<T, String> {
    recheck()?;
    Ok(verification())
}

#[cfg(test)]
mod signed_session_mint_tests {
    use super::on_mint_failure;
    use crate::auth::AuthRegistry;
    use crate::manifest::SignedSession;
    use crate::signed_session::SignedRegistry;
    use mornye_network::NetworkService;
    use std::collections::BTreeMap;
    use std::net::TcpListener;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant};

    #[test]
    fn mint_failure_becomes_verification_required() {
        let out = on_mint_failure(|| Ok(()), || serde_json::json!({"needsVerification": true}));
        assert_eq!(out.unwrap()["needsVerification"], true);
    }

    #[test]
    fn mint_failure_propagates_cancellation() {
        let out = on_mint_failure(|| Err("download cancelled".to_string()), || 1);
        assert_eq!(out.unwrap_err(), "download cancelled");
    }

    #[test]
    fn signed_fetch_preserves_verification_for_missing_expired_and_blocked_sessions() {
        let directory = tempfile::tempdir().unwrap();
        let network = NetworkService::new().unwrap();
        let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
        let client = registry
            .session(
                "example.session",
                SignedSession {
                    namespace: "example-session".into(),
                    base_url: "https://127.0.0.1".into(),
                    ..Default::default()
                },
                network.native_session(Duration::from_secs(2)),
            )
            .unwrap();
        // Private network access stays denied, so bootstrap fails without
        // contacting a real gateway or depending on an external service.
        for state in ["missing", "expired", "blocked"] {
            let mut record = client.load().unwrap();
            if state != "missing" {
                record.session_id = "example-session-id".into();
                record.session_secret = "example-session-secret".into();
                record.expires_at = if state == "expired" {
                    "2000-01-01T00:00:00Z"
                } else {
                    "2099-01-01T00:00:00Z"
                }
                .into();
                client.store.save(&record).unwrap();
            }
            if state == "blocked" {
                client.scope.lock().unwrap().blocked_generation = record.generation();
            }
            let result = client
                .signed_fetch("GET", "/track", "", &BTreeMap::new(), || Ok(()))
                .unwrap();
            assert_eq!(result["ok"], false, "{state}");
            assert_eq!(result["needsVerification"], true, "{state}");
            assert_eq!(result["error"], "VERIFY_REQUIRED", "{state}");
            assert_eq!(result["auth_url"], "", "{state}");
            assert_eq!(result["open_auth_url"], "", "{state}");
            assert!(client.take_verification_url().is_empty());
        }
    }

    #[test]
    fn signed_fetch_does_not_turn_in_flight_cancellation_into_verification() {
        let directory = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let base_url = format!("https://{}", listener.local_addr().unwrap());
        let cancelled = Arc::new(AtomicBool::new(false));
        let cancel = Arc::clone(&cancelled);
        let server = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            while Instant::now() < deadline {
                match listener.accept() {
                    Ok((stream, _)) => {
                        cancel.store(true, Ordering::Release);
                        drop(stream);
                        return;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    Err(error) => panic!("session fixture accept: {error}"),
                }
            }
            panic!("bootstrap did not contact the session fixture");
        });
        let network = NetworkService::new().unwrap();
        network.set_allow_private_network(true);
        let registry = SignedRegistry::new(directory.path(), Arc::new(AuthRegistry::default()));
        let client = registry
            .session(
                "example.session",
                SignedSession {
                    namespace: "example-session".into(),
                    base_url,
                    ..Default::default()
                },
                network.native_session(Duration::from_secs(2)),
            )
            .unwrap();
        let result = client.signed_fetch("GET", "/track", "", &BTreeMap::new(), || {
            if cancelled.load(Ordering::Acquire) {
                Err("download cancelled".into())
            } else {
                Ok(())
            }
        });
        server.join().unwrap();
        assert_eq!(result.unwrap_err(), "download cancelled");
    }
}
