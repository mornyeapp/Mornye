//! Root ownership for installed extensions and shared provider services.

mod cover;
mod downloads;
mod health;
mod library;
mod lyrics;
mod metadata;
mod musicbrainz;
mod provider_metadata;
mod reenrich;
mod share;
mod tags;

pub use cover::{LIBRARY_COVER_REGENERATE_MARKER, library_cover_is_current, library_cover_stem};
pub use lyrics::LyricsRequest;
pub use metadata::MetadataOptions;

use crate::RuntimeLimits;
use crate::environment::ExtensionEnvironment;
use crate::lyrics::InstalledLyricsFetcher;
use crate::manager::{ExtensionManager, ManagerError};
use mornye_core::lyrics::config::{self, FetchOptions};
use mornye_providers::deezer::DeezerClient;
use mornye_providers::lyrics::{LyricsService, builtin::BuiltinLyricsClient};
use mornye_providers::musicbrainz::MusicBrainzClient;
use mornye_providers::resolver::{PlatformResolverChain, availability::AvailabilityService};
use std::ops::Deref;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};

/// Retained by the native owner, never by a VM or provider worker. Shutdown
/// finishes provider work and persistence before releasing directory locks.
pub struct Backend {
    manager: Arc<ExtensionManager>,
    lyrics: Arc<LyricsService>,
    availability: Arc<AvailabilityService>,
    deezer: Arc<DeezerClient>,
    musicbrainz: MusicBrainzClient,
    share_cache: Mutex<share::Cache>,
    cover: cover::Cover,
    library_cover_directory: Mutex<String>,
    library_scan: library::ScanState,
    prepared_downloads: Mutex<downloads::PreparedDownloads>,
    health: Arc<health::Health>,
    closed: AtomicBool,
    operations: Mutex<usize>,
    idle: Condvar,
    lyrics_settings: Mutex<()>,
    shutdown: Mutex<Option<Result<(), String>>>,
}

impl Backend {
    pub fn new(
        sources: &Path,
        data: &Path,
        master_key: &str,
        app_version: &str,
        limits: RuntimeLimits,
    ) -> Result<Self, ManagerError> {
        let environment = ExtensionEnvironment::new(data, master_key, app_version)
            .map_err(|error| ManagerError(error.to_string()))?;
        Self::with_environment(sources, environment, limits, MetadataOptions::default())
    }

    /// Apply persisted settings before restoring caches that depend on them.
    pub fn with_lyrics_settings(
        sources: &Path,
        data: &Path,
        master_key: &str,
        app_version: &str,
        limits: RuntimeLimits,
        providers_json: &str,
        options_json: &str,
    ) -> Result<Self, ManagerError> {
        let providers = config::decode_providers(providers_json)
            .map_err(|error| ManagerError(error.to_string()))?;
        let mut options = FetchOptions::default();
        options
            .update_json(options_json)
            .map_err(|error| ManagerError(error.to_string()))?;
        let environment = ExtensionEnvironment::new(data, master_key, app_version)
            .map_err(|error| ManagerError(error.to_string()))?;
        Self::with_environment_and_lyrics(
            sources,
            environment,
            limits,
            MetadataOptions::default(),
            &providers,
            options,
        )
    }

    /// Transfer a native environment into this root. Provider configuration is
    /// native-owned and all services reuse the environment's network/policy.
    pub fn with_environment(
        sources: &Path,
        environment: ExtensionEnvironment,
        limits: RuntimeLimits,
        options: MetadataOptions,
    ) -> Result<Self, ManagerError> {
        Self::with_environment_and_lyrics(
            sources,
            environment,
            limits,
            options,
            &[],
            FetchOptions::default(),
        )
    }

    fn with_environment_and_lyrics(
        sources: &Path,
        environment: ExtensionEnvironment,
        limits: RuntimeLimits,
        options: MetadataOptions,
        lyrics_providers: &[String],
        lyrics_options: FetchOptions,
    ) -> Result<Self, ManagerError> {
        let manager = Arc::new(ExtensionManager::with_environment(
            sources,
            environment,
            limits,
        )?);
        let environment = manager.environment();
        let network = environment
            .network_service()
            .map_err(|error| ManagerError(error.to_string()))?;
        let deezer = Arc::new(
            DeezerClient::with_endpoint(&network, &options.deezer_endpoint)
                .map_err(|error| ManagerError(error.to_string()))?,
        );
        let musicbrainz = MusicBrainzClient::with_options(&network, options.musicbrainz)
            .map_err(|error| ManagerError(error.to_string()))?;
        let resolver = PlatformResolverChain::with_options(&network, options.resolver)
            .map_err(|error| ManagerError(error.to_string()))?;
        let availability = Arc::new(AvailabilityService::new(Arc::new(resolver), deezer.clone()));
        let lyrics = Arc::new(LyricsService::new(Arc::new(InstalledLyricsFetcher::new(
            &manager,
            BuiltinLyricsClient::new(
                &network,
                environment.shared_app_version(),
                availability.clone(),
            ),
        ))));
        lyrics
            .set_providers(lyrics_providers)
            .and_then(|()| lyrics.set_options(lyrics_options))
            .map_err(|error| ManagerError(error.to_string()))?;
        lyrics
            .set_persistence_path(&environment.data_directory().join(".lyrics_cache.json"))
            .map_err(|error| ManagerError(error.to_string()))?;
        environment.attach_lyrics(&lyrics);
        let cover = cover::Cover::new(&network, environment.shared_app_version());
        let health = Arc::new(health::Health::new(
            &network,
            environment.shared_app_version(),
        ));
        Ok(Self {
            manager,
            lyrics,
            availability,
            deezer,
            musicbrainz,
            share_cache: Mutex::default(),
            cover,
            library_cover_directory: Mutex::default(),
            library_scan: library::ScanState::default(),
            prepared_downloads: Mutex::default(),
            health,
            closed: AtomicBool::new(false),
            operations: Mutex::new(0),
            idle: Condvar::new(),
            lyrics_settings: Mutex::new(()),
            shutdown: Mutex::new(None),
        })
    }

    pub fn lyrics(&self) -> Arc<LyricsService> {
        Arc::clone(&self.lyrics)
    }

    pub fn availability(&self) -> Arc<AvailabilityService> {
        Arc::clone(&self.availability)
    }

    pub fn get_extension_pending_auth_json(&self, id: &str) -> Result<String, String> {
        let _operation = self.enter()?;
        let id = id.trim();
        if id.is_empty() {
            return Ok(String::new());
        }
        let environment = self.manager.environment();
        if let Some(pending) = environment
            .pending_auth(id)
            .map_err(|error| error.to_string())?
        {
            return serde_json::to_string(&pending).map_err(|error| error.to_string());
        }
        // A missing or expired challenge may require network preflight. Reuse
        // cancellable provider work so owner shutdown interrupts that request.
        self.metadata_provider_work(&|| self.check(), |lease| {
            self.manager
                .preflight_auth(id, lease)
                .map(|_| "null".into())
        })
        .map_err(|error| error.to_string())?;
        environment
            .pending_auth(id)
            .map_err(|error| error.to_string())?
            .map(|pending| serde_json::to_string(&pending).map_err(|error| error.to_string()))
            .transpose()
            .map(Option::unwrap_or_default)
    }

    /// Drop disposable resources while active requests retain their owner and IO.
    /// Memory pressure does not clear persisted lyrics, settings or credentials.
    pub fn release_memory(&self, under_pressure: bool) -> Result<(), String> {
        let _operation = self.enter()?;
        self.manager
            .release_idle_download_runtimes()
            .map_err(|error| error.to_string())?;
        self.manager
            .environment()
            .cleanup_connections()
            .map_err(|error| error.to_string())?;
        if under_pressure {
            self.manager
                .environment()
                .clear_isrc_cache()
                .map_err(|error| error.to_string())?;
            self.cover.clear();
            self.lyrics
                .drop_memory()
                .map_err(|error| error.to_string())?;
            self.health.clear_memory_cache();
        }
        Ok(())
    }

    pub fn shutdown_checked(&self) -> Result<(), String> {
        let mut state = self.shutdown.lock().expect("backend shutdown lock");
        if let Some(result) = state.as_ref() {
            return result.clone();
        }
        self.closed.store(true, Ordering::Release);
        self.health.shutdown();
        self.musicbrainz.shutdown();
        self.manager.environment().shared_app_version().close();
        let result = self.lyrics.shutdown();
        let mut operations = self.operations.lock().expect("backend operations lock");
        while *operations != 0 {
            operations = self.idle.wait(operations).expect("backend operations wait");
        }
        drop(operations);
        self.share_cache.lock().expect("share cache lock").clear();
        self.cover.clear();
        self.prepared_downloads
            .lock()
            .expect("prepared downloads lock")
            .clear();
        if let Err(error) = &result {
            let _ = self.manager.environment().log_buffer().add(
                "ERROR",
                "Lyrics",
                &format!("Failed to persist lyrics cache: {error}"),
            );
        }
        self.availability.shutdown();
        self.manager.shutdown();
        *state = Some(result.clone());
        result
    }

    /// Preserve the native manager's void shutdown API; flush failures are
    /// logged, and native callers can also inspect `shutdown_checked`.
    pub fn shutdown(&self) {
        let _ = self.shutdown_checked();
    }

    fn check(&self) -> Result<(), String> {
        if self.closed.load(Ordering::Acquire) || self.manager.environment().is_closed() {
            Err("backend is closed".into())
        } else {
            Ok(())
        }
    }

    fn enter(&self) -> Result<Operation<'_>, String> {
        let mut operations = self.operations.lock().expect("backend operations lock");
        self.check()?;
        *operations += 1;
        Ok(Operation(self))
    }
}

struct Operation<'a>(&'a Backend);

impl Drop for Operation<'_> {
    fn drop(&mut self) {
        *self.0.operations.lock().expect("backend operations lock") -= 1;
        self.0.idle.notify_all();
    }
}

impl Deref for Backend {
    type Target = ExtensionManager;

    fn deref(&self) -> &Self::Target {
        &self.manager
    }
}

impl Drop for Backend {
    fn drop(&mut self) {
        self.shutdown();
    }
}
