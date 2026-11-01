//! Pure directory-listing parser. Transport and credentials remain owned by
//! the platform; only a bounded response body enters this worker operation.
use scraper::{Html, Selector};
use serde_json::{Value, json};
use std::collections::HashMap;
use url::Url;

pub(crate) fn execute(request: &Value, bytes: Option<&[u8]>) -> Result<Value, String> {
    if bytes.map_or_else(
        || request["body"].as_str().unwrap_or_default().len(),
        <[u8]>::len,
    ) > 4 * 1024 * 1024
    {
        return Err("Directory listing is too large".into());
    }
    let body = match bytes {
        Some(bytes) => String::from_utf8_lossy(bytes).into_owned(),
        None => request["body"].as_str().unwrap_or_default().to_owned(),
    };
    let target = Url::parse(required(request, "base_url")?).map_err(|e| e.to_string())?;
    let path = required(request, "path")?;
    let mut base = target;
    if !base.path().ends_with('/') {
        base.set_path(&format!("{}/", base.path()));
    }
    let base_segments = decoded_segments(&base)?;
    let webdav = request["protocol"] == "webdav";
    let document = if webdav {
        mornye_core::xml::check_depth(&body)?;
        let document = roxmltree::Document::parse(&body).map_err(|e| e.to_string())?;
        if !named(document.root_element(), "multistatus") {
            return Err("Server did not return a WebDAV directory listing".into());
        }
        Some(document)
    } else {
        None
    };
    let advertised_origin = document
        .as_ref()
        .and_then(|document| dav_collection_origin(document, &base, &base_segments));
    let mut entries = Vec::<Value>::new();
    let mut positions = HashMap::<String, usize>::new();
    let mut add = |href: &str,
                   directory: bool,
                   size: Option<i64>,
                   modified_time: Option<i64>,
                   etag: Option<String>|
     -> Result<(), String> {
        let uri = base.join(&dart_href(href)).map_err(|e| e.to_string())?;
        // A tunnel can expose a different host from the DAV collection href.
        // Only child paths leave this parser; transport keeps the saved origin.
        let same_server = uri.origin() == base.origin()
            || (webdav
                && matches!(uri.scheme(), "http" | "https")
                && (uri.host() == base.host()
                    || advertised_origin.as_ref() == Some(&uri.origin())));
        if !same_server
            || uri.query().is_some()
            || uri.fragment().is_some()
            || !uri.username().is_empty()
            || uri.password().is_some()
        {
            return Ok(());
        }
        // Match decoded components once. Equivalent URI spellings must not
        // hide a whole album; encoded separators must not escape the folder.
        let segments = decoded_segments(&uri)?;
        if segments.len() != base_segments.len() + 1
            || !segments.starts_with(&base_segments)
            || segments.iter().any(|segment| {
                segment.contains(['/', '\\', '\0']) || matches!(segment.as_str(), "." | "..")
            })
        {
            return Ok(());
        }
        let name = segments.last().expect("one child component");
        if name.is_empty() {
            return Ok(());
        }
        let relative = format!("{path}{name}{}", if directory { "/" } else { "" });
        let mut entry =
            json!({"path": relative, "name": name, "directory": directory, "size": size});
        if let Some(modified_time) = modified_time {
            entry["modifiedTime"] = modified_time.into();
        }
        if let Some(etag) = etag {
            entry["etag"] = etag.into();
        }
        if let Some(index) = positions.get(&relative) {
            entries[*index] = entry;
        } else {
            positions.insert(relative, entries.len());
            entries.push(entry);
        }
        Ok(())
    };
    if let Some(document) = document {
        for response in document
            .descendants()
            .filter(|node| named(*node, "response"))
        {
            let href = response.descendants().find(|node| named(*node, "href"));
            let props: Vec<_> = successful_properties(response).collect();
            if let Some(href) = href.filter(|_| !props.is_empty()) {
                let values: Vec<_> = props
                    .iter()
                    .flat_map(|node| node.descendants().skip(1))
                    .collect();
                let directory = values.iter().any(|node| named(*node, "collection"));
                let size = values
                    .iter()
                    .find(|node| named(**node, "getcontentlength"))
                    .and_then(|node| inner_text(*node).trim().parse::<i64>().ok());
                let modified_time = values
                    .iter()
                    .find(|node| named(**node, "getlastmodified"))
                    .and_then(|node| {
                        chrono::DateTime::parse_from_rfc2822(inner_text(*node).trim()).ok()
                    })
                    .map(|date| date.timestamp_millis());
                let etag = values
                    .iter()
                    .find(|node| named(**node, "getetag"))
                    .map(|node| inner_text(*node).trim().to_owned());
                add(&inner_text(href), directory, size, modified_time, etag)?;
            }
        }
    } else {
        let document = Html::parse_document(&body);
        let selector = Selector::parse("a[href]").map_err(|e| e.to_string())?;
        for anchor in document.select(&selector) {
            let href = anchor.value().attr("href").unwrap_or_default();
            let path = href.split(['?', '#']).next().unwrap_or_default();
            let directory = path.ends_with('/') || path.ends_with('\\');
            add(href, directory, None, None, None)?;
        }
    }
    entries.sort_by(|a, b| {
        b["directory"]
            .as_bool()
            .cmp(&a["directory"].as_bool())
            .then_with(|| {
                // Dart String.compareTo orders UTF-16 code units, rather than UTF-8.
                dart_lower(a["name"].as_str().unwrap_or_default())
                    .encode_utf16()
                    .cmp(dart_lower(b["name"].as_str().unwrap_or_default()).encode_utf16())
            })
    });
    Ok(json!({"entries": entries}))
}

fn dart_lower(value: &str) -> String {
    // String.toLowerCase uses simple character mappings (İ -> i), without
    // Rust's multi-character expansions or contextual final sigma.
    value
        .chars()
        .map(|ch| ch.to_lowercase().next().unwrap_or(ch))
        .collect()
}

fn required<'a>(request: &'a Value, key: &str) -> Result<&'a str, String> {
    request[key]
        .as_str()
        .ok_or_else(|| format!("Missing listing {key}"))
}

fn dart_href(href: &str) -> String {
    // Uri.resolve preserves edge spaces/controls and quotes invalid '%' as
    // a literal. WHATWG URL otherwise trims controls and keeps broken escapes.
    let mut result = String::with_capacity(href.len());
    let bytes = href.as_bytes();
    for (index, character) in href.char_indices() {
        if character == '%'
            && !(bytes.get(index + 1).is_some_and(u8::is_ascii_hexdigit)
                && bytes.get(index + 2).is_some_and(u8::is_ascii_hexdigit))
        {
            result.push_str("%25");
        } else if character <= ' ' || character == '\u{007f}' {
            result.push_str(&format!("%{:02X}", character as u32));
        } else {
            result.push(character);
        }
    }
    result
}

fn named(node: roxmltree::Node<'_, '_>, name: &str) -> bool {
    node.is_element() && node.tag_name().name() == name
}

fn successful_properties<'a, 'input>(
    response: roxmltree::Node<'a, 'input>,
) -> impl Iterator<Item = roxmltree::Node<'a, 'input>> {
    response.descendants().filter(|node| {
        named(*node, "propstat")
            && node
                .children()
                .any(|child| named(child, "status") && successful_status(&inner_text(child)))
    })
}

fn dav_collection_origin(
    document: &roxmltree::Document<'_>,
    base: &Url,
    base_segments: &[String],
) -> Option<url::Origin> {
    let mut origin = None;
    for response in document
        .descendants()
        .filter(|node| named(*node, "response"))
    {
        let Some(href) = response.descendants().find(|node| named(*node, "href")) else {
            continue;
        };
        let Ok(uri) = base.join(&dart_href(&inner_text(href))) else {
            continue;
        };
        if !matches!(uri.scheme(), "http" | "https")
            || uri.query().is_some()
            || uri.fragment().is_some()
            || !uri.username().is_empty()
            || uri.password().is_some()
            || decoded_segments(&uri).ok().as_deref() != Some(base_segments)
            || !successful_properties(response)
                .flat_map(|prop| prop.descendants())
                .any(|node| named(node, "collection"))
        {
            continue;
        }
        let next = uri.origin();
        if origin.as_ref().is_some_and(|origin| *origin != next) {
            return None;
        }
        origin = Some(next);
    }
    origin
}

fn successful_status(value: &str) -> bool {
    let mut parts = value.split_whitespace();
    parts
        .next()
        .and_then(|version| version.strip_prefix("HTTP/"))
        .is_some_and(|version| !version.is_empty())
        && parts.next() == Some("200")
}

fn inner_text(node: roxmltree::Node<'_, '_>) -> String {
    node.descendants()
        .filter(|node| node.is_text())
        .filter_map(|node| node.text())
        .collect()
}

fn decoded_segments(uri: &Url) -> Result<Vec<String>, String> {
    let mut segments = uri
        .path_segments()
        .ok_or("Invalid listing path")?
        .map(decode_component)
        .collect::<Result<Vec<_>, _>>()?;
    if segments.last().is_some_and(String::is_empty) {
        segments.pop();
    }
    Ok(segments)
}

fn decode_component(value: &str) -> Result<String, String> {
    let mut decoded = Vec::with_capacity(value.len());
    let mut bytes = value.bytes();
    while let Some(byte) = bytes.next() {
        if byte == b'%' {
            let first = bytes.next().and_then(hex).ok_or("Invalid percent escape")?;
            let second = bytes.next().and_then(hex).ok_or("Invalid percent escape")?;
            decoded.push(first * 16 + second);
        } else {
            decoded.push(byte);
        }
    }
    String::from_utf8(decoded).map_err(|e| e.to_string())
}

fn hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_dart_listing_fixtures_match_native_output() {
        let cases: Value = serde_json::from_str(include_str!(
            "../../../../test/fixtures/native_metadata_parsers.json"
        ))
        .unwrap();
        for case in cases["listings"].as_array().unwrap() {
            let result = execute(case, None).unwrap();
            assert_eq!(result["entries"], case["entries"]);
        }
    }

    #[test]
    fn html_children_entities_unicode_and_origin_are_preserved() {
        let result = execute(&json!({"base_url":"https://nas.test/music/", "path":"", "protocol":"http", "body":
            "<a href='../'>parent</a><a href='Folder/'>folder</a><a href='A%20%2B%23%25.flac'>audio</a><a href='音.flac'>music</a><a href='nested/song.flac'>nested</a><a href='https://other.test/music/b.flac'>other</a><a href='bad.flac?q=1'>query</a><a href='A%20%2B%23%25.flac'>duplicate</a>"}), None).unwrap();
        assert_eq!(result["entries"].as_array().unwrap().len(), 3);
        assert_eq!(result["entries"][0]["path"], "Folder/");
        assert_eq!(result["entries"][1]["name"], "A +#%.flac");
        assert_eq!(result["entries"][2]["name"], "音.flac");
    }

    #[test]
    fn dav_only_accepts_successful_properties_and_immediate_children() {
        let result = execute(&json!({"base_url":"https://nas.test/dav/Album/", "path":"Album/", "protocol":"webdav", "body":
            "<d:multistatus xmlns:d='DAV:'><d:response><d:href>/dav/Album/A%20B.flac</d:href><d:propstat><d:prop><d:getcontentlength>123</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response><d:response><d:href>/dav/Album/Missing.flac</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response></d:multistatus>"}), None).unwrap();
        assert_eq!(
            result["entries"],
            json!([{"path":"Album/A B.flac", "name":"A B.flac", "directory":false, "size":123}])
        );
    }

    #[test]
    fn dav_retains_successful_validators_and_tolerates_invalid_dates() {
        for date in ["Mon, 19 Oct 2026 12:00:00 GMT", "invalid", ""] {
            let body = format!(
                "<d:multistatus xmlns:d='DAV:'><d:response><d:href>/dav/song.flac</d:href>\
                 <d:propstat><d:prop><d:getcontentlength>123</d:getcontentlength>\
                 <d:getlastmodified>{date}</d:getlastmodified><d:getetag>&quot;one&quot;</d:getetag>\
                 </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>\
                 <d:propstat><d:prop><d:getetag>invalid</d:getetag></d:prop>\
                 <d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response></d:multistatus>"
            );
            let result = execute(
                &json!({"base_url":"https://nas.test/dav/", "path":"", "protocol":"webdav", "body":body}),
                None,
            )
            .unwrap();
            let entry = &result["entries"][0];
            assert_eq!(entry["etag"], "\"one\"");
            if date.starts_with("Mon") {
                assert_eq!(entry["modifiedTime"], 1792411200000_i64);
            } else {
                assert!(entry["modifiedTime"].is_null());
            }
        }
    }

    #[test]
    fn encoded_slash_and_credentials_do_not_escape_the_root() {
        let result = execute(&json!({"base_url":"https://nas.test/music/", "path":"", "protocol":"http", "body":
            "<a href='a%2fb.flac'>nested</a><a href='https://user@nas.test/music/private.flac'>credentials</a><a href='ok.flac#part'>fragment</a>"}), None).unwrap();
        assert_eq!(result["entries"], json!([]));
    }

    #[test]
    fn deeply_nested_dav_response_is_rejected_before_xml_tokenization() {
        let body = format!(
            "<multistatus>{}ignored{}</multistatus>",
            "<wrapper>".repeat(1_000),
            "</wrapper>".repeat(1_000),
        );
        let error = execute(&json!({"base_url":"https://nas.test/dav/", "path":"", "protocol":"webdav", "body":body}), None).unwrap_err();
        assert_eq!(error, "XML nesting exceeds 16 elements");
    }

    #[test]
    fn non_dav_documents_are_not_empty_dav_directories() {
        let error = execute(
            &json!({"base_url":"http://nas.test/dav/", "path":"", "protocol":"webdav",
                "body":"<html><body>Please sign in</body></html>"}),
            None,
        )
        .unwrap_err();
        assert_eq!(error, "Server did not return a WebDAV directory listing");
    }
}
