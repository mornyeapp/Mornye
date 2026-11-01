use crate::cancellation::RequestLease;
use crate::manager::{ExtensionManager, ExtensionManagerError};
use std::sync::Arc;

fn check(lease: &Option<Arc<RequestLease>>) -> Result<(), String> {
    lease.as_ref().map_or(Ok(()), |lease| {
        lease
            .inner
            .check_active()
            .map_err(|error| error.to_string())
    })
}

/// Metadata, platform resolution and installed extensions share one root.
/// Run network operations on a native background thread and retain any lease.
#[uniffi::export]
impl ExtensionManager {
    pub fn handle_url_json(&self, url: String) -> Result<String, ExtensionManagerError> {
        self.inner
            .handle_url_json(&url)
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn custom_search_json(
        &self,
        extension_id: String,
        query: String,
        options_json: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .custom_search_json(
                &extension_id,
                &query,
                &options_json,
                lease.map(|lease| Arc::clone(&lease.inner)),
            )
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn get_extension_related_tracks_json(
        &self,
        extension_id: String,
        seeds_json: String,
        options_json: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .get_extension_related_tracks_json(
                &extension_id,
                &seeds_json,
                &options_json,
                lease.map(|lease| Arc::clone(&lease.inner)),
            )
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn get_extension_home_feed_json(
        &self,
        extension_id: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .get_extension_home_feed_json(
                &extension_id,
                lease.map(|lease| Arc::clone(&lease.inner)),
            )
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn find_collection_across_extensions_json(
        &self,
        request_json: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .find_collection_across_extensions_json(&request_json, &|| check(&lease))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn fetch_music_brainz_genre_by_isrc(
        &self,
        isrc: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .fetch_music_brainz_genre_by_isrc(&isrc, &|| check(&lease))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn fetch_music_brainz_album_artist_by_isrc(
        &self,
        isrc: String,
        album_name: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .fetch_music_brainz_album_artist_by_isrc(&isrc, &album_name, &|| check(&lease))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn get_provider_metadata_json(
        &self,
        provider_id: String,
        resource_type: String,
        resource_id: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .get_provider_metadata_json(&provider_id, &resource_type, &resource_id, &|| {
                check(&lease)
            })
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn set_metadata_language(&self, tag: String) -> Result<(), ExtensionManagerError> {
        self.inner
            .set_metadata_language(&tag)
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn get_track_cache_size(&self) -> Result<u64, ExtensionManagerError> {
        self.inner
            .get_track_cache_size()
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn clear_track_id_cache(&self) -> Result<(), ExtensionManagerError> {
        self.inner
            .clear_track_id_cache()
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn get_deezer_extended_metadata(
        &self,
        track_id: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .get_deezer_extended_metadata(&track_id, &|| check(&lease))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn search_deezer_by_isrc_for_item_id(
        &self,
        isrc: String,
        item_id: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .search_deezer_by_isrc_for_item_id(&isrc, &item_id, &|| check(&lease))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn convert_spotify_to_deezer(
        &self,
        resource_type: String,
        spotify_id: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .convert_spotify_to_deezer(&resource_type, &spotify_id, &|| check(&lease))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn get_track_platform_links_json(
        &self,
        spotify_id: String,
        isrc: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .get_track_platform_links_json(&spotify_id, &isrc, &|| check(&lease))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn reenrich_file(
        &self,
        request_json: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .reenrich_file(&request_json, &|| check(&lease))
            .map_err(ExtensionManagerError::Operation)
    }
}
