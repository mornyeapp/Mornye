use super::*;
use crate::RuntimeLimits;
use crate::backend::MetadataOptions;
use crate::environment::ExtensionEnvironment;
use mornye_network::{NetworkOptions, NetworkService};
use std::io::{BufRead, BufReader};
use std::net::TcpListener;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

const ID: &str = "example.motion";
const SOURCE: &str = r#"
function searchTracks() {
    return {tracks: [{id: "track-1", name: "Song", artists: "Artist",
        album_name: "Album", album_id: "album-1",
        images: "https://example.invalid/still.jpg"}]};
}
function getTrack(id) {
    return {id, name: "Song", artists: "Artist", album_name: "Album", album_id: "album-1"};
}
function getAlbum(id) {
    if (id === "unavailable") throw new Error("optional artwork unavailable");
    return {id, name: "Album", artists: "Artist", tracks: [],
        cover_url: "https://example.invalid/still.jpg",
        header_video: "https://example.invalid/motion.m3u8"};
}
registerExtension({searchTracks, getTrack, getAlbum});
"#;

fn fixture() -> (tempfile::TempDir, Backend) {
    let root = tempfile::tempdir().unwrap();
    let source = root.path().join("sources").join(ID);
    std::fs::create_dir_all(&source).unwrap();
    std::fs::write(
        source.join("manifest.json"),
        json!({"name":ID,"displayName":"Example Motion","version":"1",
            "description":"Generic motion metadata fixture","type":["metadata_provider"]})
        .to_string(),
    )
    .unwrap();
    std::fs::write(source.join("index.js"), SOURCE).unwrap();
    let backend = Backend::new(
        &root.path().join("sources"),
        &root.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        RuntimeLimits::default(),
    )
    .unwrap();
    backend.load_all().unwrap();
    backend.set_enabled(ID, true).unwrap();
    (root, backend)
}

fn request() -> Request {
    Request::parse(
        r#"{"track_name":"Song","artist_name":"Artist","album_name":"Album",
        "update_fields":["cover"]}"#,
    )
    .unwrap()
}

#[test]
fn cover_preview_resolves_album_motion_without_replacing_the_still_image() {
    let (_root, backend) = fixture();
    let mut request = request();
    request.file_path = "unused-preview.flac".into();
    request.search_online = true;
    request.preview_only = true;
    let raw = backend
        .reenrich_file(&serde_json::to_string(&request).unwrap(), &|| Ok(()))
        .unwrap();
    let response: Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(response["method"], "preview");
    assert_eq!(
        response["enriched_metadata"]["cover_url"],
        "https://example.invalid/still.jpg"
    );
    assert_eq!(
        response["enriched_metadata"]["header_video"],
        "https://example.invalid/motion.m3u8"
    );
}

#[test]
fn missing_album_id_uses_provider_track_details() {
    let (_root, backend) = fixture();
    let video = backend.reenrich_motion_artwork(
        &request(),
        &json!({"id":"track-1","provider_id":ID}),
        &|| Ok(()),
    );
    assert_eq!(
        video.as_deref(),
        Some("https://example.invalid/motion.m3u8")
    );
}

#[test]
fn optional_failures_and_different_releases_do_not_supply_video() {
    let (_root, backend) = fixture();
    let track = json!({"id":"track-1","album_id":"unavailable","provider_id":ID});
    assert!(
        backend
            .reenrich_motion_artwork(&request(), &track, &|| Ok(()))
            .is_none()
    );
    let mut request = request();
    request.album_name = "Another Release".into();
    let track = json!({"id":"track-1","album_id":"album-1","provider_id":ID});
    assert!(
        backend
            .reenrich_motion_artwork(&request, &track, &|| Ok(()))
            .is_none()
    );
}

const CATALOG_TRACK: &str = r#"{"id":7,"title":"Signal","duration":200,"isrc":"EXAMPLE00001",
    "readable":true,"release_date":"2001-01-01","track_position":4,
    "artist":{"id":2,"name":"Lead Artist"},"album":{"id":9,"title":"Catalog Album"}}"#;
const CATALOG_ALBUM: &str = r#"{"id":9,"genres":{"data":[{"name":"Catalog Genre"}]},
    "label":"Catalog Label","copyright":"Catalog Copyright"}"#;
/// More songs than a provider's limit, whose titles only contain the local
/// title, different for each query.
const WRONG_SONGS: &str = r#"(query) => Array.from({length: 12}, (_, i) => ({
    id: "wrong-" + query.length + "-" + i, name: "Signal Night Dance " + query.length + "-" + i,
    artists: "Lead Artist", album_name: "Album", duration_ms: 200000}))"#;
const RIGHT_SONG: &str = r#"() => [{id: "right-1", name: "Signal", artists: "Lead Artist",
    album_name: "Album", duration_ms: 201000, release_date: "2020-01-01", track_number: 3,
    cover_url: "https://example.com/right.jpg"}]"#;

/// Serves Deezer catalog paths over local TLS and records every request.
struct Catalog {
    url: String,
    paths: Arc<Mutex<Vec<String>>>,
    stop: Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}

impl Drop for Catalog {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Catalog {
    fn paths(&self) -> Vec<String> {
        self.paths.lock().unwrap().clone()
    }
}

fn catalog(config: Arc<rustls::ServerConfig>) -> Catalog {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let url = format!("https://{}", listener.local_addr().unwrap());
    let paths = Arc::new(Mutex::new(Vec::new()));
    let stop = Arc::new(AtomicBool::new(false));
    let worker = {
        let (paths, stop) = (paths.clone(), stop.clone());
        std::thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                let stream = match listener.accept() {
                    Ok((stream, _)) => stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(1));
                        continue;
                    }
                    Err(error) => panic!("{error}"),
                };
                let _ = respond(stream, config.clone(), &paths);
            }
        })
    };
    Catalog {
        url,
        paths,
        stop,
        worker: Some(worker),
    }
}

fn respond(
    stream: std::net::TcpStream,
    config: Arc<rustls::ServerConfig>,
    paths: &Mutex<Vec<String>>,
) -> std::io::Result<()> {
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_secs(3)))?;
    let connection = rustls::ServerConnection::new(config).map_err(std::io::Error::other)?;
    let mut stream = rustls::StreamOwned::new(connection, stream);
    let mut reader = BufReader::new(&mut stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let path = line.split(' ').nth(1).unwrap_or_default().to_owned();
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header)? == 0 || header == "\r\n" {
            break;
        }
    }
    paths.lock().unwrap().push(path.clone());
    let (status, body) = if path.starts_with("/2.0/track/isrc:EXAMPLE00001") {
        ("200 OK", CATALOG_TRACK)
    } else if path.starts_with("/2.0/album/9") {
        ("200 OK", CATALOG_ALBUM)
    } else {
        ("404 Not Found", r#"{"error":{"message":"not found"}}"#)
    };
    write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )?;
    stream.flush()?;
    stream.conn.send_close_notify();
    stream.flush()
}

struct Providers {
    backend: Backend,
    catalog: Catalog,
    _root: tempfile::TempDir,
}

impl Providers {
    /// Every query a provider was asked, with its limit, in order.
    fn queries(&self, id: &str) -> String {
        let raw = self
            .backend
            .get_provider_metadata_json(id, "track", "queries", &|| Ok(()))
            .unwrap();
        let details: Value = serde_json::from_str(&raw).unwrap();
        text(&details["track"], "name").to_owned()
    }

    fn reenrich(&self, request: Value) -> Result<Value, String> {
        self.backend
            .reenrich_file(&request.to_string(), &|| Ok(()))
            .map(|raw| serde_json::from_str(&raw).unwrap())
    }
}

/// Metadata providers in priority order, each answering a search with the
/// tracks its JavaScript `results(query)` returns. The catalog is local.
fn providers(results: &[(&str, &str)]) -> Providers {
    let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(
        vec![certificate.cert.der().clone()],
        rustls::pki_types::PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der()).into(),
    )
    .unwrap();
    let network = NetworkService::with_options(NetworkOptions {
        extra_root_pem: certificate.cert.pem().into_bytes(),
        doh_upstreams: vec![],
        ..Default::default()
    })
    .unwrap();
    network.set_allow_private_network(true);
    let catalog = catalog(Arc::new(config));
    let root = tempfile::tempdir().unwrap();
    for (id, results) in results {
        let source = root.path().join("sources").join(id);
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(
            source.join("manifest.json"),
            json!({"name":id,"displayName":"Example Provider","version":"1",
                "description":"Generic metadata fixture","type":["metadata_provider"]})
            .to_string(),
        )
        .unwrap();
        std::fs::write(
            source.join("index.js"),
            format!(
                r##"const asked = [];
const results = {results};
function searchTracks(query, limit) {{
    asked.push(query + "#" + limit);
    return {{tracks: results(query)}};
}}
function getTrack(id) {{
    return {{id, name: id === "queries" ? asked.join("|") : "Fixture", artists: "Fixture"}};
}}
registerExtension({{searchTracks, getTrack}});
"##
            ),
        )
        .unwrap();
    }
    let environment = ExtensionEnvironment::with_network(
        &root.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        network,
    )
    .unwrap();
    let mut options = MetadataOptions {
        deezer_endpoint: catalog.url.clone(),
        ..Default::default()
    };
    options.musicbrainz.endpoint = catalog.url.clone();
    options.musicbrainz.retry_delay = Duration::from_millis(1);
    let backend = Backend::with_environment(
        &root.path().join("sources"),
        environment,
        RuntimeLimits::default(),
        options,
    )
    .unwrap();
    backend.load_all().unwrap();
    for (id, _) in results {
        backend.set_enabled(id, true).unwrap();
    }
    backend
        .manager
        .set_provider_priority(
            "metadata",
            results.iter().map(|(id, _)| (*id).to_owned()).collect(),
        )
        .unwrap();
    Providers {
        backend,
        catalog,
        _root: root,
    }
}

fn song(extra: Value) -> Value {
    let mut request = json!({"file_path":"song.mp3","track_name":"Signal",
        "artist_name":"Lead Artist","album_name":"Album","duration_ms":200_000,
        "search_online":true,"preview_only":true});
    for (key, value) in extra.as_object().unwrap() {
        request[key] = value.clone();
    }
    request
}

#[test]
fn a_later_provider_is_asked_when_the_first_returns_only_other_songs() {
    let fixture = providers(&[("provider-a", WRONG_SONGS), ("provider-b", RIGHT_SONG)]);
    let response = fixture.reenrich(song(json!({}))).unwrap();
    assert_eq!(response["auto_match"], "strong");
    assert!(response.get("candidates").is_none());
    let enriched = &response["enriched_metadata"];
    assert_eq!(enriched["release_date"], "2020-01-01");
    assert_eq!(enriched["track_number"], 3);
    assert_eq!(enriched["cover_url"], "https://example.com/right.jpg");
    assert_eq!(fixture.queries("provider-a"), "Signal Lead Artist#8");
    // The confident match ends the search before the album query.
    assert_eq!(fixture.queries("provider-b"), "Signal Lead Artist#8");
}

#[test]
fn an_automatic_run_stops_at_the_first_confident_provider() {
    let reissue = r#"() => [{id: "reissue", name: "Signal", artists: "Lead Artist",
        album_name: "Album", duration_ms: 201000, release_date: "2021-05-05", track_number: 3,
        cover_url: "https://example.com/reissue.jpg"}]"#;
    let fixture = providers(&[("provider-a", RIGHT_SONG), ("provider-b", reissue)]);
    let response = fixture.reenrich(song(json!({}))).unwrap();
    assert_eq!(response["auto_match"], "strong");
    assert_eq!(fixture.queries("provider-a"), "Signal Lead Artist#8");
    assert_eq!(fixture.queries("provider-b"), "");
    // A picker asks every provider, and the first candidate is the applied one.
    let response = fixture
        .reenrich(song(json!({"include_candidates":true})))
        .unwrap();
    assert_eq!(fixture.queries("provider-b"), "Signal Lead Artist#8");
    let candidates = response["candidates"].as_array().unwrap();
    assert_eq!(candidates.len(), 2);
    assert_eq!(candidates[0]["provider_id"], "provider-a");
    assert_eq!(candidates[1]["provider_id"], "provider-b");
    assert_eq!(response["auto_match"], candidates[0]["match"]);
    assert_eq!(
        response["enriched_metadata"]["spotify_id"],
        candidates[0]["id"]
    );
}

#[test]
fn a_picker_asks_its_providers_at_once_and_keeps_their_order() {
    let slow = |id: &str, year: u32| {
        format!(
            r#"() => {{ const end = Date.now() + 500; while (Date.now() < end) {{}}
            return [{{id: "{id}", name: "Signal", artists: "Lead Artist", album_name: "Album",
            duration_ms: 201000, release_date: "{year}-01-01"}}]; }}"#
        )
    };
    let (a, b, c) = (
        slow("from-a", 2001),
        slow("from-b", 2002),
        slow("from-c", 2003),
    );
    let fixture = providers(&[("provider-a", &a), ("provider-b", &b), ("provider-c", &c)]);
    let started = std::time::Instant::now();
    let response = fixture
        .reenrich(song(json!({"include_candidates":true})))
        .unwrap();
    let elapsed = started.elapsed();
    let candidates = response["candidates"].as_array().unwrap();
    let ids: Vec<_> = candidates.iter().map(|track| text(track, "id")).collect();
    assert_eq!(ids, ["from-a", "from-b", "from-c"]);
    // Three 500 ms providers took at least 1.5 s one after another.
    assert!(elapsed < Duration::from_millis(1200), "{elapsed:?}");
}

#[test]
fn a_batch_lists_candidates_but_keeps_the_early_stop() {
    let reissue = r#"() => [{id: "reissue", name: "Signal", artists: "Lead Artist",
        album_name: "Album", duration_ms: 201000}]"#;
    let fixture = providers(&[("provider-a", RIGHT_SONG), ("provider-b", reissue)]);
    let response = fixture
        .reenrich(song(
            json!({"include_candidates":true,"quick_candidates":true}),
        ))
        .unwrap();
    assert_eq!(response["auto_match"], "strong");
    assert_eq!(fixture.queries("provider-b"), "");
    let candidates = response["candidates"].as_array().unwrap();
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0]["provider_id"], "provider-a");
}

#[test]
fn candidates_are_ranked_unique_and_capped_and_weak_matches_wait_for_a_choice() {
    let compilation = r#"() => [{id: "compilation", name: "Signal", artists: "Lead Artist",
        album_name: "Different Record", duration_ms: 202000}]"#;
    let fixture = providers(&[("provider-a", WRONG_SONGS), ("provider-c", compilation)]);
    let response = fixture
        .reenrich(song(
            json!({"include_candidates":true,"release_date":"2020"}),
        ))
        .unwrap();
    // Nothing confident, so the album query runs too.
    assert_eq!(
        fixture.queries("provider-a"),
        "Signal Lead Artist#8|Signal Album#8"
    );
    assert_eq!(response["auto_match"], "none");
    let enriched = &response["enriched_metadata"];
    assert_eq!(enriched["album_name"], "Album");
    assert_eq!(enriched["release_date"], "2020");
    let candidates = response["candidates"].as_array().unwrap();
    assert_eq!(candidates.len(), reenrich::MAX_CANDIDATES);
    assert_eq!(candidates[0]["provider_id"], "provider-c");
    assert_eq!(candidates[0]["match"], "weak");
    let mut seen = std::collections::BTreeSet::new();
    for pair in candidates.windows(2) {
        let level = |track: &Value| {
            ["other", "weak", "strong", "exact"]
                .iter()
                .position(|level| *level == text(track, "match"))
                .unwrap()
        };
        let (first, second) = (&pair[0], &pair[1]);
        assert!(
            (level(first), first["match_score"].as_i64().unwrap())
                >= (level(second), second["match_score"].as_i64().unwrap())
        );
    }
    for candidate in candidates {
        assert!(seen.insert(format!("{}:{}", candidate["provider_id"], candidate["id"])));
        if candidate["provider_id"] == "provider-a" {
            assert_eq!(candidate["match"], "other");
        }
    }
}

#[test]
fn a_selected_candidate_is_applied_as_given_without_any_search() {
    let fixture = providers(&[("provider-a", WRONG_SONGS), ("provider-b", RIGHT_SONG)]);
    let candidate = json!({"provider_id":"provider-b","id":"chosen","name":"Signal",
        "artists":"Lead Artist","album_name":"Other Release","release_date":"1999",
        "duration_ms":200_000,"track_number":5,"total_tracks":12,
        "match":"weak","match_score":1234});
    let fields = json!(["basic_tags", "release_info", "track_info"]);
    for preview in [true, false] {
        let response = fixture
            .reenrich(song(
                json!({"preview_only":preview,"selected_candidate":candidate,
                "release_date":"2020","track_number":1,"update_fields":fields}),
            ))
            .unwrap();
        assert_eq!(
            response["method"],
            if preview { "preview" } else { "ffmpeg" }
        );
        assert_eq!(response["auto_match"], "weak");
        let enriched = &response["enriched_metadata"];
        assert_eq!(enriched["album_name"], "Other Release");
        assert_eq!(enriched["release_date"], "1999");
        assert_eq!(enriched["track_number"], 5);
        assert_eq!(enriched["total_tracks"], 12);
        assert_eq!(enriched["spotify_id"], "chosen");
    }
    assert_eq!(fixture.queries("provider-a"), "");
    assert_eq!(fixture.queries("provider-b"), "");
    assert!(fixture.catalog.paths().is_empty());
}

#[test]
fn provider_ids_limit_the_search_and_leave_out_the_catalog() {
    let fixture = providers(&[("provider-a", RIGHT_SONG), ("provider-b", RIGHT_SONG)]);
    let response = fixture
        .reenrich(song(
            json!({"include_candidates":true,"isrc":"EXAMPLE00001",
            "provider_ids":["provider-b"],
            "update_fields":["track_name","artist_name","album_name","release_info"]}),
        ))
        .unwrap();
    assert_eq!(fixture.queries("provider-a"), "");
    assert_eq!(fixture.queries("provider-b"), "Signal Lead Artist#8");
    let candidates = response["candidates"].as_array().unwrap();
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0]["provider_id"], "provider-b");
    assert!(fixture.catalog.paths().is_empty());
}

#[test]
fn the_catalog_track_neither_wins_nor_fills_fields_a_provider_match_lacks() {
    let exact = r#"() => [{id: "exact", name: "Signal", artists: "Lead Artist",
        album_name: "Album", duration_ms: 200000, isrc: "EXAMPLE00001"}]"#;
    let fixture = providers(&[("provider-b", exact)]);
    let response = fixture
        .reenrich(song(
            json!({"include_candidates":true,"isrc":"EXAMPLE00001",
            "release_date":"2020","label":"Existing Label"}),
        ))
        .unwrap();
    assert_eq!(response["auto_match"], "exact");
    let candidates = response["candidates"].as_array().unwrap();
    assert_eq!(candidates[0]["provider_id"], "provider-b");
    assert_eq!(candidates[1]["provider_id"], "deezer");
    assert_eq!(candidates[1]["match"], "exact");
    let enriched = &response["enriched_metadata"];
    assert_eq!(enriched["spotify_id"], "exact");
    assert_eq!(enriched["album_name"], "Album");
    assert_eq!(enriched["release_date"], "2020");
    assert_eq!(enriched["track_number"], 0);
    // The catalog's album artist and date belong to another release.
    assert_eq!(enriched["album_artist"], "");
    // Extras by ISRC only fill what is still empty.
    assert_eq!(enriched["genre"], "Catalog Genre");
    assert_eq!(enriched["label"], "Existing Label");
    assert_eq!(enriched["copyright"], "Catalog Copyright");
}

#[test]
fn a_picker_reports_a_needed_verification_when_no_provider_answered() {
    let blocked = r#"() => { throw new Error("verification_required: sign in again"); }"#;
    let fixture = providers(&[("provider-v", blocked)]);
    let error = fixture
        .reenrich(song(json!({"include_candidates":true})))
        .unwrap_err();
    assert!(
        error.starts_with("verification_required: extension 'provider-v' needs verification"),
        "{error}"
    );
    // An automatic run keeps the file's values instead of failing.
    let response = fixture.reenrich(song(json!({}))).unwrap();
    assert_eq!(response["auto_match"], "none");
    assert_eq!(response["enriched_metadata"]["album_name"], "Album");
}

#[test]
fn a_picker_asking_providers_at_once_reports_verification_as_one_after_another() {
    let blocked = r#"() => { throw new Error("verification_required: sign in again"); }"#;
    let fixture = providers(&[("provider-v", blocked), ("provider-w", blocked)]);
    let error = fixture
        .reenrich(song(json!({"include_candidates":true})))
        .unwrap_err();
    assert!(
        error.starts_with("verification_required: extension 'provider-v' needs verification"),
        "{error}"
    );
    let fixture = providers(&[("provider-v", blocked), ("provider-b", RIGHT_SONG)]);
    let response = fixture
        .reenrich(song(json!({"include_candidates":true})))
        .unwrap();
    let candidates = response["candidates"].as_array().unwrap();
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0]["provider_id"], "provider-b");
}
