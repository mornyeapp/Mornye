//! Worker thread and JavaScript VM that compile extension sources and execute their calls.

use super::{
    CallKind, Command, Control, ExtensionError, ExtensionServices, IDLE_GC_DELAY, LoadMode,
    MAX_INPUT_BYTES, Operation, RuntimeLimits, lifecycle_result, validate_json,
};
use rquickjs::{Coerced, Context, Ctx, FromJs, Function, Object, Persistent, Runtime, Value};
use std::sync::atomic::Ordering;
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

pub(super) fn run_worker(
    receiver: Receiver<Command>,
    ready: SyncSender<Result<(), ExtensionError>>,
    control: &Arc<Control>,
    limits: &RuntimeLimits,
    source: &str,
    settings: &str,
    services: &ExtensionServices,
) {
    let vm = match Vm::load(control, limits, source, settings, services) {
        Ok(vm) => vm,
        Err(error) => {
            let _ = ready.send(Err(error));
            return;
        }
    };
    *control.operation.lock().expect("extension operation lock") = None;
    if services.load_mode == LoadMode::Validate {
        // Validation owns a fresh VM only until cleanup finishes. Keeping both
        // steps on this worker avoids a caller/worker round trip and never
        // exposes the validation VM to a later provider call.
        let result = vm.execute(
            control,
            "cleanup",
            "[]",
            Operation {
                item_id: String::new(),
                deadline: Instant::now() + limits.timeout(0),
                lease: None,
                resolution: None,
            },
            CallKind::Lifecycle,
        );
        if let Err(error) = lifecycle_result("cleanup", result) {
            let _ = services
                .logs
                .backend(&format!("[Extension] Cleanup error: {error}"));
        }
        let _ = ready.send(Ok(()));
        return;
    }
    if ready.send(Ok(())).is_err() {
        return;
    }
    // Reclaim unreachable cycles once after a burst. Reference-counted values
    // are already released; reachable extension state must remain untouched.
    let mut collect_at = Some(Instant::now() + IDLE_GC_DELAY);
    #[cfg(test)]
    let mut idle_collections = 0;
    loop {
        let command = if let Some(deadline) = collect_at {
            match receiver.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                Ok(command) => command,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => match receiver.try_recv() {
                    Ok(command) => command,
                    Err(mpsc::TryRecvError::Disconnected) => break,
                    Err(mpsc::TryRecvError::Empty) => {
                        if control.is_closed() {
                            break;
                        }
                        vm._runtime.run_gc();
                        collect_at = None;
                        #[cfg(test)]
                        {
                            idle_collections += 1;
                        }
                        continue;
                    }
                },
            }
        } else {
            match receiver.recv() {
                Ok(command) => command,
                Err(_) => break,
            }
        };
        #[cfg(test)]
        if let Command::InspectHeap(reply) = command {
            let _ = reply.send((
                vm._runtime.memory_usage().memory_used_size,
                idle_collections,
            ));
            continue;
        }
        let Command::Call {
            method,
            arguments,
            operation,
            started,
            reply,
            kind,
        } = command
        else {
            break;
        };
        // A caller that expired or cancelled while queued has dropped its
        // receiver. Never execute that abandoned command or retire this VM.
        if started.send(()).is_err() {
            continue;
        }
        let result = vm.execute(control, &method, &arguments, operation, kind);
        collect_at = Some(Instant::now() + IDLE_GC_DELAY);
        let _ = reply.send(result);
        if control.closed.load(Ordering::Acquire) {
            // Dropping receiver rejects all queued callers. No stale jobs survive.
            break;
        }
    }
}

pub(super) struct Vm {
    gateway: Persistent<Object<'static>>,
    context: Context,
    // Drop the context and its persistent values before the owning runtime.
    pub(super) _runtime: Runtime,
}

pub(crate) struct CompiledSource {
    pub(super) source: Arc<str>,
    pub(super) bytecode: OnceLock<Vec<u8>>,
}

fn builtin_factory<'js>(
    ctx: &Ctx<'js>,
    source: &'static str,
    cache: &OnceLock<Vec<u8>>,
) -> rquickjs::Result<Function<'js>> {
    Function::from_js(ctx, eval_cached(ctx, source, cache, true)?)
}

// Bytecode is compiled locally by this engine. Each VM decodes its own objects;
// installed source caches belong to one primary runtime/install generation.
#[allow(unsafe_code)]
fn eval_cached<'js>(
    ctx: &Ctx<'js>,
    source: &str,
    cache: &OnceLock<Vec<u8>>,
    strict: bool,
) -> rquickjs::Result<Value<'js>> {
    use rquickjs::qjs;

    let context = ctx.as_raw().as_ptr();
    // Match Ctx::eval's stack bookkeeping before entering QuickJS.
    unsafe { qjs::JS_UpdateStackTop(qjs::JS_GetRuntime(context)) };
    let compiled = if let Some(bytes) = cache.get() {
        // JS_ReadObject accepts only bytecode produced locally by this engine.
        unsafe {
            qjs::JS_ReadObject(
                context,
                bytes.as_ptr(),
                bytes.len() as _,
                qjs::JS_READ_OBJ_BYTECODE as i32,
            )
        }
    } else {
        let mut source = source.as_bytes().to_vec();
        source.push(0);
        let flags = qjs::JS_EVAL_TYPE_GLOBAL
            | qjs::JS_EVAL_FLAG_COMPILE_ONLY
            | if strict { qjs::JS_EVAL_FLAG_STRICT } else { 0 };
        // The owned value belongs to this context; its RAII wrapper releases it
        // on every return path, including compilation/serialization failure.
        let compiled = unsafe {
            Value::from_raw(
                ctx.clone(),
                qjs::JS_Eval(
                    context,
                    source.as_ptr().cast(),
                    (source.len() - 1) as _,
                    if strict {
                        c"eval_script".as_ptr()
                    } else {
                        c"index.js".as_ptr()
                    },
                    flags as i32,
                ),
            )
        };
        if compiled.is_exception() {
            return Err(rquickjs::Error::Exception);
        }
        let mut len = 0;
        let buffer = unsafe {
            qjs::JS_WriteObject(
                context,
                &mut len,
                compiled.as_raw(),
                qjs::JS_WRITE_OBJ_BYTECODE as i32,
            )
        };
        if buffer.is_null() {
            // Caching is optional under memory/stack pressure. Keep the already
            // compiled script and let execution enforce the VM's limits.
            drop(ctx.catch());
        } else {
            if len as usize <= MAX_INPUT_BYTES {
                let bytes = unsafe { std::slice::from_raw_parts(buffer, len as _).to_vec() };
                let _ = cache.set(bytes);
            }
            unsafe { qjs::js_free(context, buffer.cast()) };
        }
        // Give JS_EvalFunction its own reference; the wrapper still releases
        // both its original value and context reference on this branch.
        unsafe { qjs::JS_DupValue(context, compiled.as_raw()) }
    };
    if unsafe { qjs::JS_IsException(compiled) } {
        return Err(rquickjs::Error::Exception);
    }
    // JS_EvalFunction consumes compiled. Only its owned result gets a wrapper.
    let result = unsafe { Value::from_raw(ctx.clone(), qjs::JS_EvalFunction(context, compiled)) };
    if result.is_exception() {
        return Err(rquickjs::Error::Exception);
    }
    Ok(result)
}

impl Vm {
    pub(super) fn load(
        control: &Arc<Control>,
        limits: &RuntimeLimits,
        source: &str,
        settings: &str,
        services: &ExtensionServices,
    ) -> Result<Self, ExtensionError> {
        let runtime = Runtime::new().map_err(|error| ExtensionError::Script(error.to_string()))?;
        runtime.set_memory_limit(limits.memory_bytes);
        runtime.set_max_stack_size(limits.stack_bytes);
        let interrupt = Arc::clone(control);
        runtime.set_interrupt_handler(Some(Box::new(move || interrupt.check().is_err())));
        let context =
            Context::full(&runtime).map_err(|error| ExtensionError::Script(error.to_string()))?;
        let gateway = context.with(|ctx| {
            static PRELUDE: OnceLock<Vec<u8>> = OnceLock::new();
            static PROVIDER: OnceLock<Vec<u8>> = OnceLock::new();
            let host = crate::host::register(&ctx, Arc::clone(control), services)
                .map_err(|error| script_error(&ctx, control, error))?;
            let factory = builtin_factory(&ctx, include_str!("../prelude.js"), &PRELUDE)
                .map_err(|error| script_error(&ctx, control, error))?;
            let gateway: Object = factory
                .call((host.clone(),))
                .map_err(|error| script_error(&ctx, control, error))?;
            let provider_factory = builtin_factory(&ctx, include_str!("../provider.js"), &PROVIDER)
                .map_err(|error| script_error(&ctx, control, error))?;
            let helpers: Object = gateway
                .get("providerHelpers")
                .map_err(|error| script_error(&ctx, control, error))?;
            let provider: Object = provider_factory
                .call((host, helpers))
                .map_err(|error| script_error(&ctx, control, error))?;
            gateway
                .set("provider", provider)
                .map_err(|error| script_error(&ctx, control, error))?;
            // Goja compiles extension scripts without forcing strict mode.
            let cache = &services
                .compiled_source
                .as_ref()
                .expect("local source cache")
                .bytecode;
            eval_cached(&ctx, source, cache, false)
                .map_err(|error| script_error(&ctx, control, error))?;
            drain_jobs(&ctx, control)?;
            let registered: Function = gateway
                .get("registered")
                .map_err(|error| script_error(&ctx, control, error))?;
            if !registered
                .call::<_, bool>(())
                .map_err(|error| script_error(&ctx, control, error))?
            {
                return Err(ExtensionError::NotRegistered);
            }
            Ok(Persistent::save(&ctx, gateway))
        })?;
        let vm = Self {
            gateway,
            context,
            _runtime: runtime,
        };
        let empty_settings = validate_json(settings)?.is_empty_object();
        if services.load_mode == LoadMode::Initialize
            && (services.initialize_empty_settings || !empty_settings)
        {
            vm.call(
                control,
                "initialize",
                &format!("[{settings}]"),
                true,
                CallKind::Function,
            )?;
        }
        control.check()?;
        Ok(vm)
    }

    pub(super) fn execute(
        &self,
        control: &Control,
        method: &str,
        arguments: &str,
        operation: Operation,
        kind: CallKind,
    ) -> Result<String, ExtensionError> {
        *control.operation.lock().expect("extension operation lock") = Some(operation);
        // A queued cancellation/expiry has not touched the VM and need not retire it.
        if let Err(error) = control.check() {
            *control.operation.lock().expect("extension operation lock") = None;
            return Err(error);
        }
        let result = self.call(control, method, arguments, false, kind);
        // A thrown synchronous error can still leave Promise jobs in the queue.
        let jobs = self.context.with(|ctx| drain_jobs(&ctx, control));
        let result = result.and_then(|value| jobs.map(|()| value));
        let interruption = control.check().err();
        *control.operation.lock().expect("extension operation lock") = None;
        if interruption.is_some() {
            // Callers must see the retired VM before handling its interruption.
            control.close();
        }
        interruption.map_or(result, Err)
    }

    fn call(
        &self,
        control: &Control,
        method: &str,
        arguments: &str,
        optional: bool,
        kind: CallKind,
    ) -> Result<String, ExtensionError> {
        self.context.with(|ctx| {
            let result = (|| -> rquickjs::Result<Option<Value<'_>>> {
                let gateway = self.gateway.clone().restore(&ctx)?;
                if matches!(
                    kind,
                    CallKind::Provider | CallKind::DownloadProvider | CallKind::PostProcess
                ) {
                    let provider: Object = gateway.get("provider")?;
                    let invoke: Function =
                        provider.get(if matches!(kind, CallKind::DownloadProvider) {
                            "invokeDownload"
                        } else if matches!(kind, CallKind::PostProcess) {
                            "invokePostProcess"
                        } else {
                            "invoke"
                        })?;
                    let arguments: rquickjs::Array = ctx.json_parse(arguments)?.get()?;
                    return Ok(Some(invoke.call((method, arguments))?));
                }
                if !matches!(kind, CallKind::Function) {
                    let invoke: Function = gateway.get("invokeManaged")?;
                    let arguments: rquickjs::Array = ctx.json_parse(arguments)?.get()?;
                    return Ok(Some(invoke.call((
                        matches!(kind, CallKind::Action),
                        method,
                        arguments,
                    ))?));
                }
                let get: Function = gateway.get("getExtension")?;
                let extension: Value = get.call(())?;
                let Some(object) = extension.as_object() else {
                    return Ok(None);
                };
                let function: Value = object.get(method)?;
                let Some(function) = function.as_function() else {
                    return Ok(None);
                };
                let arguments: rquickjs::Array = ctx.json_parse(arguments)?.get()?;
                let mut args = rquickjs::function::Args::new(ctx.clone(), arguments.len());
                args.this(object.clone())?;
                for argument in arguments.iter::<Value>() {
                    args.push_arg(argument?)?;
                }
                Ok(Some(function.call_arg(args)?))
            })()
            .map_err(|error| script_error(&ctx, control, error))?;
            let Some(mut value) = result else {
                return if optional {
                    Ok("null".to_owned())
                } else {
                    Err(ExtensionError::MissingFunction(method.to_owned()))
                };
            };
            if !optional
                && matches!(kind, CallKind::Function)
                && let Some(promise) = value.as_promise()
            {
                value = loop {
                    control.check()?;
                    if let Some(result) = promise.result::<Value>() {
                        break result.map_err(|error| script_error(&ctx, control, error))?;
                    }
                    if !ctx.execute_pending_job() {
                        if ctx.has_exception() {
                            return Err(script_error(&ctx, control, rquickjs::Error::Exception));
                        }
                        control.sleep(Duration::from_millis(10));
                    }
                };
            }
            drain_jobs(&ctx, control)?;
            if optional {
                // The Go manager ignores initialize's return value.
                return Ok("null".to_owned());
            }
            let gateway = self
                .gateway
                .clone()
                .restore(&ctx)
                .map_err(|error| script_error(&ctx, control, error))?;
            if matches!(
                kind,
                CallKind::Provider | CallKind::DownloadProvider | CallKind::PostProcess
            ) {
                let provider: Object = gateway
                    .get("provider")
                    .map_err(|error| script_error(&ctx, control, error))?;
                let parse: Function = provider
                    .get(if matches!(kind, CallKind::PostProcess) {
                        "parsePostProcess"
                    } else {
                        "parse"
                    })
                    .map_err(|error| script_error(&ctx, control, error))?;
                let json: String = parse
                    .call((method, value))
                    .map_err(|error| script_error(&ctx, control, error))?;
                drain_jobs(&ctx, control)?;
                control.check()?;
                return Ok(json);
            }
            let serialize: Function = gateway
                .get("serialize")
                .map_err(|error| script_error(&ctx, control, error))?;
            let json: String = serialize
                .call((value,))
                .map_err(|error| script_error(&ctx, control, error))?;
            // Go export serialization may execute extension-defined getters and jobs.
            drain_jobs(&ctx, control)?;
            control.check()?;
            Ok(json)
        })
    }
}

fn drain_jobs(ctx: &Ctx<'_>, control: &Control) -> Result<(), ExtensionError> {
    loop {
        control.check()?;
        let ran = ctx.execute_pending_job();
        if ctx.has_exception() {
            return Err(script_error(ctx, control, rquickjs::Error::Exception));
        }
        if !ran {
            return Ok(());
        }
    }
}

fn script_error(ctx: &Ctx<'_>, control: &Control, error: rquickjs::Error) -> ExtensionError {
    if let Err(interruption) = control.check() {
        return interruption;
    }
    let message = if error.is_exception() {
        Coerced::<String>::from_js(ctx, ctx.catch())
            .map(|message| message.0)
            .unwrap_or_else(|_| "JavaScript exception".to_owned())
    } else {
        error.to_string()
    };
    // Even converting a thrown value to text may execute arbitrary JS.
    control
        .check()
        .err()
        .unwrap_or(ExtensionError::Script(message))
}
