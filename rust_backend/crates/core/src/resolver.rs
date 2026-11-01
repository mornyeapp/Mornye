//! Typed platform-resolver payloads and metadata matching shared with Go.

use crate::json::{Update, lenient_deserialize};
use crate::lyrics::matching::normalize_loose_artist;
use serde::{Deserialize, Deserializer, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Metadata {
    pub title: String,
    pub artist: String,
}

/// Go reuses a non-nil map across repeated JSON fields, but resets it on null.
#[derive(Clone, Debug)]
pub struct Map<T>(pub BTreeMap<String, T>);

impl<T> Default for Map<T> {
    fn default() -> Self {
        Self(BTreeMap::new())
    }
}

impl<'de, T: Deserialize<'de>> Update<'de> for Map<T> {
    fn update<D: Deserializer<'de>>(&mut self, decoder: D) -> Result<(), D::Error> {
        match Option::<BTreeMap<String, T>>::deserialize(decoder)? {
            Some(values) => self.0.extend(values),
            None => self.0.clear(),
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Default)]
pub struct Link {
    pub url: String,
}
lenient_deserialize!(Link { "url" => url, });

#[derive(Clone, Debug, Default)]
pub struct Entity {
    pub title: String,
    pub artist: String,
}
lenient_deserialize!(Entity { "title" => title, "artistname" => artist, });

#[derive(Clone, Debug, Default)]
pub struct UniTune {
    pub entity_id: String,
    pub links: Map<Link>,
    pub entities: Map<Entity>,
}
lenient_deserialize!(UniTune {
    "entityuniqueid" => entity_id,
    "linksbyplatform" => links,
    "entitiesbyuniqueid" => entities,
});

#[derive(Clone, Debug, Default)]
pub struct Artist {
    pub name: String,
}
lenient_deserialize!(Artist { "name" => name, });

#[derive(Clone, Debug, Default)]
pub struct Recording {
    pub id: String,
    pub score: isize,
    pub title: String,
    pub artists: Option<Vec<Artist>>,
}
lenient_deserialize!(Recording {
    "id" => id, "score" => score, "title" => title, "artist-credit" => artists,
});

#[derive(Clone, Debug, Default)]
pub struct Recordings {
    pub recordings: Option<Vec<Recording>>,
}
lenient_deserialize!(Recordings { "recordings" => recordings, });

#[derive(Clone, Debug, Default)]
pub struct Resource {
    pub resource: String,
}
lenient_deserialize!(Resource { "resource" => resource, });

#[derive(Clone, Debug, Default)]
pub struct Relation {
    pub url: Resource,
}
lenient_deserialize!(Relation { "url" => url, });

#[derive(Clone, Debug, Default)]
pub struct Relations {
    pub relations: Option<Vec<Relation>>,
}
lenient_deserialize!(Relations { "relations" => relations, });

#[derive(Clone, Debug, Default)]
pub struct Created {
    pub full_url: String,
    pub title: String,
    pub artist: String,
}
lenient_deserialize!(Created { "full_url" => full_url, "title" => title, "artist" => artist, });

#[derive(Clone, Debug, Default)]
pub struct PageData {
    pub title: String,
    pub artist: String,
    pub services: Map<Option<Link>>,
}
lenient_deserialize!(PageData { "title" => title, "artist" => artist, "services" => services, });

#[derive(Clone, Debug, Default)]
pub struct Page {
    pub data: PageData,
}
lenient_deserialize!(Page { "data" => data, });

/// The platform resolver uses Go's broader metadata artist matcher, rather
/// than the stricter primary-artist equality required for lyrics searches.
pub fn artists_match(expected: &str, found: &str) -> bool {
    let first = normalize_loose_artist(expected);
    let second = normalize_loose_artist(found);
    if first.contains(&second) || second.contains(&first) {
        return true;
    }
    let split = |value: &str| {
        let mut value = crate::matching::lowercase(value);
        for separator in [
            " feat. ", " feat ", " ft. ", " ft ", " & ", " and ", ",", ";", " x ",
        ] {
            value = value.replace(separator, "|");
        }
        value
            .split('|')
            .map(normalize_loose_artist)
            .filter(|v| !v.is_empty())
            .collect::<Vec<_>>()
    };
    for first in split(expected) {
        for second in split(found) {
            if first.contains(&second) || second.contains(&first) {
                return true;
            }
            let mut first: Vec<_> = first.split_whitespace().collect();
            let mut second: Vec<_> = second.split_whitespace().collect();
            first.sort_unstable();
            second.sort_unstable();
            if first == second {
                return true;
            }
        }
    }
    let latin = |value: &str| {
        !value.chars().any(|ch| {
            matches!(ch as u32,
        0x4e00..=0x9fff | 0x3040..=0x309f | 0x30a0..=0x30ff |
        0xac00..=0xd7af | 0x0600..=0x06ff | 0x0400..=0x04ff)
        })
    };
    latin(expected) != latin(found)
}

/// Album/title matching used by Go's metadata enrichment policy.
pub fn titles_match(expected: &str, found: &str) -> bool {
    use crate::lyrics::matching::normalize_title;
    use crate::matching::lowercase;
    let (expected, found) = (lowercase(expected.trim()), lowercase(found.trim()));
    let contains = |a: &str, b: &str| a.contains(b) || b.contains(a);
    if contains(&expected, &found) {
        return true;
    }
    let clean = |value: &str| {
        let mut value = value.to_owned();
        let versions = [
            "remaster",
            "remastered",
            "deluxe",
            "bonus",
            "single",
            "album version",
            "radio edit",
            "original mix",
            "extended",
            "club mix",
            "remix",
            "live",
            "acoustic",
            "demo",
        ];
        for (open, close) in [('(', ')'), ('[', ']')] {
            while let (Some(start), Some(end)) = (value.rfind(open), value.rfind(close)) {
                if end <= start
                    || !versions
                        .iter()
                        .any(|word| value[start + 1..end].contains(word))
                {
                    break;
                }
                value = format!("{}{}", value[..start].trim(), &value[end + 1..]);
            }
        }
        for suffix in [
            " - remaster",
            " - remastered",
            " - single version",
            " - radio edit",
            " - live",
            " - acoustic",
            " - demo",
            " - remix",
        ] {
            if value.ends_with(suffix) {
                value.truncate(value.len() - suffix.len());
            }
        }
        while value.contains("  ") {
            value = value.replace("  ", " ");
        }
        value.trim().to_owned()
    };
    let (a, b) = (clean(&expected), clean(&found));
    if a == b || (!a.is_empty() && !b.is_empty() && contains(&a, &b)) {
        return true;
    }
    let core = |value: &str| {
        let end = [value.find('('), value.find('['), value.find(" - ")]
            .into_iter()
            .flatten()
            .filter(|index| *index > 0)
            .min()
            .unwrap_or(value.len());
        value[..end].trim().to_owned()
    };
    let (a, b) = (core(&expected), core(&found));
    if !a.is_empty() && a == b {
        return true;
    }
    let (a, b) = (normalize_title(&expected), normalize_title(&found));
    if !a.is_empty() && !b.is_empty() && contains(&a, &b) {
        return true;
    }
    let symbols = |value: &str| {
        use unicode_general_category::{GeneralCategory::*, get_general_category};
        value
            .chars()
            .filter(|ch| {
                !ch.is_alphanumeric()
                    && !ch.is_whitespace()
                    && !matches!(
                        get_general_category(*ch),
                        ConnectorPunctuation
                            | DashPunctuation
                            | OpenPunctuation
                            | ClosePunctuation
                            | InitialPunctuation
                            | FinalPunctuation
                            | OtherPunctuation
                            | NonspacingMark
                            | SpacingMark
                            | EnclosingMark
                    )
            })
            .collect::<String>()
    };
    if !expected.chars().any(char::is_alphanumeric) || !found.chars().any(char::is_alphanumeric) {
        let a = symbols(&expected);
        return !a.is_empty() && a == symbols(&found);
    }
    false
}

pub fn track_identity_title(value: &str) -> String {
    crate::lyrics::matching::normalize_title(&track_title_without_annotations(value))
}

fn track_title_without_annotations(value: &str) -> std::borrow::Cow<'_, str> {
    static ANNOTATION: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r#"(?i)[(\[][\t\n\f\r ]*(?:(feat\.?|ft\.?|featuring|with)[\t\n\f\r ]+[^)\]]+|from[\t\n\f\r ]+["“][^)\]]+["”][\t\n\f\r ]*)[)\]]"#).unwrap()
    });
    static VERSION: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"(?i)\b(?:mix|remix|live|acoustic|demo|instrumental|karaoke|edit|extended|slowed|sped)\b").unwrap()
    });
    ANNOTATION.replace_all(value, |captures: &regex::Captures<'_>| {
        if captures
            .get(1)
            .is_some_and(|credit| credit.as_str().eq_ignore_ascii_case("with"))
            && VERSION.is_match(&captures[0])
        {
            captures[0].to_owned()
        } else {
            " ".to_owned()
        }
    })
}

pub fn track_titles_match(expected: &str, found: &str) -> bool {
    let (expected, found) = (
        track_title_without_annotations(expected),
        track_title_without_annotations(found),
    );
    let (a, b) = (
        crate::lyrics::matching::normalize_title(&expected),
        crate::lyrics::matching::normalize_title(&found),
    );
    if !a.is_empty() && a == b {
        return true;
    }
    if a.split_whitespace()
        .chain(b.split_whitespace())
        .any(|word| {
            matches!(
                word,
                "mix"
                    | "remix"
                    | "live"
                    | "acoustic"
                    | "demo"
                    | "instrumental"
                    | "karaoke"
                    | "edit"
                    | "extended"
                    | "slowed"
                    | "sped"
            )
        })
    {
        return false;
    }
    titles_match(&expected, &found)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contributor_annotations_keep_the_recording_identity() {
        assert_eq!(
            track_identity_title("Signal (with Guest Artist)"),
            track_identity_title("Signal")
        );
        assert!(track_titles_match("Signal (with Guest Artist)", "Signal"));
        for version in ["[Live]", "(Club Mix)", "(Acoustic)"] {
            assert!(!track_titles_match(
                &format!("Signal (with Guest Artist) {version}"),
                "Signal"
            ));
        }
        assert!(!track_titles_match("Signal (with Live Band)", "Signal"));
    }

    #[test]
    fn repeated_maps_merge_but_null_resets_and_nested_structs_retain_fields() {
        let payload: UniTune = crate::lyrics::decode_document(br#"{"linksByPlatform":{"a":{"url":"first"}},"LINKSBYPLATFORM":{"b":{"URL":"second","url":null}},"unused":1e400}"#).unwrap();
        assert_eq!(payload.links.0.len(), 2);
        assert_eq!(payload.links.0["b"].url, "second");
        let payload: Page = crate::lyrics::decode_response(br#"{"data":{"title":"Title","services":{"a":{"url":"old"}}},"data":{"services":null},"data":{"artist":"Artist","services":{"b":null}}}; ignored"#).unwrap();
        assert_eq!(payload.data.title, "Title");
        assert_eq!(payload.data.artist, "Artist");
        assert_eq!(payload.data.services.0.len(), 1);
        assert!(payload.data.services.0["b"].is_none());
    }
}
