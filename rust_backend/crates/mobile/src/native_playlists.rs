//! The existing playlist import contract, executed on the native data worker.
//! CSV remains line-based for compatibility with existing exports/imports.
use crate::native_library::path_keys::dart_trim as trim;
use mornye_core::fs::write_atomic;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::{self, BufWriter, Write},
    path::Path,
};

pub(crate) fn execute(
    request: &Value,
    bytes: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    check()?;
    match request["operation"].as_str().unwrap_or_default() {
        "parse_playlist" => {
            let content =
                std::str::from_utf8(bytes.unwrap_or_default()).map_err(|e| e.to_string())?;
            let seed = request["id_seed"]
                .as_i64()
                .ok_or("Missing playlist ID seed")?;
            let tracks = if request["format"] == "csv" {
                parse_csv(content, seed, check)?
            } else {
                parse_m3u(content, seed, check)?
            };
            Ok(json!({"tracks": tracks}))
        }
        "build_m3u" => {
            let entries = request["entries"]
                .as_array()
                .ok_or("Missing playlist entries")?;
            let path = request["output_path"]
                .as_str()
                .ok_or("Missing playlist output path")?;
            let parent = Path::new(path)
                .parent()
                .filter(|parent| !parent.as_os_str().is_empty())
                .unwrap_or(Path::new("."));
            // No leading dot: some file systems keep a dot name's hidden
            // attribute through the rename onto the playlist.
            write_atomic(
                parent,
                Path::new(path),
                "mornye-m3u-",
                |staging| {
                    let mut file = BufWriter::with_capacity(64 * 1024, staging);
                    file.write_all(b"#EXTM3U\n")?;
                    for entry in entries {
                        check().map_err(io::Error::other)?;
                        let duration = entry["duration"].as_i64().filter(|n| *n > 0).unwrap_or(-1);
                        let artist = trim(entry["artist"].as_str().unwrap_or_default());
                        let title = entry["name"].as_str().unwrap_or_default();
                        let display = if artist.is_empty() {
                            title.to_owned()
                        } else {
                            format!("{artist} - {title}")
                        };
                        let source = entry["path"]
                            .as_str()
                            .ok_or_else(|| io::Error::other("Missing M3U entry path"))?;
                        writeln!(file, "#EXTINF:{duration},{display}\n{source}")?;
                    }
                    file.flush()
                },
                || check().map_err(io::Error::other),
                false,
            )
            .map_err(|e| e.to_string())?;
            Ok(json!({"output_path": path, "committed": true}))
        }
        _ => Err("Unknown playlist operation".into()),
    }
}

fn lines(content: &str) -> Vec<&str> {
    let mut result = Vec::new();
    let mut start = 0;
    let bytes = content.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if matches!(bytes[index], b'\r' | b'\n') {
            result.push(&content[start..index]);
            if bytes[index] == b'\r' && bytes.get(index + 1) == Some(&b'\n') {
                index += 1;
            }
            start = index + 1;
        }
        index += 1;
    }
    result.push(&content[start..]);
    result
}

fn track(
    id: String,
    title: &str,
    artist: &str,
    album: &str,
    duration: i64,
    isrc: Option<&str>,
) -> Value {
    json!({"id": id, "name": title, "artistName": artist, "albumName": album,
        "duration": duration, "coverUrl": null, "isrc": isrc})
}

fn parse_csv(
    content: &str,
    seed: i64,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Vec<Value>, String> {
    let lines = lines(content);
    let Some(start) = lines.iter().position(|line| !trim(line).is_empty()) else {
        return Ok(Vec::new());
    };
    let columns: HashMap<_, _> = parse_line(lines[start])
        .iter()
        .enumerate()
        .map(|(i, value)| (clean(value).to_lowercase(), i))
        .collect();
    let mut tracks = Vec::new();
    for (index, line) in lines.iter().enumerate().skip(start + 1) {
        check()?;
        if trim(line).is_empty() {
            continue;
        }
        let values = parse_line(trim(line));
        let get = |keys: &[&str]| -> Option<String> {
            keys.iter().find_map(|key| {
                columns
                    .get(*key)
                    .and_then(|i| values.get(*i))
                    .map(|value| clean(value))
            })
        };
        let name = get(&["track name", "track", "name", "title"]);
        let artist = get(&["artist name(s)", "artist name", "artist", "artists"]);
        let album = get(&["album name", "album"]);
        let isrc = get(&["isrc"]);
        let id = get(&[
            "track uri",
            "spotify - id",
            "spotify id",
            "spotify_id",
            "id",
            "uri",
        ])
        .map(|value| {
            if value.starts_with("spotify:track:") {
                value.replace("spotify:track:", "")
            } else {
                value
            }
        });
        if (name.as_deref().is_some_and(|name| !name.is_empty()) && artist.is_some())
            || id.as_deref().is_some_and(|id| !id.is_empty())
        {
            tracks.push(track(
                id.unwrap_or_else(|| format!("csv_{seed}_{index}")),
                name.as_deref().unwrap_or("Unknown Track"),
                artist.as_deref().unwrap_or("Unknown Artist"),
                album.as_deref().unwrap_or("Unknown Album"),
                0,
                isrc.as_deref(),
            ));
        }
    }
    Ok(tracks)
}

fn clean(value: &str) -> String {
    let value = trim(value);
    let value = if value.len() >= 2 && value.starts_with('"') && value.ends_with('"') {
        &value[1..value.len() - 1]
    } else {
        value
    };
    value.replace("\"\"", "\"")
}

fn parse_line(line: &str) -> Vec<String> {
    let mut fields = Vec::new();
    let mut buffer = String::new();
    let mut quoted = false;
    let mut chars = line.chars().peekable();
    while let Some(character) = chars.next() {
        match character {
            '"' if quoted && chars.peek() == Some(&'"') => {
                buffer.push('"');
                chars.next();
            }
            '"' => quoted = !quoted,
            ',' if !quoted => {
                fields.push(std::mem::take(&mut buffer));
            }
            _ => buffer.push(character),
        }
    }
    fields.push(buffer);
    fields
}

fn parse_m3u(
    content: &str,
    seed: i64,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Vec<Value>, String> {
    let mut tracks = Vec::new();
    let mut duration = None;
    let mut display = None;
    for raw in lines(content) {
        check()?;
        let line = trim(raw);
        if line.is_empty() {
            continue;
        }
        if let Some(body) = line.strip_prefix("#EXTINF:") {
            if let Some((raw_duration, text)) = body.split_once(',') {
                let parsed = raw_duration
                    .split(' ')
                    .next()
                    .and_then(|value| value.parse::<f64>().ok());
                if parsed.is_some_and(|value| !value.is_finite()) {
                    return Err("Non-finite M3U duration".into());
                }
                duration = parsed.map(|value| value.round() as i64);
                display = Some(trim(text).to_owned());
            }
            continue;
        }
        if line.starts_with('#') {
            continue;
        }
        let text = display
            .take()
            .filter(|text| !text.is_empty())
            .unwrap_or_else(|| basename_stem(line));
        let (artist, title) = text
            .find(" - ")
            .filter(|index| *index > 0)
            .map_or(("", text.as_str()), |index| {
                (trim(&text[..index]), trim(&text[index + 3..]))
            });
        if !title.is_empty() {
            tracks.push(track(
                format!("m3u_{seed}_{}", tracks.len()),
                title,
                if artist.is_empty() {
                    "Unknown Artist"
                } else {
                    artist
                },
                "Unknown Album",
                duration.unwrap_or(0).max(0),
                None,
            ));
        }
        duration = None;
    }
    Ok(tracks)
}

fn basename_stem(path: &str) -> String {
    // The app uses path's POSIX context on Android and iOS. A leading dot is
    // part of a filename, rather than an extension.
    let filename = path
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or_default();
    let stem = filename
        .rfind('.')
        .filter(|index| *index > 0)
        .map_or(filename, |index| &filename[..index]);
    trim(stem).to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn shared_dart_playlist_fixtures_match_native_output() {
        let cases: Value = serde_json::from_str(include_str!(
            "../../../../test/fixtures/native_metadata_parsers.json"
        ))
        .unwrap();
        for case in cases["playlists"].as_array().unwrap() {
            let mut request = case.clone();
            request["operation"] = "parse_playlist".into();
            let result = execute(
                &request,
                Some(case["body"].as_str().unwrap().as_bytes()),
                &|| Ok(()),
            )
            .unwrap();
            assert_eq!(result["tracks"], case["tracks"]);
        }
    }

    #[test]
    fn csv_preserves_aliases_quotes_ids_empty_values_and_line_indices() {
        let tracks = parse_csv(
            "\r\nTrack Name,Artist Name(s),Album Name,Track URI,ISRC\r\n\"Song, \"\"One\"\"\",Artist,Album,spotify:track:abc,AAABC1200001\r\nSecond,,Album,,\r\n",
            10,
            &|| Ok(()),
        ).unwrap();
        assert_eq!(tracks.len(), 2);
        assert_eq!(tracks[0]["id"], "abc");
        assert_eq!(tracks[0]["name"], "Song, \"One\"");
        assert_eq!(tracks[1]["id"], "");
        assert_eq!(tracks[1]["artistName"], "");
        let without_id = parse_csv("title,artist\nA,B\n\nC,D", 42, &|| Ok(())).unwrap();
        assert_eq!(without_id[0]["id"], "csv_42_1");
        assert_eq!(without_id[1]["id"], "csv_42_3");
    }

    #[test]
    fn m3u_retains_extinf_pending_state_and_posix_fallback() {
        let tracks = parse_m3u("#EXTM3U\r#EXTINF:180.5,Artist - Song - Mix\r#comment\r\nfolder/a.flac\nMusic/02 Demo.flac\n#EXTINF:-1,\nx/.hidden", 100, &|| Ok(())).unwrap();
        assert_eq!(tracks.len(), 3);
        assert_eq!(tracks[0]["name"], "Song - Mix");
        assert_eq!(tracks[0]["duration"], 181);
        assert_eq!(tracks[1]["name"], "02 Demo");
        assert_eq!(tracks[2]["name"], ".hidden");
        assert_eq!(tracks[2]["duration"], 0);
    }

    #[test]
    fn m3u_export_streams_exact_lines_to_file() {
        let path = std::env::temp_dir().join(format!("native-m3u-{}.m3u8", std::process::id()));
        let request = json!({"operation":"build_m3u", "output_path":path, "entries":[
            {"name":"Song", "artist":" Artist ", "duration":10, "path":"folder/song.flac"},
            {"name":"Unknown", "artist":"", "duration":0, "path":"x.flac"}]});
        execute(&request, None, &|| Ok(())).unwrap();
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "#EXTM3U\n#EXTINF:10,Artist - Song\nfolder/song.flac\n#EXTINF:-1,Unknown\nx.flac\n"
        );
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn cancelled_export_keeps_existing_file_and_removes_unique_staging() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("existing.m3u8");
        fs::write(&path, "original").unwrap();
        let request = json!({"operation":"build_m3u", "output_path":path, "entries":[{"name":"Song", "artist":"Artist", "duration":1, "path":"song.flac"}]});
        let calls = std::cell::Cell::new(0);
        let check = || {
            let count = calls.get() + 1;
            calls.set(count);
            if count == 3 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        };
        assert_eq!(execute(&request, None, &check).unwrap_err(), "cancelled");
        assert_eq!(fs::read_to_string(&path).unwrap(), "original");
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 1);
    }

    #[test]
    fn concurrent_exports_do_not_share_staging_files() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("same.m3u8");
        let workers = (0..8).map(|index| {
            let path = path.clone();
            std::thread::spawn(move || execute(&json!({"operation":"build_m3u", "output_path":path, "entries":[{"name":format!("Song{index}"), "artist":"", "duration":1, "path":format!("{index}.flac")}]}), None, &|| Ok(())))
        }).collect::<Vec<_>>();
        for worker in workers {
            assert_eq!(worker.join().unwrap().unwrap()["committed"], true);
        }
        let content = fs::read_to_string(&path).unwrap();
        assert!(content.starts_with("#EXTM3U\n#EXTINF:1,Song"));
        assert_eq!(content.lines().count(), 3);
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 1);
    }
}
