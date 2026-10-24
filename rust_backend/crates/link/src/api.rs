//! Request routing (contract sections 3, 4 and 6.1):
//! - `/rest/<method>` and `/rest/<method>.view`, GET or POST with a form body
//!   merged after the query: Subsonic authentication, then the Subsonic layer;
//! - `GET /mornye/v1/info` and `POST /mornye/v1/pair`, no authentication;
//! - `GET /mornye/v1/ws`, the WebSocket;
//! - any other `/mornye/v1/<op>`: Bearer authentication, then forwarded to
//!   the app as `linkRequest` with `_method` added to the arguments.

use crate::pairing::{PAIRED, PairError};
use crate::server::{MAX_BODY, State};
use crate::types::{HttpResponse, SubsonicRequest, json};
use crate::{auth, subsonic, ws};
use bytes::Bytes;
use http::{HeaderMap, Method, header};
use http_body_util::{BodyExt, LengthLimitError, Limited};
use hyper::body::Incoming;
use serde_json::{Map, Value, json as object};
use std::net::IpAddr;
use std::sync::Arc;

/// The longest accepted `deviceId` in a pairing request.
const MAX_DEVICE_ID: usize = 200;

/// Answers one request.
pub(crate) async fn route(
    state: &Arc<State>,
    peer: IpAddr,
    request: http::Request<Incoming>,
) -> HttpResponse {
    let path = request.uri().path().to_owned();
    if let Some(method) = path.strip_prefix("/rest/") {
        return rest(state, method, request).await;
    }
    let Some(op) = path.strip_prefix("/mornye/v1/") else {
        return not_found();
    };
    match op {
        "info" if request.method() == Method::GET => info(state),
        "pair" if request.method() == Method::POST => pair(state, peer, request).await,
        "ws" if request.method() == Method::GET => {
            match auth::bearer(&state.store, request.headers()) {
                Some(device) => ws::upgrade(state, device, request),
                None => unauthorized(),
            }
        }
        "info" | "pair" | "ws" => method_not_allowed(),
        _ => forward(state, op, request).await,
    }
}

async fn rest(state: &Arc<State>, method: &str, request: http::Request<Incoming>) -> HttpResponse {
    if method.contains('/') {
        return not_found();
    }
    if !matches!(*request.method(), Method::GET | Method::HEAD | Method::POST) {
        return method_not_allowed();
    }
    let method = method.strip_suffix(".view").unwrap_or(method).to_owned();
    let (parts, body) = request.into_parts();
    let mut params: Vec<(String, String)> = parts
        .uri
        .query()
        .map(|query| {
            url::form_urlencoded::parse(query.as_bytes())
                .into_owned()
                .collect()
        })
        .unwrap_or_default();
    if parts.method == Method::POST && is_form(&parts.headers) {
        match read_body(&parts.headers, body).await {
            Ok(bytes) => params.extend(url::form_urlencoded::parse(&bytes).into_owned()),
            Err(error) => return error.response(),
        }
    }
    match auth::subsonic(&state.store, &params) {
        Ok(record) => {
            state.store.touch(&record.device_id);
            let request = SubsonicRequest {
                method,
                params,
                headers: parts.headers,
                device: record.device(),
            };
            subsonic::handle(&state.shared, request).await
        }
        Err((code, message)) => subsonic::error_response(&params, code, message),
    }
}

/// `GET /mornye/v1/info`: what a phone checks before pairing.
fn info(state: &State) -> HttpResponse {
    json(
        200,
        &object!({
            "serverId": state.shared.server_id,
            "name": state.name(),
            "protocol": 1,
            "appVersion": state.shared.config.app_version,
            "fingerprint": state.fingerprint,
            "pairing": state.pairing.is_open(),
        }),
    )
}

/// `POST /mornye/v1/pair` `{"deviceId","name","platform","proof"}`.
async fn pair(state: &Arc<State>, peer: IpAddr, request: http::Request<Incoming>) -> HttpResponse {
    let (parts, body) = request.into_parts();
    let bytes = match read_body(&parts.headers, body).await {
        Ok(bytes) => bytes,
        Err(error) => return error.response(),
    };
    let Ok(body) = serde_json::from_slice::<Value>(&bytes) else {
        return invalid("The body must be a JSON object");
    };
    let text = |key: &str| {
        body.get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
    };
    let (Some(device_id), Some(proof)) = (text("deviceId"), text("proof")) else {
        return invalid("deviceId and proof are required");
    };
    if device_id.len() > MAX_DEVICE_ID {
        return invalid("deviceId is too long");
    }
    let name = text("name").unwrap_or(device_id);
    let platform = text("platform").unwrap_or("unknown");
    let (result, ended) = state
        .pairing
        .attempt(peer, &state.fingerprint, device_id, proof, || {
            state.store.upsert(device_id, name, platform, true)
        });
    if let Some(reason) = ended {
        if reason == PAIRED {
            state.shared.host.event(
                "linkPaired",
                object!({"deviceId": device_id, "name": name, "platform": platform}),
            );
        }
        state.emit_pairing_ended(reason);
    }
    match result {
        Ok(record) => json(
            200,
            &object!({
                "apiKey": record.api_key,
                "serverId": state.shared.server_id,
                "name": state.name(),
                "fingerprint": state.fingerprint,
            }),
        ),
        Err(PairError::RateLimited) => json(429, &object!({"error": "rate_limited"})),
        Err(PairError::Closed) => json(403, &object!({"error": "pairing_closed"})),
        Err(PairError::BadProof) => json(403, &object!({"error": "bad_proof"})),
        Err(PairError::Failed(message)) => {
            json(500, &object!({"error": "internal", "message": message}))
        }
    }
}

/// Any other `/mornye/v1/<op>`: forwarded to the app.
async fn forward(state: &Arc<State>, op: &str, request: http::Request<Incoming>) -> HttpResponse {
    let Some(record) = auth::bearer(&state.store, request.headers()) else {
        return unauthorized();
    };
    if op
        .split('/')
        .any(|segment| segment.is_empty() || segment == "." || segment == "..")
    {
        return not_found();
    }
    let (parts, body) = request.into_parts();
    let (mut args, method) = match parts.method {
        Method::GET => (query_map(parts.uri.query()), "GET"),
        Method::POST => {
            let bytes = match read_body(&parts.headers, body).await {
                Ok(bytes) => bytes,
                Err(error) => return error.response(),
            };
            if bytes.iter().all(u8::is_ascii_whitespace) {
                (Map::new(), "POST")
            } else {
                match serde_json::from_slice::<Value>(&bytes) {
                    Ok(Value::Object(map)) => (map, "POST"),
                    _ => return invalid("The body must be a JSON object"),
                }
            }
        }
        _ => return method_not_allowed(),
    };
    args.insert("_method".to_owned(), Value::from(method));
    state.store.touch(&record.device_id);
    match state
        .shared
        .host
        .request(op, &record.device_id, Value::Object(args))
        .await
    {
        Ok(reply) => json(200, &reply),
        Err(error) => json(
            error.http_status(),
            &object!({"error": error.code, "message": error.message}),
        ),
    }
}

/// The query as a JSON object of strings; a repeated key keeps its last
/// value.
fn query_map(query: Option<&str>) -> Map<String, Value> {
    query
        .map(|query| {
            url::form_urlencoded::parse(query.as_bytes())
                .into_owned()
                .map(|(key, value)| (key, Value::String(value)))
                .collect()
        })
        .unwrap_or_default()
}

fn is_form(headers: &HeaderMap) -> bool {
    headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .is_some_and(|value| {
            value
                .trim()
                .eq_ignore_ascii_case("application/x-www-form-urlencoded")
        })
}

/// Why a request body was refused.
enum BodyError {
    TooLarge,
    Unreadable,
}

impl BodyError {
    fn response(self) -> HttpResponse {
        match self {
            Self::TooLarge => json(413, &object!({"error": "too_large"})),
            Self::Unreadable => invalid("The body could not be read"),
        }
    }
}

/// The whole body, at most [`MAX_BODY`] bytes (413 beyond).
async fn read_body(headers: &HeaderMap, body: Incoming) -> Result<Bytes, BodyError> {
    let declared = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok());
    if declared.is_some_and(|length| length > MAX_BODY as u64) {
        return Err(BodyError::TooLarge);
    }
    match Limited::new(body, MAX_BODY).collect().await {
        Ok(collected) => Ok(collected.to_bytes()),
        Err(error) if error.downcast_ref::<LengthLimitError>().is_some() => {
            Err(BodyError::TooLarge)
        }
        Err(_) => Err(BodyError::Unreadable),
    }
}

fn unauthorized() -> HttpResponse {
    json(401, &object!({"error": "unauthorized"}))
}

fn not_found() -> HttpResponse {
    json(404, &object!({"error": "not_found"}))
}

fn method_not_allowed() -> HttpResponse {
    json(405, &object!({"error": "method_not_allowed"}))
}

fn invalid(message: &str) -> HttpResponse {
    json(400, &object!({"error": "invalid", "message": message}))
}
