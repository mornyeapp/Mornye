//! Re-enrichment input, candidate policy and preview metadata. No file access.

use crate::json::lenient_deserialize;
use crate::lyrics::matching::{normalize_loose_artist, normalize_title};
use crate::matching::{lowercase, uppercase};
use crate::resolver::{
    artists_match, same_track_title, titles_match, track_identity_title, track_titles_match,
};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::LazyLock;

/// Candidates returned to the picker; enough for every plausible release.
pub const MAX_CANDIDATES: usize = 15;

/// How closely a provider track matches the song being re-enriched.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Match {
    Other,
    Weak,
    Strong,
    Exact,
}

impl Match {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Exact => "exact",
            Self::Strong => "strong",
            Self::Weak => "weak",
            Self::Other => "other",
        }
    }

    fn parse(value: &str) -> Self {
        match value {
            "exact" => Self::Exact,
            "strong" => Self::Strong,
            "weak" => Self::Weak,
            _ => Self::Other,
        }
    }
}

/// One track found for a re-enrich, before ranking.
pub struct Candidate {
    pub track: Value,
    /// The built-in ISRC/ID catalog lookup, which yields to providers.
    pub catalog: bool,
    /// Position of the provider in the search order; lower asks first.
    pub priority: usize,
}

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
    pub include_candidates: bool,
    /// Lists candidates without giving up the automatic early stop, for a
    /// batch whose songs are mostly matched without a pick.
    pub quick_candidates: bool,
    pub selected_candidate: Option<Value>,
    pub provider_ids: Option<Vec<Option<String>>>,
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
    "include_candidates" => include_candidates, "quick_candidates" => quick_candidates,
    "selected_candidate" => selected_candidate, "provider_ids" => provider_ids,
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

    /// A candidate exactly as an earlier preview returned it, chosen by the user.
    pub fn selected_candidate(&self) -> Option<&Value> {
        self.selected_candidate
            .as_ref()
            .filter(|track| track.as_object().is_some_and(|track| !track.is_empty()))
    }

    /// Metadata providers the search is limited to, in the order to ask them.
    /// Empty means every enabled provider in the user's priority order.
    pub fn provider_ids(&self) -> Vec<String> {
        let mut seen = BTreeSet::new();
        self.provider_ids
            .iter()
            .flatten()
            .flatten()
            .map(|id| id.trim())
            .filter(|id| !id.is_empty() && seen.insert(id.to_owned()))
            .map(Into::into)
            .collect()
    }

    /// Candidates are only listed for a preview, which is what a picker shows.
    pub fn wants_candidates(&self) -> bool {
        self.include_candidates && self.preview_only
    }

    /// Whether the search may stop at the first provider with a confident
    /// match. A picker for one song asks every provider instead; a batch
    /// keeps the stop, since asking every provider for every song of a large
    /// library multiplies its searches.
    pub fn stops_when_confident(&self) -> bool {
        !self.wants_candidates() || self.quick_candidates
    }

    /// The whole artist string or the album finds songs from other releases,
    /// so the title goes with the primary artist first, then with the album.
    pub fn queries(&self) -> Vec<String> {
        let known = |value: &str| (!placeholder(value)).then(|| value.trim().to_owned());
        let mut queries = Vec::new();
        if let Some(title) = known(&self.track_name) {
            let artist = known(&self.artist_name)
                .or_else(|| known(&self.album_artist))
                .map(|artist| primary_artist(&artist).to_owned())
                .unwrap_or_default();
            queries.push(format!("{title} {artist}"));
            if let Some(album) = known(&self.album_name) {
                queries.push(format!("{title} {album}"));
            }
        } else if let Some(other) = known(&self.artist_name).or_else(|| known(&self.album_name)) {
            // Without a title only an ISRC can match, but the search may still
            // return the song with one.
            queries.push(other);
        }
        let mut seen = BTreeSet::new();
        queries
            .into_iter()
            .map(|query| query.trim().to_owned())
            .filter(|query| !query.is_empty() && seen.insert(lowercase(query)))
            .collect()
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

    /// Extras from another source only fill values the winning track and the
    /// file both lack; they never replace what the winner supplied.
    pub fn fill_empty_extras(&mut self, genre: &str, label: &str, copyright: &str) {
        for (target, value) in [
            (&mut self.genre, genre),
            (&mut self.label, label),
            (&mut self.copyright, copyright),
        ] {
            if target.is_empty() && !value.is_empty() {
                *target = value.into();
            }
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

    fn known_title(&self) -> &str {
        if placeholder(&self.track_name) {
            ""
        } else {
            self.track_name.trim()
        }
    }

    fn known_artist(&self) -> &str {
        [&self.artist_name, &self.album_artist]
            .into_iter()
            .find(|artist| !placeholder(artist))
            .map_or("", |artist| artist.trim())
    }

    fn known_album(&self) -> &str {
        if placeholder(&self.album_name) {
            ""
        } else {
            self.album_name.trim()
        }
    }

    /// The level shared by automatic runs and the candidate list.
    pub fn match_level(&self, track: &Value) -> Match {
        let isrc = self.isrc.trim();
        // An equal ISRC still needs `verified`, which rejects previews and
        // other recordings that a catalog filed under the same code.
        if !isrc.is_empty()
            && isrc.eq_ignore_ascii_case(text(track, "isrc").trim())
            && self.verified(track)
        {
            return Match::Exact;
        }
        let (title, artist) = (self.known_title(), self.known_artist());
        let (found_title, found_artist) = (text(track, "name"), text(track, "artists"));
        if title.is_empty()
            || artist.is_empty()
            || found_title.trim().is_empty()
            || found_artist.trim().is_empty()
            || !same_track_title(title, found_title)
            || !artists_match(artist, found_artist)
        {
            return Match::Other;
        }
        let (expected, duration) = (self.duration_ms / 1000, number(track, "duration_ms") / 1000);
        let duration = (expected > 0 && duration > 0).then(|| expected.abs_diff(duration) <= 10);
        let (album, found_album) = (self.known_album(), text(track, "album_name").trim());
        match (duration, album.is_empty() || found_album.is_empty()) {
            (Some(false), _) => Match::Other,
            (_, true) => Match::Weak,
            _ if titles_match(album, found_album) => Match::Strong,
            // A compilation carries the same recording under another album.
            (Some(true), _) => Match::Weak,
            _ => Match::Other,
        }
    }

    /// Orders tracks of one level; providers outrank the catalog, so the
    /// user's provider priority decides between equal matches.
    fn match_score(&self, track: &Value, catalog: bool) -> i64 {
        let (title, artist, album) = (self.known_title(), self.known_artist(), self.known_album());
        let (found_title, found_artist, found_album) = (
            text(track, "name"),
            text(track, "artists"),
            text(track, "album_name").trim(),
        );
        let mut score = if catalog { 0 } else { 1000 };
        if !title.is_empty() && !found_title.is_empty() {
            let identity = track_identity_title(title);
            score += if !identity.is_empty() && identity == track_identity_title(found_title) {
                200
            } else if same_track_title(title, found_title) {
                150
            } else if track_titles_match(title, found_title) {
                100
            } else {
                0
            };
        }
        if !artist.is_empty() && !found_artist.is_empty() {
            score += if normalize_loose_artist(artist) == normalize_loose_artist(found_artist) {
                150
            } else if artists_match(artist, found_artist) {
                80
            } else {
                0
            };
        }
        if !album.is_empty() && !found_album.is_empty() && titles_match(album, found_album) {
            score += 120 + i64::from(normalize_title(album) == normalize_title(found_album)) * 60;
        }
        let (expected, duration) = (self.duration_ms / 1000, number(track, "duration_ms") / 1000);
        if expected > 0 && duration > 0 {
            score += match expected.abs_diff(duration) {
                0..=2 => 100,
                3..=10 => 60,
                _ => 0,
            };
        }
        score
            + i64::from(!text(track, "release_date").is_empty()) * 40
            + i64::from(number(track, "track_number") > 0) * 20
            + i64::from(number(track, "disc_number") > 0) * 10
            + i64::from(!text(track, "isrc").is_empty()) * 30
            + i64::from(!text(track, "cover_url").is_empty() || !text(track, "images").is_empty())
                * 20
    }

    /// An exact or strong match ends an automatic search early.
    pub fn confident(&self, track: &Value) -> bool {
        self.match_level(track) >= Match::Strong
    }

    /// Sorts by level, then score, then provider priority, drops duplicates
    /// and records `match` and `match_score` on every track.
    pub fn rank(&self, found: Vec<Candidate>) -> Vec<Value> {
        let mut ranked: Vec<_> = found
            .into_iter()
            .filter(|candidate| candidate.track.is_object())
            .enumerate()
            .map(|(arrival, candidate)| {
                let level = self.match_level(&candidate.track);
                let score = self.match_score(&candidate.track, candidate.catalog);
                let mut track = candidate.track;
                track["match"] = level.as_str().into();
                track["match_score"] = score.into();
                (level, score, candidate.priority, arrival, track)
            })
            .collect();
        ranked.sort_by(|a, b| {
            (b.0, b.1)
                .cmp(&(a.0, a.1))
                .then((a.2, a.3).cmp(&(b.2, b.3)))
        });
        let mut seen = BTreeSet::new();
        ranked
            .into_iter()
            .map(|(.., track)| track)
            .filter(|track| {
                let id = text(track, "id").trim();
                let identity = (!id.is_empty())
                    .then(|| format!("id\0{}\0{id}", text(track, "provider_id").trim()));
                // Providers often list the same release; rows the user could
                // not tell apart are one candidate.
                let content = format!(
                    "content\0{}\0{}\0{}\0{}\0{}",
                    normalize_title(text(track, "name")),
                    normalize_loose_artist(text(track, "artists")),
                    normalize_title(text(track, "album_name")),
                    uppercase(text(track, "isrc").trim()),
                    text(track, "release_date").trim()
                );
                let unseen = !seen.contains(&content)
                    && identity.as_ref().is_none_or(|key| !seen.contains(key));
                seen.insert(content);
                seen.extend(identity);
                unseen
            })
            .collect()
    }

    /// Whether an automatic run may apply a track of this level. A weak match
    /// only applies when the file has no album to contradict it.
    pub fn applies_automatically(&self, level: Match) -> bool {
        level >= Match::Strong || (level == Match::Weak && self.known_album().is_empty())
    }

    /// The candidate an automatic run applies: the first ranked one, when its
    /// level allows applying it without asking.
    pub fn automatic<'a>(&self, ranked: &'a [Value]) -> Option<(&'a Value, Match)> {
        let best = ranked.first()?;
        let level = Match::parse(text(best, "match"));
        self.applies_automatically(level).then_some((best, level))
    }
}

static ARTIST_SEPARATOR: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r"(?i)[,;&]|[\t\n\f\r ](?:feat\.?|ft\.?|featuring|x|and)[\t\n\f\r ]").unwrap()
});

/// The first artist of a credit such as "Lead, Guest" or "Lead feat. Guest".
fn primary_artist(value: &str) -> &str {
    ARTIST_SEPARATOR
        .find(value)
        .map(|separator| value[..separator.start()].trim())
        .filter(|artist| !artist.is_empty())
        .unwrap_or(value.trim())
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

#[cfg(test)]
mod tests {
    use super::*;

    fn request(album: &str) -> Request {
        Request::parse(
            &json!({"track_name":"Signal","artist_name":"Lead Artist, Guest Artist",
                "album_name":album,"duration_ms":200_000})
            .to_string(),
        )
        .unwrap()
    }

    fn track(name: &str, album: &str, duration_ms: i64) -> Value {
        json!({"provider_id":"provider-a","id":name,"name":name,"artists":"Lead Artist",
            "album_name":album,"duration_ms":duration_ms})
    }

    fn search(track: Value, priority: usize) -> Candidate {
        Candidate {
            track,
            catalog: false,
            priority,
        }
    }

    #[test]
    fn new_request_fields_parse_leniently_and_keep_nested_candidates() {
        let request = Request::parse(
            r#"{"include_candidates":true,"preview_only":true,
            "provider_ids":["provider-b"," provider-a ","",null,"provider-b"],
            "selected_candidate":{"id":"one","name":"Signal","duration_ms":1}}"#,
        )
        .unwrap();
        assert!(request.wants_candidates());
        assert_eq!(request.provider_ids(), ["provider-b", "provider-a"]);
        assert_eq!(request.selected_candidate().unwrap()["duration_ms"], 1);
        let request =
            Request::parse(r#"{"selected_candidate":{},"include_candidates":true}"#).unwrap();
        assert!(request.selected_candidate().is_none());
        assert!(!request.wants_candidates());
        assert!(request.provider_ids().is_empty());
    }

    #[test]
    fn queries_use_the_primary_artist_then_the_album() {
        assert_eq!(
            request("Album").queries(),
            ["Signal Lead Artist", "Signal Album"]
        );
        let mut request = request("Unknown Album");
        request.artist_name = "Lead Artist feat. Guest".into();
        assert_eq!(request.queries(), ["Signal Lead Artist"]);
        request.artist_name = String::new();
        request.album_artist = "Band x Other Band".into();
        assert_eq!(request.queries(), ["Signal Band"]);
        request.album_name = "band".into();
        assert_eq!(request.queries(), ["Signal Band"]);
        request.album_artist = String::new();
        request.album_name = String::new();
        assert_eq!(request.queries(), ["Signal"]);
    }

    #[test]
    fn a_longer_title_that_contains_the_song_is_another_song() {
        let request = request("Album");
        assert_eq!(
            request.match_level(&track("Signal Night Dance", "Album", 200_000)),
            Match::Other
        );
        for name in [
            "Signal",
            "Signal (feat. Guest Artist)",
            "Signal (From \"Example Film\")",
        ] {
            assert_eq!(
                request.match_level(&track(name, "Album", 201_000)),
                Match::Strong,
                "{name}"
            );
        }
        let mut other_artist = track("Signal", "Album", 200_000);
        other_artist["artists"] = "Someone Else".into();
        assert_eq!(request.match_level(&other_artist), Match::Other);
    }

    #[test]
    fn album_and_duration_decide_between_weak_and_other() {
        let request = request("Album (Original Soundtrack)");
        assert_eq!(
            request.match_level(&track("Signal", "Album", 200_000)),
            Match::Strong
        );
        let level = request.match_level(&track("Signal", "Other Album", 260_000));
        assert_eq!(level, Match::Other);
        assert!(!request.applies_automatically(level));
        let level = request.match_level(&track("Signal", "Other Album", 205_000));
        assert_eq!(level, Match::Weak);
        assert!(!request.applies_automatically(level));
        assert_eq!(
            request.match_level(&track("Signal", "Album", 260_000)),
            Match::Other
        );
        for album in ["", "Unknown Album"] {
            let request = super::tests::request(album);
            let level = request.match_level(&track("Signal", "Other Album", 260_000));
            assert_eq!(level, Match::Other);
            let level = request.match_level(&track("Signal", "Other Album", 0));
            assert_eq!(level, Match::Weak);
            assert!(request.applies_automatically(level));
        }
        let mut exact = track("Different Title", "Other Album", 200_000);
        exact["isrc"] = "EXAMPLE00001".into();
        let mut request = request.clone();
        request.isrc = "example00001".into();
        assert_eq!(request.match_level(&exact), Match::Exact);
        exact["duration_ms"] = 30_000.into();
        assert_eq!(request.match_level(&exact), Match::Other);
    }

    #[test]
    fn ranking_orders_by_level_score_and_priority_and_drops_duplicates() {
        let request = request("Album");
        let mut later = track("Signal", "Album", 200_000);
        later["provider_id"] = "provider-b".into();
        later["id"] = "b-1".into();
        later["release_date"] = "2001".into();
        let mut first = track("Signal", "Album", 200_000);
        first["release_date"] = "2002".into();
        let mut same_as_first = first.clone();
        same_as_first["provider_id"] = "provider-b".into();
        same_as_first["id"] = "b-2".into();
        let other = track("Signal Night Dance", "Album", 200_000);
        let mut weak = track("Signal", "Different Record", 200_000);
        weak["id"] = "compilation".into();
        let ranked = request.rank(vec![
            search(other, 0),
            search(weak, 0),
            search(later.clone(), 1),
            search(first.clone(), 0),
            // The same song again from the album query.
            search(first, 0),
            search(later, 1),
            // Another provider listing exactly the same release.
            search(same_as_first, 1),
        ]);
        let order: Vec<_> = ranked
            .iter()
            .map(|track| (text(track, "provider_id"), text(track, "match")))
            .collect();
        assert_eq!(
            order,
            [
                ("provider-a", "strong"),
                ("provider-b", "strong"),
                ("provider-a", "weak"),
                ("provider-a", "other"),
            ]
        );
        assert!(ranked[0]["match_score"].as_i64().unwrap() > 1000);
        let (best, level) = request.automatic(&ranked).unwrap();
        assert_eq!(level, Match::Strong);
        assert_eq!(best, &ranked[0]);
        assert!(request.automatic(&ranked[2..]).is_none());
    }

    #[test]
    fn the_winner_supplies_every_field_and_the_catalog_fills_nothing() {
        let mut request = request("Album");
        request.isrc = "EXAMPLE00001".into();
        request.release_date = "2020".into();
        request.genre = "Existing Genre".into();
        let mut catalog = track("Signal", "Album", 200_000);
        catalog["provider_id"] = "deezer".into();
        catalog["isrc"] = "EXAMPLE00001".into();
        catalog["composer"] = "Catalog Composer".into();
        catalog["release_date"] = "2001-01-01".into();
        catalog["genre"] = "Catalog Genre".into();
        catalog["label"] = "Catalog Label".into();
        let mut found = track("Signal", "Album", 200_000);
        found["isrc"] = "EXAMPLE00001".into();
        found["album_artist"] = "Lead Artist".into();
        let ranked = request.rank(vec![
            Candidate {
                track: catalog,
                catalog: true,
                priority: usize::MAX,
            },
            search(found, 0),
        ]);
        let (winner, level) = request.automatic(&ranked).unwrap();
        assert_eq!(level, Match::Exact);
        assert_eq!(text(winner, "provider_id"), "provider-a");
        let winner = winner.clone();
        request.apply(&winner);
        assert_eq!(request.composer, "");
        assert_eq!(request.release_date, "2020");
        assert_eq!(request.album_artist, "Lead Artist");
        assert_eq!(request.label, "");
        request.fill_empty_extras("Extra Genre", "Extra Label", "Extra Copyright");
        assert_eq!(request.genre, "Existing Genre");
        assert_eq!(request.label, "Extra Label");
        assert_eq!(request.copyright, "Extra Copyright");
    }
}
