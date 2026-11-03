//! Model reply validation on the data worker, with the Dart parser's wire contract.
use crate::native_library::path_keys::dart_trim;
use regex::Regex;
use serde::de::{DeserializeOwned, MapAccess, Visitor};
use serde::{Deserialize, Deserializer};
use serde_json::{Value, json, value::RawValue};
use std::{
    collections::{HashMap, HashSet},
    fmt,
    sync::LazyLock,
};

static THOUGHTS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<think>.*?</think>").unwrap());
static FENCE: LazyLock<Regex> = LazyLock::new(|| {
    let whitespace = r"[\t\n\v\f\r \u{00a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}]";
    Regex::new(&format!(
        r"(?s)^```[a-zA-Z0-9_-]*{whitespace}*\n?(.*?)\n?```{whitespace}*$"
    ))
    .unwrap()
});

// Dart retains insertion order when selecting the first array of an object.
// Duplicate keys replace the value without moving the original position.
struct OrderedObject(Vec<(String, Box<RawValue>)>);

impl OrderedObject {
    fn get(&self, name: &str) -> Option<&RawValue> {
        self.0
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.as_ref())
    }

    fn read<T: DeserializeOwned>(&self, name: &str) -> Option<T> {
        serde_json::from_str(self.get(name)?.get()).ok()
    }
}

impl<'de> Deserialize<'de> for OrderedObject {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct ObjectVisitor;
        impl<'de> Visitor<'de> for ObjectVisitor {
            type Value = OrderedObject;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a JSON object")
            }

            fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Self::Value, M::Error> {
                let mut fields: Vec<(String, Box<RawValue>)> = Vec::new();
                let mut positions = HashMap::<String, usize>::new();
                while let Some((key, value)) = map.next_entry::<String, Box<RawValue>>()? {
                    if let Some(&index) = positions.get(&key) {
                        fields[index].1 = value;
                    } else {
                        positions.insert(key.clone(), fields.len());
                        fields.push((key, value));
                    }
                }
                Ok(OrderedObject(fields))
            }
        }
        deserializer.deserialize_map(ObjectVisitor)
    }
}

pub(crate) fn execute(
    request: &Value,
    bytes: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    check()?;
    let reply = match bytes.filter(|bytes| !bytes.is_empty()) {
        Some(bytes) => std::str::from_utf8(bytes).map_err(|error| error.to_string())?,
        None => request["reply"].as_str().unwrap_or_default(),
    };
    let ids = request["ids"]
        .as_array()
        .ok_or("Missing native translation field: ids")?
        .iter()
        .map(|id| id.as_i64().ok_or("Invalid native translation id"))
        .collect::<Result<HashSet<_>, _>>()?;
    let stripped = THOUGHTS.replace_all(dart_trim(reply), "");
    let text = dart_trim(&stripped);
    let fence = FENCE.captures(text);
    let text = fence
        .as_ref()
        .map_or(text, |capture| dart_trim(capture.get(1).unwrap().as_str()));
    check()?;
    let decoded = serde_json::from_str::<Box<RawValue>>(text).ok();
    let decoded = match decoded.filter(|value| value.get() != "null") {
        Some(value) => Some(value),
        None => match (text.find(['[', '{']), text.rfind([']', '}'])) {
            (Some(start), Some(end)) if end > start => {
                serde_json::from_str::<Box<RawValue>>(&text[start..=end]).ok()
            }
            _ => None,
        },
    };
    let entries = decoded.and_then(|value| reply_entries(&value));
    let Some(entries) = entries else {
        return Ok(json!({"error": "badResponse", "detail": "reply is not a JSON list"}));
    };
    let mut seen = HashSet::new();
    let mut lines = Vec::new();
    for entry in entries {
        check()?;
        let Ok(entry) = serde_json::from_str::<OrderedObject>(entry.get()) else {
            continue;
        };
        let Some(id) = entry.read::<Value>("id").as_ref().and_then(reply_id) else {
            continue;
        };
        let text = entry
            .get("text")
            .filter(|value| value.get() != "null")
            .or_else(|| entry.get("translation"))
            .and_then(|value| serde_json::from_str::<String>(value.get()).ok());
        let Some(text) = text
            .as_deref()
            .map(dart_trim)
            .filter(|text| !text.is_empty())
        else {
            continue;
        };
        if !ids.contains(&id) || !seen.insert(id) {
            continue;
        }
        let reading = entry.read::<String>("romanization");
        let romanization = reading
            .as_deref()
            .map(dart_trim)
            .filter(|text| !text.is_empty());
        lines.push(json!({
            "id": id,
            "text": text,
            "romanization": romanization,
            "alignment": chunks(entry.get("alignment"), text, check)?.unwrap_or_default(),
            "romanizationAlignment": chunks(
                entry.get("romanizationAlignment"), romanization.unwrap_or_default(), check
            )?.unwrap_or_default(),
        }));
    }
    check()?;
    Ok(json!({"lines": lines}))
}

fn reply_entries(value: &RawValue) -> Option<Vec<Box<RawValue>>> {
    let raw = value.get();
    if raw.starts_with('[') {
        return serde_json::from_str(raw).ok();
    }
    let OrderedObject(fields) = serde_json::from_str(raw).ok()?;
    let selected = ["lines", "translations"]
        .into_iter()
        .find_map(|name| {
            fields
                .iter()
                .find(|(key, value)| key == name && value.get() != "null")
                .map(|(_, value)| value)
        })
        .or_else(|| {
            fields
                .iter()
                .find(|(_, value)| value.get().starts_with('['))
                .map(|(_, value)| value)
        })?;
    serde_json::from_str(selected.get()).ok()
}

fn reply_id(value: &Value) -> Option<i64> {
    match value {
        Value::Number(number) => number
            .as_i64()
            .or_else(|| number.as_f64().map(|value| value as i64)),
        Value::String(value) => {
            let value = dart_trim(value);
            let (negative, digits) = if let Some(digits) = value.strip_prefix('-') {
                (true, digits)
            } else {
                (false, value.strip_prefix('+').unwrap_or(value))
            };
            if let Some(hex) = digits
                .strip_prefix("0x")
                .or_else(|| digits.strip_prefix("0X"))
            {
                if !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                    return None;
                }
                let unsigned = u64::from_str_radix(hex, 16).ok()?;
                let signed = unsigned as i64;
                Some(if negative {
                    signed.wrapping_neg()
                } else {
                    signed
                })
            } else {
                value.parse().ok()
            }
        }
        _ => None,
    }
}

fn chunks(
    value: Option<&RawValue>,
    text: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<Vec<Value>>, String> {
    let Some(value) = value.filter(|value| value.get() != "null") else {
        return Ok(Some(Vec::new()));
    };
    let Some(values) = serde_json::from_str::<Vec<Box<RawValue>>>(value.get())
        .ok()
        .filter(|values| values.len() <= 256)
    else {
        return Ok(None);
    };
    let mut previous = 0;
    let mut length = 0;
    let mut joined = String::new();
    let mut chunks = Vec::with_capacity(values.len());
    for value in &values {
        check()?;
        let (part, source) = match value.get().as_bytes().first() {
            Some(b'[') => {
                let Ok(pair) = serde_json::from_str::<Vec<Box<RawValue>>>(value.get()) else {
                    return Ok(None);
                };
                if pair.len() != 2 {
                    return Ok(None);
                }
                (
                    serde_json::from_str::<String>(pair[1].get()).ok(),
                    serde_json::from_str::<i64>(pair[0].get()).ok(),
                )
            }
            Some(b'{') => {
                let Ok(map) = serde_json::from_str::<OrderedObject>(value.get()) else {
                    return Ok(None);
                };
                (map.read::<String>("text"), map.read::<i64>("source"))
            }
            _ => return Ok(None),
        };
        let (Some(part), Some(source)) = (part, source) else {
            return Ok(None);
        };
        if part.is_empty() || source < previous || source >= 512 {
            return Ok(None);
        }
        length += part.encode_utf16().count();
        if length > 4000 {
            return Ok(None);
        }
        joined.push_str(&part);
        chunks.push(json!({"text": part, "source": source}));
        previous = source;
    }
    if !chunks.is_empty() && joined != text {
        return Ok(None);
    }
    Ok(Some(chunks))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn parse(reply: &str, ids: &[i64]) -> Value {
        execute(&json!({"reply": reply, "ids": ids}), None, &|| Ok(())).unwrap()
    }

    fn line(id: i64, text: &str) -> Value {
        json!({
            "id": id, "text": text, "romanization": null,
            "alignment": [], "romanizationAlignment": [],
        })
    }

    #[test]
    fn accepts_reply_wrappers_and_string_ids() {
        for reply in [
            r#"{"lines":[{"id":"0","text":" Uno "}]}"#,
            r#"[{"id":0,"translation":" Uno "}]"#,
            "```json\n[{\"id\":0,\"text\":\"Uno\"}]\n```",
            "<think>one\ntwo</think>Here: {\"translations\":[{\"id\":0,\"text\":\"Uno\"}]}",
        ] {
            assert_eq!(parse(reply, &[0]), json!({"lines": [line(0, "Uno")]}));
        }
    }

    #[test]
    fn first_non_null_named_list_precedes_insertion_order_fallback() {
        assert_eq!(
            parse(
                r#"{"z":[{"id":1,"text":"first"}],"a":[{"id":0,"text":"last"}]}"#,
                &[0, 1]
            ),
            json!({"lines": [line(1, "first")]})
        );
        assert_eq!(
            parse(
                r#"{"z":[],"z":[{"id":1,"text":"first"}],"a":[{"id":0,"text":"last"}]}"#,
                &[0, 1]
            ),
            json!({"lines": [line(1, "first")]})
        );
        assert_eq!(
            parse(
                r#"{"lines":null,"z":[],"translations":[{"id":0,"text":"named"}]}"#,
                &[0]
            ),
            json!({"lines": [line(0, "named")]})
        );
        assert!(
            parse(r#"{"lines":false,"translations":[]}"#, &[0])
                .get("error")
                .is_some()
        );
    }

    #[test]
    fn drops_invalid_unknown_blank_and_duplicate_lines() {
        let reply = r#"[null,[],{"id":0,"text":" "},{"id":0,"text":"first"},{"id":0,"text":"second"},{"id":9,"text":"unknown"},{"text":"missing"},{"id":1,"text":false,"translation":"ignored"},{"id":2,"text":null,"translation":"fallback"}]"#;
        assert_eq!(
            parse(reply, &[0, 1, 2]),
            json!({"lines": [line(0, "first"), line(2, "fallback")]})
        );
    }

    #[test]
    fn preserves_response_order_and_numeric_id_semantics() {
        let reply = r#"[{"id":2.9,"text":"two"},{"id":" +0x1 ","text":"one"},{"id":-0.9,"text":"zero"},{"id":"-1","text":"negative"},{"id":true,"text":"ignored"}]"#;
        assert_eq!(
            parse(reply, &[-1, 0, 1, 2]),
            json!({"lines": [line(2, "two"), line(1, "one"), line(0, "zero"), line(-1, "negative")]})
        );
        assert_eq!(reply_id(&json!("0xffffffffffffffff")), Some(-1));
        assert_eq!(reply_id(&json!("9223372036854775808")), None);
        assert_eq!(reply_id(&json!(1e40)), Some(i64::MAX));
        assert_eq!(reply_id(&json!(-1e40)), Some(i64::MIN));
        assert_eq!(reply_id(&json!("1.0")), None);
        assert_eq!(reply_id(&json!("0x+1")), None);
    }

    #[test]
    fn trims_dart_whitespace_including_bom_and_next_line_control() {
        let reply = "\u{feff} [{\"id\":0,\"text\":\"\\ufefftext\\ufeff\",\"romanization\":\"  read  \"},{\"id\":1,\"text\":\"\\u0085kept\\u0085\"}] \u{feff}";
        let mut expected = line(0, "text");
        expected["romanization"] = json!("read");
        assert_eq!(
            parse(reply, &[0, 1]),
            json!({"lines": [expected, line(1, "kept")]})
        );
    }

    #[test]
    fn preserves_valid_phrase_and_romanization_alignment() {
        let reply = r#"[{"id":0,"text":" A B ","romanization":" read it ","alignment":[[0,"A "],{"source":0,"text":"B"}],"romanizationAlignment":[[0,"read "],[511,"it"]]}]"#;
        let expected = json!({"id": 0, "text": "A B", "romanization": "read it", "alignment": [{"source":0,"text":"A "},{"source":0,"text":"B"}], "romanizationAlignment": [{"source":0,"text":"read "},{"source":511,"text":"it"}]});
        assert_eq!(parse(reply, &[0]), json!({"lines":[expected]}));
    }

    #[test]
    fn invalid_alignment_preserves_translated_text() {
        for alignment in [
            json!(false),
            json!({}),
            json!([[0, "wrong"]]),
            json!([[0.0, "text"]]),
            json!([["0", "text"]]),
            json!([[-1, "text"]]),
            json!([[512, "text"]]),
            json!([[0, ""]]),
            json!([[1, "te"], [0, "xt"]]),
            json!([[0, "text", "extra"]]),
        ] {
            let reply = json!([{"id":0,"text":"text","alignment":alignment}]).to_string();
            assert_eq!(parse(&reply, &[0]), json!({"lines":[line(0, "text")]}));
        }
    }

    #[test]
    fn alignment_limits_count_utf16_units_and_chunks() {
        let check = || Ok(());
        let at_limit = "😀".repeat(2000);
        let valid = RawValue::from_string(json!([[0, at_limit]]).to_string()).unwrap();
        assert!(chunks(Some(&valid), &at_limit, &check).unwrap().is_some());
        let too_long = "😀".repeat(2001);
        let invalid = RawValue::from_string(json!([[0, too_long]]).to_string()).unwrap();
        assert!(chunks(Some(&invalid), &too_long, &check).unwrap().is_none());
        for count in [256, 257] {
            let value = Value::Array((0..count).map(|_| json!([0, "a"])).collect());
            let value = RawValue::from_string(value.to_string()).unwrap();
            assert_eq!(
                chunks(Some(&value), &"a".repeat(count), &check)
                    .unwrap()
                    .is_some(),
                count == 256
            );
        }
    }

    #[test]
    fn shared_dart_fixtures_match_native_contract() {
        let fixtures: Vec<Value> = serde_json::from_str(include_str!(
            "../../../../test/fixtures/native_lyrics_translation_replies.json"
        ))
        .unwrap();
        for fixture in fixtures {
            assert_eq!(
                execute(&fixture["request"], None, &|| Ok(())).unwrap(),
                fixture["expected"],
                "{}",
                fixture["name"]
            );
        }
    }

    #[test]
    fn deeply_nested_unknown_fields_do_not_discard_usable_lines() {
        let nested = format!("{}null{}", "[".repeat(200), "]".repeat(200));
        let reply = format!(
            r#"{{"ignored":{nested},"lines":[{{"id":0,"text":"kept","extra":{nested},"alignment":[{{"source":0,"text":"kept","extra":{nested}}}]}}]}}"#
        );
        let mut expected = line(0, "kept");
        expected["alignment"] = json!([{"source":0,"text":"kept"}]);
        assert_eq!(parse(&reply, &[0]), json!({"lines":[expected]}));
    }

    #[test]
    fn invalid_documents_return_typed_bad_response() {
        for reply in [
            "",
            "Sorry, I cannot.",
            "null",
            "42",
            "{}",
            r#"{"lines":"none"}"#,
            "[{broken}]",
        ] {
            assert_eq!(
                parse(reply, &[0]),
                json!({"error":"badResponse", "detail":"reply is not a JSON list"})
            );
        }
        assert_eq!(parse("[]", &[0]), json!({"lines":[]}));
    }

    #[test]
    fn bytes_take_precedence_and_invalid_utf8_is_an_error() {
        let request = json!({"ids":[0], "reply":"not a list"});
        assert_eq!(
            execute(&request, Some(b"[]"), &|| Ok(())).unwrap(),
            json!({"lines":[]})
        );
        assert!(execute(&request, Some(&[0xff]), &|| Ok(())).is_err());
        assert!(execute(&json!({}), None, &|| Ok(())).is_err());
    }

    #[test]
    fn cancellation_interrupts_validation_without_a_partial_result() {
        let calls = Cell::new(0);
        let request =
            json!({"reply": r#"[{"id":0,"text":"one"},{"id":1,"text":"two"}]"#, "ids":[0,1]});
        let result = execute(&request, None, &|| {
            calls.set(calls.get() + 1);
            if calls.get() == 4 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        });
        assert_eq!(result.unwrap_err(), "cancelled");
    }
}
