use super::*;

fn names(value: &Value, field: &str) -> Vec<String> {
    value
        .as_array()
        .map(|items| {
            items
                .iter()
                .map(|item| item[field].as_str().unwrap_or_default().to_owned())
                .collect()
        })
        .unwrap_or_default()
}

#[tokio::test]
async fn ping_answers_the_open_subsonic_envelope() {
    let fixture = library();
    let response = fixture.json("ping", &[]).await;
    assert_eq!(
        response,
        json!({
            "status": "ok",
            "version": "1.16.1",
            "type": "mornye",
            "serverVersion": APP_VERSION,
            "openSubsonic": true,
        })
    );
    let jsonp = fixture
        .raw(
            "ping",
            &[("f", "jsonp"), ("callback", "cb")],
            HeaderMap::new(),
        )
        .await;
    assert_eq!(jsonp.subsonic()["status"], "ok");
}

#[tokio::test]
async fn unknown_methods_and_bad_parameters_fail_with_http_200() {
    let fixture = library();
    let response = fixture.json("getVideos", &[]).await;
    assert_eq!(response["status"], "failed");
    assert_eq!(
        response["error"],
        json!({ "code": 0, "message": "not implemented" })
    );
    assert_eq!(response["openSubsonic"], true);
    assert_eq!(fixture.error_code("getAlbum", &[]).await, 10);
    assert_eq!(fixture.error_code("getAlbum", &[("id", " ")]).await, 10);
    assert_eq!(fixture.error_code("getAlbum", &[("id", "al-0")]).await, 70);
    assert_eq!(fixture.error_code("getSong", &[("id", "l:999")]).await, 70);
    assert_eq!(fixture.error_code("getArtist", &[("id", "ar-0")]).await, 70);
    assert_eq!(
        fixture
            .error_code("getMusicDirectory", &[("id", "x")])
            .await,
        70
    );
}

#[tokio::test]
async fn error_response_follows_the_requested_format() {
    let json_reply = Reply::from(error_response(
        "5.3.0",
        &[("f".to_owned(), "json".to_owned())],
        40,
        "Wrong username or password",
    ))
    .await;
    assert_eq!(json_reply.status, 200);
    assert_eq!(json_reply.header("content-type"), Some(JSON_TYPE));
    let response = json_reply.subsonic();
    assert_eq!(response["status"], "failed");
    assert_eq!(response["version"], "1.16.1");
    assert_eq!(response["serverVersion"], "5.3.0");
    assert_eq!(response["type"], "mornye");
    assert_eq!(response["openSubsonic"], true);
    assert_eq!(
        response["error"],
        json!({ "code": 40, "message": "Wrong username or password" })
    );
    let xml_reply = Reply::from(error_response("5.3.0", &[], 44, "Invalid API key")).await;
    assert_eq!(xml_reply.status, 200);
    assert_eq!(xml_reply.header("content-type"), Some(XML_TYPE));
    let text = xml_reply.text();
    let document = roxmltree::Document::parse(&text).expect("well-formed XML");
    let root = document.root_element();
    assert_eq!(
        root.tag_name().namespace(),
        Some(crate::subsonic::xml::NAMESPACE)
    );
    assert_eq!(root.attribute("status"), Some("failed"));
    let error = root.first_element_child().expect("error element");
    assert_eq!(error.tag_name().name(), "error");
    assert_eq!(error.attribute("code"), Some("44"));
    assert_eq!(error.attribute("message"), Some("Invalid API key"));
}

#[tokio::test]
async fn static_endpoints_describe_the_server() {
    let fixture = library();
    assert_eq!(
        fixture.ok("getLicense", &[], "license").await,
        json!({ "valid": true })
    );
    assert_eq!(
        fixture.ok("getMusicFolders", &[], "musicFolders").await,
        json!({ "musicFolder": [{ "id": 1, "name": "Music" }] })
    );
    let extensions = fixture
        .ok("getOpenSubsonicExtensions", &[], "openSubsonicExtensions")
        .await;
    assert_eq!(
        names(&extensions, "name"),
        ["apiKeyAuthentication", "formPost", "songLyrics"]
    );
    assert_eq!(extensions[0]["versions"], json!([1]));
    let user = fixture
        .ok(
            "getUser",
            &[("u", "listener"), ("username", "listener")],
            "user",
        )
        .await;
    assert_eq!(user["username"], "listener");
    assert_eq!(user["streamRole"], true);
    assert_eq!(user["downloadRole"], true);
    assert_eq!(user["adminRole"], false);
    assert_eq!(user["folder"], json!([1]));
}

#[tokio::test]
async fn artists_are_indexed_by_initial_with_others_last() {
    let fixture = library();
    let artists = fixture.ok("getArtists", &[], "artists").await;
    assert_eq!(artists["ignoredArticles"], "");
    let index = &artists["index"];
    assert_eq!(names(index, "name"), ["B", "T", "V", "Z", "#"]);
    let beyonce = &index[0]["artist"][0];
    assert_eq!(beyonce["id"], fixture.artist_id("Beyoncé"));
    assert_eq!(beyonce["name"], "Beyoncé");
    assert_eq!(beyonce["albumCount"], 1);
    assert_eq!(
        beyonce["coverArt"], beyonce["id"],
        "no cover file, but a FLAC that may embed one"
    );
    let band = &index[1]["artist"][0];
    assert_eq!(band["name"], "The Band");
    assert_eq!(band["coverArt"], band["id"]);
    assert_eq!(index[4]["artist"][0]["name"], "42 Crew");
    let indexes = fixture.ok("getIndexes", &[], "indexes").await;
    assert_eq!(indexes["lastModified"], 1_761_350_400_000_i64);
    assert_eq!(indexes["index"], artists["index"]);
}

#[tokio::test]
async fn artists_list_owned_albums_or_the_albums_they_appear_on() {
    let fixture = library();
    let band = fixture
        .ok(
            "getArtist",
            &[("id", &fixture.artist_id("The Band"))],
            "artist",
        )
        .await;
    assert_eq!(band["name"], "The Band");
    assert_eq!(ids(&band["album"]), [fixture.album_id("l:1")]);
    assert_eq!(band["album"][0]["songCount"], 3);
    let alpha = fixture
        .ok(
            "getArtist",
            &[("id", &fixture.artist_id("Alpha"))],
            "artist",
        )
        .await;
    assert_eq!(ids(&alpha["album"]), [fixture.album_id("d:20")]);
    assert_eq!(alpha["album"][0]["artist"], "Various Artists");
}

#[tokio::test]
async fn albums_carry_id3_fields_and_songs_in_disc_track_order() {
    let fixture = library();
    let blue = fixture.album_id("l:1");
    let album = fixture.ok("getAlbum", &[("id", &blue)], "album").await;
    assert_eq!(ids(&album["song"]), ["l:1", "l:2", "l:3"]);
    assert_eq!(album["id"], blue);
    assert_eq!(album["name"], "Blue Album");
    assert_eq!(album["artist"], "The Band");
    assert_eq!(album["artistId"], fixture.artist_id("The Band"));
    assert_eq!(album["coverArt"], blue);
    assert_eq!(album["songCount"], 3);
    assert_eq!(album["duration"], 600);
    assert_eq!(album["year"], 2001);
    assert_eq!(album["genre"], "Rock");
    assert_eq!(album["created"], "1970-01-01T00:00:01.000Z");
    assert_eq!(album["isCompilation"], false);
    let hits = fixture
        .ok("getAlbum", &[("id", &fixture.album_id("d:20"))], "album")
        .await;
    assert_eq!(hits["id"], crate::catalog::short_id("al-", "comp-1"));
    assert_eq!(hits["artist"], "Various Artists");
    assert_eq!(hits["isCompilation"], true);
    let loose = fixture
        .ok("getAlbum", &[("id", &fixture.album_id("l:40"))], "album")
        .await;
    assert_eq!(loose["name"], "Unknown Album");
    assert_eq!(
        loose["created"], "2025-10-25T00:00:00.000Z",
        "falls back to generatedMs"
    );
}

#[tokio::test]
async fn song_children_carry_open_subsonic_fields() {
    let fixture = library();
    let song = fixture.ok("getSong", &[("id", "l:10")], "song").await;
    let album = fixture.album_id("l:10");
    let artist = fixture.artist_id("Beyoncé");
    assert_eq!(
        song,
        json!({
            "id": "l:10",
            "parent": album,
            "isDir": false,
            "title": "Halo",
            "album": "Café Songs",
            "artist": "Beyoncé",
            "displayArtist": "Beyoncé",
            "artists": [{ "id": artist, "name": "Beyoncé" }],
            "displayAlbumArtist": "Beyoncé",
            "albumArtists": [{ "id": artist, "name": "Beyoncé" }],
            "albumId": album,
            "artistId": artist,
            "year": 2008,
            "genre": "pop",
            "genres": [{ "name": "pop" }],
            "coverArt": album,
            "size": 4,
            "contentType": "audio/flac",
            "suffix": "flac",
            "duration": 200,
            "bitRate": 900,
            "samplingRate": 44_100,
            "bitDepth": 16,
            "channelCount": 2,
            "path": "Beyoncé/Café Songs/audio.flac",
            "created": "1970-01-01T00:00:05.000Z",
            "type": "music",
            "mediaType": "song",
            "isVideo": false,
            "isrc": ["USSM10800001"],
            "replayGain": {
                "trackGain": -4.2,
                "albumGain": -3.5,
                "trackPeak": 0.9,
                "albumPeak": 1.0,
            },
            "explicitStatus": "explicit",
        })
    );
    let first = fixture.ok("getSong", &[("id", "l:1")], "song").await;
    assert_eq!(first["coverArt"], fixture.album_id("l:1"));
    assert_eq!(first["track"], 1);
    assert_eq!(first["discNumber"], 1);
    let loose = fixture.ok("getSong", &[("id", "l:40")], "song").await;
    assert_eq!(loose["album"], "Unknown Album");
    assert_eq!(loose["explicitStatus"], "");
    assert!(loose.get("replayGain").is_none());
    assert!(loose.get("isrc").is_none());
    assert_eq!(
        loose["coverArt"],
        fixture.album_id("l:40"),
        "a FLAC may embed a cover"
    );
}

#[tokio::test]
async fn music_directories_nest_artists_albums_and_songs() {
    let fixture = library();
    let artist = fixture.artist_id("The Band");
    let blue = fixture.album_id("l:1");
    let directory = fixture
        .ok("getMusicDirectory", &[("id", &artist)], "directory")
        .await;
    assert_eq!(directory["name"], "The Band");
    let child = &directory["child"][0];
    assert_eq!(child["id"], blue);
    assert_eq!(child["isDir"], true);
    assert_eq!(child["title"], "Blue Album");
    assert_eq!(child["parent"], artist);
    let album = fixture
        .ok("getMusicDirectory", &[("id", &blue)], "directory")
        .await;
    assert_eq!(album["parent"], artist);
    assert_eq!(album["name"], "Blue Album");
    assert_eq!(ids(&album["child"]), ["l:1", "l:2", "l:3"]);
    assert_eq!(album["child"][0]["isDir"], false);
}

async fn album_names(fixture: &Fixture, params: &[(&str, &str)]) -> Vec<String> {
    let list = fixture.ok("getAlbumList2", params, "albumList2").await;
    names(&list["album"], "name")
}

#[tokio::test]
async fn album_lists_sort_filter_and_page() {
    let fixture = library();
    let by_name = |offset: &'static str| {
        [
            ("type", "alphabeticalByName"),
            ("size", "2"),
            ("offset", offset),
        ]
    };
    assert_eq!(
        album_names(&fixture, &by_name("0")).await,
        ["Blue Album", "Café Songs"]
    );
    assert_eq!(
        album_names(&fixture, &by_name("2")).await,
        ["Hits", "Numbers"]
    );
    assert_eq!(
        album_names(&fixture, &by_name("4")).await,
        ["Unknown Album"]
    );
    assert!(album_names(&fixture, &by_name("9")).await.is_empty());
    assert_eq!(
        album_names(
            &fixture,
            &[("type", "alphabeticalByArtist"), ("size", "10")]
        )
        .await,
        [
            "Numbers",
            "Café Songs",
            "Blue Album",
            "Hits",
            "Unknown Album"
        ]
    );
    let newest = [
        "Café Songs",
        "Numbers",
        "Hits",
        "Blue Album",
        "Unknown Album",
    ];
    for kind in ["newest", "recent", "frequent", "highest"] {
        assert_eq!(
            album_names(&fixture, &[("type", kind), ("size", "10")]).await,
            newest
        );
    }
    assert_eq!(
        album_names(&fixture, &[("type", "newest")]).await.len(),
        5,
        "default size is 10"
    );
    assert_eq!(
        album_names(
            &fixture,
            &[("type", "byYear"), ("fromYear", "1990"), ("toYear", "2005")]
        )
        .await,
        ["Hits", "Blue Album"]
    );
    assert_eq!(
        album_names(
            &fixture,
            &[("type", "byYear"), ("fromYear", "2005"), ("toYear", "1990")]
        )
        .await,
        ["Blue Album", "Hits"]
    );
    assert_eq!(
        fixture
            .error_code("getAlbumList2", &[("type", "byYear"), ("fromYear", "1990")])
            .await,
        10
    );
    assert_eq!(
        album_names(&fixture, &[("type", "byGenre"), ("genre", "POP")]).await,
        ["Café Songs", "Hits"]
    );
    assert_eq!(
        fixture
            .error_code("getAlbumList2", &[("type", "byGenre")])
            .await,
        10
    );
    let mut random = album_names(&fixture, &[("type", "random"), ("size", "3")]).await;
    assert_eq!(random.len(), 3);
    random.sort();
    random.dedup();
    assert_eq!(random.len(), 3, "random albums are distinct");
    assert_eq!(
        album_names(&fixture, &[("type", "random"), ("size", "100")])
            .await
            .len(),
        5
    );
    assert_eq!(fixture.error_code("getAlbumList2", &[]).await, 10);
    assert_eq!(
        fixture
            .error_code("getAlbumList2", &[("type", "bogus")])
            .await,
        0
    );
    let legacy = fixture
        .ok(
            "getAlbumList",
            &[("type", "alphabeticalByName")],
            "albumList",
        )
        .await;
    let first = &legacy["album"][0];
    assert_eq!(first["isDir"], true);
    assert_eq!(first["title"], "Blue Album");
    assert_eq!(first["parent"], fixture.artist_id("The Band"));
}

#[tokio::test]
async fn random_songs_honor_genre_and_years() {
    let fixture = library();
    let songs = fixture
        .ok("getRandomSongs", &[("size", "3")], "randomSongs")
        .await;
    let mut picked = ids(&songs["song"]);
    assert_eq!(picked.len(), 3);
    picked.sort();
    picked.dedup();
    assert_eq!(picked.len(), 3);
    let rock = fixture
        .ok(
            "getRandomSongs",
            &[("size", "50"), ("genre", "rock")],
            "randomSongs",
        )
        .await;
    let mut rock = ids(&rock["song"]);
    rock.sort();
    assert_eq!(rock, ["l:1", "l:2", "l:3"]);
    let recent = fixture
        .ok(
            "getRandomSongs",
            &[("size", "50"), ("fromYear", "2000")],
            "randomSongs",
        )
        .await;
    let mut recent = ids(&recent["song"]);
    recent.sort();
    assert_eq!(recent, ["l:1", "l:10", "l:2"]);
}

#[tokio::test]
async fn genres_count_songs_and_albums() {
    let fixture = library();
    let genres = fixture.ok("getGenres", &[], "genres").await;
    assert_eq!(
        genres,
        json!({ "genre": [
            { "value": "pop", "songCount": 3, "albumCount": 2 },
            { "value": "Rock", "songCount": 3, "albumCount": 1 },
        ] })
    );
    let page = fixture
        .ok(
            "getSongsByGenre",
            &[("genre", "POP"), ("count", "2"), ("offset", "1")],
            "songsByGenre",
        )
        .await;
    assert_eq!(ids(&page["song"]), ["d:20", "d:21"]);
    let unknown = fixture
        .ok("getSongsByGenre", &[("genre", "Polka")], "songsByGenre")
        .await;
    assert_eq!(unknown, json!({ "song": [] }));
    assert_eq!(fixture.error_code("getSongsByGenre", &[]).await, 10);
}

#[tokio::test]
async fn search_folds_pages_and_lists_everything_for_empty_queries() {
    let fixture = library();
    let result = fixture
        .ok("search3", &[("query", "BEYONCE")], "searchResult3")
        .await;
    assert_eq!(ids(&result["artist"]), [fixture.artist_id("Beyoncé")]);
    assert_eq!(ids(&result["album"]), [fixture.album_id("l:10")]);
    assert_eq!(ids(&result["song"]), ["l:10"]);
    let band = fixture
        .ok("search3", &[("query", "band")], "searchResult3")
        .await;
    assert_eq!(ids(&band["song"]), ["l:2", "l:1", "l:3"], "export order");
    let various = fixture
        .ok("search3", &[("query", "various")], "searchResult3")
        .await;
    assert_eq!(ids(&various["album"]), [fixture.album_id("d:20")]);
    let page = fixture
        .ok(
            "search3",
            &[
                ("query", ""),
                ("songCount", "3"),
                ("songOffset", "2"),
                ("artistCount", "0"),
            ],
            "searchResult3",
        )
        .await;
    assert_eq!(ids(&page["song"]), ["l:3", "l:10", "d:20"]);
    assert_eq!(page["artist"], json!([]));
    let everything = fixture
        .ok("search3", &[("query", "\"\"")], "searchResult3")
        .await;
    assert_eq!(ids(&everything["song"]).len(), 8);
    assert_eq!(ids(&everything["album"]).len(), 5);
    assert_eq!(ids(&everything["artist"]).len(), 5);
    let no_query = fixture.ok("search3", &[], "searchResult3").await;
    assert_eq!(no_query, everything);
    let legacy = fixture
        .ok("search2", &[("query", "band")], "searchResult2")
        .await;
    assert_eq!(legacy["album"][0]["isDir"], true);
    assert_eq!(legacy["album"][0]["title"], "Blue Album");
    assert_eq!(ids(&legacy["song"]).len(), 3);
}

#[tokio::test]
async fn page_sizes_are_capped_at_five_hundred() {
    let fixture = Fixture::new(|_| {
        (0..600)
            .map(|index| {
                json!({
                    "id": format!("l:{index}"),
                    "title": format!("Song {index:03}"),
                    "artist": "Artist",
                    "album": format!("Album {index:03}"),
                    "path": format!("/music/{index}.flac"),
                })
            })
            .collect()
    });
    let all = fixture
        .ok(
            "search3",
            &[("query", ""), ("songCount", "1000"), ("albumCount", "-5")],
            "searchResult3",
        )
        .await;
    assert_eq!(ids(&all["song"]).len(), 500);
    assert_eq!(all["album"], json!([]));
    let tail = fixture
        .ok(
            "search3",
            &[("query", ""), ("songCount", "500"), ("songOffset", "550")],
            "searchResult3",
        )
        .await;
    assert_eq!(ids(&tail["song"]).len(), 50);
    assert_eq!(tail["song"][0]["id"], "l:550");
    let albums = album_names(&fixture, &[("type", "alphabeticalByName"), ("size", "900")]).await;
    assert_eq!(albums.len(), 500);
    assert_eq!(albums[0], "Album 000");
}
