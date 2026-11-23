//! The FCast sender against a scripted receiver speaking the v3 framing
//! over loopback TCP, as a v2, v3 and newer receiver.

use crate::discovery::{Device, Kind};
use crate::fcast::{self, Packet, Timing, encode, opcode};
use crate::session::{Control, Item, Remote};
use crate::status::Status;
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::mpsc;

#[derive(Clone, Copy, PartialEq)]
enum Script {
    /// Answers every request as a reference receiver does.
    Normal,
    /// Sends its version, then nothing, not even pongs.
    Mute,
    /// Never sends a version, as a v1 receiver.
    Old,
}

type Seen = mpsc::UnboundedSender<(u8, Value)>;

/// Speaks `version`, reports every packet it receives to `seen`, and sends
/// whatever the test pushes into `push`.
async fn receiver(
    listener: TcpListener,
    version: u64,
    script: Script,
    seen: Seen,
    mut push: mpsc::UnboundedReceiver<Option<Vec<u8>>>,
) {
    let (stream, _) = listener.accept().await.unwrap();
    let (mut reader, mut writer) = stream.into_split();
    if script != Script::Old {
        let hello = encode(opcode::VERSION, Some(&json!({"version": version}))).unwrap();
        writer.write_all(&hello).await.unwrap();
    }
    let (frames, mut incoming) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let mut size = [0u8; 4];
        while reader.read_exact(&mut size).await.is_ok() {
            let mut data = vec![0u8; u32::from_le_bytes(size) as usize];
            reader.read_exact(&mut data).await.unwrap();
            let body = data.split_off(1);
            if frames
                .send(Packet {
                    opcode: data[0],
                    body,
                })
                .is_err()
            {
                return;
            }
        }
    });
    let update = |state: i64, time: f64| {
        let body = json!({"generationTime": 1, "state": state, "time": time, "duration": 180.0, "speed": 1.0});
        encode(opcode::PLAYBACK_UPDATE, Some(&body)).unwrap()
    };
    let mut time = 0.0;
    loop {
        tokio::select! {
            packet = incoming.recv() => {
                let Some(packet) = packet else { return };
                let body = packet.json();
                let _ = seen.send((packet.opcode, body.clone()));
                if script != Script::Normal {
                    continue;
                }
                let mut out = Vec::new();
                match packet.opcode {
                    opcode::PLAY => {
                        time = body["time"].as_f64().unwrap_or_default();
                        let echo = json!({"generationTime": 1, "playData": body});
                        out.push(encode(opcode::PLAY_UPDATE, Some(&echo)).unwrap());
                        out.push(update(1, time));
                    }
                    opcode::PAUSE => out.push(update(2, time)),
                    opcode::RESUME => out.push(update(1, time)),
                    opcode::SEEK => {
                        time = body["time"].as_f64().unwrap();
                        out.push(update(1, time));
                    }
                    opcode::STOP => out.push(update(0, 0.0)),
                    opcode::SET_VOLUME => {
                        let volume = json!({"generationTime": 1, "volume": body["volume"]});
                        out.push(encode(opcode::VOLUME_UPDATE, Some(&volume)).unwrap());
                    }
                    opcode::PING => out.push(encode(opcode::PONG, None).unwrap()),
                    _ => {}
                }
                for frame in out {
                    if writer.write_all(&frame).await.is_err() {
                        return;
                    }
                }
            }
            frame = push.recv() => match frame.flatten() {
                Some(frame) => {
                    if writer.write_all(&frame).await.is_err() {
                        return;
                    }
                }
                // `None`: hang up.
                None => return,
            },
        }
    }
}

struct Fake {
    remote: Remote,
    status: Arc<Mutex<Status>>,
    events: Arc<Mutex<Vec<Value>>>,
    seen: mpsc::UnboundedReceiver<(u8, Value)>,
    push: mpsc::UnboundedSender<Option<Vec<u8>>>,
}

impl Fake {
    fn drain(&mut self) -> Vec<(u8, Value)> {
        let mut packets = Vec::new();
        while let Ok(packet) = self.seen.try_recv() {
            packets.push(packet);
        }
        packets
    }

    /// What the receiver got, keep-alive pings aside.
    fn packets(&mut self) -> Vec<(u8, Value)> {
        let mut packets = self.drain();
        packets.retain(|(code, _)| *code != opcode::PING);
        packets
    }
}

fn timing() -> Timing {
    Timing {
        connect: Duration::from_secs(1),
        version: Duration::from_millis(300),
        ping_after: Duration::from_millis(80),
        silence: Duration::from_millis(400),
        start_limit: Duration::from_secs(2),
        progress: Duration::from_millis(20),
    }
}

fn device(port: u16) -> Device {
    let host = "127.0.0.1".parse().unwrap();
    Device::new(Kind::Fcast, "fcast:Den TV", "Den TV", "FCast", host, port)
}

async fn start(version: u64, script: Script) -> Result<Fake, String> {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (seen_tx, seen) = mpsc::unbounded_channel();
    let (push, pushed) = mpsc::unbounded_channel();
    tokio::spawn(receiver(listener, version, script, seen_tx, pushed));
    let events = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&events);
    let status = Arc::new(Mutex::new(Status::default()));
    let remote = fcast::connect_with(
        device(port),
        Arc::clone(&status),
        Arc::new(move |name: &str, payload: Value| {
            assert_eq!(name, "castStatus");
            log.lock().unwrap().push(payload);
        }),
        timing(),
    )
    .await?;
    Ok(Fake {
        remote,
        status,
        events,
        seen,
        push,
    })
}

fn item(token: i64) -> Box<Item> {
    Box::new(
        Item::from_request(&json!({
            "url": format!("http://192.0.2.1:4000/media/{token}"), "mime": "audio/flac",
            "token": token, "title": "Song", "artist": "Artist", "album": "Album",
            "artwork": "http://192.0.2.1:4000/media/art", "duration": 180_000,
        }))
        .unwrap(),
    )
}

async fn until(status: &Arc<Mutex<Status>>, what: &str, check: impl Fn(&Value) -> bool) {
    for _ in 0..100 {
        if check(&status.lock().unwrap().snapshot()) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("{what}: {}", status.lock().unwrap().snapshot());
}

fn end_event(url: &str) -> Option<Vec<u8>> {
    let event = json!({"generationTime": 1, "event": {"type": 1, "item": {"container": "audio/flac", "url": url}}});
    Some(encode(opcode::EVENT, Some(&event)).unwrap())
}

#[tokio::test]
async fn a_v3_receiver_plays_seeks_and_tells_a_natural_end_from_a_stop() {
    let mut fake = start(3, Script::Normal).await.unwrap();
    let connected = fake.status.lock().unwrap().snapshot();
    assert_eq!(
        (connected["connected"].clone(), connected["kind"].clone()),
        (json!(true), json!("fcast"))
    );
    assert_eq!(connected["deviceId"], "fcast:Den TV");
    assert_eq!(connected["volume"], 1.0);
    tokio::time::sleep(Duration::from_millis(30)).await;
    let handshake = fake.packets();
    assert_eq!(handshake[0], (opcode::VERSION, json!({"version": 3})));
    assert_eq!(handshake[1].0, opcode::INITIAL);
    assert_eq!(handshake[2], (17, json!({"event": {"type": 1}})));

    // Loading holds the song until play, which starts at an earlier seek.
    fake.remote.ask(Control::Load(item(42))).await.unwrap();
    fake.remote.ask(Control::Seek(30.0)).await.unwrap();
    assert!(fake.packets().is_empty(), "nothing is sent before play");
    let snapshot = fake.status.lock().unwrap().snapshot();
    assert_eq!(
        (snapshot["state"].clone(), snapshot["token"].clone()),
        (json!(3), json!(42))
    );
    fake.remote.ask(Control::Play).await.unwrap();
    until(&fake.status, "playing", |s| s["state"] == 2).await;
    let (code, play) = fake.packets().remove(0);
    assert_eq!(code, opcode::PLAY);
    assert_eq!(play["container"], "audio/flac");
    assert_eq!(play["url"], "http://192.0.2.1:4000/media/42");
    assert_eq!(play["time"], 30.0);
    assert_eq!(play["metadata"]["type"], 0);
    assert_eq!(play["metadata"]["title"], "Song");
    assert_eq!(
        play["metadata"]["thumbnailUrl"],
        "http://192.0.2.1:4000/media/art"
    );
    assert!((30_000..31_000).contains(&fake.status.lock().unwrap().position_ms()));

    fake.remote.ask(Control::Pause).await.unwrap();
    until(&fake.status, "paused", |s| s["state"] == 3).await;
    fake.remote.ask(Control::Volume(0.25)).await.unwrap();
    until(&fake.status, "volume", |s| s["volume"] == 0.25).await;
    fake.remote.ask(Control::Play).await.unwrap();
    fake.remote.ask(Control::Seek(170.0)).await.unwrap();
    until(&fake.status, "seeked", |s| {
        s["state"] == 2 && s["position"].as_i64() >= Some(170_000)
    })
    .await;
    let codes: Vec<u8> = fake.packets().into_iter().map(|(code, _)| code).collect();
    assert_eq!(
        codes,
        [
            opcode::PAUSE,
            opcode::SET_VOLUME,
            opcode::RESUME,
            opcode::SEEK
        ]
    );

    // Another song's end event is not this one's.
    fake.push
        .send(end_event("http://192.0.2.1:4000/media/other"))
        .unwrap();
    tokio::time::sleep(Duration::from_millis(40)).await;
    assert_eq!(fake.status.lock().unwrap().snapshot()["finished"], false);
    fake.push
        .send(end_event("http://192.0.2.1:4000/media/42"))
        .unwrap();
    until(&fake.status, "finished", |s| {
        s["finished"] == true && s["token"] == 42
    })
    .await;

    // A stop the app asks for is not an end.
    fake.remote.ask(Control::Load(item(43))).await.unwrap();
    fake.remote.ask(Control::Play).await.unwrap();
    until(&fake.status, "playing again", |s| {
        s["state"] == 2 && s["token"] == 43
    })
    .await;
    fake.remote.ask(Control::Stop).await.unwrap();
    tokio::time::sleep(Duration::from_millis(60)).await;
    let snapshot = fake.status.lock().unwrap().snapshot();
    assert_eq!(
        (snapshot["state"].clone(), snapshot["finished"].clone()),
        (json!(1), json!(false))
    );
    assert!(
        fake.events
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e["token"] == 43)
            .all(|e| e["finished"] == false)
    );
    // Play after a stop starts the song again: there is nothing to resume.
    fake.remote.ask(Control::Play).await.unwrap();
    tokio::time::sleep(Duration::from_millis(30)).await;
    let codes: Vec<u8> = fake.packets().into_iter().map(|(code, _)| code).collect();
    assert_eq!(codes, [opcode::PLAY, opcode::STOP, opcode::PLAY]);

    fake.remote.ask(Control::Disconnect).await.unwrap();
    tokio::time::sleep(Duration::from_millis(40)).await;
    assert_eq!(
        fake.packets().last().map(|(code, _)| *code),
        Some(opcode::STOP)
    );
    assert_eq!(
        fake.events.lock().unwrap().last().unwrap()["connected"],
        false
    );
    assert!(fake.remote.ask(Control::Play).await.is_err());
}

#[tokio::test]
async fn a_v2_receiver_gets_v2_messages_and_its_paused_end_counts() {
    let mut fake = start(2, Script::Normal).await.unwrap();
    fake.remote.ask(Control::Load(item(7))).await.unwrap();
    fake.remote.ask(Control::Play).await.unwrap();
    until(&fake.status, "playing", |s| s["state"] == 2).await;
    let packets = fake.packets();
    assert_eq!(packets[0], (opcode::VERSION, json!({"version": 3})));
    let (code, play) = &packets[1];
    assert_eq!(*code, opcode::PLAY, "no Initial or subscription for v2");
    assert!(play.get("metadata").is_none());
    // v2 receivers end a song paused at its last second.
    let body =
        json!({"generationTime": 1, "state": 2, "time": 179.6, "duration": 180.0, "speed": 1.0});
    let paused = Some(encode(opcode::PLAYBACK_UPDATE, Some(&body)).unwrap());
    fake.push.send(paused).unwrap();
    until(&fake.status, "finished", |s| {
        s["finished"] == true && s["token"] == 7
    })
    .await;
}

#[tokio::test]
async fn a_newer_receiver_is_spoken_to_in_v3_and_errors_fail_the_song() {
    let mut fake = start(4, Script::Normal).await.unwrap();
    tokio::time::sleep(Duration::from_millis(30)).await;
    let codes: Vec<u8> = fake.packets().into_iter().map(|(code, _)| code).collect();
    assert_eq!(codes, [opcode::VERSION, opcode::INITIAL, 17]);
    fake.remote.ask(Control::Load(item(8))).await.unwrap();
    fake.remote.ask(Control::Play).await.unwrap();
    until(&fake.status, "playing", |s| s["state"] == 2).await;
    let error = json!({"message": "Unsupported format"});
    fake.push
        .send(Some(encode(opcode::PLAYBACK_ERROR, Some(&error)).unwrap()))
        .unwrap();
    until(&fake.status, "failed", |s| {
        s["failed"] == true && s["token"] == 8
    })
    .await;
    assert_eq!(fake.status.lock().unwrap().snapshot()["finished"], false);
    assert!(
        fake.remote.ask(Control::Play).await.is_err(),
        "the failed song is gone"
    );

    // Another sender playing something else takes the receiver away.
    fake.remote.ask(Control::Load(item(9))).await.unwrap();
    fake.remote.ask(Control::Play).await.unwrap();
    until(&fake.status, "playing", |s| {
        s["state"] == 2 && s["token"] == 9
    })
    .await;
    let other = json!({"generationTime": 2, "playData": {"container": "video/mp4", "url": "http://198.51.100.2/v.mp4"}});
    fake.push
        .send(Some(encode(opcode::PLAY_UPDATE, Some(&other)).unwrap()))
        .unwrap();
    until(&fake.status, "taken", |s| s["connected"] == false).await;
}

#[tokio::test]
async fn a_dropped_or_mute_receiver_ends_the_session() {
    let fake = start(3, Script::Normal).await.unwrap();
    fake.remote.ask(Control::Load(item(1))).await.unwrap();
    fake.push.send(None).unwrap();
    until(&fake.status, "dropped", |s| s["connected"] == false).await;
    assert!(fake.remote.ask(Control::Play).await.is_err());

    // Answers nothing, not even pings: silence ends it.
    let mut mute = start(3, Script::Mute).await.unwrap();
    until(&mute.status, "silenced", |s| s["connected"] == false).await;
    assert!(mute.drain().iter().any(|(code, _)| *code == opcode::PING));
}

#[tokio::test]
async fn receivers_that_cannot_be_reached_or_speak_no_version_fail_to_connect() {
    let error = start(3, Script::Old).await.err().unwrap();
    assert_eq!(error, "Den TV does not speak a supported FCast version");
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let status = Arc::new(Mutex::new(Status::default()));
    let result = fcast::connect_with(
        device(port),
        Arc::clone(&status),
        Arc::new(|_: &str, _| {}),
        timing(),
    )
    .await;
    assert_eq!(result.err().unwrap(), "Could not reach Den TV");
    assert_eq!(status.lock().unwrap().snapshot()["connected"], false);
}
