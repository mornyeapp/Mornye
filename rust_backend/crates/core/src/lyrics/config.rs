use crate::matching::lowercase;
use serde::Serialize;
use std::collections::HashSet;

pub const DEFAULT_PROVIDERS: &[&str] = &[
    "apple_music",
    "lrcred",
    "mornye_lyrics",
    "lyricsplus",
    "lrclib",
];
pub const BUILTIN_PROVIDERS: &[&str] = &[
    "lrclib",
    "netease",
    "musixmatch",
    "apple_music",
    "mornye_lyrics",
    "qqmusic",
    "spotify",
    "deezer",
    "youtube",
    "kugou",
    "genius",
    "lyricsplus",
    "lrcred",
    "betterlyrics",
];

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct FetchOptions {
    pub include_translation_netease: bool,
    pub include_romanization_netease: bool,
    pub multi_person_word_by_word: bool,
    pub apple_elrc_word_sync: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub musixmatch_language: String,
    /// Choose the provider result with the best timing (word, then line,
    /// then plain) instead of the first provider that has lyrics. Provider
    /// order still breaks ties.
    pub prefer_best_timing: bool,
}

crate::json::lenient_deserialize!(FetchOptions {
    "include_translation_netease" => include_translation_netease,
    "include_romanization_netease" => include_romanization_netease,
    "multi_person_word_by_word" => multi_person_word_by_word,
    "apple_elrc_word_sync" => apple_elrc_word_sync,
    "musixmatch_language" => musixmatch_language,
    "prefer_best_timing" => prefer_best_timing,
});

impl Default for FetchOptions {
    fn default() -> Self {
        Self {
            include_translation_netease: false,
            include_romanization_netease: false,
            multi_person_word_by_word: true,
            apple_elrc_word_sync: false,
            musixmatch_language: String::new(),
            prefer_best_timing: true,
        }
    }
}

impl FetchOptions {
    /// Go unmarshals partial settings into the current options. Commit only a
    /// fully valid document, including duplicate fields and null scalar values.
    pub fn update_json(&mut self, raw: &str) -> Result<(), serde_json::Error> {
        use crate::json::Update;
        if raw.trim().is_empty() {
            return Ok(());
        }
        let document = super::decode_document::<Box<serde_json::value::RawValue>>(raw.as_bytes())?;
        let mut next = self.clone();
        next.update(&mut serde_json::Deserializer::from_str(document.get()))?;
        *self = next;
        Ok(())
    }

    pub fn normalize(&mut self) {
        self.musixmatch_language = lowercase(self.musixmatch_language.trim())
            .chars()
            .filter(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || matches!(ch, '-' | '_'))
            .take(16)
            .collect();
    }
}

pub fn decode_providers(raw: &str) -> Result<Vec<String>, serde_json::Error> {
    Ok(
        super::decode_document::<Option<Vec<Option<String>>>>(raw.as_bytes())?
            .unwrap_or_default()
            .into_iter()
            .map(Option::unwrap_or_default)
            .collect(),
    )
}

#[derive(Serialize)]
pub struct AvailableProvider {
    pub id: &'static str,
    pub name: &'static str,
    pub has_proxy_dependency: bool,
    pub description: &'static str,
}

pub fn available_providers() -> Vec<AvailableProvider> {
    [
        (
            "lrclib",
            "LRCLIB",
            false,
            "Open-source synced lyrics database",
        ),
        ("netease", "Netease", true, "NetEase Cloud Music lyrics"),
        ("musixmatch", "Musixmatch", true, "Musixmatch lyrics"),
        (
            "apple_music",
            "Apple Music",
            true,
            "Apple Music synced lyrics via Paxsenix",
        ),
        (
            "mornye_lyrics",
            "Zarz-LRC",
            false,
            "Word-by-word Apple Music lyrics from Zarz-LRC",
        ),
        (
            "qqmusic",
            "QQ Music",
            false,
            "Direct QQ Music line-synced lyrics",
        ),
        ("spotify", "Spotify", true, "Spotify synced lyrics"),
        ("deezer", "Deezer", true, "Deezer lyrics"),
        ("youtube", "YouTube", true, "YouTube lyrics"),
        ("kugou", "Kugou", false, "Direct Kugou synced lyrics"),
        ("genius", "Genius", false, "Direct Genius lyrics"),
        (
            "lyricsplus",
            "LyricsPlus",
            true,
            "Word-by-word karaoke lyrics (Apple/Musixmatch/Spotify/QQ)",
        ),
        (
            "lrcred",
            "lrc.red",
            false,
            "Word-by-word Apple Music lyrics matched by recording",
        ),
        (
            "betterlyrics",
            "BetterLyrics",
            false,
            "Word-by-word Apple Music lyrics for popular songs",
        ),
    ]
    .into_iter()
    .map(
        |(id, name, has_proxy_dependency, description)| AvailableProvider {
            id,
            name,
            has_proxy_dependency,
            description,
        },
    )
    .collect()
}

/// Empty/invalid selections use defaults when read, matching Go's getter.
pub fn provider_order(providers: &[String]) -> Vec<String> {
    let mut result = normalize_provider_order(providers);
    if result.is_empty() {
        result = DEFAULT_PROVIDERS
            .iter()
            .map(|name| (*name).into())
            .collect();
    }
    result
}

pub fn normalize_provider_order(providers: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    providers
        .iter()
        .map(|name| lowercase(name.trim()))
        .map(|name| {
            if name == "spotiflac_lyrics" {
                "mornye_lyrics".into()
            } else {
                name
            }
        })
        .filter(|name| {
            BUILTIN_PROVIDERS.contains(&name.as_str())
                || name
                    .strip_prefix("extension:")
                    .is_some_and(|id| !id.trim().is_empty())
        })
        .filter(|name| seen.insert(name.clone()))
        .collect()
}

pub fn resolve_order(configured: &[String], extensions: &[String]) -> Vec<String> {
    let available: HashSet<_> = extensions
        .iter()
        .map(|id| format!("extension:{}", lowercase(id.trim())))
        .collect();
    configured
        .iter()
        .map(|name| {
            if name == "spotiflac_lyrics" {
                "mornye_lyrics"
            } else {
                name.as_str()
            }
        })
        .filter(|name| BUILTIN_PROVIDERS.contains(name) || available.contains(*name))
        .map(str::to_owned)
        .collect()
}

pub fn cache_key(
    spotify_id: &str,
    track: &str,
    artist: &str,
    duration: f64,
    providers: &[String],
    extensions: &[String],
    options: &FetchOptions,
) -> String {
    let mut extensions: Vec<_> = extensions.iter().map(|id| lowercase(id.trim())).collect();
    extensions.sort();
    format!(
        "{}|{}|{}|{:.0}|{}|{}|{}|{}|{}|{}|{}|{}",
        spotify_id.trim(),
        lowercase(artist.trim()),
        lowercase(track.trim()),
        (duration / 10.0).round() * 10.0,
        providers.join(","),
        extensions.join(","),
        options.include_translation_netease,
        options.include_romanization_netease,
        options.multi_person_word_by_word,
        options.apple_elrc_word_sync,
        options.musixmatch_language,
        // The timing choice can pick another provider's result. The extra
        // field also retires results cached before the choice existed.
        options.prefer_best_timing
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_lyrics_provider_id_resolves_to_current_id_without_duplicates() {
        let configured = vec![
            " SPOTIFLAC_LYRICS ".into(),
            "mornye_lyrics".into(),
            "lrclib".into(),
        ];
        assert_eq!(
            normalize_provider_order(&configured),
            ["mornye_lyrics", "lrclib"]
        );
        assert_eq!(
            resolve_order(&["spotiflac_lyrics".into()], &[]),
            ["mornye_lyrics"]
        );
        assert!(
            available_providers()
                .iter()
                .any(|p| p.id == "mornye_lyrics")
        );
    }

    #[test]
    fn best_timing_is_the_default_and_changes_the_cache_key() {
        let mut options = FetchOptions::default();
        assert!(options.prefer_best_timing);
        let key =
            |options: &FetchOptions| cache_key("", "Song", "Artist", 180.0, &[], &[], options);
        let best = key(&options);
        options
            .update_json(r#"{"prefer_best_timing":false}"#)
            .unwrap();
        assert!(!options.prefer_best_timing);
        assert_ne!(key(&options), best);
        // A partial update of another option keeps the choice.
        options
            .update_json(r#"{"musixmatch_language":"id"}"#)
            .unwrap();
        assert!(!options.prefer_best_timing);
    }
}
