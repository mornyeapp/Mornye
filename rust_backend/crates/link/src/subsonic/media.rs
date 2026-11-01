//! `stream` and `download`: the original file with single-range support, or
//! an ffmpeg transcode piped as a chunked body.

use super::objects::content_type;
use super::{Failure, number, required};
use crate::catalog::{Catalog, Song};
use crate::types::{Body, HttpResponse, Shared, SubsonicRequest, full};
use bytes::Bytes;
use futures_util::{Stream, StreamExt, TryStreamExt};
use http::header::{
    ACCEPT_RANGES, CONTENT_DISPOSITION, CONTENT_LENGTH, CONTENT_RANGE, CONTENT_TYPE, HeaderName,
    RANGE,
};
use http::{HeaderMap, Response};
use http_body_util::{BodyExt, StreamBody};
use hyper::body::Frame;
use std::ffi::OsString;
use std::io::SeekFrom;
use std::path::Path;
use std::pin::Pin;
use std::process::Stdio;
use std::sync::Mutex;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncSeekExt};
use tokio::process::{Child, ChildStdout, Command};
use tokio_util::io::ReaderStream;

/// Read size for file and transcode bodies.
const CHUNK: usize = 64 * 1024;
/// How long ffmpeg may take to produce its first bytes before the original
/// file is served instead.
const FIRST_CHUNK_TIMEOUT: Duration = Duration::from_secs(20);
/// Sources whose bit rate exceeds any lossy cap even when unknown.
const LOSSLESS: &[&str] = &[
    "flac", "wav", "aif", "aiff", "aifc", "alac", "ape", "wv", "dsf", "dff", "tta",
];

pub(super) async fn stream(
    shared: &Shared,
    catalog: &Catalog,
    request: &SubsonicRequest,
) -> Result<HttpResponse, Failure> {
    let song = song(catalog, request)?;
    let plan = plan(
        song,
        request.param("format"),
        number::<u32>(request, "maxBitRate"),
        number::<f64>(request, "timeOffset"),
    );
    if let (Some(plan), Some(ffmpeg)) = (plan, &shared.config.ffmpeg_path)
        && let Some(response) = transcode(ffmpeg, &song.path, &plan).await
    {
        return Ok(response);
    }
    file_response(
        &song.path,
        content_type(&song.suffix),
        &request.headers,
        Vec::new(),
    )
    .await
}

pub(super) async fn download(
    catalog: &Catalog,
    request: &SubsonicRequest,
) -> Result<HttpResponse, Failure> {
    let song = song(catalog, request)?;
    let name = song
        .path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| format!("{}.{}", song.title, song.suffix));
    let disposition = format!("attachment; filename*=UTF-8''{}", percent_encode(&name));
    file_response(
        &song.path,
        content_type(&song.suffix),
        &request.headers,
        vec![(CONTENT_DISPOSITION, disposition)],
    )
    .await
}

fn song<'a>(catalog: &'a Catalog, request: &SubsonicRequest) -> Result<&'a Song, Failure> {
    let id = required(request, "id")?;
    catalog
        .song(id)
        .ok_or_else(|| Failure::not_found("Song").with_status(404))
}

/// Serves `path` with `Range` support. A missing file answers error 70 with
/// HTTP 404.
pub(super) async fn file_response(
    path: &Path,
    content_type: &str,
    headers: &HeaderMap,
    extra: Vec<(HeaderName, String)>,
) -> Result<HttpResponse, Failure> {
    let missing = || Failure::not_found("File").with_status(404);
    let mut file = tokio::fs::File::open(path).await.map_err(|_| missing())?;
    let metadata = file.metadata().await.map_err(|_| missing())?;
    if !metadata.is_file() {
        return Err(missing());
    }
    let len = metadata.len();
    let range = headers
        .get(RANGE)
        .and_then(|value| value.to_str().ok())
        .map_or(ByteRange::Full, |value| parse_range(value, len));
    let mut builder = Response::builder()
        .header(CONTENT_TYPE, content_type)
        .header(ACCEPT_RANGES, "bytes");
    for (name, value) in extra {
        builder = builder.header(name, value);
    }
    let response = match range {
        ByteRange::Full => builder
            .status(200)
            .header(CONTENT_LENGTH, len)
            .body(reader_body(file)),
        ByteRange::Partial(start, end) => {
            file.seek(SeekFrom::Start(start))
                .await
                .map_err(|_| missing())?;
            builder
                .status(206)
                .header(CONTENT_LENGTH, end - start + 1)
                .header(CONTENT_RANGE, format!("bytes {start}-{end}/{len}"))
                .body(reader_body(file.take(end - start + 1)))
        }
        ByteRange::Unsatisfiable => builder
            .status(416)
            .header(CONTENT_RANGE, format!("bytes */{len}"))
            .body(full(Bytes::new())),
    };
    response.map_err(|error| Failure::new(super::code::GENERIC, error.to_string()))
}

fn reader_body(reader: impl AsyncRead + Send + Sync + 'static) -> Body {
    BodyExt::boxed(StreamBody::new(
        ReaderStream::with_capacity(reader, CHUNK).map_ok(Frame::data),
    ))
}

/// The answer to a `Range` header for a `len`-byte file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ByteRange {
    /// No usable range: send everything (also for multi-range requests).
    Full,
    /// Inclusive byte positions.
    Partial(u64, u64),
    Unsatisfiable,
}

pub(super) fn parse_range(header: &str, len: u64) -> ByteRange {
    let header = header.trim();
    let Some(spec) = header
        .get(..6)
        .filter(|unit| unit.eq_ignore_ascii_case("bytes="))
        .map(|_| &header[6..])
    else {
        return ByteRange::Full;
    };
    if spec.contains(',') {
        return ByteRange::Full;
    }
    let Some((first, last)) = spec.split_once('-') else {
        return ByteRange::Full;
    };
    let (first, last) = (first.trim(), last.trim());
    if first.is_empty() {
        let Ok(suffix) = last.parse::<u64>() else {
            return ByteRange::Full;
        };
        if suffix == 0 || len == 0 {
            return ByteRange::Unsatisfiable;
        }
        return ByteRange::Partial(len.saturating_sub(suffix), len - 1);
    }
    let Ok(start) = first.parse::<u64>() else {
        return ByteRange::Full;
    };
    let end = if last.is_empty() {
        u64::MAX
    } else {
        match last.parse::<u64>() {
            Ok(end) if end >= start => end,
            _ => return ByteRange::Full,
        }
    };
    if start >= len {
        return ByteRange::Unsatisfiable;
    }
    ByteRange::Partial(start, end.min(len - 1))
}

/// Transcode targets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Codec {
    Mp3,
    Opus,
    Aac,
}

impl Codec {
    fn parse(format: &str) -> Option<Self> {
        match format.trim().to_ascii_lowercase().as_str() {
            "mp3" => Some(Self::Mp3),
            "opus" | "ogg" => Some(Self::Opus),
            "aac" => Some(Self::Aac),
            _ => None,
        }
    }

    fn encoder(self) -> &'static str {
        match self {
            Self::Mp3 => "libmp3lame",
            Self::Opus => "libopus",
            Self::Aac => "aac",
        }
    }

    fn muxer(self) -> &'static str {
        match self {
            Self::Mp3 => "mp3",
            Self::Opus => "ogg",
            Self::Aac => "adts",
        }
    }

    pub(super) fn content_type(self) -> &'static str {
        match self {
            Self::Mp3 => "audio/mpeg",
            Self::Opus => "audio/ogg",
            Self::Aac => "audio/aac",
        }
    }

    /// The source suffix that already is this codec.
    fn suffix(self) -> &'static str {
        match self {
            Self::Mp3 => "mp3",
            Self::Opus => "opus",
            Self::Aac => "aac",
        }
    }

    fn default_kbps(self) -> u32 {
        match self {
            Self::Mp3 => 320,
            Self::Opus => 160,
            Self::Aac => 256,
        }
    }

    fn max_kbps(self) -> u32 {
        match self {
            Self::Opus => 256,
            Self::Mp3 | Self::Aac => 320,
        }
    }
}

/// A transcode to run instead of serving the file.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Transcode {
    pub(super) codec: Codec,
    pub(super) kbps: u32,
    pub(super) offset_secs: Option<f64>,
}

/// Decides whether `stream` transcodes: `format=mp3|opus|aac` (unless the
/// source already is that codec within the cap), or `maxBitRate` below the
/// source bit rate (to MP3). `format=raw` never transcodes.
pub(super) fn plan(
    song: &Song,
    format: Option<&str>,
    max_bit_rate: Option<u32>,
    time_offset: Option<f64>,
) -> Option<Transcode> {
    let format = format.map(str::trim).filter(|format| !format.is_empty());
    if format.is_some_and(|format| format.eq_ignore_ascii_case("raw")) {
        return None;
    }
    let cap = max_bit_rate.filter(|cap| *cap > 0);
    let source = song.source_kbps();
    let exceeds = |cap: u32| match source {
        Some(source) => source > cap,
        None => LOSSLESS.contains(&song.suffix.as_str()),
    };
    let codec = match format.and_then(Codec::parse) {
        Some(codec) => {
            if song.suffix == codec.suffix() && cap.is_none_or(|cap| !exceeds(cap)) {
                return None;
            }
            codec
        }
        None if cap.is_some_and(exceeds) => Codec::Mp3,
        None => return None,
    };
    let kbps = cap
        .map_or(codec.default_kbps(), |cap| cap.min(codec.default_kbps()))
        .clamp(32, codec.max_kbps());
    Some(Transcode {
        codec,
        kbps,
        offset_secs: time_offset.filter(|offset| offset.is_finite() && *offset > 0.0),
    })
}

/// ffmpeg arguments that write `plan` to stdout.
pub(super) fn ffmpeg_args(input: &Path, plan: &Transcode) -> Vec<OsString> {
    let mut args: Vec<OsString> = ["-nostdin", "-hide_banner", "-loglevel", "error"]
        .into_iter()
        .map(OsString::from)
        .collect();
    if let Some(offset) = plan.offset_secs {
        args.push("-ss".into());
        args.push(format!("{offset:.3}").into());
    }
    args.push("-i".into());
    args.push(input.as_os_str().to_owned());
    for arg in [
        "-map",
        "0:a:0",
        "-vn",
        "-sn",
        "-dn",
        "-map_metadata",
        "-1",
        "-ac",
        "2",
        "-c:a",
        plan.codec.encoder(),
        "-b:a",
    ] {
        args.push(arg.into());
    }
    args.push(format!("{}k", plan.kbps).into());
    args.push("-f".into());
    args.push(plan.codec.muxer().into());
    args.push("pipe:1".into());
    args
}

/// Starts ffmpeg and answers once it produced its first bytes; `None` when
/// it cannot start or fails before writing, so the caller serves the file.
async fn transcode(ffmpeg: &Path, input: &Path, plan: &Transcode) -> Option<HttpResponse> {
    let mut child = Command::new(ffmpeg)
        .args(ffmpeg_args(input, plan))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let mut stream = ReaderStream::with_capacity(child.stdout.take()?, CHUNK);
    let first = match tokio::time::timeout(FIRST_CHUNK_TIMEOUT, stream.next()).await {
        Ok(Some(Ok(chunk))) => chunk,
        _ => return None,
    };
    let body = TranscodeStream {
        first: Some(first),
        stream,
        _child: Mutex::new(child),
    };
    Response::builder()
        .status(200)
        .header(CONTENT_TYPE, plan.codec.content_type())
        .header(ACCEPT_RANGES, "none")
        .body(BodyExt::boxed(StreamBody::new(body.map_ok(Frame::data))))
        .ok()
}

/// ffmpeg's stdout. Dropping it (the client went away or the body ended)
/// drops the child, which `kill_on_drop` terminates.
struct TranscodeStream {
    first: Option<Bytes>,
    stream: ReaderStream<ChildStdout>,
    /// Only held for its drop; the mutex keeps the body `Sync` whatever the
    /// platform's `Child` is.
    _child: Mutex<Child>,
}

impl Stream for TranscodeStream {
    type Item = std::io::Result<Bytes>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();
        if let Some(first) = this.first.take() {
            return Poll::Ready(Some(Ok(first)));
        }
        this.stream.poll_next_unpin(cx)
    }
}

/// RFC 5987 `attr-char` encoding for `filename*`.
fn percent_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"!#$&+-.^_`|~".contains(&byte) {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}
