//! Physical/converted path identities shared with Dart's path_match_keys.dart.
//! Opaque SAF document identities decode once and preserve case and extension.
use base64::{Engine, engine::general_purpose::URL_SAFE};
use std::collections::{BTreeSet, VecDeque};
use url::Url;

const ALIASES: &[&str] = &[
    "/storage/emulated/0",
    "/storage/emulated/legacy",
    "/storage/self/primary",
    "/sdcard",
    "/mnt/sdcard",
];
const EXTENSIONS: &[&str] = &[
    ".flac", ".m4a", ".mp3", ".opus", ".ogg", ".wav", ".aiff", ".aif", ".aac",
];

/// Dart's `String.trim` set: Unicode White_Space plus the U+FEFF BOM.
pub(crate) fn dart_whitespace(ch: char) -> bool {
    ch.is_whitespace() || ch == '\u{feff}'
}

pub(crate) fn dart_trim(value: &str) -> &str {
    value.trim_matches(dart_whitespace)
}

/// Dart applies Unicode simple casing, without multi-character expansions or
/// the final-sigma context rules of Rust's full string lowercase operation.
pub(crate) fn dart_lower(value: &str) -> String {
    value
        .chars()
        .map(|ch| ch.to_lowercase().next().unwrap_or(ch))
        .collect()
}

pub(crate) fn dart_upper(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            let mut upper = ch.to_uppercase();
            let first = upper.next().unwrap_or(ch);
            if upper.next().is_some() { ch } else { first }
        })
        .collect()
}

pub(crate) fn regex_whitespace(ch: char) -> bool {
    matches!(ch,'\u{0009}'..='\u{000d}'|'\u{0020}'|'\u{00a0}'|'\u{1680}'|'\u{2000}'..='\u{200a}'|'\u{2028}'|'\u{2029}'|'\u{202f}'|'\u{205f}'|'\u{3000}'|'\u{feff}')
}

fn decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let high = (*bytes.get(index + 1)? as char).to_digit(16)?;
            let low = (*bytes.get(index + 2)? as char).to_digit(16)?;
            decoded.push((high * 16 + low) as u8);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

fn dart_uri(value: &str) -> Result<Url, url::ParseError> {
    // Uri.parse escapes stray '%' before pathSegments decodes them. Keeping
    // them unescaped would lose opaque document identities with literal '%'.
    let mut sanitized = String::with_capacity(value.len());
    let bytes = value.as_bytes();
    for (index, ch) in value.char_indices() {
        if ch == '%'
            && !(bytes.get(index + 1).is_some_and(u8::is_ascii_hexdigit)
                && bytes.get(index + 2).is_some_and(u8::is_ascii_hexdigit))
        {
            sanitized.push_str("%25");
        } else {
            sanitized.push(ch);
        }
    }
    Url::parse(&sanitized)
}

fn segments(uri: &Url) -> Option<Vec<String>> {
    uri.path_segments()?.map(decode).collect()
}

fn document_key(uri: &Url) -> Option<String> {
    if uri.scheme() != "content" {
        return None;
    }
    let authority = &uri[url::Position::BeforeUsername..url::Position::AfterPort];
    if authority.is_empty() {
        return None;
    }
    let parts = segments(uri)?;
    let direct = parts.len() == 2 && parts[0] == "document";
    let tree =
        parts.len() == 4 && parts[0] == "tree" && !parts[1].is_empty() && parts[2] == "document";
    let id = parts.last()?;
    if !(direct || tree) || id.is_empty() {
        return None;
    }
    Some(format!(
        "saf-document:{}:{id}",
        URL_SAFE.encode(dart_lower(authority))
    ))
}

fn storage_documents(uri: &Url) -> Vec<String> {
    if uri.scheme() != "content"
        || !uri
            .host_str()
            .is_some_and(|host| host.eq_ignore_ascii_case("com.android.externalstorage.documents"))
    {
        return Vec::new();
    }
    let Some(parts) = segments(uri) else {
        return Vec::new();
    };
    let index = parts
        .iter()
        .rposition(|s| s == "document")
        .or_else(|| parts.iter().rposition(|s| s == "tree"));
    let Some(index) = index else {
        return Vec::new();
    };
    if index + 1 >= parts.len() {
        return Vec::new();
    }
    let joined = parts[index + 1..].join("/");
    let id = decode(&joined).unwrap_or(joined);
    let Some((volume, relative)) = id.split_once(':') else {
        return Vec::new();
    };
    if volume.to_lowercase() != "primary" {
        return Vec::new();
    }
    let relative = relative.replace('\\', "/");
    let relative = relative.trim_start_matches('/');
    ALIASES
        .iter()
        .map(|prefix| {
            if relative.is_empty() {
                (*prefix).into()
            } else {
                format!("{prefix}/{relative}")
            }
        })
        .collect()
}

fn android_aliases(value: &str) -> Vec<String> {
    let normalized = value.replace('\\', "/");
    let lower = dart_lower(&normalized);
    for prefix in ALIASES {
        if lower == *prefix || lower.starts_with(&format!("{prefix}/")) {
            let suffix = &normalized[prefix.len()..];
            return ALIASES
                .iter()
                .map(|alias| format!("{alias}{suffix}"))
                .collect();
        }
    }
    Vec::new()
}

fn uri_text(uri: &Url) -> String {
    // Dart canonicalizes percent escape hex and decodes unreserved ASCII in
    // Uri.parse. url::Url keeps original percent escapes for custom schemes.
    let mut uri = Url::parse(&uri.as_str().replace('\\', "/")).unwrap_or_else(|_| uri.clone());
    if let Some(host) = uri.host_str().map(dart_lower) {
        let _ = uri.set_host(Some(&host));
    }
    let bytes = uri.as_str().as_bytes();
    let mut output = String::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%'
            && index + 2 < bytes.len()
            && let (Some(high), Some(low)) = (
                (bytes[index + 1] as char).to_digit(16),
                (bytes[index + 2] as char).to_digit(16),
            )
        {
            let value = (high * 16 + low) as u8;
            if value.is_ascii_alphanumeric() || b"-._~".contains(&value) {
                output.push(value as char);
            } else {
                output.push_str(&format!("%{value:02X}"));
            }
            index += 3;
        } else {
            let tail = &uri.as_str()[index..];
            let ch = tail.chars().next().expect("URI character");
            output.push(ch);
            index += ch.len_utf8();
        }
    }
    output
}

pub(crate) fn build(path: &str, android: bool) -> Result<BTreeSet<String>, String> {
    let path = dart_trim(path);
    let cleaned = path.strip_prefix("EXISTS:").map(dart_trim).unwrap_or(path);
    if cleaned.is_empty() {
        return Ok(BTreeSet::new());
    }
    let mut keys = BTreeSet::new();
    let mut visited = BTreeSet::new();
    let mut pending = VecDeque::from([cleaned.to_string()]);
    if let Some(path) = mornye_core::windows_path_identity::identity(cleaned) {
        keys.insert(format!("windows-file:{path}"));
        pending.push_back(path);
    }
    if let Ok(uri) = dart_uri(cleaned)
        && let Some(key) = document_key(&uri)
    {
        keys.insert(key);
    }
    while let Some(value) = pending.pop_front() {
        let trimmed = dart_trim(&value);
        if trimmed.is_empty() || !visited.insert(trimmed.to_string()) {
            continue;
        }
        // A malicious string can recursively expose many percent-encoded
        // variants. The existing cache is bounded; keep the native walk bounded.
        if visited.len() > 1024 {
            return Err("Too many Library path aliases".into());
        }
        keys.insert(trimmed.to_string());
        keys.insert(dart_lower(trimmed));
        if trimmed.contains('\\') {
            pending.push_back(trimmed.replace('\\', "/"));
        }
        if trimmed.contains('%')
            && let Some(decoded) = decode(trimmed)
            && decoded != trimmed
        {
            pending.push_back(decoded);
        }
        if let Ok(uri) = dart_uri(trimmed) {
            // replace(query:null, fragment:null) in Dart retains existing fields.
            // Preserve that behavior; clearing them would change path identity.
            // WHATWG normalizes file://localhost to an empty host. Dart keeps
            // that authority and refuses toFilePath on Unix, so do not invent
            // a local filesystem alias for it.
            let localhost = trimmed
                .get(..16)
                .is_some_and(|v| v.eq_ignore_ascii_case("file://localhost"))
                && (trimmed.len() == 16
                    || trimmed
                        .get(16..17)
                        .is_some_and(|v| ["/", "?", "#"].contains(&v)));
            let text = if localhost {
                let alternate = format!("nativefile{}", &trimmed[4..]);
                let mut uri = dart_uri(&alternate).map_err(|e| e.to_string())?;
                if uri.path().is_empty() {
                    uri.set_path("/");
                }
                uri_text(&uri).replacen("nativefile:", "file:", 1)
            } else {
                uri_text(&uri)
            };
            keys.insert(text.clone());
            keys.insert(dart_lower(&text));
            if uri.scheme() == "file"
                && !localhost
                && uri.query().is_none()
                && uri.fragment().is_none()
                && let Ok(file) = uri.to_file_path()
            {
                pending.push_back(file.to_string_lossy().into_owned());
            }
            pending.extend(storage_documents(&uri));
        } else if trimmed.starts_with('/')
            && let Ok(uri) = Url::from_file_path(trimmed)
        {
            let text = uri_text(&uri);
            keys.insert(text.clone());
            keys.insert(dart_lower(&text));
        }
        if android {
            pending.extend(android_aliases(trimmed));
        }
    }
    let extensionless = keys
        .iter()
        .filter_map(|key| {
            if key.starts_with("windows-file:") {
                return None;
            }
            let lower = dart_lower(key);
            EXTENSIONS
                .iter()
                .find(|extension| lower.ends_with(**extension))
                .map(|extension| key[..key.len() - extension.len()].to_string())
                .filter(|stripped| !stripped.is_empty())
        })
        .collect::<Vec<_>>();
    keys.extend(extensionless);
    Ok(keys)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn windows_physical_keys_keep_extensions() {
        let plain = build(r"C:\Music\song.flac", false).unwrap();
        let extended = build(r"\\?\C:\Music\song.flac", false).unwrap();
        assert!(plain.contains("windows-file:C:/Music/song.flac"));
        assert!(extended.contains("windows-file:C:/Music/song.flac"));
        assert!(!extended.contains("windows-file:C:/Music/song"));
    }
    #[test]
    fn saf_document_aliases_keep_opaque_case_and_escape_identity() {
        let direct = build("content://nas.provider/document/Ab%252FC.flac", false).unwrap();
        let tree = build(
            "content://nas.provider/tree/root/document/Ab%252FC.flac",
            false,
        )
        .unwrap();
        let expected = format!(
            "saf-document:{}:Ab%2FC.flac",
            URL_SAFE.encode("nas.provider")
        );
        assert!(direct.contains(&expected));
        assert!(tree.contains(&expected));
        assert!(!direct.contains(&expected.replace("Ab%2FC", "ab%2fc")));
    }
    #[test]
    fn android_storage_and_converted_paths_share_keys() {
        let direct = build("/sdcard/Music/Café.flac", true).unwrap();
        let converted = build("/storage/emulated/0/Music/Café.opus", true).unwrap();
        let saf = build("content://com.android.externalstorage.documents/tree/primary%3AMusic/document/primary%3AMusic%2FCaf%C3%A9.flac",true).unwrap();
        assert!(
            direct
                .intersection(&converted)
                .any(|key| key == "/storage/emulated/0/Music/Café")
        );
        assert!(
            direct
                .intersection(&saf)
                .any(|key| key == "/storage/emulated/0/Music/Café.flac")
        );
    }

    fn previous_lyrics_whitespace(c: char) -> bool {
        matches!(
            c,
            '\t' | '\n'
                | '\u{000b}'
                | '\u{000c}'
                | '\r'
                | ' '
                | '\u{0085}'
                | '\u{00a0}'
                | '\u{1680}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202f}'
                | '\u{205f}'
                | '\u{3000}'
                | '\u{feff}'
        ) || ('\u{2000}'..='\u{200a}').contains(&c)
    }

    #[test]
    fn dart_whitespace_equals_previous_lyrics_set_for_every_scalar() {
        for c in (0..=char::MAX as u32).filter_map(char::from_u32) {
            assert_eq!(dart_whitespace(c), previous_lyrics_whitespace(c), "{c:?}");
        }
        for (input, expected) in [
            ("", ""),
            ("\u{feff}", ""),
            ("\u{feff} a b \u{3000}", "a b"),
            ("\u{0085}x\u{200a}", "x"),
            ("\u{200b}x\u{200b}", "\u{200b}x\u{200b}"),
            ("\u{180e}x", "\u{180e}x"),
            (
                "\t\n\u{000b}\u{000c}\r Caf\u{00e9} \u{1f3b5}\u{00a0}",
                "Caf\u{00e9} \u{1f3b5}",
            ),
        ] {
            assert_eq!(dart_trim(input), expected, "{input:?}");
            assert_eq!(
                dart_trim(input),
                input.trim_matches(previous_lyrics_whitespace),
                "{input:?}"
            );
        }
    }
}
