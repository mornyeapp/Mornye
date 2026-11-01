use super::*;
use std::thread;

type Handler = dyn Fn(&str, &SearchRequest, &Check<'_>) -> FetchResult + Send + Sync;
struct Mock {
    handler: Box<Handler>,
    extensions: Vec<String>,
}
impl LyricsFetcher for Mock {
    fn extensions(&self) -> Vec<String> {
        self.extensions.clone()
    }
    fn fetch(&self, provider: &str, request: &SearchRequest, check: &Check<'_>) -> FetchResult {
        (self.handler)(provider, request, check)
    }
}
fn service(
    handler: impl Fn(&str, &SearchRequest, &Check<'_>) -> FetchResult + Send + Sync + 'static,
) -> Arc<LyricsService> {
    let service = Arc::new(LyricsService::new(Arc::new(Mock {
        handler: Box::new(handler),
        extensions: vec!["example.lyrics".into()],
    })));
    service.set_providers(&["lrclib".into()]).unwrap();
    service
}
fn request() -> SearchRequest {
    SearchRequest {
        track: "Song".into(),
        artist: "Artist".into(),
        duration: 180.0,
        ..SearchRequest::default()
    }
}
fn lyrics(source: &str) -> LyricsResponse {
    LyricsResponse::from_text("[00:01.00]Line", "Example", source)
}
fn until(condition: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(3);
    while !condition() {
        assert!(Instant::now() < deadline, "condition timed out");
        thread::sleep(Duration::from_millis(2));
    }
}
fn waiters(service: &LyricsService) -> usize {
    service
        .inner
        .state
        .lock()
        .unwrap()
        .flights
        .values()
        .map(|flight| flight.waiters())
        .sum()
}
fn wait_gate(gate: &AtomicBool, check: &Check<'_>) -> Result<(), LyricsError> {
    while !gate.load(Ordering::Acquire) {
        check().map_err(LyricsError::Cancelled)?;
        thread::sleep(Duration::from_millis(2));
    }
    check().map_err(LyricsError::Cancelled)
}

#[test]
fn eight_callers_share_work_and_cancelled_waiter_does_not_cancel_others() {
    let calls = Arc::new(AtomicUsize::new(0));
    let gate = Arc::new(AtomicBool::new(false));
    let service = service({
        let calls = calls.clone();
        let gate = gate.clone();
        move |_, _, check| {
            calls.fetch_add(1, Ordering::AcqRel);
            wait_gate(&gate, check)?;
            Ok(lyrics("LRCLIB"))
        }
    });
    let cancelled = Arc::new(AtomicBool::new(false));
    let mut workers = Vec::new();
    for index in 0..8 {
        let service = service.clone();
        let cancelled = cancelled.clone();
        workers.push(thread::spawn(move || {
            service.fetch(request(), &|| {
                if index == 0 && cancelled.load(Ordering::Acquire) {
                    Err("caller cancelled".into())
                } else {
                    Ok(())
                }
            })
        }));
    }
    until(|| waiters(&service) == 8);
    cancelled.store(true, Ordering::Release);
    assert_eq!(
        workers.remove(0).join().unwrap(),
        Err(LyricsError::Cancelled("caller cancelled".into()))
    );
    gate.store(true, Ordering::Release);
    for worker in workers {
        assert_eq!(worker.join().unwrap().unwrap().source, "LRCLIB");
    }
    assert_eq!(calls.load(Ordering::Acquire), 1);
    assert_eq!(
        service.fetch(request(), &|| Ok(())).unwrap().source,
        "LRCLIB (cached)"
    );
}

#[test]
fn abandoning_all_waiters_cancels_work_without_negative_caching() {
    let calls = Arc::new(AtomicUsize::new(0));
    let service = service({
        let calls = calls.clone();
        move |_, _, check| {
            if calls.fetch_add(1, Ordering::AcqRel) == 0 {
                loop {
                    check().map_err(LyricsError::Cancelled)?;
                    thread::sleep(Duration::from_millis(2));
                }
            }
            Ok(lyrics("LRCLIB"))
        }
    });
    let cancelled = Arc::new(AtomicBool::new(false));
    let worker = {
        let service = service.clone();
        let cancelled = cancelled.clone();
        thread::spawn(move || {
            service.fetch(request(), &|| {
                if cancelled.load(Ordering::Acquire) {
                    Err("cancelled".into())
                } else {
                    Ok(())
                }
            })
        })
    };
    until(|| calls.load(Ordering::Acquire) == 1);
    cancelled.store(true, Ordering::Release);
    assert!(matches!(
        worker.join().unwrap(),
        Err(LyricsError::Cancelled(_))
    ));
    until(|| service.inner.state.lock().unwrap().flights.active() == 0);
    assert_eq!(
        service.fetch(request(), &|| Ok(())).unwrap().source,
        "LRCLIB"
    );
    assert_eq!(calls.load(Ordering::Acquire), 2);
}

#[test]
fn rejecting_recursive_joins_releases_their_waiter_registrations() {
    let gate = Arc::new(AtomicBool::new(false));
    let service = service({
        let gate = gate.clone();
        move |_, _, check| {
            wait_gate(&gate, check)?;
            Ok(lyrics("LRCLIB"))
        }
    });
    let cancelled = Arc::new(AtomicBool::new(false));
    let worker = {
        let service = service.clone();
        let cancelled = cancelled.clone();
        thread::spawn(move || {
            service.fetch(request(), &|| {
                if cancelled.load(Ordering::Acquire) {
                    Err("cancelled".into())
                } else {
                    Ok(())
                }
            })
        })
    };
    until(|| waiters(&service) == 1);
    let caller = service
        .inner
        .state
        .lock()
        .unwrap()
        .flights
        .values()
        .next()
        .unwrap()
        .tag()
        .clone();
    for _ in 0..3 {
        let mut recursive = request();
        recursive.caller = Some(caller.clone());
        assert!(matches!(
            service.fetch(recursive, &|| Ok(())),
            Err(LyricsError::Recursive(_))
        ));
        assert_eq!(waiters(&service), 1);
    }
    cancelled.store(true, Ordering::Release);
    assert!(matches!(
        worker.join().unwrap(),
        Err(LyricsError::Cancelled(_))
    ));
    until(|| service.inner.state.lock().unwrap().flights.active() == 0);
}

#[test]
fn provider_priority_waits_within_grace_then_cancels_slow_workers() {
    let calls = Arc::new(AtomicUsize::new(0));
    let cancelled = Arc::new(AtomicBool::new(false));
    let service = service({
        let calls = calls.clone();
        let cancelled = cancelled.clone();
        move |name, _, check| {
            calls.fetch_add(1, Ordering::AcqRel);
            if name == "lrclib" {
                while check().is_ok() {
                    thread::sleep(Duration::from_millis(2));
                }
                cancelled.store(true, Ordering::Release);
                return Err(LyricsError::Cancelled("cancelled loser".into()));
            }
            Ok(lyrics("Extension:example.lyrics"))
        }
    });
    service
        .set_providers(&["lrclib".into(), "extension:example.lyrics".into()])
        .unwrap();
    let start = Instant::now();
    assert_eq!(
        service.fetch(request(), &|| Ok(())).unwrap().source,
        "Extension:example.lyrics"
    );
    assert!(start.elapsed() >= PRIORITY_GRACE);
    assert!(start.elapsed() < PRIORITY_GRACE + Duration::from_secs(2));
    assert!(cancelled.load(Ordering::Acquire));
    assert_eq!(calls.load(Ordering::Acquire), 2);

    let preferred = service_for_preference();
    assert_eq!(
        preferred.fetch(request(), &|| Ok(())).unwrap().source,
        "LRCLIB"
    );
}

fn service_for_preference() -> Arc<LyricsService> {
    let service = service(|name, _, check| {
        if name == "lrclib" {
            thread::sleep(Duration::from_millis(60));
        }
        check().map_err(LyricsError::Cancelled)?;
        Ok(lyrics(if name == "lrclib" {
            "LRCLIB"
        } else {
            "Extension:example.lyrics"
        }))
    });
    service
        .set_providers(&["lrclib".into(), "extension:example.lyrics".into()])
        .unwrap();
    service
}

#[test]
fn at_most_three_providers_run_and_shutdown_joins_cancelled_calls() {
    let active = Arc::new(AtomicUsize::new(0));
    let entered = Arc::new(AtomicUsize::new(0));
    let service = service({
        let active = active.clone();
        let entered = entered.clone();
        move |_, _, check| {
            active.fetch_add(1, Ordering::AcqRel);
            entered.fetch_add(1, Ordering::AcqRel);
            let result = loop {
                if let Err(error) = check() {
                    break Err(LyricsError::Cancelled(error));
                }
                thread::sleep(Duration::from_millis(2));
            };
            active.fetch_sub(1, Ordering::AcqRel);
            result
        }
    });
    service
        .set_providers(&[
            "lrclib".into(),
            "apple_music".into(),
            "netease".into(),
            "qqmusic".into(),
            "extension:example.lyrics".into(),
        ])
        .unwrap();
    let worker = {
        let service = service.clone();
        thread::spawn(move || service.fetch(request(), &|| Ok(())))
    };
    until(|| active.load(Ordering::Acquire) == 3);
    service.shutdown().unwrap();
    assert_eq!(entered.load(Ordering::Acquire), 3);
    assert_eq!(active.load(Ordering::Acquire), 0);
    assert!(matches!(
        worker.join().unwrap(),
        Err(LyricsError::Cancelled(_))
    ));
    assert!(matches!(
        service.fetch(request(), &|| Ok(())),
        Err(LyricsError::Cancelled(_))
    ));
}

#[test]
fn confirmed_missing_lyrics_are_cached_with_a_bounded_expiry() {
    let calls = Arc::new(AtomicUsize::new(0));
    let service = service({
        let calls = calls.clone();
        move |_, _, _| {
            calls.fetch_add(1, Ordering::AcqRel);
            Err(LyricsError::NotFound("missing".into()))
        }
    });
    assert!(service.fetch(request(), &|| Ok(())).is_err());
    assert_eq!(
        service.fetch(request(), &|| Ok(())),
        Err(LyricsError::NotFound("lyrics not found (cached)".into()))
    );
    let mut second = request();
    second.track = "Second".into();
    assert!(service.fetch(second, &|| Ok(())).is_err());
    assert_eq!(calls.load(Ordering::Acquire), 2);
    {
        let mut state = service.inner.state.lock().unwrap();
        for expiry in state.negative.values_mut() {
            *expiry = Instant::now();
        }
        for expiry in state.health.values_mut() {
            *expiry = Instant::now();
        }
    }
    assert!(service.fetch(request(), &|| Ok(())).is_err());
    assert_eq!(calls.load(Ordering::Acquire), 3);
    let mut third = request();
    third.track = "Third".into();
    assert!(service.fetch(third, &|| Ok(())).is_err());
    assert_eq!(calls.load(Ordering::Acquire), 4);
    for index in 0..510 {
        let mut request = request();
        request.track = format!("Missing {index}");
        assert!(service.fetch(request, &|| Ok(())).is_err());
    }
    assert_eq!(
        service.inner.state.lock().unwrap().negative.len(),
        MAX_NEGATIVE
    );
}

#[test]
fn a_transient_outage_recovers_before_flac_lyrics_embedding() {
    let calls = Arc::new(AtomicUsize::new(0));
    let service = service({
        let calls = Arc::clone(&calls);
        move |_, _, _| {
            if calls.fetch_add(1, Ordering::AcqRel) == 0 {
                Err(LyricsError::Unavailable("HTTP 503".into()))
            } else {
                Ok(lyrics("LRCLIB"))
            }
        }
    });
    let found = service.fetch(request(), &|| Ok(())).unwrap();
    assert_eq!(found.source, "LRCLIB");
    assert_eq!(calls.load(Ordering::Acquire), 2);
    let state = service.inner.state.lock().unwrap();
    assert!(state.negative.is_empty());
    assert!(state.health.is_empty());
    drop(state);
    let lrc = mornye_core::lyrics::lrc::with_metadata(&found, "Song", "Artist");
    let mut original = b"fLaC\x80\x00\x00\x22".to_vec();
    original.extend_from_slice(&[0; 34]);
    let audio = b"\xff\xf8original audio frames";
    original.extend_from_slice(audio);
    let mut tagged = Vec::new();
    mornye_core::tags::embed_flac_metadata(
        &mut std::io::Cursor::new(original),
        &mut tagged,
        &BTreeMap::from([("LYRICS".into(), lrc.clone())]),
        "joined",
        None,
        &|| Ok(()),
    )
    .unwrap();
    assert!(tagged.ends_with(audio));
    let metadata =
        mornye_core::tags::read_audio_tags(&mut std::io::Cursor::new(tagged), "flac", &|| Ok(()))
            .unwrap();
    assert_eq!(metadata.lyrics, lrc);
}

#[test]
fn recovery_respects_a_providers_rate_limit() {
    let calls = Arc::new(AtomicUsize::new(0));
    let service = service({
        let calls = Arc::clone(&calls);
        move |_, _, _| {
            calls.fetch_add(1, Ordering::AcqRel);
            Err(LyricsError::Unavailable("HTTP 429".into()))
        }
    });
    assert!(matches!(
        service.fetch(request(), &|| Ok(())),
        Err(LyricsError::Unavailable(_))
    ));
    assert_eq!(calls.load(Ordering::Acquire), 1);
    let state = service.inner.state.lock().unwrap();
    assert!(state.negative.is_empty());
    assert!(state.health["lrclib"] > Instant::now() + Duration::from_secs(30));
}

#[test]
fn exhausted_recovery_does_not_cache_an_outage_as_missing_lyrics() {
    let recovered = Arc::new(AtomicBool::new(false));
    let calls = Arc::new(AtomicUsize::new(0));
    let service = service({
        let recovered = Arc::clone(&recovered);
        let calls = Arc::clone(&calls);
        move |_, _, _| {
            calls.fetch_add(1, Ordering::AcqRel);
            if recovered.load(Ordering::Acquire) {
                Ok(lyrics("LRCLIB"))
            } else {
                Err(LyricsError::Unavailable("HTTP 503".into()))
            }
        }
    });
    assert_eq!(
        service.fetch(request(), &|| Ok(())),
        Err(LyricsError::Unavailable("HTTP 503".into()))
    );
    assert_eq!(calls.load(Ordering::Acquire), 2);
    assert!(service.inner.state.lock().unwrap().negative.is_empty());
    recovered.store(true, Ordering::Release);
    // A successful explicit provider lookup also clears the shared cooldown.
    assert!(service.fetch_from("lrclib", request(), &|| Ok(())).is_ok());
    assert!(service.fetch(request(), &|| Ok(())).is_ok());
    assert_eq!(calls.load(Ordering::Acquire), 4);
}

#[test]
fn a_cooling_provider_cannot_turn_another_providers_miss_into_a_cached_miss() {
    let calls = Arc::new(AtomicUsize::new(0));
    let service = service({
        let calls = Arc::clone(&calls);
        move |provider, _, _| {
            calls.fetch_add(1, Ordering::AcqRel);
            if provider == "extension:example.lyrics" {
                Ok(lyrics(provider))
            } else {
                Err(LyricsError::NotFound("missing".into()))
            }
        }
    });
    service
        .set_providers(&["lrclib".into(), "extension:example.lyrics".into()])
        .unwrap();
    service.inner.state.lock().unwrap().health.insert(
        "extension:example.lyrics".into(),
        Instant::now() + UNAVAILABLE_COOLDOWN,
    );
    let result = service.fetch(request(), &|| Ok(())).unwrap();
    assert_eq!(result.source, "extension:example.lyrics");
    assert_eq!(calls.load(Ordering::Acquire), 3);
    assert!(service.inner.state.lock().unwrap().negative.is_empty());
}

#[test]
fn a_later_missing_result_cannot_hide_another_providers_error() {
    let service = service(|provider, _, _| {
        if provider == "lrclib" {
            Err(LyricsError::Other("invalid provider response".into()))
        } else {
            thread::sleep(Duration::from_millis(30));
            Err(LyricsError::NotFound("missing".into()))
        }
    });
    service
        .set_providers(&["lrclib".into(), "extension:example.lyrics".into()])
        .unwrap();
    assert_eq!(
        service.fetch(request(), &|| Ok(())),
        Err(LyricsError::Other("invalid provider response".into()))
    );
    assert!(service.inner.state.lock().unwrap().negative.is_empty());
}

#[test]
fn unclassified_provider_errors_can_recover_in_the_same_lookup() {
    let calls = Arc::new(AtomicUsize::new(0));
    let service = service({
        let calls = Arc::clone(&calls);
        move |_, _, _| {
            if calls.fetch_add(1, Ordering::AcqRel) == 0 {
                Err(LyricsError::Other("invalid provider response".into()))
            } else {
                Ok(lyrics("LRCLIB"))
            }
        }
    });
    assert!(service.fetch(request(), &|| Ok(())).is_ok());
    assert!(service.fetch(request(), &|| Ok(())).is_ok());
    assert_eq!(calls.load(Ordering::Acquire), 2);
}

#[test]
fn cancelling_recovery_does_not_start_a_second_provider_attempt() {
    let calls = Arc::new(AtomicUsize::new(0));
    let service = service({
        let calls = Arc::clone(&calls);
        move |_, _, _| {
            calls.fetch_add(1, Ordering::AcqRel);
            Err(LyricsError::Unavailable("HTTP 503".into()))
        }
    });
    let cancel = Arc::new(AtomicBool::new(false));
    let worker = {
        let service = Arc::clone(&service);
        let cancel = Arc::clone(&cancel);
        thread::spawn(move || {
            service.fetch(request(), &|| {
                if cancel.load(Ordering::Acquire) {
                    Err("cancelled during recovery".into())
                } else {
                    Ok(())
                }
            })
        })
    };
    until(|| calls.load(Ordering::Acquire) == 1);
    cancel.store(true, Ordering::Release);
    assert!(matches!(
        worker.join().unwrap(),
        Err(LyricsError::Cancelled(_))
    ));
    until(|| service.inner.state.lock().unwrap().flights.active() == 0);
    assert_eq!(calls.load(Ordering::Acquire), 1);
    assert!(service.inner.state.lock().unwrap().negative.is_empty());
}

#[test]
fn config_changes_prevent_late_results_from_repopulating_current_cache() {
    let gate = Arc::new(AtomicBool::new(false));
    let calls = Arc::new(AtomicUsize::new(0));
    let service = service({
        let gate = gate.clone();
        let calls = calls.clone();
        move |_, request, check| {
            calls.fetch_add(1, Ordering::AcqRel);
            if request.options.musixmatch_language.is_empty() {
                wait_gate(&gate, check)?;
            }
            Ok(lyrics(&request.options.musixmatch_language))
        }
    });
    let old = {
        let service = service.clone();
        thread::spawn(move || service.fetch(request(), &|| Ok(())))
    };
    until(|| calls.load(Ordering::Acquire) == 1);
    service
        .set_options(FetchOptions {
            musixmatch_language: " EN! ".into(),
            ..FetchOptions::default()
        })
        .unwrap();
    assert_eq!(service.fetch(request(), &|| Ok(())).unwrap().source, "en");
    gate.store(true, Ordering::Release);
    assert_eq!(old.join().unwrap().unwrap().source, "");
    assert_eq!(service.cache_size(), 1);
    assert_eq!(
        service.fetch(request(), &|| Ok(())).unwrap().source,
        "en (cached)"
    );
    assert_eq!(calls.load(Ordering::Acquire), 2);
}

#[test]
fn selected_extension_gets_a_chance_before_builtin_cache_and_has_cached_fallback() {
    let mode = Arc::new(AtomicUsize::new(0));
    let calls = Arc::new(AtomicUsize::new(0));
    let service = service({
        let mode = mode.clone();
        let calls = calls.clone();
        move |name, _, _| {
            calls.fetch_add(1, Ordering::AcqRel);
            match (mode.load(Ordering::Acquire), name) {
                (0, "lrclib") => Ok(lyrics("LRCLIB")),
                (2, "extension:example.lyrics") => Ok(lyrics("Extension:example.lyrics")),
                _ => Err(LyricsError::NotFound("missing".into())),
            }
        }
    });
    service
        .set_providers(&["extension:example.lyrics".into(), "lrclib".into()])
        .unwrap();
    assert_eq!(
        service.fetch(request(), &|| Ok(())).unwrap().source,
        "LRCLIB"
    );
    mode.store(1, Ordering::Release);
    assert_eq!(
        service.fetch(request(), &|| Ok(())).unwrap().source,
        "LRCLIB (cached fallback)"
    );
    mode.store(2, Ordering::Release);
    assert_eq!(
        service.fetch(request(), &|| Ok(())).unwrap().source,
        "Extension:example.lyrics"
    );
    let previous = calls.load(Ordering::Acquire);
    assert_eq!(
        service.fetch(request(), &|| Ok(())).unwrap().source,
        "Extension:example.lyrics (cached)"
    );
    assert_eq!(calls.load(Ordering::Acquire), previous);
}

#[test]
fn instrumental_heuristic_skips_network_and_provider_panics_release_workers() {
    let service = service(|_, _, _| panic!("fixture provider failure"));
    let mut instrumental = request();
    instrumental.track = "Song (Instrumental)".into();
    let response = service.fetch(instrumental, &|| Ok(())).unwrap();
    assert!(response.instrumental);
    assert_eq!(response.source, "Heuristic: Instrumental");
    assert!(service.fetch(request(), &|| Ok(())).is_err());
    service.shutdown().unwrap();
    assert_eq!(service.inner.state.lock().unwrap().flights.active(), 0);
}

#[test]
fn transport_policy_cancellation_is_not_cached_as_missing_lyrics() {
    let calls = Arc::new(AtomicUsize::new(0));
    let service = service({
        let calls = calls.clone();
        move |_, _, _| {
            if calls.fetch_add(1, Ordering::AcqRel) == 0 {
                Err(LyricsError::Cancelled("network policy changed".into()))
            } else {
                Ok(lyrics("LRCLIB"))
            }
        }
    });
    assert_eq!(
        service.fetch(request(), &|| Ok(())),
        Err(LyricsError::Cancelled("network policy changed".into()))
    );
    assert_eq!(
        service.fetch(request(), &|| Ok(())).unwrap().source,
        "LRCLIB"
    );
    assert_eq!(calls.load(Ordering::Acquire), 2);
}

#[test]
fn shutdown_flushes_cache_and_rejects_retained_mutations() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("lyrics.json");
    let replacement = directory.path().join("replacement.json");
    let service = service(|_, _, _| Ok(lyrics("LRCLIB")));
    service.set_persistence_path(&path).unwrap();
    service.fetch(request(), &|| Ok(())).unwrap();
    service.shutdown().unwrap();
    let persisted = std::fs::read(&path).unwrap();
    let options = service.options();
    let providers = service.providers();
    let closed = LyricsError::Cancelled("lyrics service is closed".into());
    assert_eq!(
        service.set_providers(&["apple_music".into()]),
        Err(closed.clone())
    );
    assert_eq!(
        service.set_options(FetchOptions {
            musixmatch_language: "id".into(),
            ..Default::default()
        }),
        Err(closed.clone())
    );
    assert_eq!(
        service.set_persistence_path(&replacement),
        Err(closed.clone())
    );
    assert_eq!(service.clear_cache(), Err(closed.clone()));
    assert_eq!(service.drop_memory(), Err(closed));
    assert_eq!(service.options(), options);
    assert_eq!(service.providers(), providers);
    assert_eq!(service.cache_size(), 1);
    service.shutdown().unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), persisted);
    assert!(!replacement.exists());
}

#[test]
fn fetch_from_asks_only_the_chosen_provider_and_bypasses_the_cache() {
    let asked = Arc::new(Mutex::new(Vec::new()));
    let service = service({
        let asked = asked.clone();
        move |provider, _, _| {
            asked.lock().unwrap().push(provider.to_owned());
            Ok(lyrics(provider))
        }
    });
    service
        .set_providers(&[
            "lrclib".into(),
            "netease".into(),
            "extension:example.lyrics".into(),
        ])
        .unwrap();
    // The chain answers from LRCLIB and caches it. It races several
    // providers, so only later calls are recorded.
    assert_eq!(
        service.fetch(request(), &|| Ok(())).unwrap().source,
        "lrclib"
    );
    asked.lock().unwrap().clear();
    assert_eq!(
        service
            .fetch_from(" Netease ", request(), &|| Ok(()))
            .unwrap()
            .source,
        "netease"
    );
    assert_eq!(
        service
            .fetch_from("extension:example.lyrics", request(), &|| Ok(()))
            .unwrap()
            .source,
        "extension:example.lyrics"
    );
    assert_eq!(
        *asked.lock().unwrap(),
        ["netease", "extension:example.lyrics"]
    );
    assert_eq!(
        service.enabled_providers(),
        ["lrclib", "netease", "extension:example.lyrics"]
    );
}

#[test]
fn fetch_from_rejects_disabled_providers_and_honours_cancellation() {
    let service = service(|provider, _, _| Ok(lyrics(provider)));
    assert!(matches!(
        service.fetch_from("netease", request(), &|| Ok(())),
        Err(LyricsError::Other(_))
    ));
    assert!(matches!(
        service.fetch_from("extension:missing", request(), &|| Ok(())),
        Err(LyricsError::Other(_))
    ));
    assert!(matches!(
        service.fetch_from("lrclib", request(), &|| Err("gone".into())),
        Err(LyricsError::Cancelled(_))
    ));
}
