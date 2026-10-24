//! The OpenSubsonic surface (contract section 4). Owned by unit L1b. The
//! server core authenticates first, then calls [`handle`]; it answers
//! authentication failures with [`error_response`].

use crate::types::{HttpResponse, Shared, SubsonicRequest, respond};

/// Answers one authenticated Subsonic call.
pub async fn handle(shared: &Shared, request: SubsonicRequest) -> HttpResponse {
    let _ = shared;
    error_response(&request.params, 0, "not implemented")
}

/// A Subsonic error response (`code` 0, 10, 40, 44, 70, ...), formatted per
/// the request's `f` parameter (JSON or XML).
pub fn error_response(params: &[(String, String)], code: u32, message: &str) -> HttpResponse {
    let _ = (params, code, message);
    respond(200, "text/plain", "not implemented")
}
