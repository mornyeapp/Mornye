//! One connected receiver of any kind behind the same commands. Google Cast
//! keeps its own sender; the other kinds run an actor fed by [`Remote`].

use crate::discovery::{Device, Kind};
use crate::sender::{self, Emit, Sender};
use crate::status::Status;
use crate::{dlna, fcast};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

/// What a song needs to play, read from `load` arguments.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Item {
    pub(crate) url: String,
    pub(crate) mime: String,
    pub(crate) token: i64,
    pub(crate) title: String,
    pub(crate) artist: String,
    pub(crate) album: String,
    pub(crate) artwork: Option<String>,
    /// Milliseconds, when the app knows it.
    pub(crate) duration: Option<i64>,
}

impl Item {
    pub(crate) fn from_request(request: &Value) -> Result<Self, String> {
        let text = |key: &str| request[key].as_str().unwrap_or_default().to_owned();
        Ok(Self {
            url: request["url"]
                .as_str()
                .ok_or("load needs a url")?
                .to_owned(),
            mime: request["mime"]
                .as_str()
                .ok_or("load needs a mime type")?
                .to_owned(),
            token: request["token"].as_i64().ok_or("load needs a token")?,
            title: text("title"),
            artist: text("artist"),
            album: text("album"),
            artwork: request["artwork"].as_str().map(str::to_owned),
            duration: request["duration"].as_i64().filter(|ms| *ms > 0),
        })
    }

    pub(crate) fn duration_seconds(&self) -> f64 {
        self.duration.map_or(0.0, |ms| ms as f64 / 1000.0)
    }
}

pub(crate) enum Control {
    Load(Box<Item>),
    Play,
    Pause,
    Stop,
    /// Seconds from the start of the song.
    Seek(f64),
    /// 0 to 1.
    Volume(f64),
    Disconnect,
}

pub(crate) type Reply = oneshot::Sender<Result<(), String>>;
pub(crate) type Commands = mpsc::UnboundedReceiver<(Control, Reply)>;

/// The command side of a receiver actor; dropping every clone ends it.
#[derive(Clone)]
pub(crate) struct Remote {
    commands: mpsc::UnboundedSender<(Control, Reply)>,
}

impl Remote {
    pub(crate) fn channel() -> (Self, Commands) {
        let (commands, receiver) = mpsc::unbounded_channel();
        (Self { commands }, receiver)
    }

    pub(crate) async fn ask(&self, control: Control) -> Result<(), String> {
        let (reply, answer) = oneshot::channel();
        self.commands
            .send((control, reply))
            .map_err(|_| "Device is disconnected".to_owned())?;
        match tokio::time::timeout(Duration::from_secs(25), answer).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err("Device is disconnected".into()),
            Err(_) => Err("Device did not answer".into()),
        }
    }
}

#[derive(Clone)]
pub(crate) enum Session {
    Cast(Sender),
    Remote(Remote),
}

impl Session {
    pub(crate) fn is_closed(&self) -> bool {
        match self {
            Self::Cast(sender) => sender.is_closed(),
            Self::Remote(remote) => remote.commands.is_closed(),
        }
    }

    pub(crate) async fn control(&self, control: Control) -> Result<(), String> {
        let sender = match self {
            Self::Cast(sender) => sender,
            Self::Remote(remote) => return remote.ask(control).await,
        };
        match control {
            Control::Load(item) => sender.load(&item).await,
            Control::Play => sender.media("PLAY", json!({})).await,
            Control::Pause => sender.media("PAUSE", json!({})).await,
            Control::Stop => sender.media("STOP", json!({})).await,
            Control::Seek(seconds) => sender.media("SEEK", json!({"currentTime": seconds})).await,
            Control::Volume(level) => sender.volume(level).await,
            Control::Disconnect => sender.disconnect().await,
        }
    }
}

/// Connects to `device` with the sender of its kind.
pub(crate) async fn connect(
    device: Device,
    status: Arc<Mutex<Status>>,
    emit: Emit,
) -> Result<Session, String> {
    match device.kind {
        Kind::Cast => sender::connect(device, status, emit)
            .await
            .map(Session::Cast),
        Kind::Dlna => dlna::connect(device, status, emit)
            .await
            .map(Session::Remote),
        Kind::Fcast => fcast::connect(device, status, emit)
            .await
            .map(Session::Remote),
        Kind::Roku => Err("Roku devices are not supported".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_arguments_keep_the_cast_keys() {
        let item = Item::from_request(&json!({
            "url": "http://192.0.2.1/media/a", "mime": "audio/flac", "token": 3,
            "title": "Song", "artist": "Artist", "album": "Album",
            "artwork": "http://192.0.2.1/media/b", "duration": 180_500,
        }))
        .unwrap();
        assert_eq!(item.token, 3);
        assert_eq!(item.artwork.as_deref(), Some("http://192.0.2.1/media/b"));
        assert_eq!(item.duration_seconds(), 180.5);
        let bare = Item::from_request(&json!({"url": "u", "mime": "m", "token": 1, "duration": 0}))
            .unwrap();
        assert_eq!((bare.title.as_str(), bare.duration), ("", None));
        assert!(Item::from_request(&json!({"url": "u", "mime": "m"})).is_err());
    }
}
