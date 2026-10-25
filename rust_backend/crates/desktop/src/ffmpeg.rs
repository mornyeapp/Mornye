//! Desktop FFmpeg command pump. While `downloadByStrategy` or
//! `runPostProcessingV2` runs, the mobile hosts drain the backend's FFmpeg
//! command queue with FFmpegKit (`ios/Runner/CoreBackend.swift:14-135`,
//! Android `CoreBackend.kt` `withCoreFFmpegExecution`). Desktop runs the
//! configured `ffmpeg` executable instead, with the same staging then rename
//! semantics and cancellation.

use crate::paths::{self, RemoveOnDrop};
use mornye_mobile::{ExtensionManager, FfmpegCommands};
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// One claimed command (`CoreFFmpegCommand`).
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct PendingCommand {
    pub(crate) command_id: String,
    pub(crate) arguments: Vec<String>,
    pub(crate) output_path: String,
}

fn parse_commands(json: &str) -> Result<Vec<PendingCommand>, String> {
    let value: Value = serde_json::from_str(json).map_err(|error| error.to_string())?;
    let commands = value.as_array().ok_or("FFmpeg commands must be a list")?;
    commands
        .iter()
        .map(|command| {
            let command_id = command["command_id"]
                .as_str()
                .ok_or("FFmpeg command is missing its ID")?
                .to_owned();
            let arguments = command["arguments"]
                .as_array()
                .ok_or("FFmpeg command is missing its arguments")?
                .iter()
                .map(|argument| argument.as_str().map(str::to_owned))
                .collect::<Option<Vec<_>>>()
                .ok_or("FFmpeg arguments must be strings")?;
            let output_path = command["output_path"].as_str().unwrap_or("").to_owned();
            Ok(PendingCommand {
                command_id,
                arguments,
                output_path,
            })
        })
        .collect()
}

pub(crate) type Outcome = (bool, String);

/// Runs FFmpeg with the given arguments, polling the cancellation check.
pub(crate) type Execute<'a> = &'a dyn Fn(&[String], &dyn Fn() -> bool) -> Outcome;

/// Runs `block` while a pump thread drains the manager's FFmpeg queue.
pub(crate) fn with_ffmpeg_commands<T>(
    manager: &ExtensionManager,
    ffmpeg: Option<PathBuf>,
    block: impl FnOnce() -> T,
) -> T {
    let commands = manager.environment().ffmpeg_commands();
    let running = Arc::new(AtomicBool::new(true));
    let pump_running = Arc::clone(&running);
    let pump = std::thread::Builder::new()
        .name("mornye-ffmpeg-pump".into())
        .spawn(move || pump_commands(&commands, &pump_running, ffmpeg.as_deref()));
    if let Err(error) = pump {
        crate::runtime::log("error", &format!("FFmpeg pump could not start: {error}"));
    }
    let result = block();
    // Do not interrupt a claimed command that belongs to another operation.
    running.store(false, Ordering::SeqCst);
    result
}

fn pump_commands(commands: &FfmpegCommands, running: &AtomicBool, ffmpeg: Option<&Path>) {
    while running.load(Ordering::SeqCst) {
        let Ok(batch) = commands.wait_pending(1_000) else {
            return;
        };
        let batch = match parse_commands(&batch) {
            Ok(batch) => batch,
            Err(error) => {
                crate::runtime::log("error", &format!("Invalid FFmpeg command batch: {error}"));
                continue;
            }
        };
        // Finish every claimed command, even if the caller finished first:
        // another operation on this owner may be waiting for its result.
        for command in batch {
            let id = command.command_id.clone();
            let cancelled = || {
                commands
                    .get_command(id.clone())
                    .map_or(true, |command| command.is_empty())
            };
            let (success, output) = if cancelled() {
                (false, "cancelled".to_owned())
            } else if command.arguments.is_empty() {
                (false, "FFmpeg arguments are empty".to_owned())
            } else {
                execute_command(&command, &cancelled, &|arguments, cancelled| {
                    run_ffmpeg(ffmpeg, arguments, cancelled)
                })
            };
            let error = if success {
                String::new()
            } else {
                output.clone()
            };
            // Owner shutdown removes commands; late results cannot revive them.
            let _ = commands.complete(command.command_id, success, output, error);
        }
    }
}

/// Process-wide staging names, swept once per directory per process.
mod staging {
    use super::*;

    pub(super) const PREFIX: &str = ".mornye-ffmpeg-mornye-desktop-";

    static SWEPT: Mutex<Option<HashSet<PathBuf>>> = Mutex::new(None);

    fn sweep(directory: &Path) -> std::io::Result<()> {
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            let name = entry.file_name();
            let Some(suffix) = name.to_str().and_then(|name| name.strip_prefix(PREFIX)) else {
                continue;
            };
            let token = suffix.get(..36).unwrap_or("");
            let metadata = fs::symlink_metadata(entry.path())?;
            if paths::is_uuid(token) && suffix[36..].starts_with('.') && metadata.is_file() {
                fs::remove_file(entry.path())?;
            }
        }
        Ok(())
    }

    pub(super) fn create(target: &Path) -> std::io::Result<PathBuf> {
        let parent = target
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or(Path::new("/"));
        let directory = paths::resolve(&parent.to_string_lossy());
        {
            let mut swept = SWEPT.lock().expect("FFmpeg staging lock");
            let swept = swept.get_or_insert_with(HashSet::new);
            // One process owns these stages. Sweep before its first command in
            // this directory; later or concurrent commands may own live files.
            if !swept.contains(&directory) {
                sweep(&directory)?;
                swept.insert(directory.clone());
            }
        }
        let extension = target
            .extension()
            .map(|extension| extension.to_string_lossy().into_owned())
            .unwrap_or_default();
        let staged = directory.join(format!("{PREFIX}{}.{extension}", paths::uuid()));
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&staged)?;
        Ok(staged)
    }
}

/// `executeCoreFFmpegCommand`: writes to a staging file next to the output
/// and renames it over the output only after FFmpeg succeeds.
pub(crate) fn execute_command(
    command: &PendingCommand,
    cancelled: &dyn Fn() -> bool,
    execute: Execute<'_>,
) -> Outcome {
    if cancelled() {
        return (false, "cancelled".into());
    }
    let output = &command.output_path;
    if output.is_empty() {
        return execute(&command.arguments, cancelled);
    }
    if command.arguments.last() != Some(output) {
        return (false, "FFmpeg output does not match command".into());
    }
    let target = Path::new(output);
    let staged = match staging::create(target) {
        Ok(staged) => staged,
        Err(error) => return (false, error.to_string()),
    };
    let _cleanup = RemoveOnDrop(staged.clone());
    let mut arguments = command.arguments.clone();
    *arguments.last_mut().expect("non-empty arguments") = staged.to_string_lossy().into_owned();
    let result = execute(&arguments, cancelled);
    if cancelled() {
        return (false, "cancelled".into());
    }
    if !result.0 {
        return result;
    }
    // Rename replaces the destination atomically on the same filesystem.
    match fs::rename(&staged, target) {
        Ok(()) => result,
        Err(error) => (false, error.to_string()),
    }
}

/// Runs `ffmpeg` with `arguments` (no program name, as with FFmpegKit) and
/// returns its success and combined log output.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub(crate) fn run_ffmpeg(
    ffmpeg: Option<&Path>,
    arguments: &[String],
    cancelled: &dyn Fn() -> bool,
) -> Outcome {
    use std::io::Read;
    use std::process::{Command, Stdio};
    use std::time::Duration;

    let Some(ffmpeg) = ffmpeg else {
        return (
            false,
            "FFmpeg is not available: the desktop backend was initialized without ffmpeg_path"
                .into(),
        );
    };
    if cancelled() {
        return (false, "cancelled".into());
    }
    let mut command = Command::new(ffmpeg);
    command
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // The app has no console, so Windows would open a visible one for the
    // ffmpeg.exe console program on every run. CREATE_NO_WINDOW keeps it
    // hidden, as dart:io does for Process.start.
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return (
                false,
                format!("FFmpeg could not start ({}): {error}", ffmpeg.display()),
            );
        }
    };
    let drain = |stream: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut text = Vec::new();
            if let Some(mut stream) = stream {
                let _ = stream.read_to_end(&mut text);
            }
            String::from_utf8_lossy(&text).into_owned()
        })
    };
    let stdout = drain(
        child
            .stdout
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
    );
    let stderr = drain(
        child
            .stderr
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
    );
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) if cancelled() => {
                let _ = child.kill();
                let _ = child.wait();
                break Err("cancelled".to_owned());
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(200)),
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                break Err(format!("FFmpeg wait failed: {error}"));
            }
        }
    };
    let mut output = stderr.join().unwrap_or_default();
    let stdout = stdout.join().unwrap_or_default();
    if !stdout.is_empty() {
        output.push_str(&stdout);
    }
    match status {
        Ok(_) if cancelled() => (false, "cancelled".into()),
        Ok(status) => (status.success(), output),
        Err(error) => (false, error),
    }
}

/// The mobile hosts drain the queue with FFmpegKit; this crate never ships
/// there.
#[cfg(any(target_os = "android", target_os = "ios"))]
pub(crate) fn run_ffmpeg(_: Option<&Path>, _: &[String], _: &dyn Fn() -> bool) -> Outcome {
    (
        false,
        "FFmpeg runs in the mobile host on this platform".into(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn command(output: &Path) -> PendingCommand {
        let output = output.to_string_lossy().into_owned();
        PendingCommand {
            command_id: "ext_1".into(),
            arguments: vec!["-i".into(), "in.flac".into(), "-y".into(), output.clone()],
            output_path: output,
        }
    }

    #[test]
    fn parses_claimed_batch() {
        let batch = r#"[{"command_id":"a_1","extension_id":"a","arguments":["-i","x"],"input_path":"x","output_path":""}]"#;
        assert_eq!(
            parse_commands(batch).unwrap(),
            [PendingCommand {
                command_id: "a_1".into(),
                arguments: vec!["-i".into(), "x".into()],
                output_path: String::new(),
            }]
        );
    }

    #[test]
    fn stages_then_renames_over_output() {
        let directory = tempfile::tempdir().unwrap();
        let output = directory.path().join("song.flac");
        fs::write(&output, b"old").unwrap();
        let seen = RefCell::new(Vec::new());
        let result = execute_command(&command(&output), &|| false, &|arguments, _| {
            let staged = PathBuf::from(arguments.last().unwrap());
            assert_ne!(staged, output);
            assert!(
                staged
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with(staging::PREFIX)
            );
            fs::write(&staged, b"new").unwrap();
            seen.borrow_mut().push(staged);
            (true, "log".into())
        });
        assert_eq!(result, (true, "log".into()));
        assert_eq!(fs::read(&output).unwrap(), b"new");
        assert!(!seen.borrow()[0].exists());
    }

    #[test]
    fn failure_keeps_output_and_removes_stage() {
        let directory = tempfile::tempdir().unwrap();
        let output = directory.path().join("song.m4a");
        fs::write(&output, b"old").unwrap();
        let result = execute_command(&command(&output), &|| false, &|_, _| (false, "boom".into()));
        assert_eq!(result, (false, "boom".into()));
        assert_eq!(fs::read(&output).unwrap(), b"old");
        let leftovers = fs::read_dir(directory.path()).unwrap().count();
        assert_eq!(leftovers, 1);
    }

    #[test]
    fn rejects_mismatched_output_and_cancellation() {
        let directory = tempfile::tempdir().unwrap();
        let mut pending = command(&directory.path().join("a.flac"));
        pending.output_path = directory.path().join("b.flac").to_string_lossy().into();
        let never = |_: &[String], _: &dyn Fn() -> bool| -> Outcome { unreachable!() };
        assert_eq!(
            execute_command(&pending, &|| false, &never),
            (false, "FFmpeg output does not match command".into())
        );
        assert_eq!(
            execute_command(&pending, &|| true, &never),
            (false, "cancelled".into())
        );
    }

    #[test]
    fn missing_ffmpeg_path_is_a_clear_error() {
        let (success, message) = run_ffmpeg(None, &["-version".into()], &|| false);
        assert!(!success);
        assert!(message.contains("ffmpeg_path"), "{message}");
    }

    #[cfg(unix)]
    #[test]
    fn runs_executable_and_reports_status() {
        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("fake-ffmpeg.sh");
        fs::write(&script, "echo \"args:$*\" >&2\nexit \"$2\"\n").unwrap();
        // Run through /bin/sh rather than executing the fresh file, which can
        // fail with ETXTBSY while other test threads fork.
        let run = |status: &str| {
            let arguments = [
                script.to_string_lossy().into_owned(),
                "-i".into(),
                status.into(),
            ];
            run_ffmpeg(Some(Path::new("/bin/sh")), &arguments, &|| false)
        };
        let (success, output) = run("0");
        assert!(success);
        assert!(output.contains("args:-i 0"), "{output}");
        assert!(!run("1").0);
    }
}
