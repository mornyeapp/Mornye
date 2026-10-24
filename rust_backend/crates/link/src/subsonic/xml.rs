//! Subsonic XML from the JSON response shape: objects become elements,
//! scalar fields become attributes, a scalar `value` field becomes the text
//! content (genres, lyrics), arrays become repeated elements and nulls are
//! omitted.

use serde_json::{Map, Value};

pub(super) const NAMESPACE: &str = "http://subsonic.org/restapi";

/// A complete document with `root` in the Subsonic namespace.
pub(super) fn document(root: &str, body: &Map<String, Value>) -> String {
    let mut out = String::with_capacity(256);
    out.push_str(r#"<?xml version="1.0" encoding="UTF-8"?>"#);
    object(&mut out, root, body, Some(NAMESPACE));
    out
}

fn element(out: &mut String, name: &str, value: &Value) {
    match value {
        Value::Null => {}
        Value::Object(map) => object(out, name, map, None),
        Value::Array(items) => {
            for item in items {
                element(out, name, item);
            }
        }
        scalar => {
            out.push('<');
            out.push_str(name);
            out.push('>');
            escape(out, &scalar_text(scalar), false);
            out.push_str("</");
            out.push_str(name);
            out.push('>');
        }
    }
}

fn object(out: &mut String, name: &str, map: &Map<String, Value>, namespace: Option<&str>) {
    out.push('<');
    out.push_str(name);
    if let Some(namespace) = namespace {
        out.push_str(" xmlns=\"");
        out.push_str(namespace);
        out.push('"');
    }
    let mut text = None;
    let mut children = false;
    for (key, value) in map {
        match value {
            Value::Null => {}
            Value::Object(_) | Value::Array(_) => children = true,
            scalar if key == "value" => text = Some(scalar_text(scalar)),
            scalar => {
                out.push(' ');
                out.push_str(key);
                out.push_str("=\"");
                escape(out, &scalar_text(scalar), true);
                out.push('"');
            }
        }
    }
    if text.is_none() && !children {
        out.push_str("/>");
        return;
    }
    out.push('>');
    if let Some(text) = text {
        escape(out, &text, false);
    }
    for (key, value) in map {
        if matches!(value, Value::Object(_) | Value::Array(_)) {
            element(out, key, value);
        }
    }
    out.push_str("</");
    out.push_str(name);
    out.push('>');
}

fn scalar_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Bool(flag) => flag.to_string(),
        Value::Number(number) => number.to_string(),
        _ => String::new(),
    }
}

/// Escapes markup characters and drops characters XML 1.0 cannot carry.
fn escape(out: &mut String, text: &str, attribute: bool) {
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' if attribute => out.push_str("&quot;"),
            '\'' if attribute => out.push_str("&apos;"),
            '\t' if attribute => out.push_str("&#9;"),
            '\n' if attribute => out.push_str("&#10;"),
            '\r' => out.push_str("&#13;"),
            '\t' | '\n' => out.push(c),
            c if (c as u32) < 0x20 || c == '\u{FFFE}' || c == '\u{FFFF}' => {}
            c => out.push(c),
        }
    }
}
