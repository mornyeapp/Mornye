//! Backend metadata options and operations: language and region settings, caches, and Deezer lookups.

use super::Backend;
use mornye_core::metadata::TrackMetadata;
use mornye_providers::deezer::MetadataLookup;
use mornye_providers::musicbrainz::MusicBrainzOptions;
use mornye_providers::resolver::{Check, ResolverError, ResolverOptions};
use serde::Serialize;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

/// Trusted native configuration, never extension arguments or persisted settings.
pub struct MetadataOptions {
    pub deezer_endpoint: String,
    pub resolver: ResolverOptions,
    pub musicbrainz: MusicBrainzOptions,
}

impl Default for MetadataOptions {
    fn default() -> Self {
        Self {
            deezer_endpoint: "https://api.deezer.com".into(),
            resolver: ResolverOptions::default(),
            musicbrainz: MusicBrainzOptions::default(),
        }
    }
}

fn encode(value: &impl Serialize) -> Result<String, ResolverError> {
    serde_json::to_string(value).map_err(|error| ResolverError::Failed(error.to_string()))
}

fn context(error: ResolverError, prefix: &str) -> ResolverError {
    match error {
        ResolverError::Cancelled(_) | ResolverError::Closed | ResolverError::Busy => error,
        _ => ResolverError::Failed(format!("{prefix}: {error}")),
    }
}

fn isrc_result(track: &TrackMetadata) -> Value {
    // Go's public map includes fields omitted by the ordinary track serializer.
    let mut result = json!({
        "spotify_id": track.spotify_id, "artists": track.artists, "name": track.name,
        "album_name": track.album_name, "album_artist": track.album_artist,
        "duration_ms": track.duration_ms, "images": track.images,
        "release_date": track.release_date, "track_number": track.track_number,
        "total_tracks": track.total_tracks, "disc_number": track.disc_number,
        "total_discs": track.total_discs, "external_urls": track.external_urls,
        "isrc": track.isrc, "album_id": track.album_id, "artist_id": track.artist_id,
        "album_type": track.album_type, "composer": track.composer
    });
    let id = track
        .spotify_id
        .strip_prefix("deezer:")
        .unwrap_or(&track.spotify_id)
        .trim();
    if !id.is_empty() {
        result["id"] = json!(id);
        result["track_id"] = json!(id);
        result["success"] = json!(true);
    }
    result
}

impl Backend {
    pub(super) fn metadata_operation<T>(
        &self,
        seconds: u64,
        check: &Check<'_>,
        work: impl FnOnce(&Check<'_>) -> Result<T, ResolverError>,
    ) -> Result<T, String> {
        let _operation = self.enter()?;
        let started = Instant::now();
        let check = || {
            self.check()?;
            check()?;
            if started.elapsed() >= Duration::from_secs(seconds) {
                Err("context deadline exceeded".into())
            } else {
                Ok(())
            }
        };
        check()?;
        let result = work(&check);
        check()?;
        result.map_err(|error| error.to_string())
    }

    pub fn set_metadata_language(&self, tag: &str) -> Result<(), String> {
        let _operation = self.enter()?;
        self.deezer.set_language(tag);
        Ok(())
    }

    pub fn set_song_link_region(&self, region: &str) -> Result<(), String> {
        let _operation = self.enter()?;
        self.availability
            .set_region(region)
            .map_err(|error| error.to_string())
    }

    // The retired Settings track-ID cache is distinct from catalog caches.
    pub fn get_track_cache_size(&self) -> Result<u64, String> {
        let _operation = self.enter()?;
        Ok(0)
    }

    pub fn clear_track_id_cache(&self) -> Result<(), String> {
        let _operation = self.enter()?;
        Ok(())
    }

    pub(super) fn deezer_metadata(
        &self,
        kind: &str,
        id: &str,
        check: &Check<'_>,
    ) -> Result<String, ResolverError> {
        match kind {
            "track" => encode(&json!({"track": self.deezer.get_track(id, check)?})),
            "album" => encode(self.deezer.get_album(id, check)?.as_ref()),
            "artist" => encode(self.deezer.get_artist(id, check)?.as_ref()),
            "playlist" => encode(&self.deezer.get_playlist(id, check)?),
            _ => Err(ResolverError::Failed(format!(
                "unsupported Deezer resource type: {kind}"
            ))),
        }
    }

    pub fn get_deezer_extended_metadata(
        &self,
        id: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        self.metadata_operation(15, check, |check| {
            if id.is_empty() { return Err(ResolverError::Failed("empty track ID".into())); }
            let metadata = self.deezer.get_extended_metadata_by_track_id(id, check)?;
            encode(&json!({"genre":metadata.genre,"label":metadata.label,"copyright":metadata.copyright}))
        })
    }

    pub fn search_deezer_by_isrc_for_item_id(
        &self,
        isrc: &str,
        item_id: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        self.metadata_operation(10, check, |check| {
            let state = self.manager.environment().download_state();
            let lease = if item_id.is_empty() {
                None
            } else {
                Some(
                    state
                        .cancellation
                        .acquire(item_id)
                        .map_err(|error| ResolverError::Cancelled(error.to_string()))?,
                )
            };
            let check = || {
                check()?;
                lease.as_ref().map_or(Ok(()), |lease| {
                    lease.check_active().map_err(|error| error.to_string())
                })
            };
            check().map_err(ResolverError::Cancelled)?;
            let track = self.deezer.search_by_isrc(isrc, &check);
            check().map_err(ResolverError::Cancelled)?;
            encode(&isrc_result(&track?))
        })
    }

    pub fn convert_spotify_to_deezer(
        &self,
        kind: &str,
        id: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        self.metadata_operation(30, check, |check| {
            let (deezer_id, fetch_error) = match kind {
                "track" => (self.deezer_id_from_spotify(id, check).map_err(|error| context(error, "could not find Deezer equivalent"))?, "failed to fetch Deezer metadata"),
                "album" => (self.availability.deezer_album_id(id, check).map_err(|error| context(error, "could not find Deezer album"))?, "failed to fetch Deezer album metadata"),
                _ => return Err(ResolverError::Failed(format!("spotify to Deezer conversion only supported for tracks and albums: please search by name for {kind}"))),
            };
            self.deezer_metadata(kind, &deezer_id, check).map_err(|error| context(error, fetch_error))
        })
    }

    fn deezer_id_from_spotify(&self, id: &str, check: &Check<'_>) -> Result<String, ResolverError> {
        let track = self.availability.check_track(id, "", check)?;
        if track.deezer && !track.deezer_id.is_empty() {
            Ok(track.deezer_id)
        } else {
            Err(ResolverError::Failed("track not found on Deezer".into()))
        }
    }

    pub fn get_track_platform_links_json(
        &self,
        id: &str,
        isrc: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        self.metadata_operation(30, check, |check| {
            encode(&json!({"platforms":self.availability.track_platform_links(id, isrc, check)?}))
        })
    }

    pub fn get_deezer_id_from_spotify(
        &self,
        id: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        self.metadata_operation(30, check, |check| self.deezer_id_from_spotify(id, check))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::RuntimeLimits;
    use crate::environment::ExtensionEnvironment;
    use mornye_network::{NetworkOptions, NetworkService};
    use std::io::{BufRead, BufReader, ErrorKind, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, mpsc};
    use std::thread;

    type FakeDeezer = (
        TcpListener,
        Arc<rustls::ServerConfig>,
        Arc<Backend>,
        tempfile::TempDir,
    );

    /// A backend whose Deezer requests reach a local TLS listener.
    fn fake_deezer() -> FakeDeezer {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
        let config = Arc::new(
            rustls::ServerConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![certificate.cert.der().clone()],
                rustls::pki_types::PrivatePkcs8KeyDer::from(
                    certificate.signing_key.serialize_der(),
                )
                .into(),
            )
            .unwrap(),
        );
        let network = NetworkService::with_options(NetworkOptions {
            extra_root_pem: certificate.cert.pem().into_bytes(),
            doh_upstreams: vec![],
            ..Default::default()
        })
        .unwrap();
        network.set_allow_private_network(true);
        let root = tempfile::tempdir().unwrap();
        let environment = ExtensionEnvironment::with_network(
            &root.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            network,
        )
        .unwrap();
        let backend = Arc::new(
            Backend::with_environment(
                &root.path().join("sources"),
                environment,
                RuntimeLimits::default(),
                MetadataOptions {
                    deezer_endpoint: format!("https://{}", listener.local_addr().unwrap()),
                    ..Default::default()
                },
            )
            .unwrap(),
        );
        (listener, config, backend, root)
    }

    #[test]
    fn an_unplayable_isrc_match_gives_way_to_a_playable_release() {
        let (listener, config, backend, _root) = fake_deezer();
        let isrc = "JPAAA8300060";
        let worker = {
            let owner = backend.clone();
            thread::spawn(move || owner.search_deezer_by_isrc_for_item_id(isrc, "", &|| Ok(())))
        };
        let track = |id: i64, isrc: &str, readable: bool, album: &str| {
            format!(
                r#"{{"id":{id},"title":"Song","duration":265,"isrc":"{isrc}","readable":{readable},"artist":{{"id":2,"name":"Singer"}},"album":{{"id":{id},"title":"{album}"}}}}"#
            )
        };
        let mut paths = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(10);
        while !worker.is_finished() && Instant::now() < deadline {
            let stream = match listener.accept() {
                Ok((stream, _)) => stream,
                Err(error) if error.kind() == ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(1));
                    continue;
                }
                Err(error) => panic!("{error}"),
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut stream = rustls::StreamOwned::new(
                rustls::ServerConnection::new(config.clone()).unwrap(),
                stream,
            );
            let mut reader = BufReader::new(&mut stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let path = line.split(' ').nth(1).unwrap().to_owned();
            loop {
                line.clear();
                assert!(reader.read_line(&mut line).unwrap() > 0);
                if line == "\r\n" {
                    break;
                }
            }
            let body = if path == format!("/2.0/track/isrc:{isrc}") {
                track(1, isrc, false, "Withdrawn Best Of")
            } else if path.starts_with("/2.0/search/track?q=Singer+Song") {
                // The unplayable match itself, an unplayable cover and two
                // playable releases, only the second of the same recording.
                format!(
                    r#"{{"data":[{},{},{},{}]}}"#,
                    track(1, "", false, "Withdrawn Best Of"),
                    track(2, "", false, "Covers"),
                    track(3, "", true, "Live"),
                    track(4, "", true, "Original Album"),
                )
            } else if path == "/2.0/track/3" {
                track(3, "JPAAA9900001", true, "Live")
            } else if path == "/2.0/track/4" {
                track(4, &isrc.to_lowercase(), true, "Original Album")
            } else {
                panic!("unexpected request: {path}");
            };
            paths.push(path);
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
            stream.flush().unwrap();
        }
        let result: Value = serde_json::from_str(&worker.join().unwrap().unwrap()).unwrap();
        assert_eq!(result["track_id"], "4");
        assert_eq!(result["album_name"], "Original Album");
        assert_eq!(paths.len(), 4, "{paths:?}");
        backend.shutdown_checked().unwrap();
    }

    #[test]
    fn isrc_http_cancellation_does_not_cancel_another_item() {
        let (listener, config, backend, _root) = fake_deezer();
        let start = |isrc: &'static str, item: &'static str| {
            let owner = backend.clone();
            let (finished, completion) = mpsc::channel();
            let worker = thread::spawn(move || {
                finished
                    .send(owner.search_deezer_by_isrc_for_item_id(isrc, item, &|| Ok(())))
                    .unwrap();
            });
            (worker, completion)
        };
        let accept = |isrc: &str| {
            let deadline = Instant::now() + Duration::from_secs(3);
            let stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(error)
                        if error.kind() == ErrorKind::WouldBlock && Instant::now() < deadline =>
                    {
                        thread::sleep(Duration::from_millis(1));
                    }
                    Err(error) => panic!("ISRC request did not arrive: {error}"),
                }
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            stream
                .set_write_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut stream = rustls::StreamOwned::new(
                rustls::ServerConnection::new(config.clone()).unwrap(),
                stream,
            );
            let mut reader = BufReader::new(&mut stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert!(line.starts_with(&format!("GET /2.0/track/isrc:{isrc} ")));
            loop {
                line.clear();
                assert!(reader.read_line(&mut line).unwrap() > 0);
                if line == "\r\n" {
                    break;
                }
            }
            stream
        };
        let (cancelled_worker, cancelled) = start("USAAA2600001", "item-a");
        let cancelled_stream = accept("USAAA2600001");
        let (surviving_worker, surviving) = start("USAAA2600002", "item-b");
        let mut surviving_stream = accept("USAAA2600002");

        backend.release_memory(true).unwrap();
        assert!(cancelled.try_recv().is_err());
        assert!(surviving.try_recv().is_err());
        backend
            .environment()
            .download_state()
            .cancel("item-a")
            .unwrap();
        assert_eq!(
            cancelled.recv_timeout(Duration::from_secs(3)).unwrap(),
            Err("download cancelled".into())
        );
        assert!(surviving.try_recv().is_err());
        // Neither response has been sent: cancellation must interrupt active IO.
        drop(cancelled_stream);
        let body = r#"{"id":7,"title":"Survivor","duration":3,"isrc":"USAAA2600002","artist":{"id":2,"name":"Artist"},"album":{"id":3,"title":"Album"}}"#;
        write!(
            surviving_stream,
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
        .unwrap();
        surviving_stream.flush().unwrap();
        drop(surviving_stream);
        let result = surviving
            .recv_timeout(Duration::from_secs(3))
            .unwrap()
            .unwrap();
        let result: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(result["success"], true);
        assert_eq!(result["track_id"], "7");
        assert_eq!(result["isrc"], "USAAA2600002");
        cancelled_worker.join().unwrap();
        surviving_worker.join().unwrap();
        backend.shutdown_checked().unwrap();
    }

    #[test]
    fn shutdown_cancels_metadata_and_keeps_directory_ownership_until_work_releases() {
        let root = tempfile::tempdir().unwrap();
        let create = || {
            Backend::new(
                &root.path().join("sources"),
                &root.path().join("data"),
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                "1",
                RuntimeLimits::default(),
            )
            .unwrap()
        };
        let backend = Arc::new(create());
        let availability = backend.availability();
        let (entered, started) = mpsc::channel();
        let (cancelled, cancellation) = mpsc::channel();
        let (release, released) = mpsc::channel();
        let (finished, completion) = mpsc::channel();
        let owner = backend.clone();
        let worker = thread::spawn(move || {
            owner.metadata_operation(30, &|| Ok(()), |check| -> Result<(), ResolverError> {
                entered.send(()).unwrap();
                loop {
                    if let Err(error) = check() {
                        cancelled.send(()).unwrap();
                        released.recv_timeout(Duration::from_secs(3)).unwrap();
                        return Err(ResolverError::Cancelled(error));
                    }
                    thread::sleep(Duration::from_millis(1));
                }
            })
        });
        started.recv_timeout(Duration::from_secs(3)).unwrap();
        let owner = backend.clone();
        let shutdown = thread::spawn(move || {
            owner.shutdown_checked().unwrap();
            finished.send(()).unwrap();
        });
        cancellation.recv_timeout(Duration::from_secs(3)).unwrap();
        assert!(completion.try_recv().is_err());
        assert!(
            Backend::new(
                &root.path().join("sources"),
                &root.path().join("data"),
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                "1",
                RuntimeLimits::default()
            )
            .is_err()
        );
        release.send(()).unwrap();
        assert_eq!(worker.join().unwrap(), Err("backend is closed".into()));
        shutdown.join().unwrap();
        completion.recv_timeout(Duration::from_secs(3)).unwrap();
        assert!(availability.region().is_err());
        assert_eq!(
            backend.get_track_cache_size(),
            Err("backend is closed".into())
        );
        assert_eq!(create().get_track_cache_size().unwrap(), 0);
    }
}
