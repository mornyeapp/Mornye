use super::*;

fn song_info(fixture: &Fixture, id: &str) -> Value {
    let catalog = fixture.catalog();
    let song = catalog.song(id).expect("song");
    json!({
        "id": id,
        "title": song.title,
        "artist": song.artist,
        "album": song.album_name,
        "albumArtist": song.album_artist,
        "durationMs": song.duration_ms,
        "isrc": song.isrc,
        "matchKey": song.match_key,
        "path": song.path.to_string_lossy(),
    })
}

fn sample_playlist() -> Value {
    json!({
        "id": "p1",
        "name": "Road trip",
        "comment": "loud",
        "songIds": ["l:3", "gone", "l:2"],
        "createdMs": 1_000,
        "changedMs": 61_000,
    })
}

#[tokio::test]
async fn get_playlists_expands_counts_duration_cover_and_owner() {
    let fixture = library();
    fixture.host.reply(
        "subsonic/getPlaylists",
        Ok(json!({ "playlists": [sample_playlist(), { "name": "no id" }, { "id": 7, "songIds": [] }] })),
    );
    let playlists = fixture.ok("getPlaylists", &[], "playlists").await;
    assert_eq!(fixture.host.single("subsonic/getPlaylists"), json!({}));
    assert_eq!(
        playlists["playlist"],
        json!([
            {
                "id": "p1",
                "name": "Road trip",
                "comment": "loud",
                "owner": "mornye",
                "public": false,
                "songCount": 2,
                "duration": 400,
                "created": "1970-01-01T00:00:01.000Z",
                "changed": "1970-01-01T00:01:01.000Z",
                "coverArt": fixture.album_id("l:3"),
            },
            {
                "id": "7",
                "name": "",
                "owner": "mornye",
                "public": false,
                "songCount": 0,
                "duration": 0,
                "created": "1970-01-01T00:00:00.000Z",
                "changed": "1970-01-01T00:00:00.000Z",
            },
        ])
    );
}

#[tokio::test]
async fn get_playlist_includes_known_entries_in_order() {
    let fixture = library();
    fixture.host.reply(
        "subsonic/getPlaylist",
        Ok(json!({ "playlist": sample_playlist() })),
    );
    let playlist = fixture.ok("getPlaylist", &[("id", "p1")], "playlist").await;
    assert_eq!(
        fixture.host.single("subsonic/getPlaylist"),
        json!({ "id": "p1" })
    );
    assert_eq!(ids(&playlist["entry"]), ["l:3", "l:2"]);
    assert_eq!(playlist["entry"][0]["title"], "Bonus");
    assert_eq!(fixture.error_code("getPlaylist", &[]).await, 10);
    fixture.host.reply("subsonic/getPlaylist", Ok(json!({})));
    assert_eq!(fixture.error_code("getPlaylist", &[("id", "p1")]).await, 0);
}

#[tokio::test]
async fn create_playlist_forwards_song_infos_and_returns_the_playlist() {
    let fixture = library();
    fixture.host.reply(
        "subsonic/createPlaylist",
        Ok(json!({ "playlist": { "id": "p9", "name": "New", "songIds": ["l:10"] } })),
    );
    let playlist = fixture
        .ok(
            "createPlaylist",
            &[("name", "New"), ("songId", "l:10"), ("songId", "nope")],
            "playlist",
        )
        .await;
    assert_eq!(
        fixture.host.single("subsonic/createPlaylist"),
        json!({ "name": "New", "songs": [song_info(&fixture, "l:10")] })
    );
    assert_eq!(playlist["id"], "p9");
    assert_eq!(ids(&playlist["entry"]), ["l:10"]);
    assert_eq!(
        fixture
            .error_code("createPlaylist", &[("songId", "l:10")])
            .await,
        10
    );
    let replace = library();
    replace.host.reply(
        "subsonic/createPlaylist",
        Ok(json!({ "playlist": { "id": "p9", "songIds": [] } })),
    );
    replace
        .ok("createPlaylist", &[("playlistId", "p9")], "playlist")
        .await;
    assert_eq!(
        replace.host.single("subsonic/createPlaylist"),
        json!({ "playlistId": "p9", "songs": [] })
    );
}

#[tokio::test]
async fn update_and_delete_playlist_forward_their_arguments() {
    let fixture = library();
    let response = fixture
        .json(
            "updatePlaylist",
            &[
                ("playlistId", "p1"),
                ("name", "Renamed"),
                ("comment", "c"),
                ("songIdToAdd", "l:1"),
                ("songIdToAdd", "unknown"),
                ("songIndexToRemove", "0"),
                ("songIndexToRemove", "x"),
                ("songIndexToRemove", "4"),
            ],
        )
        .await;
    assert_eq!(response["status"], "ok");
    assert_eq!(
        fixture.host.single("subsonic/updatePlaylist"),
        json!({
            "playlistId": "p1",
            "name": "Renamed",
            "comment": "c",
            "songsToAdd": [song_info(&fixture, "l:1")],
            "songIndexesToRemove": [0, 4],
        })
    );
    assert_eq!(
        fixture.error_code("updatePlaylist", &[("name", "x")]).await,
        10
    );
    let delete = library();
    assert_eq!(
        delete.json("deletePlaylist", &[("id", "p1")]).await["status"],
        "ok"
    );
    assert_eq!(
        delete.host.single("subsonic/deletePlaylist"),
        json!({ "id": "p1" })
    );
    assert_eq!(delete.error_code("deletePlaylist", &[]).await, 10);
}

#[tokio::test]
async fn star_and_unstar_classify_and_expand_ids() {
    let fixture = library();
    let album = fixture.album_id("l:1");
    let artist = fixture.artist_id("Beyoncé");
    let response = fixture
        .json(
            "star",
            &[
                ("id", "l:10"),
                ("id", &album),
                ("id", &artist),
                ("id", "missing"),
                ("albumId", &fixture.album_id("d:20")),
                ("artistId", &fixture.artist_id("The Band")),
            ],
        )
        .await;
    assert_eq!(response["status"], "ok");
    assert_eq!(
        fixture.host.single("subsonic/star"),
        json!({
            "songs": [song_info(&fixture, "l:10")],
            "albums": [
                { "id": album, "name": "Blue Album", "artist": "The Band" },
                { "id": fixture.album_id("d:20"), "name": "Hits", "artist": "Various Artists" },
            ],
            "artists": [
                { "id": artist, "name": "Beyoncé" },
                { "id": fixture.artist_id("The Band"), "name": "The Band" },
            ],
        })
    );
    let unstar = library();
    assert_eq!(
        unstar.json("unstar", &[("id", "l:1")]).await["status"],
        "ok"
    );
    assert_eq!(unstar.host.requests()[0].0, "subsonic/unstar");
    assert_eq!(unstar.error_code("star", &[]).await, 10);
    assert_eq!(unstar.error_code("star", &[("id", "missing")]).await, 70);
    assert_eq!(
        unstar.host.requests().len(),
        1,
        "invalid calls are not forwarded"
    );
}

#[tokio::test]
async fn starred_lists_expand_ids_and_drop_unknown_ones() {
    let fixture = library();
    let album = fixture.album_id("d:20");
    let artist = fixture.artist_id("Zed");
    fixture.host.reply(
        "subsonic/getStarred",
        Ok(json!({
            "songIds": ["l:2", "gone"],
            "albumIds": [album, "al-0000000000000000"],
            "artistIds": [artist],
        })),
    );
    let starred = fixture.ok("getStarred2", &[], "starred2").await;
    assert_eq!(ids(&starred["song"]), ["l:2"]);
    assert_eq!(ids(&starred["album"]), [album.as_str()]);
    assert_eq!(starred["album"][0]["name"], "Hits");
    assert!(starred["album"][0].get("isDir").is_none(), "ID3 albums");
    assert_eq!(ids(&starred["artist"]), [artist]);
    let legacy = fixture.ok("getStarred", &[], "starred").await;
    assert_eq!(legacy["album"][0]["isDir"], true);
    let list = fixture
        .ok("getAlbumList2", &[("type", "starred")], "albumList2")
        .await;
    assert_eq!(ids(&list["album"]), [album]);
    let requests = fixture.host.requests();
    assert_eq!(requests.len(), 3);
    assert!(
        requests
            .iter()
            .all(|(op, _, _)| op == "subsonic/getStarred")
    );
}

#[tokio::test]
async fn starred_artists_may_be_named_instead_of_identified() {
    let fixture = library();
    let artist = fixture.artist_id("Zed");
    fixture.host.reply(
        "subsonic/getStarred",
        Ok(json!({
            "songIds": [],
            "artistIds": [artist],
            "artistNames": ["  ZED ", "Nobody Here"],
        })),
    );
    let starred = fixture.ok("getStarred2", &[], "starred2").await;
    assert_eq!(ids(&starred["artist"]), [artist]);
}

#[tokio::test]
async fn scrobble_aligns_times_with_known_songs() {
    let fixture = library();
    let response = fixture
        .json(
            "scrobble",
            &[
                ("id", "gone"),
                ("id", "l:1"),
                ("id", "l:2"),
                ("time", "111"),
                ("time", "222"),
                ("submission", "false"),
            ],
        )
        .await;
    assert_eq!(response["status"], "ok");
    let args = fixture.host.single("subsonic/scrobble");
    assert_eq!(
        args["songs"],
        json!([song_info(&fixture, "l:1"), song_info(&fixture, "l:2")])
    );
    assert_eq!(args["timesMs"][0], 222);
    assert!(args["timesMs"][1].as_i64().expect("now") > 1_700_000_000_000);
    assert_eq!(args["submission"], false);
    let defaults = library();
    defaults.json("scrobble", &[("id", "l:1")]).await;
    assert_eq!(
        defaults.host.single("subsonic/scrobble")["submission"],
        true
    );
    assert_eq!(defaults.error_code("scrobble", &[]).await, 10);
    assert_eq!(defaults.error_code("scrobble", &[("id", "gone")]).await, 70);
}

#[tokio::test]
async fn play_queue_round_trips_through_the_app() {
    let fixture = library();
    fixture.host.reply(
        "subsonic/getPlayQueue",
        Ok(json!({
            "songIds": ["l:1", "gone", "l:10"],
            "currentId": "l:10",
            "positionMs": 42_000,
            "changedMs": 61_000,
            "changedBy": "Desk",
        })),
    );
    let queue = fixture.ok("getPlayQueue", &[], "playQueue").await;
    assert_eq!(ids(&queue["entry"]), ["l:1", "l:10"]);
    assert_eq!(queue["current"], "l:10");
    assert_eq!(queue["position"], 42_000);
    assert_eq!(queue["username"], "mornye");
    assert_eq!(queue["changed"], "1970-01-01T00:01:01.000Z");
    assert_eq!(queue["changedBy"], "Desk");
    fixture
        .host
        .reply("subsonic/getPlayQueue", Ok(json!({ "songIds": [] })));
    let empty = fixture.json("getPlayQueue", &[]).await;
    assert_eq!(empty["status"], "ok");
    assert!(empty.get("playQueue").is_none());
    let save = library();
    let response = save
        .json(
            "savePlayQueue",
            &[
                ("id", "l:2"),
                ("id", "gone"),
                ("current", "l:2"),
                ("position", "5000"),
            ],
        )
        .await;
    assert_eq!(response["status"], "ok");
    assert_eq!(
        save.host.single("subsonic/savePlayQueue"),
        json!({ "songs": [song_info(&save, "l:2")], "currentId": "l:2", "positionMs": 5000 })
    );
    let clear = library();
    clear.json("savePlayQueue", &[]).await;
    assert_eq!(
        clear.host.single("subsonic/savePlayQueue"),
        json!({ "songs": [], "positionMs": 0 })
    );
}

#[tokio::test]
async fn host_errors_map_to_subsonic_codes() {
    let fixture = library();
    for (code, expected) in [
        ("not_found", 70),
        ("invalid", 10),
        ("timeout", 0),
        ("unavailable", 0),
    ] {
        fixture.host.reply(
            "subsonic/getPlaylists",
            Err(HostError::new(code, format!("{code} happened"))),
        );
        let response = fixture.json("getPlaylists", &[]).await;
        assert_eq!(response["status"], "failed");
        assert_eq!(response["error"]["code"], expected, "{code}");
        assert_eq!(response["error"]["message"], format!("{code} happened"));
    }
    fixture
        .host
        .reply("subsonic/getPlaylists", Err(HostError::new("timeout", "")));
    let response = fixture.json("getPlaylists", &[]).await;
    assert_eq!(response["error"]["message"], "timeout");
}
