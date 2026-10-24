//! The OpenSubsonic surface (contract section 4). Owned by unit L1b. The
//! server core authenticates first, then calls [`handle`]; it answers
//! authentication failures with [`error_response`].
//!
//! Responses are built as JSON values, then rendered as OpenSubsonic JSON
//! (`f=json`; `f=jsonp` is answered as plain JSON) or as Subsonic XML (the
//! default) by a generic converter.

mod browse;
mod covers;
mod forward;
mod media;
mod objects;
#[cfg(test)]
mod tests;
mod xml;

use crate::catalog::Catalog;
use crate::types::{HttpResponse, Shared, SubsonicRequest, param, respond};
use serde_json::{Map, Value, json};
use std::str::FromStr;

/// The Subsonic API version this server implements.
pub(crate) const API_VERSION: &str = "1.16.1";
/// OpenSubsonic `type`.
pub(crate) const SERVER_TYPE: &str = "mornye";
/// Largest page any list endpoint returns.
pub(crate) const MAX_PAGE: usize = 500;

const JSON_TYPE: &str = "application/json; charset=utf-8";
const XML_TYPE: &str = "text/xml; charset=utf-8";

/// Subsonic error codes used by this server.
pub(crate) mod code {
    pub(crate) const GENERIC: u32 = 0;
    pub(crate) const MISSING_PARAMETER: u32 = 10;
    pub(crate) const NOT_FOUND: u32 = 70;
}

/// Fields merged into `subsonic-response` on success.
pub(crate) type Payload = Map<String, Value>;

/// A failed call: the Subsonic error and the HTTP status that carries it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Failure {
    pub(crate) code: u32,
    pub(crate) message: String,
    pub(crate) status: u16,
}

impl Failure {
    pub(crate) fn new(code: u32, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            status: 200,
        }
    }

    pub(crate) fn missing(name: &str) -> Self {
        Self::new(
            code::MISSING_PARAMETER,
            format!("Required parameter is missing: {name}"),
        )
    }

    pub(crate) fn not_found(what: &str) -> Self {
        Self::new(code::NOT_FOUND, format!("{what} not found"))
    }

    /// Binary endpoints answer missing media with HTTP 404.
    pub(crate) fn with_status(mut self, status: u16) -> Self {
        self.status = status;
        self
    }
}

/// The response format a request asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Format {
    Json,
    Xml,
}

impl Format {
    pub(crate) fn of(params: &[(String, String)]) -> Self {
        match param(params, "f").map(str::trim) {
            Some(format)
                if format.eq_ignore_ascii_case("json") || format.eq_ignore_ascii_case("jsonp") =>
            {
                Self::Json
            }
            _ => Self::Xml,
        }
    }
}

/// Answers one authenticated Subsonic call.
pub async fn handle(shared: &Shared, request: SubsonicRequest) -> HttpResponse {
    let format = Format::of(&request.params);
    let version = shared.config.app_version.as_str();
    let catalog = shared.catalog();
    let binary = match request.method.as_str() {
        "stream" => media::stream(shared, &catalog, &request).await,
        "download" => media::download(&catalog, &request).await,
        "getCoverArt" => covers::cover_art(shared, &catalog, &request).await,
        method => {
            let outcome = if forward::handles(method) {
                forward::call(shared, &catalog, &request).await
            } else {
                dispatch(shared, &catalog, &request).await
            };
            return render(format, version, outcome);
        }
    };
    binary.unwrap_or_else(|failure| render(format, version, Err(failure)))
}

/// A Subsonic error response (`code` 0, 10, 40, 44, 70, ...), formatted per
/// the request's `f` parameter (JSON or XML). Without server state its
/// `serverVersion` is this crate's version.
pub fn error_response(params: &[(String, String)], code: u32, message: &str) -> HttpResponse {
    render(
        Format::of(params),
        env!("CARGO_PKG_VERSION"),
        Err(Failure::new(code, message)),
    )
}

async fn dispatch(
    shared: &Shared,
    catalog: &Catalog,
    request: &SubsonicRequest,
) -> Result<Payload, Failure> {
    match request.method.as_str() {
        "ping" => Ok(Payload::new()),
        "getLicense" => Ok(payload("license", json!({ "valid": true }))),
        "getOpenSubsonicExtensions" => Ok(payload(
            "openSubsonicExtensions",
            json!([
                { "name": "apiKeyAuthentication", "versions": [1] },
                { "name": "formPost", "versions": [1] },
            ]),
        )),
        "getMusicFolders" => Ok(payload(
            "musicFolders",
            json!({ "musicFolder": [{ "id": 1, "name": "Music" }] }),
        )),
        "getUser" => Ok(browse::user(request)),
        "getIndexes" => Ok(browse::indexes(catalog)),
        "getArtists" => Ok(browse::artists(catalog)),
        "getArtist" => browse::artist(catalog, request),
        "getAlbum" => browse::album(catalog, request),
        "getSong" => browse::song(catalog, request),
        "getMusicDirectory" => browse::directory(catalog, request),
        "getAlbumList" => browse::album_list(shared, catalog, request, false).await,
        "getAlbumList2" => browse::album_list(shared, catalog, request, true).await,
        "getRandomSongs" => browse::random_songs(catalog, request),
        "getGenres" => Ok(browse::genres(catalog)),
        "getSongsByGenre" => browse::songs_by_genre(catalog, request),
        "search2" => Ok(browse::search(catalog, request, false)),
        "search3" => Ok(browse::search(catalog, request, true)),
        _ => Err(Failure::new(code::GENERIC, "not implemented")),
    }
}

/// A payload with one field.
pub(crate) fn payload(key: &str, value: Value) -> Payload {
    let mut payload = Payload::new();
    payload.insert(key.to_owned(), value);
    payload
}

/// Renders the OpenSubsonic envelope around `outcome`.
fn render(format: Format, server_version: &str, outcome: Result<Payload, Failure>) -> HttpResponse {
    let mut body = Map::new();
    let status = if outcome.is_ok() { "ok" } else { "failed" };
    body.insert("status".to_owned(), status.into());
    body.insert("version".to_owned(), API_VERSION.into());
    body.insert("type".to_owned(), SERVER_TYPE.into());
    body.insert("serverVersion".to_owned(), server_version.into());
    body.insert("openSubsonic".to_owned(), true.into());
    let http_status = match outcome {
        Ok(payload) => {
            body.extend(payload);
            200
        }
        Err(failure) => {
            body.insert(
                "error".to_owned(),
                json!({ "code": failure.code, "message": failure.message }),
            );
            failure.status
        }
    };
    match format {
        Format::Json => respond(
            http_status,
            JSON_TYPE,
            json!({ "subsonic-response": body }).to_string(),
        ),
        Format::Xml => respond(
            http_status,
            XML_TYPE,
            xml::document("subsonic-response", &body),
        ),
    }
}

/// A non-empty parameter, else error 10.
pub(crate) fn required<'a>(request: &'a SubsonicRequest, name: &str) -> Result<&'a str, Failure> {
    request
        .param(name)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| Failure::missing(name))
}

/// A parsed parameter; absent or unparsable values read as `None`.
pub(crate) fn number<T: FromStr>(request: &SubsonicRequest, name: &str) -> Option<T> {
    request.param(name)?.trim().parse().ok()
}

/// A page size: `default` when absent, capped at [`MAX_PAGE`].
pub(crate) fn page_size(request: &SubsonicRequest, name: &str, default: usize) -> usize {
    number::<i64>(request, name)
        .map_or(default, |size| usize::try_from(size.max(0)).unwrap_or(0))
        .min(MAX_PAGE)
}

/// A page offset, 0 when absent or negative.
pub(crate) fn page_offset(request: &SubsonicRequest, name: &str) -> usize {
    number::<i64>(request, name).map_or(0, |offset| usize::try_from(offset.max(0)).unwrap_or(0))
}

/// A boolean parameter (`true`/`false`, `1`/`0`).
pub(crate) fn flag(request: &SubsonicRequest, name: &str) -> Option<bool> {
    match request.param(name)?.trim().to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" => Some(true),
        "false" | "0" | "no" => Some(false),
        _ => None,
    }
}
