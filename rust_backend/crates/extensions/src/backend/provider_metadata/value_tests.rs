use super::*;
use crate::RuntimeLimits;
use std::sync::atomic::{AtomicBool, Ordering};

const ID: &str = "example.metadata";
const SOURCE: &str = r#"
function collection(id) {
    if (id === "null") return null;
    if (id === "bad") return {id: "bad", tracks: {}};
    if (id === "scalar") return {id: "scalar", tracks: "not an array"};
    if (id === "throw") throw new Error("fixture failure");
    const count = Number(id);
    return {id, name: "Album 音楽 🎵", artists: "Artist Café", provider_id: "supplied",
        cover_url: "https://example.invalid/cover.jpg", total_tracks: count,
        editorialNotes: {standard: "<p>A <i>new</i> direction &amp; sound.</p>", short: "A new direction."},
        description: "Collection notes",
        tracks: Array.from({length: count}, (_, i) => ({id: "track-" + i,
            name: "歌 🎵 " + i, artists: "Artist Café", album_name: "Album 音楽 🎵",
            provider_id: "supplied-track", duration_ms: 123456, track_number: i + 1,
            explicit: i % 2 === 0, external_links: {example: "https://example.invalid/track/" + i}}))};
}
function getArtist(id) {
    return {id, name: "Example Artist", image_url: "https://example.invalid/portrait.jpg",
        concerts: id === "bad-concerts" ? {} : [{id: "event-1", location: "Example City",
            venue: "Example Hall", startAt: "2026-10-07T01:00:00Z", timeZone: "America/New_York",
            url: "https://example.invalid/events/1", detailId: "event-1"}],
        headerLogo: "https://example.invalid/logo.png", albumsNext: "artist-page-2", albums: []};
}
function handleUrl(url) {
    if (url.includes("/album/")) return {type: "album", album: collection("1"), tracks: collection("1").tracks};
    return {type: "artist", artist: getArtist("artist-1")};
}
function getConcert(id) {
    return {id, artistName: "Example Artist", title: "Example Show", venue: "Example Hall",
        address: "123 Example Street", startAt: "2026-10-07T01:00:00Z",
        endAt: "2026-10-07T04:00:00Z", timeZone: "America/New_York",
        ticketUrl: "https://example.invalid/tickets/1", mapUrl: "https://example.invalid/maps/1",
        coverUrl: "https://example.invalid/artist.jpg", attribution: "Example Events",
        setList: {id: "list-1", name: "Concert Set List", coverUrl: "https://example.invalid/list.jpg"}};
}
function searchTracks(query) {
    if (query === "throw") throw new Error("fixture search failed");
    return {tracks: [{id: "first", name: "First", isrc: "EXAMPLE00001"},
        {id: "duplicate", name: "Duplicate", isrc: "example00001"},
        {id: "second", name: "Second", isrc: "EXAMPLE00002"}]};
}
function customSearch(query) {
    return query === "null" ? null : searchTracks(query).tracks;
}
function getRelatedTracks(seeds, options) {
    if (seeds[0].name === "null") return null;
    return Array.from({length: options.limit}, (_, i) => ({id: "related-" + i,
        name: "Like " + seeds[0].name, artists: "Other Artist", album_name: "Album",
        duration_ms: 1000, isrc: "EXAMPLE1000" + i}));
}
registerExtension({getAlbum: collection, getPlaylist: collection, getArtist, getConcert, handleUrl,
    searchTracks, customSearch, getRelatedTracks});
"#;

fn fixture() -> (tempfile::TempDir, Backend) {
    fixture_with(json!({"relatedTracks": true}))
}

fn fixture_with(capabilities: Value) -> (tempfile::TempDir, Backend) {
    let root = tempfile::tempdir().unwrap();
    let source = root.path().join("sources").join(ID);
    std::fs::create_dir_all(&source).unwrap();
    std::fs::write(
        source.join("manifest.json"),
        json!({"name":ID,"displayName":"Example Metadata","version":"1",
            "description":"Generic metadata fixture","type":["metadata_provider"],
            "searchBehavior":{"enabled":true},
            "urlHandler":{"enabled":true,"patterns":["example.invalid"]},
            "capabilities":capabilities})
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

#[test]
fn search_value_routes_preserve_public_json_dedup_limits_and_cancellation() {
    let (_root, backend) = fixture();
    let typed = backend
        .manager
        .search_metadata_providers_value_with_lease("example", 2, true, "", 30_000, None)
        .unwrap();
    let public = backend
        .manager
        .search_metadata_providers("example", 2, true, "", 30_000)
        .unwrap();
    assert_eq!(typed.to_string(), public);
    assert_eq!(typed[0]["id"], "first");
    assert_eq!(typed[1]["id"], "second");
    assert_eq!(typed[0]["provider_id"], ID);
    let custom: Value = serde_json::from_str(
        &backend
            .custom_search_json(ID, "example", "{}", None)
            .unwrap(),
    )
    .unwrap();
    assert_eq!(custom.as_array().unwrap().len(), 3);
    assert_eq!(custom[0]["name"], "First");
    assert_eq!(
        backend.custom_search_json(ID, "null", "{}", None).unwrap(),
        "[]"
    );
    assert!(
        backend
            .custom_search_json(ID, "throw", "{}", None)
            .unwrap_err()
            .contains("fixture search failed")
    );
    let registry = CancellationRegistry::new(CancellationDomain::ExtensionRequest);
    let lease = Arc::new(registry.acquire("example").unwrap());
    registry.cancel("example").unwrap();
    assert!(
        backend
            .manager
            .search_metadata_providers_value_with_lease("example", 2, true, "", 30_000, Some(lease))
            .is_err()
    );
}

#[test]
fn related_tracks_pass_seeds_and_limit_and_need_the_capability() {
    let (_root, backend) = fixture();
    let seeds = json!([{"id":"seed","name":"Seed","artists":"Artist"}]).to_string();
    let related: Value = serde_json::from_str(
        &backend
            .get_extension_related_tracks_json(ID, &seeds, r#"{"limit":3}"#, None)
            .unwrap(),
    )
    .unwrap();
    let related = related.as_array().unwrap();
    assert_eq!(related.len(), 3);
    assert_eq!(related[0]["name"], "Like Seed");
    assert_eq!(related[0]["isrc"], "EXAMPLE10000");
    assert_eq!(related[0]["provider_id"], ID);
    // The limit stays within 1 to 50.
    let capped: Value = serde_json::from_str(
        &backend
            .get_extension_related_tracks_json(ID, &seeds, r#"{"limit":500}"#, None)
            .unwrap(),
    )
    .unwrap();
    assert_eq!(capped.as_array().unwrap().len(), 50);
    let none = json!([{"name":"null","artists":"Artist"}]).to_string();
    assert_eq!(
        backend
            .get_extension_related_tracks_json(ID, &none, "{}", None)
            .unwrap(),
        "[]"
    );
    assert!(
        backend
            .get_extension_related_tracks_json(ID, "not json", "{}", None)
            .is_err()
    );

    let (_root, without) = fixture_with(json!({}));
    assert!(
        without
            .get_extension_related_tracks_json(ID, &seeds, "{}", None)
            .unwrap_err()
            .contains("does not suggest related tracks")
    );
}

#[test]
fn concert_details_preserve_generic_actions_and_set_list() {
    let (_root, backend) = fixture();
    let result: Value = serde_json::from_str(
        &backend
            .get_provider_metadata_json(ID, "concert", "event-1", &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    let detail = &result["concert"];
    assert_eq!(detail["id"], "event-1");
    assert_eq!(detail["artist_name"], "Example Artist");
    assert_eq!(detail["start_at"], "2026-10-07T01:00:00Z");
    assert_eq!(detail["end_at"], "2026-10-07T04:00:00Z");
    assert_eq!(detail["ticket_url"], "https://example.invalid/tickets/1");
    assert_eq!(detail["map_url"], "https://example.invalid/maps/1");
    assert_eq!(detail["set_list"]["id"], "list-1");
    assert_eq!(
        detail["set_list"]["cover_url"],
        "https://example.invalid/list.jpg"
    );
    assert_eq!(detail["attribution"], "Example Events");
}

#[test]
fn album_editorial_notes_survive_metadata_and_url_routes() {
    let (_root, backend) = fixture();
    let direct: Value = serde_json::from_str(
        &backend
            .get_provider_metadata_json(ID, "album", "1", &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    let linked: Value = serde_json::from_str(
        &backend
            .handle_url_json("https://example.invalid/album/1")
            .unwrap(),
    )
    .unwrap();
    for album in [&direct["album_info"], &linked["album"]] {
        assert_eq!(
            album["editorial_notes"]["standard"],
            "<p>A <i>new</i> direction &amp; sound.</p>"
        );
        assert_eq!(album["editorial_notes"]["short"], "A new direction.");
        assert_eq!(album["description"], "Collection notes");
    }
}

#[test]
fn response_envelopes_preserve_json_and_cancellation() {
    let value = json!({
        "id": "collection", "name": "音楽 🎵", "artists": "Artist Café",
        "cover_url": "https://example.invalid/cover.jpg",
        "tracks": [
            {"id": "first", "name": "One", "external_links": {"example": "link"}},
            {"id": "second", "name": "Two", "explicit": true, "track_number": 9},
        ],
    });
    let check = || Ok(());
    let cover = text(&value, "cover_url");
    let expected = json!({
        "album_info": album(&value, true),
        "track_list": tracks(array(&value, "tracks"), cover, &check).unwrap(),
    });
    let actual = response("album", &value, &check).unwrap();
    assert_eq!(actual.to_string(), expected.to_string());
    let playlist = response("playlist", &value, &check).unwrap();
    assert_eq!(playlist["track_list"], expected["track_list"]);
    assert_eq!(playlist["playlist_info"]["owner"]["name"], "Artist Café");
    assert_eq!(playlist["track_list"][0]["track_number"], 1);
    assert_eq!(playlist["track_list"][1]["track_number"], 9);
    assert_eq!(
        response("track", &value, &check).unwrap().to_string(),
        json!({"track": track(&value, "", 0)}).to_string(),
    );
    for kind in ["album", "playlist", "artist", "track"] {
        assert_eq!(
            response(kind, &value, &|| Err("cancelled".into())),
            Err(ResolverError::Cancelled("cancelled".into())),
        );
    }
}

#[test]
fn artist_metadata_preserves_logo_separately_from_portrait() {
    let (_root, backend) = fixture();
    let raw = backend
        .get_provider_metadata_json(ID, "artist", "artist-1", &|| Ok(()))
        .unwrap();
    let value: Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(
        value["artist_info"]["header_logo"],
        "https://example.invalid/logo.png"
    );
    assert_eq!(
        value["artist_info"]["images"],
        "https://example.invalid/portrait.jpg"
    );
    assert_eq!(value["artist_info"]["name"], "Example Artist");
    assert_eq!(value["artist_info"]["albums_next"], "artist-page-2");
    backend.shutdown();
}

#[test]
fn artist_concerts_survive_metadata_and_url_routes_without_provider_special_cases() {
    let (_root, backend) = fixture();
    let metadata: Value = serde_json::from_str(
        &backend
            .get_provider_metadata_json(ID, "artist", "artist-1", &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    let concerts = &metadata["artist_info"]["concerts"];
    assert_eq!(concerts[0]["start_at"], "2026-10-07T01:00:00Z");
    assert_eq!(concerts[0]["time_zone"], "America/New_York");
    assert_eq!(concerts[0]["venue"], "Example Hall");
    let handled: Value = serde_json::from_str(
        &backend
            .handle_url_json("https://example.invalid/artist/1")
            .unwrap(),
    )
    .unwrap();
    assert_eq!(&handled["artist"]["concerts"], concerts);
    let malformed: Value = serde_json::from_str(
        &backend
            .get_provider_metadata_json(ID, "artist", "bad-concerts", &|| Ok(()))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(malformed["artist_info"]["concerts"], json!([]));
    assert_eq!(malformed["artist_info"]["name"], "Example Artist");
    backend.shutdown();
}

#[test]
fn metadata_value_bridge_preserves_album_playlist_and_public_json() {
    let (_root, backend) = fixture();
    for (kind, method) in [("album", "getAlbum"), ("playlist", "getPlaylist")] {
        let arguments = r#"["100"]"#;
        let legacy = backend
            .manager
            .provider_call(ID, method, arguments, None, 30_000)
            .unwrap();
        let legacy_value: Value = serde_json::from_str(&legacy).unwrap();
        let value = backend
            .manager
            .provider_call_value(ID, method, arguments, None, 30_000)
            .unwrap();
        assert_eq!(value, legacy_value);
        assert_eq!(value.to_string(), legacy);
        assert_eq!(value["provider_id"], ID);
        assert_eq!(value["tracks"][99]["provider_id"], ID);
        assert_eq!(value["tracks"][99]["name"], "歌 🎵 99");
        let expected = response(kind, &legacy_value, &|| Ok(())).unwrap();
        let actual = backend
            .get_provider_metadata_json(ID, kind, "100", &|| Ok(()))
            .unwrap();
        assert_eq!(actual, expected.to_string());
        // Legacy array-like coercion accepts a string as one default track per
        // character. Keep that compatibility rather than tightening decoding.
        let scalar = backend
            .manager
            .provider_call(ID, method, r#"["scalar"]"#, None, 30_000)
            .unwrap();
        let scalar_value = backend
            .manager
            .provider_call_value(ID, method, r#"["scalar"]"#, None, 30_000)
            .unwrap();
        assert_eq!(scalar_value.to_string(), scalar);
        assert_eq!(scalar_value["tracks"].as_array().unwrap().len(), 12);
    }
    if std::env::var_os("MORNYE_METADATA_BRIDGE_BENCH").is_some() {
        measure_removed_roundtrip(&backend);
    }
    backend.shutdown();
}

#[test]
fn metadata_value_bridge_preserves_provider_errors_and_cancelled_leases() {
    let (_root, backend) = fixture();
    for (kind, method) in [("album", "getAlbum"), ("playlist", "getPlaylist")] {
        for id in ["null", "bad", "throw"] {
            let arguments = json!([id]).to_string();
            let legacy = backend
                .manager
                .provider_call(ID, method, &arguments, None, 30_000)
                .unwrap_err();
            let typed = backend
                .manager
                .provider_call_value(ID, method, &arguments, None, 30_000)
                .unwrap_err();
            assert_eq!(typed.to_string(), legacy.to_string());
            let facade = backend
                .get_provider_metadata_json(ID, kind, id, &|| Ok(()))
                .unwrap_err();
            assert!(facade.contains(&legacy.to_string()), "{facade}");
        }
    }
    let registry = CancellationRegistry::new(CancellationDomain::ExtensionRequest);
    let lease = Arc::new(registry.acquire("metadata-fixture").unwrap());
    lease.release();
    let legacy = backend
        .manager
        .provider_call(ID, "getAlbum", r#"["1"]"#, Some(lease.clone()), 30_000)
        .unwrap_err();
    let typed = backend
        .manager
        .provider_call_value(ID, "getAlbum", r#"["1"]"#, Some(lease), 30_000)
        .unwrap_err();
    assert_eq!(typed.to_string(), legacy.to_string());
    backend.shutdown();
}

#[test]
fn metadata_value_worker_joins_cancellation_and_reports_panic() {
    let (_root, backend) = fixture();
    let started = AtomicBool::new(false);
    let joined = AtomicBool::new(false);
    let result = backend.metadata_provider_work_result(
        &|| {
            if started.load(Ordering::Acquire) {
                Err("cancelled typed result".into())
            } else {
                Ok(())
            }
        },
        |lease| {
            started.store(true, Ordering::Release);
            assert!(lease.wait_cancelled(60_000).is_err());
            joined.store(true, Ordering::Release);
            Ok(json!({"tracks":[]}))
        },
    );
    assert_eq!(
        result,
        Err(ResolverError::Cancelled("cancelled typed result".into()))
    );
    assert!(joined.load(Ordering::Acquire));
    let panic = backend
        .metadata_provider_work_result(&|| Ok(()), |_| -> Result<Value, ManagerError> {
            panic!("typed metadata worker failed")
        });
    assert_eq!(
        panic,
        Err(ResolverError::Failed("metadata provider panicked".into()))
    );
    backend.shutdown();
}

fn measure_removed_roundtrip(backend: &Backend) {
    use std::hint::black_box;
    use std::time::Instant;

    for count in [1, 100, 1_000, 10_000] {
        let value = backend
            .manager
            .provider_call_value(
                ID,
                "getPlaylist",
                &json!([count.to_string()]).to_string(),
                None,
                30_000,
            )
            .unwrap();
        let bytes = value.to_string().len();
        let iterations = if count >= 1_000 { 25 } else { 100 };
        let start = Instant::now();
        for _ in 0..iterations {
            let encoded = black_box(&value).to_string();
            let decoded: Value = serde_json::from_str(black_box(&encoded)).unwrap();
            black_box(decoded);
        }
        let micros = start.elapsed().as_secs_f64() * 1_000_000.0 / f64::from(iterations);
        eprintln!(
            "metadata bridge isolated removed serialize+parse: tracks={count} bytes={bytes} iterations={iterations} mean_us={micros:.2}"
        );
    }
}
