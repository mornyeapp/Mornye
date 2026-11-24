//! Mornye Link on desktop (`LINK_CONTRACT.md` section 6): runs the
//! `mornye-link` HTTPS server for the `link*` methods and bridges it to Dart.
//! A request the server forwards becomes the inbound call `linkRequest`
//! (kind 12), and Dart answers it with `linkReply`; the server's other
//! events become the inbound calls `linkMessage`, `linkClients`,
//! `linkPaired` and `linkPairingEnded`. The glue itself is
//! [`mornye_link::bridge`], shared with the phone backend.

use crate::call::{Args, CallError, CallResult, Reply};
use crate::runtime::Config;
use mornye_link::bridge::{AppBridge, BridgeError, BridgePaths, Emitter};
use serde_json::Value;
use std::sync::Arc;

pub(crate) struct Link {
    bridge: AppBridge,
}

impl Default for Link {
    fn default() -> Self {
        Self::new(Arc::new(|method, args| {
            crate::runtime::inbound(method, args)
        }))
    }
}

impl Link {
    pub(crate) fn new(emit: Emitter) -> Self {
        Self {
            bridge: AppBridge::new(emit),
        }
    }

    /// `linkStart {"name", "port"?, "platform"?, "features"?}`. Restarts a
    /// running server.
    pub(crate) fn start(&self, config: &Config, args: &Args) -> CallResult {
        let started = self
            .bridge
            .start(&paths(config), args.value())
            .map_err(error)?;
        if let Some(error) = started.discovery_error {
            crate::runtime::log("warn", &error);
        }
        Ok(started.summary.into())
    }

    /// `linkStop`. Safe when stopped.
    pub(crate) fn stop(&self) {
        self.bridge.stop();
    }

    /// `linkStatus`: `{"running": false, "receivedDir"}` while stopped
    /// (`receivedDir` only once `app_support_dir` is configured).
    pub(crate) fn status(&self, config: &Config) -> Value {
        self.bridge.status(&paths(config))
    }

    /// `linkSetCatalog {"path"}`.
    pub(crate) fn set_catalog(&self, args: &Args) -> CallResult {
        reply(self.bridge.set_catalog(args.value()))
    }

    /// `linkBeginPairing`.
    pub(crate) fn begin_pairing(&self) -> CallResult {
        reply(self.bridge.begin_pairing())
    }

    /// `linkEndPairing`. Safe when stopped.
    pub(crate) fn end_pairing(&self) {
        self.bridge.end_pairing();
    }

    /// `linkDevices`; while stopped, the stored devices.
    pub(crate) fn devices(&self, config: &Config) -> CallResult {
        reply(self.bridge.devices(&paths(config)))
    }

    /// `linkRevoke {"deviceId"}`; works while stopped too.
    pub(crate) fn revoke(&self, config: &Config, args: &Args) -> CallResult {
        reply(self.bridge.revoke(&paths(config), args.value()))
    }

    /// `linkCreateKey {"name"}`.
    pub(crate) fn create_key(&self, args: &Args) -> CallResult {
        reply(self.bridge.create_key(args.value()))
    }

    /// `linkReply {"requestId", "result"?, "error"?: {"code", "message"}}`.
    pub(crate) fn reply(&self, args: &Args) -> CallResult {
        reply(self.bridge.reply(args.value()))
    }

    /// `linkEmbeddedPictures {"paths": [String]}`: `{"pictures": [bool|null]}`.
    pub(crate) fn embedded_pictures(&self, args: &Args) -> CallResult {
        reply(self.bridge.embedded_pictures(args.value()))
    }

    /// `linkSend {"deviceId"?, "message"}`: `{"delivered": <int>}`.
    pub(crate) fn send(&self, args: &Args) -> CallResult {
        reply(self.bridge.send(args.value()))
    }
}

fn paths(config: &Config) -> BridgePaths {
    BridgePaths {
        app_support_dir: config.app_support_dir.clone(),
        temp_dir: config.temp_dir.clone(),
        ffmpeg_path: config.ffmpeg_path.clone(),
        app_version: config.app_version.clone(),
    }
}

fn error(error: BridgeError) -> CallError {
    match error {
        BridgeError::Invalid(message) => CallError::invalid_arguments(message),
        BridgeError::Failure(message) => CallError::failure(message),
    }
}

fn reply(result: Result<Value, BridgeError>) -> CallResult {
    result.map(Reply::from).map_err(error)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn link() -> Link {
        Link::new(Arc::new(|_, _| {}))
    }

    fn args(value: Value) -> Args {
        Args::decode(value.to_string().as_bytes(), None).unwrap()
    }

    #[test]
    fn answers_while_stopped() {
        let link = link();
        let dir = tempfile::tempdir().unwrap();
        let config = Config {
            app_support_dir: dir.path().to_owned(),
            ..Config::default()
        };
        assert_eq!(
            link.status(&config),
            json!({
                "running": false,
                "receivedDir": dir.path().join("link").join("received").to_string_lossy(),
            })
        );
        assert_eq!(link.status(&Config::default()), json!({"running": false}));
        assert_eq!(link.devices(&config).unwrap(), Reply::Json(json!([])));
        assert!(
            link.revoke(&config, &args(json!({"deviceId": "phone"})))
                .is_ok()
        );
        assert!(link.begin_pairing().is_err());
        assert!(link.create_key(&args(json!({"name": "App"}))).is_err());
        assert_eq!(
            link.send(&args(json!({"message": {"type": "x"}}))).unwrap(),
            Reply::Json(json!({"delivered": 0}))
        );
        assert!(link.send(&args(json!({}))).is_err());
        assert_eq!(
            link.reply(&args(json!({"requestId": "gone", "result": {}})))
                .unwrap(),
            Reply::null()
        );
        assert_eq!(
            link.reply(&args(json!({}))).unwrap_err().code,
            "invalid_arguments"
        );
        let notes = dir.path().join("notes.txt");
        std::fs::write(&notes, b"no audio").unwrap();
        assert_eq!(
            link.embedded_pictures(&args(json!({
                "paths": [notes, dir.path().join("gone.flac"), "", 7],
            })))
            .unwrap(),
            Reply::Json(json!({"pictures": [false, null, null, null]}))
        );
        let many = vec![""; mornye_link::bridge::MAX_PICTURE_PROBES + 1];
        for bad in [json!({}), json!({"paths": "x"}), json!({"paths": many})] {
            assert_eq!(
                link.embedded_pictures(&args(bad)).unwrap_err().code,
                "invalid_arguments"
            );
        }
        link.end_pairing();
        link.stop();
        assert_eq!(
            link.start(&Config::default(), &args(json!({"name": "Desk"})))
                .unwrap_err()
                .message,
            "app_support_dir is not configured"
        );
        assert_eq!(
            link.start(&config, &args(json!({"port": 70000})))
                .unwrap_err()
                .code,
            "invalid_arguments"
        );
    }
}
