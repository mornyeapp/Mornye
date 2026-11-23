//! FCast receivers, protocol version 3 (docs.fcast.org/protocol/v3): TCP on
//! the port mDNS gives (46899 by default), packets of a little-endian u32
//! size (opcode plus body), a u8 opcode and a UTF-8 JSON body. Both sides
//! send `Version` first and the higher one steps down to the other: a v2
//! receiver gets v2 messages, a v4 receiver steps down to v3. v1 receivers,
//! which send no `Version`, are not supported.

use crate::discovery::{Device, Kind};
use crate::mdns;
use crate::sender::Emit;
use crate::session::{Commands, Control, Item, Remote};
use crate::status::{self, Status, state};
use mdns_sd::ResolvedService;
use serde_json::{Value, json};
use std::io;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

/// The newest version this sender speaks.
pub(crate) const VERSION: u64 = 3;
/// v3 packets are at most 32000 bytes; reads allow more from lenient peers.
const MAX_PACKET: usize = 32_000;
const MAX_READ: usize = 64 * 1024;
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);
/// Song details are cut to this many characters to fit a packet.
const MAX_TEXT: usize = 512;

pub(crate) mod opcode {
    pub(crate) const PLAY: u8 = 1;
    pub(crate) const PAUSE: u8 = 2;
    pub(crate) const RESUME: u8 = 3;
    pub(crate) const STOP: u8 = 4;
    pub(crate) const SEEK: u8 = 5;
    pub(crate) const PLAYBACK_UPDATE: u8 = 6;
    pub(crate) const VOLUME_UPDATE: u8 = 7;
    pub(crate) const SET_VOLUME: u8 = 8;
    pub(crate) const PLAYBACK_ERROR: u8 = 9;
    pub(crate) const VERSION: u8 = 11;
    pub(crate) const PING: u8 = 12;
    pub(crate) const PONG: u8 = 13;
    pub(crate) const INITIAL: u8 = 14;
    pub(crate) const PLAY_UPDATE: u8 = 15;
    pub(crate) const SUBSCRIBE_EVENT: u8 = 17;
    pub(crate) const EVENT: u8 = 19;
}

/// PlaybackState of v2 and v3.
mod playback {
    pub(super) const IDLE: i64 = 0;
    pub(super) const PLAYING: i64 = 1;
    pub(super) const PAUSED: i64 = 2;
}

/// EventType MediaItemEnd of v3.
const MEDIA_ITEM_END: i64 = 1;

/// The receiver a resolved `_fcast._tcp` instance stands for. FCast has no
/// device id record, so the instance name the receiver advertises is it.
pub(crate) fn device(service: &ResolvedService) -> Option<Device> {
    let host = mdns::ipv4(service)?;
    let name = mdns::instance(service);
    if name.is_empty() {
        return None;
    }
    Some(Device::new(
        Kind::Fcast,
        &format!("fcast:{name}"),
        name,
        "FCast",
        host,
        service.port,
    ))
}

pub(crate) struct Packet {
    pub(crate) opcode: u8,
    pub(crate) body: Vec<u8>,
}

impl Packet {
    pub(crate) fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or_default()
    }
}

pub(crate) fn encode(opcode: u8, body: Option<&Value>) -> io::Result<Vec<u8>> {
    let body = body.map(Value::to_string).unwrap_or_default();
    let size = 1 + body.len();
    if size > MAX_PACKET {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "packet too large",
        ));
    }
    let mut packet = Vec::with_capacity(4 + size);
    packet.extend_from_slice(&(size as u32).to_le_bytes());
    packet.push(opcode);
    packet.extend_from_slice(body.as_bytes());
    Ok(packet)
}

/// Reads packets until the connection ends or breaks the framing.
async fn read_packets(mut reader: OwnedReadHalf, packets: mpsc::Sender<Packet>) {
    let mut size = [0u8; 4];
    loop {
        if reader.read_exact(&mut size).await.is_err() {
            return;
        }
        let size = u32::from_le_bytes(size) as usize;
        // An empty or oversized packet ends the connection, as v4 requires.
        if size == 0 || size > MAX_READ {
            return;
        }
        let mut data = vec![0u8; size];
        if reader.read_exact(&mut data).await.is_err() {
            return;
        }
        let packet = Packet {
            opcode: data[0],
            body: data.split_off(1),
        };
        if packets.send(packet).await.is_err() {
            return;
        }
    }
}

/// Ends the reader task with the session.
struct Abort(JoinHandle<()>);

impl Drop for Abort {
    fn drop(&mut self) {
        self.0.abort();
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct Timing {
    pub(crate) connect: Duration,
    /// How long the receiver has to send its `Version`.
    pub(crate) version: Duration,
    /// Silence after which a `Ping` goes out.
    pub(crate) ping_after: Duration,
    /// Silence that ends the session.
    pub(crate) silence: Duration,
    /// Play sent but no playback report after this long fails the song.
    pub(crate) start_limit: Duration,
    pub(crate) progress: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            connect: Duration::from_secs(8),
            version: Duration::from_secs(5),
            // The v4 reference policy pings after 3 s; v3 gives none, and
            // Wi-Fi on a phone stalls for seconds.
            ping_after: Duration::from_secs(4),
            silence: Duration::from_secs(12),
            start_limit: Duration::from_secs(20),
            progress: Duration::from_millis(500),
        }
    }
}

pub(crate) async fn connect(
    device: Device,
    status: Arc<Mutex<Status>>,
    emit: Emit,
) -> Result<Remote, String> {
    connect_with(device, status, emit, Timing::default()).await
}

pub(crate) async fn connect_with(
    device: Device,
    status: Arc<Mutex<Status>>,
    emit: Emit,
    timing: Timing,
) -> Result<Remote, String> {
    let name = device.name.clone();
    let stream = tokio::time::timeout(
        timing.connect,
        TcpStream::connect(SocketAddr::new(device.host, device.port)),
    )
    .await
    .map_err(|_| format!("{name} did not answer"))?
    .map_err(|_| format!("Could not reach {name}"))?;
    let _ = stream.set_nodelay(true);
    let (reader, writer) = stream.into_split();
    let (sink, packets) = mpsc::channel(64);
    let reader = Abort(tokio::spawn(read_packets(reader, sink)));
    let mut actor = Actor {
        version: VERSION,
        writer,
        packets,
        _reader: reader,
        status,
        emit,
        timing,
        item: None,
        song: Song::default(),
        last_seen: Instant::now(),
        pinged: None,
        volume: None,
        broken: false,
    };
    let lost = |_| format!("Could not reach {}", device.name);
    actor
        .send(opcode::VERSION, Some(&json!({"version": VERSION})))
        .await
        .map_err(lost)?;
    let theirs = tokio::time::timeout(timing.version, actor.receive_version())
        .await
        .ok()
        .flatten()
        .ok_or_else(|| format!("{} does not speak a supported FCast version", device.name))?;
    actor.version = theirs.min(VERSION);
    if actor.version >= 3 {
        let initial = json!({
            "displayName": "Mornye",
            "appName": "Mornye",
            "appVersion": env!("CARGO_PKG_VERSION"),
        });
        actor
            .send(opcode::INITIAL, Some(&initial))
            .await
            .map_err(lost)?;
        let end = json!({"event": {"type": MEDIA_ITEM_END}});
        actor
            .send(opcode::SUBSCRIBE_EVENT, Some(&end))
            .await
            .map_err(lost)?;
    }
    {
        // Receivers take a volume from any version on; one not reported yet
        // is the players' default, full.
        let mut status = actor.status.lock().expect("cast status");
        status.start(device, Some(actor.volume.unwrap_or(1.0)));
        (actor.emit)("castStatus", status.snapshot());
    }
    let (remote, commands) = Remote::channel();
    tokio::spawn(actor.run(commands));
    Ok(remote)
}

/// What the app asked of the current song.
#[derive(Default)]
struct Song {
    /// `Play` went out; before it the receiver holds nothing of ours.
    started: bool,
    played_at: Option<Instant>,
    playing_seen: bool,
    asked_pause: bool,
    asked_stop: bool,
    done: bool,
    /// Seconds to start from, set by seeks before play.
    start: f64,
    /// The last position the receiver reported.
    time: f64,
}

struct Actor {
    version: u64,
    writer: OwnedWriteHalf,
    packets: mpsc::Receiver<Packet>,
    _reader: Abort,
    status: Arc<Mutex<Status>>,
    emit: Emit,
    timing: Timing,
    item: Option<Item>,
    song: Song,
    last_seen: Instant,
    pinged: Option<Instant>,
    /// A volume heard during the handshake.
    volume: Option<f64>,
    /// A write failed: the connection is gone.
    broken: bool,
}

enum Flow {
    Continue,
    End,
}

impl Actor {
    async fn send(&mut self, code: u8, body: Option<&Value>) -> io::Result<()> {
        let packet = encode(code, body)?;
        // A receiver that stops reading must not hold the session.
        let write = async {
            self.writer.write_all(&packet).await?;
            self.writer.flush().await
        };
        tokio::time::timeout(WRITE_TIMEOUT, write)
            .await
            .unwrap_or_else(|_| Err(io::ErrorKind::TimedOut.into()))
    }

    /// The receiver's version, answering pings meanwhile.
    async fn receive_version(&mut self) -> Option<u64> {
        while let Some(packet) = self.packets.recv().await {
            match packet.opcode {
                opcode::VERSION => return packet.json()["version"].as_u64().filter(|v| *v > 0),
                opcode::PING => self.send(opcode::PONG, None).await.ok()?,
                opcode::VOLUME_UPDATE => self.volume = packet.json()["volume"].as_f64(),
                _ => {}
            }
        }
        None
    }

    async fn run(mut self, mut commands: Commands) {
        let mut keepalive =
            tokio::time::interval(self.timing.ping_after.min(self.timing.silence) / 4);
        let mut progress = tokio::time::interval(self.timing.progress);
        loop {
            let flow = tokio::select! {
                packet = self.packets.recv() => match packet {
                    Some(packet) => self.receive(packet).await,
                    None => Flow::End,
                },
                command = commands.recv() => match command {
                    Some((control, reply)) => {
                        let leaving = matches!(control, Control::Disconnect);
                        let result = self.command(control).await;
                        let ended = self.broken;
                        let _ = reply.send(result);
                        if leaving || ended { Flow::End } else { Flow::Continue }
                    }
                    None => Flow::End,
                },
                _ = keepalive.tick() => self.keepalive().await,
                _ = progress.tick() => {
                    let status = self.status.lock().expect("cast status");
                    if status.player_state == state::PLAYING {
                        (self.emit)("castStatus", status.snapshot());
                    }
                    Flow::Continue
                }
            };
            if matches!(flow, Flow::End) {
                break;
            }
        }
        let mut status = self.status.lock().expect("cast status");
        status.connected = false;
        (self.emit)("castStatus", status.snapshot());
    }

    /// Sends a command packet; a failed write ends the session.
    async fn order(&mut self, code: u8, body: Option<&Value>) -> Result<(), String> {
        match self.send(code, body).await {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::InvalidInput => {
                Err("The song details are too long for this receiver".into())
            }
            Err(_) => {
                self.broken = true;
                Err("Device is disconnected".into())
            }
        }
    }

    async fn keepalive(&mut self) -> Flow {
        let silent = self.last_seen.elapsed();
        if silent > self.timing.silence {
            return Flow::End;
        }
        // Ping arrived in v2; a v2 or newer receiver must answer it.
        let due = self
            .pinged
            .is_none_or(|at| at.elapsed() >= self.timing.ping_after);
        if self.version >= 2 && silent >= self.timing.ping_after && due {
            self.pinged = Some(Instant::now());
            if self.send(opcode::PING, None).await.is_err() {
                return Flow::End;
            }
        }
        let song = &self.song;
        if song.started
            && !song.playing_seen
            && !song.done
            && song
                .played_at
                .is_some_and(|at| at.elapsed() > self.timing.start_limit)
        {
            self.end_song(status::ERROR);
        }
        Flow::Continue
    }

    fn end_song(&mut self, reason: &str) {
        self.song.done = true;
        let mut status = self.status.lock().expect("cast status");
        status.player_state = state::IDLE;
        status.idle_reason = Some(reason.into());
        if reason == status::FINISHED && status.duration > 0.0 {
            let end = status.duration;
            status.report(end);
        }
        (self.emit)("castStatus", status.snapshot());
    }

    async fn receive(&mut self, packet: Packet) -> Flow {
        self.last_seen = Instant::now();
        self.pinged = None;
        let body = packet.json();
        match packet.opcode {
            opcode::PING => {
                if self.send(opcode::PONG, None).await.is_err() {
                    return Flow::End;
                }
            }
            opcode::VOLUME_UPDATE => {
                if let Some(volume) = body["volume"].as_f64() {
                    let mut status = self.status.lock().expect("cast status");
                    status.volume = Some(volume.clamp(0.0, 1.0));
                    (self.emit)("castStatus", status.snapshot());
                }
            }
            opcode::PLAYBACK_UPDATE => self.playback(&body),
            opcode::PLAYBACK_ERROR => {
                if self.song.started && !self.song.done {
                    self.end_song(status::ERROR);
                }
            }
            opcode::EVENT => {
                let event = &body["event"];
                let ours = event["item"]["url"]
                    .as_str()
                    .is_none_or(|url| self.item.as_ref().is_some_and(|item| item.url == url));
                if event["type"].as_i64() == Some(MEDIA_ITEM_END)
                    && ours
                    && self.song.playing_seen
                    && !self.song.done
                {
                    self.end_song(status::FINISHED);
                }
            }
            opcode::PLAY_UPDATE => {
                // Another sender played something else: the receiver is
                // theirs now, as when another app takes a Cast TV.
                let theirs = body["playData"]["url"]
                    .as_str()
                    .is_some_and(|url| self.item.as_ref().is_none_or(|item| item.url != url));
                if theirs && self.song.started && !self.song.done {
                    return Flow::End;
                }
            }
            _ => {}
        }
        Flow::Continue
    }

    fn playback(&mut self, update: &Value) {
        let song = &mut self.song;
        if !song.started || song.done {
            return;
        }
        let shared = Arc::clone(&self.status);
        let mut status = shared.lock().expect("cast status");
        if let Some(duration) = update["duration"].as_f64().filter(|d| *d > 0.0) {
            status.duration = duration;
        }
        if let Some(time) = update["time"].as_f64() {
            song.time = time.max(0.0);
        }
        let (duration, time) = (status.duration, song.time);
        let near_end = move |slack: f64| duration <= 0.0 || time >= duration - slack;
        match update["state"].as_i64() {
            Some(playback::PLAYING) => {
                song.playing_seen = true;
                status.player_state = state::PLAYING;
                status.report(song.time);
            }
            // Receivers end a song paused at its last second.
            Some(playback::PAUSED)
                if song.playing_seen && !song.asked_pause && duration > 0.0 && near_end(1.5) =>
            {
                drop(status);
                self.end_song(status::FINISHED);
                return;
            }
            Some(playback::PAUSED) => {
                status.player_state = state::PAUSED;
                status.report(song.time);
            }
            Some(playback::IDLE) if song.playing_seen && !song.asked_stop => {
                if near_end((duration * 0.1).max(10.0)) {
                    drop(status);
                    self.end_song(status::FINISHED);
                    return;
                }
                // Stopped on the receiver itself: not the song's end.
                song.asked_stop = true;
                status.player_state = state::IDLE;
            }
            Some(playback::IDLE) if song.asked_stop => status.player_state = state::IDLE,
            Some(playback::IDLE) => status.player_state = state::BUFFERING,
            _ => {}
        }
        (self.emit)("castStatus", status.snapshot());
    }

    async fn command(&mut self, control: Control) -> Result<(), String> {
        match control {
            Control::Load(item) => {
                if self.song.started && !self.song.done {
                    self.order(opcode::STOP, None).await?;
                }
                {
                    let mut status = self.status.lock().expect("cast status");
                    status.begin_item(item.token, item.duration_seconds());
                    (self.emit)("castStatus", status.snapshot());
                }
                self.item = Some(*item);
                self.song = Song::default();
                Ok(())
            }
            Control::Play => {
                let item = self.loaded()?.clone();
                if self.song.started && !self.song.asked_stop {
                    self.order(opcode::RESUME, None).await?;
                } else {
                    // A stopped receiver holds nothing to resume.
                    let play = self.play_message(&item);
                    self.order(opcode::PLAY, Some(&play)).await?;
                    self.song.started = true;
                    self.song.playing_seen = false;
                    self.song.played_at = Some(Instant::now());
                    let mut status = self.status.lock().expect("cast status");
                    status.player_state = state::BUFFERING;
                    (self.emit)("castStatus", status.snapshot());
                }
                self.song.asked_pause = false;
                self.song.asked_stop = false;
                Ok(())
            }
            Control::Pause => {
                self.loaded()?;
                if self.song.started {
                    self.order(opcode::PAUSE, None).await?;
                    self.song.asked_pause = true;
                }
                let mut status = self.status.lock().expect("cast status");
                status.player_state = state::PAUSED;
                (self.emit)("castStatus", status.snapshot());
                Ok(())
            }
            Control::Stop => {
                if self.song.started && !self.song.done {
                    self.order(opcode::STOP, None).await?;
                    self.song.asked_stop = true;
                    self.song.start = 0.0;
                    let mut status = self.status.lock().expect("cast status");
                    status.player_state = state::IDLE;
                    (self.emit)("castStatus", status.snapshot());
                }
                Ok(())
            }
            Control::Seek(seconds) => {
                self.loaded()?;
                let seconds = seconds.max(0.0);
                if self.song.started {
                    self.order(opcode::SEEK, Some(&json!({"time": seconds})))
                        .await?;
                } else {
                    self.song.start = seconds;
                }
                self.song.time = seconds;
                let mut status = self.status.lock().expect("cast status");
                status.report(seconds);
                (self.emit)("castStatus", status.snapshot());
                Ok(())
            }
            Control::Volume(level) => {
                let level = level.clamp(0.0, 1.0);
                self.order(opcode::SET_VOLUME, Some(&json!({"volume": level})))
                    .await?;
                let mut status = self.status.lock().expect("cast status");
                status.volume = Some(level);
                (self.emit)("castStatus", status.snapshot());
                Ok(())
            }
            Control::Disconnect => {
                // Stop the song on the receiver, as the Cast path does.
                if self.song.started && !self.song.done {
                    let _ = self.send(opcode::STOP, None).await;
                }
                let _ = self.writer.shutdown().await;
                Ok(())
            }
        }
    }

    fn loaded(&self) -> Result<&Item, String> {
        self.item
            .as_ref()
            .filter(|_| !self.song.done)
            .ok_or_else(|| "Nothing is loaded on the device".to_owned())
    }

    /// The `Play` body for the negotiated version: metadata came in v3.
    fn play_message(&self, item: &Item) -> Value {
        let mut play = json!({
            "container": item.mime,
            "url": item.url,
            "time": self.song.start,
        });
        if self.version >= 3 {
            let mut metadata = json!({"type": 0, "title": cut(&item.title)});
            if let Some(artwork) = &item.artwork {
                metadata["thumbnailUrl"] = json!(artwork);
            }
            metadata["custom"] = json!({"artist": cut(&item.artist), "album": cut(&item.album)});
            play["metadata"] = metadata;
        }
        play
    }
}

fn cut(text: &str) -> String {
    text.chars().take(MAX_TEXT).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packets_follow_the_v3_framing() {
        assert_eq!(encode(opcode::PING, None).unwrap(), [1, 0, 0, 0, 12]);
        let packet = encode(opcode::VERSION, Some(&json!({"version": 3}))).unwrap();
        let body = br#"{"version":3}"#;
        assert_eq!(&packet[..4], &((body.len() + 1) as u32).to_le_bytes());
        assert_eq!((packet[4], &packet[5..]), (11, &body[..]));
        let huge = json!({"url": "x".repeat(MAX_PACKET)});
        assert!(encode(opcode::PLAY, Some(&huge)).is_err());
    }
}
