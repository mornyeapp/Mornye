//! Re-enrichment input, candidate policy and preview metadata. No file access.

use crate::json::lenient_deserialize;
use crate::matching::lowercase;
use crate::resolver::{artists_match, titles_match, track_identity_title, track_titles_match};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[derive(Clone, Default, Serialize)]
pub struct Request {
    pub file_path: String,
    pub cover_url: String,
    pub header_video: String,
    pub cover_max_dimension: isize,
    pub embed_lyrics: bool,
    pub lyrics_mode: String,
    pub artist_tag_mode: String,
    pub spotify_id: String,
    pub track_name: String,
    pub artist_name: String,
    pub album_name: String,
    pub album_artist: String,
    pub track_number: isize,
    pub disc_number: isize,
    pub total_tracks: isize,
    pub total_discs: isize,
    pub release_date: String,
    pub isrc: String,
    pub genre: String,
    pub label: String,
    pub copyright: String,
    pub composer: String,
    pub duration_ms: i64,
    pub search_online: bool,
    pub update_fields: Option<Vec<Option<String>>>,
    pub preview_only: bool,
    pub replace_release_metadata: bool,
}
lenient_deserialize!(Request {
    "file_path" => file_path, "cover_url" => cover_url, "header_video" => header_video,
    "cover_max_dimension" => cover_max_dimension, "embed_lyrics" => embed_lyrics,
    "lyrics_mode" => lyrics_mode, "artist_tag_mode" => artist_tag_mode,
    "spotify_id" => spotify_id, "track_name" => track_name, "artist_name" => artist_name,
    "album_name" => album_name, "album_artist" => album_artist,
    "track_number" => track_number, "disc_number" => disc_number,
    "total_tracks" => total_tracks, "total_discs" => total_discs,
    "release_date" => release_date, "isrc" => isrc, "genre" => genre,
    "label" => label, "copyright" => copyright, "composer" => composer,
    "duration_ms" => duration_ms, "search_online" => search_online,
    "update_fields" => update_fields, "preview_only" => preview_only,
    "replace_release_metadata" => replace_release_metadata,
});

pub fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or_default()
}

fn number(value: &Value, key: &str) -> i64 {
    value[key].as_i64().unwrap_or_default()
}

pub fn placeholder(value: &str) -> bool {
    matches!(
        lowercase(value.trim()).as_str(),
        "" | "unknown" | "unknown artist" | "unknown title" | "unknown album"
    )
}

impl Request {
    pub fn parse(raw: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(&crate::text::json_surrogates(raw))
    }

    pub fn selected(&self, group: &str, tag: &str) -> bool {
        selected(&self.update_fields, group, tag)
    }

    pub fn any_selected(&self, group: &str, tags: &[&str]) -> bool {
        tags.iter().any(|tag| self.selected(group, tag))
    }

    /// Canonical keys shared by native FLAC enrichment and the FFmpeg plan.
    /// Empty values preserve existing tags, unlike an explicit editor clear.
    pub fn write_metadata(&self, lyrics: &str) -> BTreeMap<String, String> {
        let mut fields = BTreeMap::new();
        for (group, tag, key, value) in [
            ("basic_tags", "track_name", "TITLE", &self.track_name),
            ("basic_tags", "artist_name", "ARTIST", &self.artist_name),
            ("basic_tags", "album_name", "ALBUM", &self.album_name),
            (
                "basic_tags",
                "album_artist",
                "ALBUMARTIST",
                &self.album_artist,
            ),
            ("release_info", "release_date", "DATE", &self.release_date),
            ("release_info", "isrc", "ISRC", &self.isrc),
            ("extra", "genre", "GENRE", &self.genre),
            ("extra", "label", "ORGANIZATION", &self.label),
            ("extra", "copyright", "COPYRIGHT", &self.copyright),
            ("extra", "composer", "COMPOSER", &self.composer),
        ] {
            if self.selected(group, tag) && !value.is_empty() {
                fields.insert(key.into(), value.clone());
            }
        }
        for (tag, total_tag, key, number, total) in [
            (
                "track_number",
                "total_tracks",
                "TRACKNUMBER",
                self.track_number,
                self.total_tracks,
            ),
            (
                "disc_number",
                "total_discs",
                "DISCNUMBER",
                self.disc_number,
                self.total_discs,
            ),
        ] {
            if self.any_selected("track_info", &[tag, total_tag]) && number > 0 {
                fields.insert(
                    key.into(),
                    if total > 0 {
                        format!("{number}/{total}")
                    } else {
                        number.to_string()
                    },
                );
            }
        }
        if self.selected("lyrics", "lyrics")
            && !self.lyrics_mode.trim().eq_ignore_ascii_case("external")
            && !lyrics.is_empty()
        {
            fields.insert("LYRICS".into(), lyrics.into());
            fields.insert("UNSYNCEDLYRICS".into(), lyrics.into());
        }
        fields
    }

    pub fn write_external_lrc(&self, lyrics: &str) -> bool {
        self.embed_lyrics
            && self.selected("lyrics", "lyrics")
            && !lyrics.trim().is_empty()
            && matches!(
                self.lyrics_mode.trim().to_ascii_lowercase().as_str(),
                "external" | "both"
            )
    }

    pub fn query(&self) -> String {
        let mut parts: Vec<_> = [&self.track_name, &self.artist_name]
            .into_iter()
            .filter(|value| !placeholder(value))
            .map(|value| value.trim())
            .collect();
        if parts.is_empty() && !placeholder(&self.album_name) {
            parts.push(self.album_name.trim());
        }
        parts.join(" ").trim().into()
    }

    pub fn same_release(&self, track: &Value) -> bool {
        self.replace_release_metadata
            || placeholder(&self.album_name)
            || text(track, "album_name").trim().is_empty()
            || titles_match(&self.album_name, text(track, "album_name"))
    }

    pub fn apply(&mut self, track: &Value) {
        let same_release = self.same_release(track);
        for (key, prefix) in [
            ("spotify_id", ""),
            ("deezer_id", "deezer:"),
            ("qobuz_id", "qobuz:"),
            ("tidal_id", "tidal:"),
            ("id", ""),
        ] {
            if !text(track, key).is_empty() {
                self.spotify_id = format!("{prefix}{}", text(track, key));
                break;
            }
        }
        let selected = |group, tag| selected(&self.update_fields, group, tag);
        for (group, tag, source, target, release_only) in [
            (
                "basic_tags",
                "track_name",
                "name",
                &mut self.track_name,
                false,
            ),
            (
                "basic_tags",
                "artist_name",
                "artists",
                &mut self.artist_name,
                false,
            ),
            (
                "basic_tags",
                "album_name",
                "album_name",
                &mut self.album_name,
                true,
            ),
            (
                "basic_tags",
                "album_artist",
                "album_artist",
                &mut self.album_artist,
                true,
            ),
            (
                "release_info",
                "release_date",
                "release_date",
                &mut self.release_date,
                true,
            ),
            ("release_info", "isrc", "isrc", &mut self.isrc, false),
            ("extra", "genre", "genre", &mut self.genre, false),
            ("extra", "label", "label", &mut self.label, false),
            (
                "extra",
                "copyright",
                "copyright",
                &mut self.copyright,
                false,
            ),
            ("extra", "composer", "composer", &mut self.composer, false),
        ] {
            let value = text(track, source);
            if (!release_only || same_release) && selected(group, tag) && !value.is_empty() {
                *target = value.into();
            }
        }
        for (tag, target) in [
            ("track_number", &mut self.track_number),
            ("total_tracks", &mut self.total_tracks),
            ("disc_number", &mut self.disc_number),
            ("total_discs", &mut self.total_discs),
        ] {
            let value = number(track, tag);
            if same_release && selected("track_info", tag) && value > 0 {
                *target = value as isize;
            }
        }
        if same_release && selected("cover", "cover") {
            if let Some(cover) = [text(track, "cover_url"), text(track, "images")]
                .into_iter()
                .find(|value| !value.is_empty())
            {
                self.cover_url = cover.into();
            }
            self.header_video = text(track, "header_video").trim().into();
        }
        if number(track, "duration_ms") > 0 {
            self.duration_ms = number(track, "duration_ms");
        }
    }

    pub fn result_metadata(&self) -> Value {
        let mut result = json!({"spotify_id":self.spotify_id,"duration_ms":self.duration_ms});
        for (group, tag, key, value) in [
            (
                "basic_tags",
                "track_name",
                "track_name",
                json!(self.track_name),
            ),
            (
                "basic_tags",
                "artist_name",
                "artist_name",
                json!(self.artist_name),
            ),
            (
                "basic_tags",
                "album_name",
                "album_name",
                json!(self.album_name),
            ),
            (
                "basic_tags",
                "album_artist",
                "album_artist",
                json!(self.album_artist),
            ),
            (
                "track_info",
                "track_number",
                "track_number",
                json!(self.track_number),
            ),
            (
                "track_info",
                "total_tracks",
                "total_tracks",
                json!(self.total_tracks),
            ),
            (
                "track_info",
                "disc_number",
                "disc_number",
                json!(self.disc_number),
            ),
            (
                "track_info",
                "total_discs",
                "total_discs",
                json!(self.total_discs),
            ),
            (
                "release_info",
                "release_date",
                "release_date",
                json!(self.release_date),
            ),
            ("release_info", "isrc", "isrc", json!(self.isrc)),
            ("cover", "cover", "cover_url", json!(self.cover_url)),
            ("extra", "genre", "genre", json!(self.genre)),
            ("extra", "label", "label", json!(self.label)),
            ("extra", "copyright", "copyright", json!(self.copyright)),
            ("extra", "composer", "composer", json!(self.composer)),
        ] {
            if self.selected(group, tag) {
                result[key] = value;
            }
        }
        if self.selected("cover", "cover") && !self.header_video.is_empty() {
            result["header_video"] = json!(self.header_video);
        }
        result
    }

    /// ReEnrich passes no candidate album to trackMatchesRequest in Go.
    pub fn verified(&self, track: &Value) -> bool {
        let (title, artist, isrc) = (
            text(track, "name"),
            text(track, "artists"),
            text(track, "isrc"),
        );
        let exact = !self.isrc.is_empty()
            && !isrc.is_empty()
            && self.isrc.trim().eq_ignore_ascii_case(isrc.trim());
        if !exact
            && ((!self.artist_name.is_empty()
                && !artist.is_empty()
                && !artists_match(&self.artist_name, artist))
                || (!self.track_name.is_empty()
                    && !title.is_empty()
                    && !track_titles_match(&self.track_name, title)))
        {
            return false;
        }
        let (expected, duration) = (self.duration_ms / 1000, number(track, "duration_ms") / 1000);
        if expected > 0 && duration > 0 && expected.abs_diff(duration) > 10 {
            let identity = track_identity_title(&self.track_name);
            let candidate_identity = track_identity_title(title);
            let identity_matches = if !identity.is_empty() && !candidate_identity.is_empty() {
                identity == candidate_identity
            } else {
                lowercase(self.track_name.trim()) == lowercase(title.trim())
            };
            return exact
                && !self.track_name.is_empty()
                && !title.is_empty()
                && identity_matches
                && !self.artist_name.is_empty()
                && !artist.is_empty()
                && artists_match(&self.artist_name, artist)
                && !(duration <= 35 && expected > 45);
        }
        true
    }

    pub fn select<'a>(&self, tracks: &'a [Value]) -> Option<&'a Value> {
        let isrc = self.isrc.trim();
        let album = self.album_name.trim();
        let title = if placeholder(&self.track_name) {
            ""
        } else {
            &self.track_name
        };
        let artist = if placeholder(&self.artist_name) {
            ""
        } else {
            &self.artist_name
        };
        let mut best = None;
        let mut best_score = i32::MIN;
        for track in tracks {
            let exact = !isrc.is_empty() && isrc.eq_ignore_ascii_case(text(track, "isrc").trim());
            let title_matches = !title.is_empty()
                && !text(track, "name").is_empty()
                && titles_match(title, text(track, "name"));
            let artist_matches = !artist.is_empty()
                && !text(track, "artists").is_empty()
                && artists_match(artist, text(track, "artists"));
            let album_matches = !album.is_empty()
                && !text(track, "album_name").is_empty()
                && titles_match(album, text(track, "album_name"));
            let verified = self.verified(track);
            if !exact
                && ((!title.is_empty() && !title_matches)
                    || (!artist.is_empty() && !artist_matches)
                    || (title.is_empty()
                        && artist.is_empty()
                        && ((!album.is_empty() && !album_matches)
                            || (album.is_empty() && !verified))))
            {
                continue;
            }
            let mut score = i32::from(verified) * 2000
                + i32::from(exact) * 10000
                + i32::from(title_matches) * 400
                + i32::from(artist_matches) * 320;
            if !album.is_empty() && !text(track, "album_name").is_empty() {
                if album_matches {
                    score += 120;
                } else if lowercase(album).contains(&lowercase(text(track, "album_name")))
                    || lowercase(text(track, "album_name")).contains(&lowercase(album))
                {
                    score += 50;
                }
            }
            if self.duration_ms > 0
                && number(track, "duration_ms") > 0
                && (self.duration_ms / 1000).abs_diff(number(track, "duration_ms") / 1000) <= 10
            {
                score += 80;
            }
            score += i32::from(!text(track, "release_date").is_empty()) * 70
                + i32::from(number(track, "track_number") > 0) * 20
                + i32::from(number(track, "disc_number") > 0) * 10
                + i32::from(!text(track, "isrc").is_empty()) * 40;
            if score > best_score {
                best_score = score;
                best = Some(track);
            }
        }
        best
    }
}

fn selected(fields: &Option<Vec<Option<String>>>, group: &str, tag: &str) -> bool {
    fields.as_ref().is_none_or(|fields| {
        fields.is_empty()
            || fields.iter().any(|field| {
                field
                    .as_deref()
                    .is_some_and(|field| field == group || field == tag)
            })
    })
}

pub fn from_catalog(track: &super::TrackMetadata) -> Value {
    let mut result = serde_json::to_value(track).expect("catalog metadata serialization");
    result["id"] = json!(track.spotify_id);
    result["deezer_id"] = json!(
        track
            .spotify_id
            .strip_prefix("deezer:")
            .unwrap_or(&track.spotify_id)
            .trim()
    );
    result["cover_url"] = json!(track.images);
    result["provider_id"] = json!("deezer");
    result
}
