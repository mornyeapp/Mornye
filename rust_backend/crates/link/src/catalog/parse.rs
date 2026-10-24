//! NDJSON export lines (contract section 5). Fields are lenient: unknown
//! keys are ignored, nulls and values of the wrong type read as absent, and
//! numbers may arrive as strings.

use serde::{Deserialize, Deserializer};
use serde_json::Value;

/// The export format this reader understands.
const CATALOG_VERSION: u64 = 1;

/// Line 1 of the export.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Header {
    pub(super) generated_ms: i64,
    pub(super) count: usize,
}

pub(super) fn header(line: &[u8]) -> Result<Header, String> {
    let value: Value = serde_json::from_slice(line)
        .map_err(|error| format!("catalog header is not valid JSON: {error}"))?;
    let object = value
        .as_object()
        .ok_or("catalog header must be a JSON object")?;
    match object.get("catalogVersion").and_then(Value::as_u64) {
        Some(CATALOG_VERSION) => {}
        Some(other) => return Err(format!("unsupported catalog version {other}")),
        None => return Err("catalog header has no catalogVersion".to_owned()),
    }
    Ok(Header {
        generated_ms: object
            .get("generatedMs")
            .and_then(Value::as_i64)
            .unwrap_or(0),
        count: object
            .get("count")
            .and_then(Value::as_u64)
            .and_then(|count| usize::try_from(count).ok())
            .unwrap_or(0),
    })
}

/// One song line before validation.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(super) struct Row {
    #[serde(deserialize_with = "text")]
    pub(super) id: Option<String>,
    #[serde(deserialize_with = "text")]
    pub(super) title: Option<String>,
    #[serde(deserialize_with = "text")]
    pub(super) artist: Option<String>,
    #[serde(deserialize_with = "text")]
    pub(super) album_artist: Option<String>,
    #[serde(deserialize_with = "text")]
    pub(super) album: Option<String>,
    #[serde(deserialize_with = "text")]
    pub(super) album_key: Option<String>,
    #[serde(deserialize_with = "integer")]
    pub(super) track: Option<i64>,
    #[serde(deserialize_with = "integer")]
    pub(super) disc: Option<i64>,
    #[serde(deserialize_with = "integer")]
    pub(super) year: Option<i64>,
    #[serde(deserialize_with = "text")]
    pub(super) genre: Option<String>,
    #[serde(deserialize_with = "integer")]
    pub(super) duration_ms: Option<i64>,
    #[serde(deserialize_with = "text")]
    pub(super) path: Option<String>,
    #[serde(deserialize_with = "integer")]
    pub(super) size: Option<i64>,
    #[serde(deserialize_with = "text")]
    pub(super) suffix: Option<String>,
    #[serde(deserialize_with = "integer")]
    pub(super) bit_rate: Option<i64>,
    #[serde(deserialize_with = "integer")]
    pub(super) sample_rate: Option<i64>,
    #[serde(deserialize_with = "integer")]
    pub(super) bit_depth: Option<i64>,
    #[serde(deserialize_with = "integer")]
    pub(super) channels: Option<i64>,
    #[serde(deserialize_with = "text")]
    pub(super) isrc: Option<String>,
    #[serde(deserialize_with = "text")]
    pub(super) match_key: Option<String>,
    #[serde(deserialize_with = "text")]
    pub(super) cover_path: Option<String>,
    #[serde(deserialize_with = "integer")]
    pub(super) added_ms: Option<i64>,
    #[serde(deserialize_with = "decimal")]
    pub(super) track_gain: Option<f64>,
    #[serde(deserialize_with = "decimal")]
    pub(super) album_gain: Option<f64>,
    #[serde(deserialize_with = "decimal")]
    pub(super) track_peak: Option<f64>,
    #[serde(deserialize_with = "decimal")]
    pub(super) album_peak: Option<f64>,
    #[serde(deserialize_with = "flag")]
    pub(super) explicit: Option<bool>,
}

pub(super) fn row(line: &[u8]) -> Option<Row> {
    serde_json::from_slice(line).ok()
}

/// A string (numbers are rendered); anything else is absent. Kept as sent:
/// required fields may legitimately be empty strings.
fn text<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<String>, D::Error> {
    Ok(match Value::deserialize(deserializer)? {
        Value::String(text) => Some(text),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    })
}

/// An integer, from a number (fractions truncate) or a numeric string.
fn integer<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<i64>, D::Error> {
    Ok(match Value::deserialize(deserializer)? {
        Value::Number(number) => number.as_i64().or_else(|| {
            number
                .as_f64()
                .filter(|value| value.is_finite() && value.abs() < 9.0e15)
                .map(|value| value.trunc() as i64)
        }),
        Value::String(text) => {
            let text = text.trim();
            text.parse::<i64>().ok().or_else(|| {
                text.parse::<f64>()
                    .ok()
                    .filter(|value| value.is_finite() && value.abs() < 9.0e15)
                    .map(|value| value.trunc() as i64)
            })
        }
        _ => None,
    })
}

/// A finite number, from a number or a string such as `-4.2 dB`.
fn decimal<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<f64>, D::Error> {
    Ok(match Value::deserialize(deserializer)? {
        Value::Number(number) => number.as_f64(),
        Value::String(text) => {
            let text = text.trim();
            let text = text
                .strip_suffix("dB")
                .or_else(|| text.strip_suffix("db"))
                .unwrap_or(text);
            text.trim().parse::<f64>().ok()
        }
        _ => None,
    }
    .filter(|value| value.is_finite()))
}

/// A boolean, also from `0`/`1` and `"true"`/`"explicit"`.
fn flag<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<bool>, D::Error> {
    Ok(match Value::deserialize(deserializer)? {
        Value::Bool(value) => Some(value),
        Value::Number(number) => number.as_f64().map(|value| value != 0.0),
        Value::String(text) => match text.trim().to_ascii_lowercase().as_str() {
            "true" | "1" | "yes" | "explicit" => Some(true),
            "false" | "0" | "no" | "clean" | "" => Some(false),
            _ => None,
        },
        _ => None,
    })
}
