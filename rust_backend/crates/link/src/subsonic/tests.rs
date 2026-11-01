//! Subsonic tests: a temp catalog with small fake audio files, a fake
//! [`Host`] recording forwarded requests, and [`handle`] called directly.

mod browse;
mod compat;
mod covers;
mod forward;
mod lyrics;
mod media;
mod web_covers;
mod xml;

use super::*;
use crate::types::{Device, Host, HostError, LinkConfig};
use bytes::Bytes;
use futures_util::future::BoxFuture;
use http::HeaderMap;
use http_body_util::BodyExt;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};

pub(super) const DEVICE_ID: &str = "device-1";
pub(super) const APP_VERSION: &str = "9.9.9-test";

/// Records forwarded requests and answers with canned replies (`{}` when
/// none is set for an op).
#[derive(Default)]
pub(super) struct FakeHost {
    requests: Mutex<Vec<(String, String, Value)>>,
    replies: Mutex<HashMap<String, Result<Value, HostError>>>,
}

impl FakeHost {
    pub(super) fn reply(&self, op: &str, reply: Result<Value, HostError>) {
        self.replies
            .lock()
            .expect("replies")
            .insert(op.to_owned(), reply);
    }

    pub(super) fn requests(&self) -> Vec<(String, String, Value)> {
        self.requests.lock().expect("requests").clone()
    }

    /// The args of the only request, asserting its op and device.
    pub(super) fn single(&self, op: &str) -> Value {
        let requests = self.requests();
        assert_eq!(requests.len(), 1, "{requests:?}");
        assert_eq!(requests[0].0, op);
        assert_eq!(requests[0].1, DEVICE_ID);
        requests[0].2.clone()
    }
}

impl Host for FakeHost {
    fn request(
        &self,
        op: &str,
        device_id: &str,
        args: Value,
    ) -> BoxFuture<'static, Result<Value, HostError>> {
        self.requests
            .lock()
            .expect("requests")
            .push((op.to_owned(), device_id.to_owned(), args));
        let reply = self
            .replies
            .lock()
            .expect("replies")
            .get(op)
            .cloned()
            .unwrap_or_else(|| Ok(json!({})));
        Box::pin(async move { reply })
    }

    fn event(&self, _method: &str, _args: Value) {}
}

pub(super) struct Fixture {
    /// Holds the catalog, fake audio and covers for the fixture's lifetime.
    _dir: tempfile::TempDir,
    pub(super) shared: Shared,
    pub(super) host: Arc<FakeHost>,
}

impl Fixture {
    /// A catalog from the rows `build` returns; it may create files in the
    /// given directory.
    pub(super) fn new(build: impl FnOnce(&Path) -> Vec<Value>) -> Self {
        Self::with_ffmpeg(None, build)
    }

    pub(super) fn with_ffmpeg(
        ffmpeg_path: Option<PathBuf>,
        build: impl FnOnce(&Path) -> Vec<Value>,
    ) -> Self {
        let dir = tempfile::tempdir().expect("temp dir");
        let rows = build(dir.path());
        let catalog_path = dir.path().join("catalog.ndjson");
        let mut file = std::fs::File::create(&catalog_path).expect("catalog file");
        writeln!(
            file,
            "{}",
            json!({ "catalogVersion": 1, "generatedMs": 1_761_350_400_000_i64, "count": rows.len() })
        )
        .expect("header");
        for row in rows {
            writeln!(file, "{row}").expect("row");
        }
        drop(file);
        let catalog = Catalog::load(&catalog_path).expect("catalog loads");
        let host = Arc::new(FakeHost::default());
        let temp_dir = dir.path().join("temp");
        std::fs::create_dir_all(&temp_dir).expect("temp dir");
        let shared = Shared {
            config: LinkConfig {
                state_dir: dir.path().join("state"),
                temp_dir,
                name: "Desk".to_owned(),
                port: 0,
                ffmpeg_path,
                app_version: APP_VERSION.to_owned(),
            },
            server_id: "server-1".to_owned(),
            host: Arc::clone(&host) as Arc<dyn Host>,
            catalog: RwLock::new(Arc::new(catalog)),
        };
        Self {
            _dir: dir,
            shared,
            host,
        }
    }

    pub(super) fn catalog(&self) -> Arc<Catalog> {
        self.shared.catalog()
    }

    pub(super) fn album_id(&self, song_id: &str) -> String {
        let catalog = self.catalog();
        let album = catalog.song(song_id).expect("song").album;
        catalog.albums()[album].id.clone()
    }

    pub(super) fn artist_id(&self, name: &str) -> String {
        short_id_for_artist(name)
    }

    /// The unread response of `method` with `params` and `headers`.
    pub(super) async fn response(
        &self,
        method: &str,
        params: &[(&str, &str)],
        headers: HeaderMap,
    ) -> HttpResponse {
        let request = SubsonicRequest {
            method: method.to_owned(),
            params: params
                .iter()
                .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
                .collect(),
            headers,
            device: Device {
                device_id: DEVICE_ID.to_owned(),
                name: "Phone".to_owned(),
                platform: "android".to_owned(),
            },
        };
        handle(&self.shared, request).await
    }

    /// The complete response of `method` with `params` and `headers`.
    pub(super) async fn raw(
        &self,
        method: &str,
        params: &[(&str, &str)],
        headers: HeaderMap,
    ) -> Reply {
        Reply::from(self.response(method, params, headers).await).await
    }

    /// `subsonic-response` of a JSON call.
    pub(super) async fn json(&self, method: &str, params: &[(&str, &str)]) -> Value {
        let mut all = vec![("f", "json"), ("v", "1.16.1"), ("c", "test")];
        all.extend_from_slice(params);
        let reply = self.raw(method, &all, HeaderMap::new()).await;
        assert_eq!(reply.status, 200, "{method}: {}", reply.text());
        assert_eq!(reply.header("content-type"), Some(JSON_TYPE));
        reply.subsonic()
    }

    /// The payload field `key` of a successful JSON call.
    pub(super) async fn ok(&self, method: &str, params: &[(&str, &str)], key: &str) -> Value {
        let response = self.json(method, params).await;
        assert_eq!(response["status"], "ok", "{method}: {response}");
        response[key].clone()
    }

    /// The Subsonic error code of a failed JSON call.
    pub(super) async fn error_code(&self, method: &str, params: &[(&str, &str)]) -> u64 {
        let response = self.json(method, params).await;
        assert_eq!(response["status"], "failed", "{method}: {response}");
        response["error"]["code"].as_u64().expect("numeric code")
    }
}

pub(super) fn short_id_for_artist(name: &str) -> String {
    crate::catalog::short_id("ar-", &crate::catalog::normalize(name))
}

pub(super) struct Reply {
    pub(super) status: u16,
    pub(super) headers: HeaderMap,
    pub(super) body: Bytes,
}

impl Reply {
    async fn from(response: HttpResponse) -> Self {
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let body = response
            .into_body()
            .collect()
            .await
            .expect("body")
            .to_bytes();
        Self {
            status,
            headers,
            body,
        }
    }

    pub(super) fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(name).and_then(|value| value.to_str().ok())
    }

    pub(super) fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    pub(super) fn subsonic(&self) -> Value {
        let value: Value = serde_json::from_slice(&self.body).expect("JSON body");
        value["subsonic-response"].clone()
    }
}

pub(super) fn headers(pairs: &[(&str, &str)]) -> HeaderMap {
    let mut map = HeaderMap::new();
    for (name, value) in pairs {
        map.insert(
            http::header::HeaderName::from_bytes(name.as_bytes()).expect("name"),
            http::HeaderValue::from_str(value).expect("value"),
        );
    }
    map
}

/// Writes `bytes` to `dir/name` and returns the path as a string.
pub(super) fn write_file(dir: &Path, name: &str, bytes: &[u8]) -> String {
    let path = dir.join(name);
    std::fs::write(&path, bytes).expect("write file");
    path.to_string_lossy().into_owned()
}

/// A PNG of `width` x `height`.
pub(super) fn png(width: u32, height: u32) -> Vec<u8> {
    let image = image::RgbImage::from_fn(width, height, |x, y| {
        image::Rgb([(x % 256) as u8, (y % 256) as u8, 128])
    });
    let mut bytes = Vec::new();
    image::DynamicImage::ImageRgb8(image)
        .write_to(
            &mut std::io::Cursor::new(&mut bytes),
            image::ImageFormat::Png,
        )
        .expect("encode png");
    bytes
}

/// The shared test library:
/// - "Blue Album" by The Band: First (1/1), Second (1/2, cover), Bonus (2/1)
/// - "Café Songs" by Beyoncé: Halo (explicit, ISRC)
/// - Hits (albumKey `comp-1`): Alpha One by Alpha, Beta Two by Beta
/// - Numbers by 42 Crew: Count
/// - Loose Track by Zed without an album
pub(super) fn library() -> Fixture {
    Fixture::new(|dir| {
        let audio = write_file(dir, "audio.flac", &[0, 1, 2, 3]);
        let cover = write_file(dir, "cover.png", &png(64, 32));
        let song = |id: &str, title: &str, artist: &str, extra: Value| -> Value {
            let mut value = json!({
                "id": id, "title": title, "artist": artist, "path": audio,
                "suffix": "flac", "durationMs": 200_000, "size": 4,
            });
            if let (Some(object), Value::Object(extra)) = (value.as_object_mut(), extra) {
                object.extend(extra);
            }
            value
        };
        vec![
            song(
                "l:2",
                "Second",
                "The Band",
                json!({ "album": "Blue Album", "albumArtist": "The Band", "disc": 1, "track": 2,
                        "year": 2001, "genre": "Rock", "coverPath": cover, "addedMs": 1_000 }),
            ),
            song(
                "l:1",
                "First",
                "The Band",
                json!({ "album": "Blue Album", "albumArtist": "The Band", "disc": 1, "track": 1,
                        "year": 2001, "genre": "Rock", "addedMs": 1_000 }),
            ),
            song(
                "l:3",
                "Bonus",
                "The Band",
                json!({ "album": "Blue Album", "albumArtist": "The Band", "disc": 2, "track": 1,
                        "genre": "Rock", "addedMs": 1_000 }),
            ),
            song(
                "l:10",
                "Halo",
                "Beyoncé",
                json!({ "album": "Café Songs", "year": 2008, "genre": "pop", "explicit": true,
                        "isrc": "USSM10800001", "addedMs": 5_000, "bitRate": 900,
                        "sampleRate": 44_100, "bitDepth": 16, "channels": 2,
                        "trackGain": -4.2, "albumGain": -3.5, "trackPeak": 0.9, "albumPeak": 1.0 }),
            ),
            song(
                "d:20",
                "Alpha One",
                "Alpha",
                json!({ "album": "Hits", "albumKey": "comp-1", "genre": "Pop", "year": 1995,
                        "addedMs": 3_000 }),
            ),
            song(
                "d:21",
                "Beta Two",
                "Beta",
                json!({ "album": "Hits", "albumKey": "comp-1", "genre": "Pop", "year": 1995,
                        "addedMs": 3_000 }),
            ),
            song(
                "l:30",
                "Count",
                "42 Crew",
                json!({ "album": "Numbers", "addedMs": 4_000 }),
            ),
            song("l:40", "Loose Track", "Zed", json!({})),
        ]
    })
}

/// Ids of the `id` fields in a JSON array.
pub(super) fn ids(value: &Value) -> Vec<String> {
    value
        .as_array()
        .map(|items| {
            items
                .iter()
                .map(|item| item["id"].as_str().unwrap_or_default().to_owned())
                .collect()
        })
        .unwrap_or_default()
}
