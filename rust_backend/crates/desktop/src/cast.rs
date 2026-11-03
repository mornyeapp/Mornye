//! Google Cast on desktop: `castCall {"method","args"}` runs a
//! `mornye_cast::CastService` method, whose events become the inbound calls
//! `castStatus` and `castDevices`. The service starts on first use.

use crate::call::{Args, CallError, CallResult, Reply};
use std::sync::OnceLock;

#[derive(Default)]
pub(crate) struct Cast {
    service: OnceLock<Result<mornye_cast::CastService, String>>,
}

impl Cast {
    pub(crate) fn call(&self, args: &Args) -> CallResult {
        let service = self
            .service
            .get_or_init(|| {
                mornye_cast::CastService::new(crate::runtime::inbound)
                    .map_err(|error| format!("Google Cast is unavailable: {error}"))
            })
            .as_ref()
            .map_err(CallError::failure)?;
        let method = args
            .opt_string("method")
            .ok_or_else(|| CallError::invalid_arguments("castCall needs a method"))?;
        let arguments = args.value().get("args").cloned().unwrap_or_default();
        service
            .call(method, &arguments)
            .map(Reply::from)
            .map_err(CallError::failure)
    }
}
