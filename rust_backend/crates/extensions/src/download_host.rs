use crate::download::{self, DownloadOptions};
use crate::runtime::{Control, ExtensionServices};
use rquickjs::{Ctx, Function, Object, Value};
use std::sync::Arc;

pub(crate) fn register<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    control: Arc<Control>,
    services: &ExtensionServices,
) -> rquickjs::Result<()> {
    register_segments(ctx, host, Arc::clone(&control), services)?;
    let Some(files) = &services.files else {
        return Ok(());
    };
    let files = Arc::clone(files);
    let downloads = Arc::clone(&services.downloads);
    let network = services.network.clone();
    let policy = services.transfer_policy.clone();
    let app_version = services.app_version.clone();
    host.set(
        "downloadCall",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>,
                  url: String,
                  path: String,
                  options: Value<'js>,
                  headers: String| {
                let result: Result<serde_json::Value, String> = (|| {
                    let check = || control.check().map_err(|error| error.to_string());
                    check()?;
                    let network = network.as_ref().ok_or("network access unavailable")?;
                    network.validate_url(&url)?;
                    let item_id = control.item_id();
                    if crate::stream_capture::is_capture_active(&item_id) {
                        let headers_map: std::collections::BTreeMap<String, String> =
                            serde_json::from_str(&headers).unwrap_or_default();
                        crate::stream_capture::record_capture(
                            &item_id,
                            crate::stream_capture::CapturedStream {
                                url: url.clone(),
                                headers: headers_map,
                                format: None,
                            },
                        );
                        return Ok(serde_json::json!({
                            "success": true,
                            "file_path": path,
                            "already_exists": true,
                            "captured_stream": true,
                        }));
                    }
                    let path = files.resolve(&path)?;
                    let options = options.as_object();
                    let value = |key: &str| -> Result<Value<'js>, String> {
                        options.map_or_else(
                            || Ok(Value::new_undefined(ctx.clone())),
                            |object| object.get(key).map_err(|error| error.to_string()),
                        )
                    };
                    let direct_network = if value("directMedia")?.as_bool() == Some(true) {
                        Some(network.direct_media())
                    } else {
                        None
                    };
                    let network = direct_network.as_ref().unwrap_or(network.as_ref());
                    let chunked = value("chunked")?;
                    let chunk_size = if chunked.as_bool() == Some(true) {
                        Some(1 << 20)
                    } else {
                        chunked
                            .as_number()
                            .filter(|value| *value > 0.0)
                            .map(|value| {
                                let size = value as i64;
                                if size <= 0 { 1 << 20 } else { size as u64 }
                            })
                    };
                    let mut policy = policy.clone();
                    if let Some(attempts) = value("maxAttempts")?
                        .as_number()
                        .filter(|number| *number > 0.0)
                    {
                        policy.max_attempts = (attempts as i64).clamp(1, 8);
                    }
                    let resume = value("resume")?
                        .as_bool()
                        .unwrap_or(policy.resume_policy == "validated");
                    let has_track = options
                        .map(|object| object.contains_key("trackItemBytes"))
                        .transpose()
                        .map_err(|error| error.to_string())?
                        .unwrap_or(false);
                    let track = value(if has_track {
                        "trackItemBytes"
                    } else {
                        "track_item_bytes"
                    })?
                    .as_bool()
                    .unwrap_or(true);
                    let persistent = value("persistentCheckpoint")?
                        .as_bool()
                        .map_or(policy.persistent_checkpoint, |enabled| enabled && resume);
                    let callback = value("onProgress")?;
                    let callback = callback.as_function();
                    let mut progress = |bytes, total| {
                        if let Some(callback) = callback
                            && callback.call::<_, ()>((bytes, total)).is_err()
                        {
                            // Go ignores download progress callback errors. Clear the
                            // pending JS exception; cancellation is checked by the host.
                            ctx.catch();
                        }
                    };
                    let headers =
                        serde_json::from_str(&headers).map_err(|error| error.to_string())?;
                    Ok(
                        match download::download(
                            &files,
                            &path,
                            network,
                            &url,
                            DownloadOptions {
                                item: download::progress::ItemProgressTarget::new(
                                    Arc::clone(&downloads.progress),
                                    control.item_id(),
                                    track,
                                ),
                                headers,
                                // Go snapshots the UA for a chunked transfer;
                                // ordinary retries read the current app version.
                                app_version: if chunk_size.is_some() {
                                    app_version.get().into()
                                } else {
                                    app_version.clone()
                                },
                                resume,
                                persistent,
                                policy,
                                budget: control.resolution(),
                                chunk_size,
                            },
                            &check,
                            &|duration| {
                                let _charge = control.resolution().map(|budget| budget.enter(true));
                                control.sleep(duration);
                                check()
                            },
                            &mut progress,
                        ) {
                            Ok(result) => result,
                            Err(error) => serde_json::to_value(error).expect("transfer error JSON"),
                        },
                    )
                })();
                match result {
                    Ok(result) => result,
                    Err(error) => serde_json::json!({"success":false,"error":error}),
                }
                .to_string()
            },
        )?,
    )?;
    Ok(())
}

fn register_segments<'js>(
    ctx: &Ctx<'js>,
    host: &Object<'js>,
    control: Arc<Control>,
    services: &ExtensionServices,
) -> rquickjs::Result<()> {
    let Some(files) = &services.files else {
        return Ok(());
    };
    let files = Arc::clone(files);
    let downloads = Arc::clone(&services.downloads);
    let network = services.network.clone();
    let policy = services.transfer_policy.clone();
    let app_version = services.app_version.clone();
    host.set(
        "downloadSegmentsCall",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, segments: String, path: String, options: Value<'js>| {
                let result = (|| {
                    let check = || control.check().map_err(|error| error.to_string());
                    check().map_err(|error| download::Failure::new("cancelled", error, 0))?;
                    let network = network.as_ref().ok_or_else(|| {
                        download::Failure::new("permission", "network access unavailable", 0)
                    })?;
                    let mut segments: Vec<download::segments::Segment> =
                        serde_json::from_str(&segments)
                            .map_err(|error| download::Failure::new("invalid_request", error, 0))?;
                    for (index, segment) in segments.iter_mut().enumerate() {
                        segment.url = segment.url.trim().to_owned();
                        if segment.url.is_empty() {
                            return Err(download::Failure::new(
                                "invalid_request",
                                format!("segment {index} URL is empty"),
                                0,
                            ));
                        }
                    }
                    for segment in &segments {
                        network
                            .validate_url(&segment.url)
                            .map_err(|error| download::Failure::new("permission", error, 0))?;
                    }
                    let path = files
                        .resolve(&path)
                        .map_err(|error| download::Failure::new("permission", error, 0))?;
                    let item_id = control.item_id();
                    if crate::stream_capture::is_capture_active(&item_id) {
                        if let Some(first) = segments.first() {
                            let mut headers_map = std::collections::BTreeMap::new();
                            if let Some(opts) = options.as_object() {
                                if let Ok(val) = opts.get::<_, rquickjs::Value>("headers") {
                                    if let Some(obj) = val.as_object() {
                                        for key in obj.keys::<String>() {
                                            if let Ok(k) = key {
                                                if let Ok(v) = obj.get::<_, String>(&k) {
                                                    headers_map.insert(k, v);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            crate::stream_capture::record_capture(
                                &item_id,
                                crate::stream_capture::CapturedStream {
                                    url: first.url.clone(),
                                    headers: headers_map,
                                    format: None,
                                },
                            );
                            return Ok(serde_json::json!({
                                "success": true,
                                "file_path": path.display().to_string(),
                                "already_exists": true,
                            }));
                        }
                    }
                    let options = options.as_object();
                    let value = |key: &str| -> Result<Value<'js>, download::Failure> {
                        options.map_or_else(
                            || Ok(Value::new_undefined(ctx.clone())),
                            |object| {
                                object.get(key).map_err(|error| {
                                    download::Failure::new("invalid_request", error, 0)
                                })
                            },
                        )
                    };
                    let mut policy = policy.clone();
                    for (name, target) in [
                        ("maxAttempts", &mut policy.max_attempts),
                        ("maxParallel", &mut policy.max_parallel_segments),
                    ] {
                        if let Some(number) = value(name)?.as_number() {
                            let rounded = crate::transfer_policy::rounded_int(number);
                            if rounded > 0 {
                                *target = rounded.clamp(1, 8);
                            }
                        }
                    }
                    let persistent = value("persistentCheckpoint")?
                        .as_bool()
                        .unwrap_or(policy.persistent_checkpoint);
                    let callback = value("onProgress")?;
                    let callback = callback.as_function();
                    let mut progress = |bytes, completed, count| {
                        if let Some(callback) = callback
                            && callback
                                .call::<_, ()>((bytes, 0, completed, count))
                                .is_err()
                        {
                            ctx.catch();
                        }
                    };
                    download::segments::download(
                        &files,
                        &path,
                        network,
                        &segments,
                        DownloadOptions {
                            item: download::progress::ItemProgressTarget::new(
                                Arc::clone(&downloads.progress),
                                control.item_id(),
                                true,
                            ),
                            headers: Default::default(),
                            app_version: app_version.clone(),
                            resume: false,
                            persistent,
                            policy,
                            budget: control.resolution(),
                            chunk_size: None,
                        },
                        &check,
                        &mut progress,
                    )
                })();
                match result {
                    Ok(result) => result,
                    Err(error) => serde_json::to_value(error).expect("transfer error JSON"),
                }
                .to_string()
            },
        )?,
    )
}
