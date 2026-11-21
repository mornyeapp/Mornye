use crate::cancellation::RequestLease;
use crate::manager::{ExtensionManager, ExtensionManagerError};
use mornye_extensions::backend::LyricsRequest as CoreRequest;
use std::sync::Arc;

#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct LyricsRequest {
    pub spotify_id: String,
    pub track: String,
    pub artist: String,
    pub file_path: String,
    pub duration_ms: i64,
}

impl From<LyricsRequest> for CoreRequest {
    fn from(request: LyricsRequest) -> Self {
        Self {
            spotify_id: request.spotify_id,
            track: request.track,
            artist: request.artist,
            file_path: request.file_path,
            duration_ms: request.duration_ms,
        }
    }
}

fn check(lease: &Option<Arc<RequestLease>>) -> Result<(), String> {
    lease.as_ref().map_or(Ok(()), |lease| {
        lease
            .inner
            .check_active()
            .map_err(|error| error.to_string())
    })
}

/// Lyrics use the installed manager's root/cache. Native file access shares
/// environment grants; the caller retains platform access through this call.
#[cfg_attr(feature = "uniffi", uniffi::export)]
impl ExtensionManager {
    pub fn embed_lyrics_to_file(
        &self,
        path: String,
        lyrics: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .embed_lyrics_to_file(&path, &lyrics, &|| check(&lease))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn get_lyrics_lrc(
        &self,
        request: LyricsRequest,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .get_lyrics_lrc(&request.into(), &|| check(&lease))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn get_lyrics_lrc_with_source(
        &self,
        request: LyricsRequest,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .get_lyrics_lrc_with_source(&request.into(), &|| check(&lease))
            .map_err(ExtensionManagerError::Operation)
    }

    /// One enabled provider's lyrics, for choosing between providers.
    pub fn get_lyrics_from_provider(
        &self,
        provider: String,
        request: LyricsRequest,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .get_lyrics_from_provider(&provider, &request.into(), &|| check(&lease))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn get_enabled_lyrics_providers_json(&self) -> Result<String, ExtensionManagerError> {
        self.inner
            .get_enabled_lyrics_providers_json()
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn fetch_and_save_lyrics(
        &self,
        request: LyricsRequest,
        output_path: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<(), ExtensionManagerError> {
        self.inner
            .fetch_and_save_lyrics(&request.into(), &output_path, &|| check(&lease))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn set_lyrics_providers_json(
        &self,
        providers_json: String,
    ) -> Result<(), ExtensionManagerError> {
        self.inner
            .set_lyrics_providers_json(&providers_json)
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn set_lyrics_fetch_options_json(
        &self,
        options_json: String,
    ) -> Result<(), ExtensionManagerError> {
        self.inner
            .set_lyrics_fetch_options_json(&options_json)
            .map_err(ExtensionManagerError::Operation)
    }
}
