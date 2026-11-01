//! Text forms used for identity keys, sorting and search.

use sha2::{Digest, Sha256};
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

/// The identity form of a name: NFKC, lowercase, whitespace runs collapsed
/// to one space, trimmed. Artist ids and fallback album keys hash this form,
/// so changing it changes every derived id.
pub(crate) fn normalize(text: &str) -> String {
    if text.is_ascii() {
        return collapse(text.chars().map(|c| c.to_ascii_lowercase()));
    }
    collapse(text.nfkc().flat_map(char::to_lowercase))
}

/// The search and sort form: [`normalize`] with diacritics removed (NFKD
/// without combining marks), so `Beyoncé` matches `beyonce`.
pub(crate) fn fold(text: &str) -> String {
    if text.is_ascii() {
        return collapse(text.chars().map(|c| c.to_ascii_lowercase()));
    }
    collapse(
        text.nfkd()
            .filter(|c| !is_combining_mark(*c))
            .flat_map(char::to_lowercase),
    )
}

fn collapse(chars: impl Iterator<Item = char>) -> String {
    let mut out = String::new();
    let mut space = false;
    for c in chars {
        if c.is_whitespace() || c.is_control() {
            space = !out.is_empty();
        } else {
            if space {
                out.push(' ');
                space = false;
            }
            out.push(c);
        }
    }
    out
}

/// `prefix` followed by the first 16 hex characters of SHA-256(`key`).
pub(crate) fn short_id(prefix: &str, key: &str) -> String {
    let digest = Sha256::digest(key.as_bytes());
    format!("{prefix}{}", hex(&digest[..8]))
}

/// Lowercase hex of `bytes`.
pub(crate) fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(char::from(HEX[usize::from(byte >> 4)]));
        out.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    out
}

const HEX: &[u8; 16] = b"0123456789abcdef";

/// Search terms: the folded query split on whitespace. An empty query, `""`
/// (Symfonium's full sync) and `*` match everything.
pub(crate) fn search_terms(query: &str) -> Vec<String> {
    let trimmed = query.trim();
    let unquoted = trimmed
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
        .unwrap_or(trimmed);
    let folded = fold(unquoted);
    folded
        .split(' ')
        .map(|term| term.trim_matches('*'))
        .filter(|term| !term.is_empty())
        .map(str::to_owned)
        .collect()
}

/// True when every term occurs in `haystack`.
pub(crate) fn matches(haystack: &str, terms: &[String]) -> bool {
    terms.iter().all(|term| haystack.contains(term.as_str()))
}
