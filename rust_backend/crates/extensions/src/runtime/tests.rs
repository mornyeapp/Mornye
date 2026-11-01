use super::vm::Vm;
use super::*;
use std::sync::atomic::Ordering;

#[test]
fn queued_timeout_returns_before_busy_worker_is_released() {
    let runtime = ExtensionRuntime::load(
        "let calls=0;registerExtension({next(){return ++calls}});",
        "{}",
        RuntimeLimits::default(),
    )
    .unwrap();
    // Hold the worker at a rendezvous without consuming CPU or relying on a
    // slow JavaScript function. The following call must remain queued.
    let (hold, release) = mpsc::sync_channel(0);
    runtime.sender.send(Command::InspectHeap(hold)).unwrap();
    thread::scope(|scope| {
        let runtime = &runtime;
        let (done, result) = mpsc::sync_channel(1);
        scope.spawn(move || done.send(runtime.call("next", "[]", None, 30)).unwrap());
        let early = result.recv_timeout(Duration::from_secs(1));
        // Always release before asserting so a failed regression cannot hang.
        release.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(early, Ok(Err(ExtensionError::Timeout)));
    });
    assert_eq!(runtime.call("next", "[]", None, 1000).unwrap(), "1");
}

#[test]
fn queued_lease_interruption_returns_without_retiring_the_busy_worker() {
    use mornye_core::cancellation::{CancellationDomain, CancellationRegistry};

    for mode in ["cancel", "release", "shutdown"] {
        let runtime = ExtensionRuntime::load(
            "let calls=0;registerExtension({next(){return ++calls}});",
            "{}",
            RuntimeLimits::default(),
        )
        .unwrap();
        let registry = CancellationRegistry::new(CancellationDomain::ExtensionRequest);
        let lease = Arc::new(registry.acquire("queued").unwrap());
        let (hold, release) = mpsc::sync_channel(0);
        runtime.sender.send(Command::InspectHeap(hold)).unwrap();
        thread::scope(|scope| {
            let runtime = &runtime;
            let request = Arc::clone(&lease);
            let (done, result) = mpsc::sync_channel(1);
            scope.spawn(move || {
                done.send(runtime.call("next", "[]", Some(request), 5000))
                    .unwrap()
            });
            // The pending operation is cloned only after its initial check.
            // Interrupt after that check, while the VM is still held above.
            let began = Instant::now();
            while Arc::strong_count(&lease) < 3 && began.elapsed() < Duration::from_secs(1) {
                thread::sleep(Duration::from_millis(1));
            }
            let pending = Arc::strong_count(&lease) >= 3;
            let expected = match mode {
                "cancel" => {
                    registry.cancel("queued").unwrap();
                    CancellationError::ExtensionRequestCancelled
                }
                "release" => {
                    lease.release();
                    CancellationError::LeaseReleased
                }
                _ => {
                    registry.shutdown();
                    CancellationError::RegistryClosed
                }
            };
            let early = result.recv_timeout(Duration::from_secs(1));
            release.recv_timeout(Duration::from_secs(1)).unwrap();
            assert!(pending, "call did not reach the queue: {mode}");
            assert_eq!(
                early,
                Ok(Err(ExtensionError::Cancelled(expected))),
                "{mode}"
            );
        });
        assert_eq!(runtime.call("next", "[]", None, 1000).unwrap(), "1");
    }
}

#[test]
fn worker_collects_once_after_idle_burst_and_preserves_live_state() {
    let runtime = ExtensionRuntime::load(
        "let calls=0;const keep={value:'live-state'};registerExtension({allocate(){const cycle={bytes:new Uint8Array(16*1024*1024)};cycle.self=cycle;return ++calls;},state(){return {calls,value:keep.value};}});",
        "{}",
        RuntimeLimits::default(),
    )
    .unwrap();
    let snapshot = || {
        let (reply, result) = mpsc::sync_channel(1);
        runtime.sender.send(Command::InspectHeap(reply)).unwrap();
        result.recv_timeout(Duration::from_secs(5)).unwrap()
    };
    assert_eq!(runtime.call("allocate", "[]", None, 0).unwrap(), "1");
    let (retained, collections) = snapshot();
    let deadline = Instant::now() + Duration::from_secs(5);
    let collected = loop {
        thread::sleep(Duration::from_millis(25));
        let (bytes, count) = snapshot();
        if count > collections {
            assert_eq!(count, collections + 1);
            break bytes;
        }
        assert!(Instant::now() < deadline, "idle collection did not run");
    };
    assert!(retained - collected >= 16 * 1024 * 1024);
    thread::sleep(IDLE_GC_DELAY + Duration::from_millis(50));
    assert_eq!(
        snapshot().1,
        collections + 1,
        "clean idle VM collected again"
    );
    let state: serde_json::Value =
        serde_json::from_str(&runtime.call("state", "[]", None, 0).unwrap()).unwrap();
    assert_eq!(state, serde_json::json!({"calls":1,"value":"live-state"}));
    eprintln!(
        "actual worker idle GC: before_bytes={retained} after_bytes={collected} freed_bytes={} collections=1",
        retained - collected
    );
    runtime.shutdown();
}

#[test]
fn idle_gc_reclaims_unreachable_cycles_without_changing_live_state() {
    let source = "let calls=0; const keep={value:'live-state'}; registerExtension({allocate(){const cycle={bytes:new Uint8Array(16*1024*1024)};cycle.self=cycle;return ++calls;},state(){return {calls,value:keep.value};}});";
    let control = Arc::new(Control::default());
    let services = ExtensionServices {
        compiled_source: Some(Arc::new(CompiledSource {
            source: source.into(),
            bytecode: OnceLock::new(),
        })),
        ..ExtensionServices::default()
    };
    let vm = Vm::load(&control, &RuntimeLimits::default(), source, "{}", &services).unwrap();
    vm._runtime.run_gc();
    let baseline = vm._runtime.memory_usage().memory_used_size;
    let call = |method| {
        vm.execute(
            &control,
            method,
            "[]",
            Operation {
                item_id: String::new(),
                deadline: Instant::now() + Duration::from_secs(5),
                lease: None,
                resolution: None,
            },
            CallKind::Function,
        )
        .unwrap()
    };
    assert_eq!(call("allocate"), "1");
    let retained = vm._runtime.memory_usage().memory_used_size;
    let started = Instant::now();
    vm._runtime.run_gc();
    let elapsed = started.elapsed();
    let collected = vm._runtime.memory_usage().memory_used_size;
    assert!(retained - collected >= 16 * 1024 * 1024);
    let state: serde_json::Value = serde_json::from_str(&call("state")).unwrap();
    assert_eq!(state, serde_json::json!({"calls":1,"value":"live-state"}));
    eprintln!(
        "QuickJS isolated idle cycle probe: baseline_bytes={baseline} retained_bytes={retained} after_gc_bytes={collected} freed_bytes={} gc_us={}",
        retained - collected,
        elapsed.as_micros()
    );
}

#[test]
fn argument_validation_rejects_before_execution_and_keeps_runtime_usable() {
    let runtime = ExtensionRuntime::load(
        "let calls=0; registerExtension({echo(value){return {calls:++calls,value}}});",
        "{}",
        RuntimeLimits::default(),
    )
    .unwrap();
    for input in ["{}", "[1e400]", "[\"\\uD800\"]", "[] true"] {
        assert!(matches!(
            runtime.call("echo", input, None, 0),
            Err(ExtensionError::InvalidInput(_))
        ));
    }
    let input = "[{\"title\":\"音楽 🎵\",\"nested\":[true,null,{\"key\":\"value\"}]}]";
    let output: serde_json::Value =
        serde_json::from_str(&runtime.call("echo", input, None, 0).unwrap()).unwrap();
    assert_eq!(output["calls"], 1);
    assert_eq!(output["value"]["title"], "音楽 🎵");
    assert_eq!(output["value"]["nested"][2]["key"], "value");
}

#[test]
fn cached_source_still_obeys_each_vms_memory_and_stack_limits() {
    let source = "registerExtension({allocate(){const a=[];while(true)a.push(new Uint8Array(65536));},recurse(){function f(){return 1+f()}return f()}});";
    let primary = ExtensionRuntime::load(source, "{}", RuntimeLimits::default()).unwrap();
    let runtime = ExtensionRuntime::load_with_services(
        source,
        "{}",
        RuntimeLimits {
            memory_bytes: 2 << 20,
            stack_bytes: 128 << 10,
            ..Default::default()
        },
        ExtensionServices {
            compiled_source: Some(Arc::clone(&primary.compiled_source)),
            ..Default::default()
        },
    )
    .unwrap();
    for method in ["recurse", "allocate"] {
        assert!(
            matches!(
                runtime.call(method, "[]", None, 1000),
                Err(ExtensionError::Script(_))
            ),
            "{method}"
        );
    }
}

#[test]
fn compiled_source_reuses_bytecode_but_isolates_state_settings_and_new_source() {
    let source = "let n=0,s={};registerExtension({initialize(v){s=v;if(v.spin)while(true){}},next(){return [++n,s.id]}});";
    let primary = ExtensionRuntime::load(source, "{\"id\":0}", RuntimeLimits::default()).unwrap();
    let cache = Arc::clone(&primary.compiled_source);
    assert!(cache.bytecode.get().is_some());
    thread::scope(|scope| {
        let workers: Vec<_> = (1..=4)
            .map(|id| {
                let cache = Arc::clone(&cache);
                scope.spawn(move || {
                    let runtime = ExtensionRuntime::load_with_services(
                        source,
                        &format!("{{\"id\":{id}}}"),
                        RuntimeLimits::default(),
                        ExtensionServices {
                            compiled_source: Some(Arc::clone(&cache)),
                            ..Default::default()
                        },
                    )
                    .unwrap();
                    assert!(Arc::ptr_eq(&cache, &runtime.compiled_source));
                    assert_eq!(
                        runtime.call("next", "[]", None, 1000).unwrap(),
                        format!("[1,{id}]")
                    );
                    assert_eq!(
                        runtime.call("next", "[]", None, 1000).unwrap(),
                        format!("[2,{id}]")
                    );
                })
            })
            .collect();
        for worker in workers {
            worker.join().unwrap();
        }
    });
    assert_eq!(primary.call("next", "[]", None, 1000).unwrap(), "[1,0]");
    let timed_out = ExtensionRuntime::load_with_services(
        source,
        "{\"spin\":true}",
        RuntimeLimits {
            timeout_ms: 30,
            ..Default::default()
        },
        ExtensionServices {
            compiled_source: Some(Arc::clone(&cache)),
            ..Default::default()
        },
    );
    assert!(matches!(timed_out, Err(ExtensionError::Timeout)));
    let changed = ExtensionRuntime::load_with_services(
        "registerExtension({next(){return 99}});",
        "{}",
        RuntimeLimits::default(),
        ExtensionServices {
            compiled_source: Some(Arc::clone(&cache)),
            ..Default::default()
        },
    )
    .unwrap();
    assert!(!Arc::ptr_eq(&cache, &changed.compiled_source));
    assert_eq!(changed.call("next", "[]", None, 1000).unwrap(), "99");
}

#[test]
fn ffmpeg_waits_for_completion_cancellation_or_deadline_without_polling() {
    use mornye_core::cancellation::{CancellationDomain, CancellationRegistry};
    for mode in [
        "complete",
        "cancel",
        "release",
        "cancel-shutdown",
        "close",
        "shutdown",
        "timeout",
    ] {
        let registry = crate::ffmpeg::CommandRegistry::default();
        let cancellation = CancellationRegistry::new(CancellationDomain::Download);
        let lease = Arc::new(cancellation.acquire("example").unwrap());
        let control = Control::default();
        *control.operation.lock().unwrap() = Some(Operation {
            item_id: "example".into(),
            deadline: Instant::now()
                + if mode == "timeout" {
                    Duration::from_millis(100)
                } else {
                    Duration::from_secs(1)
                },
            lease: Some(Arc::clone(&lease)),
            resolution: None,
        });
        thread::scope(|scope| {
            let worker = scope
                .spawn(|| registry.execute("example", vec![], "in".into(), "out".into(), &control));
            let pending: serde_json::Value =
                serde_json::from_str(&registry.wait_pending_json(500).unwrap()).unwrap();
            let id = pending[0]["command_id"].as_str().unwrap();
            thread::sleep(Duration::from_millis(45));
            assert!(
                control.checks.load(Ordering::Relaxed) <= 3,
                "FFmpeg polled during {mode}"
            );
            let result = || crate::ffmpeg::CommandResult {
                success: true,
                output: "done".into(),
                error: String::new(),
            };
            let began = Instant::now();
            match mode {
                "complete" => {
                    assert!(registry.complete(id, result()).unwrap());
                }
                "cancel" => cancellation.cancel("example").unwrap(),
                "release" => lease.release(),
                "cancel-shutdown" => cancellation.shutdown(),
                "close" => control.close(),
                "shutdown" => registry.shutdown(),
                _ => {}
            }
            let finished = worker.join().unwrap();
            assert!(
                began.elapsed() < Duration::from_millis(300),
                "late wake: {mode}"
            );
            if mode == "complete" {
                assert!(finished.unwrap().success);
            } else {
                assert!(finished.is_err(), "{mode}");
            }
            if mode != "shutdown" {
                assert!(!registry.complete(id, result()).unwrap());
            }
        });
    }
}

#[test]
fn interrupted_worker_is_closed_before_publishing_its_reply() {
    let services = ExtensionServices::default();
    services.logs.set_enabled(true).unwrap();
    let logs = Arc::clone(&services.logs);
    let downloads = Arc::clone(&services.downloads);
    let runtime = ExtensionRuntime::load_with_services(
        "registerExtension({spin(){log.info('entered');while(true){}}});",
        "{}",
        RuntimeLimits::default(),
        services,
    )
    .unwrap();
    // A rendezvous reply holds the worker at publication until we receive.
    // This makes the ordering assertion independent of thread scheduling.
    let (started, waiting) = mpsc::sync_channel(0);
    let (reply, result) = mpsc::sync_channel(0);
    assert!(
        runtime
            .sender
            .send(Command::Call {
                method: "spin".into(),
                arguments: "[]".into(),
                operation: Operation {
                    item_id: "example-item".into(),
                    deadline: Instant::now() + Duration::from_secs(10),
                    lease: Some(Arc::new(downloads.acquire("example-item").unwrap())),
                    resolution: None,
                },
                started,
                reply,
                kind: CallKind::Function,
            })
            .is_ok()
    );
    waiting.recv_timeout(Duration::from_secs(1)).unwrap();
    let began = Instant::now();
    while logs.count().unwrap() == 0 {
        assert!(
            began.elapsed() < Duration::from_secs(2),
            "VM did not enter spin"
        );
        thread::sleep(Duration::from_millis(1));
    }
    downloads.cancel("example-item").unwrap();
    let began = Instant::now();
    while !runtime.is_closed() && began.elapsed() < Duration::from_secs(1) {
        thread::sleep(Duration::from_millis(1));
    }
    let closed_before_reply = runtime.is_closed();
    let response = result.recv_timeout(Duration::from_secs(2)).unwrap();
    runtime.shutdown();
    assert_eq!(
        response,
        Err(ExtensionError::Cancelled(
            CancellationError::DownloadCancelled
        ))
    );
    assert!(
        closed_before_reply,
        "interrupted worker published before closing"
    );
}
