//! Collection matching and share links from already-decoded extension tracks.

use crate::json::lenient_deserialize;
use crate::lyrics::matching::{normalize_loose_artist, normalize_title, simplify_track};
use crate::matching::lowercase;
use serde::Serialize;
use serde_json::Value;

#[derive(Default)]
pub struct Request {
    pub name: String,
    pub artists: String,
    pub kind: String,
    pub source_extension_id: String,
}
lenient_deserialize!(Request {
    "name" => name, "artists" => artists, "type" => kind,
    "source_extension_id" => source_extension_id,
});

impl Request {
    pub fn parse(raw: &str) -> Result<Self, serde_json::Error> {
        let mut request: Self = serde_json::from_str(&crate::text::json_surrogates(raw))?;
        request.name = request.name.trim().into();
        request.artists = request.artists.trim().into();
        request.source_extension_id = request.source_extension_id.trim().into();
        request.kind = lowercase(request.kind.trim());
        if request.kind.is_empty() {
            request.kind = "album".into();
        }
        Ok(request)
    }

    pub fn query(&self) -> String {
        if self.artists.is_empty() {
            self.name.clone()
        } else {
            format!("{} {}", self.name, self.artists)
        }
    }

    pub fn cache_key(&self, providers: &[Provider]) -> String {
        let mut identities: Vec<_> = providers
            .iter()
            .map(|provider| {
                [
                    provider.id.trim(),
                    provider.display_name.trim(),
                    provider.source_dir.trim(),
                ]
                .join("\x1f")
            })
            .collect();
        identities.sort();
        [
            normalize_title(&self.kind),
            normalize_title(&self.name),
            normalize_loose_artist(&self.artists),
            self.source_extension_id.clone(),
            identities.join("\x1e"),
        ]
        .join("\x1d")
    }
}

pub struct Provider {
    pub id: String,
    pub display_name: String,
    pub source_dir: String,
    pub capabilities: Value,
}

#[derive(Serialize)]
pub struct ShareResult {
    pub extension_id: String,
    pub display_name: String,
    pub found: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub url: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub item_name: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub item_artists: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub error: String,
}

impl ShareResult {
    pub fn new(provider: &Provider) -> Self {
        Self {
            extension_id: provider.id.clone(),
            display_name: if provider.display_name.is_empty() {
                provider.id.clone()
            } else {
                provider.display_name.clone()
            },
            found: false,
            url: String::new(),
            item_name: String::new(),
            item_artists: String::new(),
            error: String::new(),
        }
    }

    pub fn cacheable(&self) -> bool {
        let error = lowercase(self.error.trim());
        self.found
            || error.is_empty()
            || matches!(error.as_str(), "no results" | "unsupported collection type")
            || error.ends_with(" not found")
            || error.contains("found without shareable link")
    }
}

fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or_default()
}

fn is_collection(track: &Value, kind: &str) -> bool {
    // Go's simple folding also accepts long s in the fixed ASCII kind "artist".
    text(track, "item_type")
        .trim()
        .chars()
        .map(|ch| {
            if ch == 'ſ' {
                's'
            } else {
                ch.to_ascii_lowercase()
            }
        })
        .eq(kind.chars())
}

fn name<'a>(track: &'a Value, kind: &str) -> &'a str {
    text(
        track,
        if is_collection(track, kind) {
            "name"
        } else if kind == "album" {
            "album_name"
        } else {
            "artists"
        },
    )
}

fn share_url(provider: &Provider, track: &Value, kind: &str) -> String {
    let direct = |value: &str| {
        let value = value.trim();
        (value.starts_with("http://") || value.starts_with("https://")).then_some(value.to_owned())
    };
    if is_collection(track, kind)
        && let Some(url) = direct(text(track, "external_urls"))
    {
        return url;
    }
    let field = if kind == "album" {
        "album_url"
    } else {
        "artist_url"
    };
    if let Some(url) = direct(text(track, field)) {
        return url;
    }
    if let Some(links) = track["external_links"].as_object() {
        for (key, value) in links {
            if lowercase(key).contains(kind)
                && let Some(url) = direct(value.as_str().unwrap_or_default())
            {
                return url;
            }
        }
    }
    let id_field = if kind == "album" {
        "album_id"
    } else {
        "artist_id"
    };
    let id = [
        text(track, id_field),
        if is_collection(track, kind) {
            text(track, "id")
        } else {
            ""
        },
        if kind == "album" {
            text(track, "album_url")
        } else {
            ""
        },
    ]
    .into_iter()
    .map(str::trim)
    .find(|id| !id.is_empty())
    .unwrap_or_default();
    if id.is_empty() {
        return String::new();
    }
    let id = id
        .split_once(':')
        .filter(|(prefix, suffix)| !prefix.is_empty() && !suffix.is_empty())
        .map_or(id, |(_, suffix)| suffix);
    provider.capabilities["shareUrlTemplates"][kind]
        .as_str()
        .unwrap_or_default()
        .trim()
        .replace("{id}", id)
}

/// Whether a search result is a song rather than an album, artist or playlist.
fn is_song(track: &Value) -> bool {
    let kind = lowercase(text(track, "item_type").trim());
    matches!(kind.as_str(), "" | "track" | "song")
}

/// A song's own page: the link its extension gave, or the extension's
/// `track` template filled with the song's id.
fn track_url(provider: &Provider, track: &Value) -> String {
    let direct = |value: &str| {
        let value = value.trim();
        (value.starts_with("http://") || value.starts_with("https://")).then_some(value.to_owned())
    };
    if let Some(url) = direct(text(track, "external_urls")) {
        return url;
    }
    if let Some(links) = track["external_links"].as_object() {
        for (key, value) in links {
            let key = lowercase(key);
            if (key.contains("track") || key.contains("song"))
                && let Some(url) = direct(value.as_str().unwrap_or_default())
            {
                return url;
            }
        }
    }
    let id = text(track, "id").trim();
    let id = id
        .split_once(':')
        .filter(|(prefix, suffix)| !prefix.is_empty() && !suffix.is_empty())
        .map_or(id, |(_, suffix)| suffix);
    if id.is_empty() {
        return String::new();
    }
    provider.capabilities["shareUrlTemplates"]["track"]
        .as_str()
        .unwrap_or_default()
        .trim()
        .replace("{id}", id)
}

/// The song of `request` among `tracks`: the same title, or the same title
/// once both lose their version notes, by an artist the request names.
fn select_track(
    provider: &Provider,
    request: &Request,
    tracks: &[Value],
    mut result: ShareResult,
) -> ShareResult {
    let title = normalize_title(&request.name);
    let simple = simplify_track(&request.name);
    let artists = normalize_loose_artist(&request.artists);
    let mut best = None;
    let mut best_score = 0;
    for track in tracks.iter().filter(|track| is_song(track)) {
        let name = text(track, "name");
        let score = if !title.is_empty() && normalize_title(name) == title {
            100
        } else if !simple.is_empty() && simplify_track(name) == simple {
            70
        } else {
            continue;
        };
        if !artists.is_empty() {
            let candidate = normalize_loose_artist(text(track, "artists"));
            if candidate.is_empty()
                || !(candidate.contains(&artists) || artists.contains(&candidate))
            {
                continue;
            }
        }
        if score > best_score {
            best_score = score;
            best = Some(track);
        }
    }
    let Some(best) = best else {
        result.error = "track not found".into();
        return result;
    };
    result.url = track_url(provider, best);
    if result.url.is_empty() {
        result.error = "track found without shareable link".into();
        return result;
    }
    result.found = true;
    result.item_name = text(best, "name").into();
    result.item_artists = text(best, "artists").into();
    result
}

pub fn select(provider: &Provider, request: &Request, tracks: &[Value]) -> ShareResult {
    let mut result = ShareResult::new(provider);
    if tracks.is_empty() {
        result.error = "no results".into();
        return result;
    }
    let kind = request.kind.as_str();
    if kind == "track" {
        return select_track(provider, request, tracks, result);
    }
    if !matches!(kind, "album" | "artist") {
        result.error = "unsupported collection type".into();
        return result;
    }
    let normalize = if kind == "album" {
        normalize_title
    } else {
        normalize_loose_artist
    };
    let target = normalize(&request.name);
    let artists = normalize_loose_artist(&request.artists);
    let mut best = None;
    let mut best_score = 0;
    for track in tracks {
        let candidate = normalize(name(track, kind));
        let mut score = if is_collection(track, kind) { 25 } else { 0 };
        if candidate == target {
            score += 100;
        } else if !candidate.is_empty()
            && !target.is_empty()
            && (candidate.contains(&target) || target.contains(&candidate))
        {
            score += if kind == "album" { 50 } else { 60 };
        }
        if kind == "album" && !artists.is_empty() {
            let candidate_artists = normalize_loose_artist(&format!(
                "{} {}",
                text(track, "artists"),
                text(track, "album_artist")
            ));
            if candidate_artists.contains(&artists) || artists.contains(&candidate_artists) {
                score += 30;
            }
        }
        if score > best_score {
            best_score = score;
            best = Some(track);
        }
    }
    let Some(best) = best.filter(|_| best_score >= if kind == "album" { 50 } else { 60 }) else {
        result.error = format!("{kind} not found");
        return result;
    };
    result.url = share_url(provider, best, kind);
    if result.url.is_empty() {
        result.error = format!("{kind} found without shareable link");
        return result;
    }
    result.found = true;
    result.item_name = name(best, kind).into();
    if kind == "album" {
        result.item_artists = text(best, "artists").into();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn provider(capabilities: Value) -> Provider {
        Provider {
            id: "example-provider".into(),
            display_name: "Example Provider".into(),
            source_dir: String::new(),
            capabilities,
        }
    }

    fn request(name: &str, artists: &str) -> Request {
        Request::parse(&json!({"name": name, "artists": artists, "type": "track"}).to_string())
            .unwrap()
    }

    #[test]
    fn a_song_is_found_by_title_and_artist() {
        let tracks = [
            json!({"id": "1", "name": "Example Song", "artists": "Someone Else",
                   "external_urls": "https://example.com/track/1"}),
            json!({"id": "2", "name": "Example Song", "artists": "Example Artist, Guest",
                   "external_urls": "https://example.com/track/2"}),
        ];
        let result = select(
            &provider(json!({})),
            &request("Example Song", "Example Artist"),
            &tracks,
        );
        assert!(result.found);
        assert_eq!(result.url, "https://example.com/track/2");
        assert_eq!(result.item_name, "Example Song");
        assert_eq!(result.item_artists, "Example Artist, Guest");
    }

    #[test]
    fn the_same_title_wins_over_another_version() {
        let tracks = [
            json!({"id": "1", "name": "Example Song (Live)", "artists": "Example Artist",
                   "external_urls": "https://example.com/track/1"}),
            json!({"id": "2", "name": "Example Song", "artists": "Example Artist",
                   "external_urls": "https://example.com/track/2"}),
        ];
        let provider = provider(json!({}));
        let exact = select(
            &provider,
            &request("Example Song", "Example Artist"),
            &tracks,
        );
        assert_eq!(exact.url, "https://example.com/track/2");
        // With no exact title, a version of the song still counts.
        let version = select(
            &provider,
            &request("Example Song (Remastered)", "Example Artist"),
            &tracks[..1],
        );
        assert_eq!(version.url, "https://example.com/track/1");
    }

    #[test]
    fn albums_and_other_songs_are_not_the_song() {
        let tracks = [
            json!({"id": "1", "name": "Example Song", "artists": "Example Artist",
                   "item_type": "album", "external_urls": "https://example.com/album/1"}),
            json!({"id": "2", "name": "Example Song Two", "artists": "Example Artist",
                   "external_urls": "https://example.com/track/2"}),
        ];
        let result = select(
            &provider(json!({})),
            &request("Example Song", "Example Artist"),
            &tracks,
        );
        assert!(!result.found);
        assert_eq!(result.error, "track not found");
        assert!(result.cacheable());
    }

    #[test]
    fn a_song_without_a_link_uses_the_track_template() {
        let tracks =
            [json!({"id": "example:42", "name": "Example Song", "artists": "Example Artist"})];
        let request = request("Example Song", "Example Artist");
        let templated = select(
            &provider(json!({"shareUrlTemplates": {"track": "https://example.com/song/{id}"}})),
            &request,
            &tracks,
        );
        assert_eq!(templated.url, "https://example.com/song/42");
        let bare = select(&provider(json!({})), &request, &tracks);
        assert!(!bare.found);
        assert_eq!(bare.error, "track found without shareable link");
    }
}
