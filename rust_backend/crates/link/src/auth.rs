//! Request authentication (contract section 3). Every device owns one API
//! key. Subsonic accepts it as `apiKey`, as the password of a salted token
//! (`u` + `t` + `s`), or as a plain or `enc:` hex password (`u` + `p`); any
//! username is accepted when the key matches. `/mornye/v1` and the WebSocket
//! take `Authorization: Bearer <key>`.

use crate::store::{DeviceRecord, Store};
use crate::types::param;
use md5::Md5;
use sha2::Digest;

/// Subsonic error 10: a required parameter is missing.
pub(crate) const MISSING: (u32, &str) = (10, "Required parameter is missing");
/// Subsonic error 40: wrong username or password.
pub(crate) const WRONG_CREDENTIALS: (u32, &str) = (40, "Wrong username or password");
/// Subsonic error 44: invalid API key.
pub(crate) const INVALID_KEY: (u32, &str) = (44, "Invalid API key");

/// The device behind a Subsonic request, or the Subsonic error to answer.
pub(crate) fn subsonic(
    store: &Store,
    params: &[(String, String)],
) -> Result<DeviceRecord, (u32, &'static str)> {
    if let Some(key) = param(params, "apiKey") {
        return by_key(store, key).ok_or(INVALID_KEY);
    }
    if let (Some(token), Some(salt)) = (param(params, "t"), param(params, "s")) {
        let token = token.to_ascii_lowercase();
        return store
            .find(|key| {
                let expected = hex(&Md5::digest(format!("{key}{salt}").as_bytes()));
                constant_time_eq(expected.as_bytes(), token.as_bytes())
            })
            .ok_or(WRONG_CREDENTIALS);
    }
    if let Some(password) = param(params, "p") {
        let password = match password.strip_prefix("enc:") {
            Some(encoded) => decode_hex(encoded)
                .and_then(|bytes| String::from_utf8(bytes).ok())
                .ok_or(WRONG_CREDENTIALS)?,
            None => password.to_owned(),
        };
        return by_key(store, &password).ok_or(WRONG_CREDENTIALS);
    }
    Err(MISSING)
}

/// The device behind `Authorization: Bearer <key>`.
pub(crate) fn bearer(store: &Store, headers: &http::HeaderMap) -> Option<DeviceRecord> {
    let value = headers.get(http::header::AUTHORIZATION)?.to_str().ok()?;
    let (scheme, key) = value.trim().split_once(' ')?;
    if !scheme.eq_ignore_ascii_case("bearer") {
        return None;
    }
    by_key(store, key.trim())
}

fn by_key(store: &Store, candidate: &str) -> Option<DeviceRecord> {
    if candidate.is_empty() {
        return None;
    }
    store.find(|key| constant_time_eq(key.as_bytes(), candidate.as_bytes()))
}

/// Compares without an early exit on the first differing byte.
pub(crate) fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0u8, |diff, (a, b)| diff | (a ^ b))
        == 0
}

/// Lowercase hex.
pub(crate) fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push(DIGITS[usize::from(byte >> 4)] as char);
        text.push(DIGITS[usize::from(byte & 0x0f)] as char);
    }
    text
}

fn decode_hex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(text.get(index..index + 2)?, 16).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect()
    }

    #[test]
    fn accepts_every_subsonic_scheme() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let record = store.upsert("phone", "Phone", "android", false).unwrap();
        let key = record.api_key.as_str();
        let token = hex(&Md5::digest(format!("{key}abc").as_bytes()));
        let encoded = format!("enc:{}", hex(key.as_bytes()));
        for pairs in [
            params(&[("apiKey", key)]),
            params(&[("u", "anyone"), ("t", &token), ("s", "abc")]),
            params(&[("u", "x"), ("t", &token.to_ascii_uppercase()), ("s", "abc")]),
            params(&[("u", "anyone"), ("p", key)]),
            params(&[("u", "anyone"), ("p", &encoded)]),
        ] {
            assert_eq!(subsonic(&store, &pairs).unwrap().device_id, "phone");
        }
        assert_eq!(
            subsonic(&store, &params(&[("apiKey", "nope")]))
                .unwrap_err()
                .0,
            44
        );
        assert_eq!(
            subsonic(&store, &params(&[("u", "a"), ("t", &token), ("s", "x")]))
                .unwrap_err()
                .0,
            40
        );
        assert_eq!(
            subsonic(&store, &params(&[("u", "a"), ("p", "enc:zz")]))
                .unwrap_err()
                .0,
            40
        );
        assert_eq!(subsonic(&store, &params(&[("u", "a")])).unwrap_err().0, 10);
    }

    #[test]
    fn reads_bearer_keys() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let record = store.upsert("phone", "Phone", "ios", false).unwrap();
        let mut headers = http::HeaderMap::new();
        assert!(bearer(&store, &headers).is_none());
        headers.insert(
            http::header::AUTHORIZATION,
            format!("Bearer {}", record.api_key).parse().unwrap(),
        );
        assert_eq!(bearer(&store, &headers), Some(record));
        headers.insert(http::header::AUTHORIZATION, "Bearer x".parse().unwrap());
        assert!(bearer(&store, &headers).is_none());
    }
}
