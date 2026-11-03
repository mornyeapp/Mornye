//! The sender against a scripted receiver speaking Cast v2 over TLS.

use crate::discovery::Device;
use crate::proto::{CONNECTION, HEARTBEAT, MEDIA, Message, RECEIVER};
use crate::sender::{self, Status};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_rustls::TlsAcceptor;

fn acceptor() -> TlsAcceptor {
    let key = rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256).unwrap();
    let cert = rcgen::CertificateParams::new(vec!["receiver".into()])
        .unwrap()
        .self_signed(&key)
        .unwrap();
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(
        vec![CertificateDer::from(cert.der().to_vec())],
        PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der())),
    )
    .unwrap();
    TlsAcceptor::from(Arc::new(config))
}

/// Answers like a TV running the Default Media Receiver and reports every
/// message it receives to `seen`.
async fn receiver(listener: TcpListener, seen: mpsc::UnboundedSender<(String, Value)>) {
    let (stream, _) = listener.accept().await.unwrap();
    let mut stream = acceptor().accept(stream).await.unwrap();
    let app = json!([{"appId": "CC1AD845", "transportId": "web-1", "sessionId": "session-1"}]);
    let mut length = [0u8; 4];
    while stream.read_exact(&mut length).await.is_ok() {
        let mut body = vec![0u8; u32::from_be_bytes(length) as usize];
        stream.read_exact(&mut body).await.unwrap();
        let message = Message::decode(&body).unwrap();
        let payload: Value = serde_json::from_str(&message.payload).unwrap();
        let id = payload["requestId"].clone();
        let reply = |namespace: &str, from: &str, payload: Value| {
            Message::new(from, "sender-0", namespace, payload.to_string()).encode()
        };
        let mut out = Vec::new();
        match (
            message.namespace.as_str(),
            payload["type"].as_str().unwrap(),
        ) {
            (RECEIVER, "LAUNCH") => out.push(reply(
                RECEIVER,
                "receiver-0",
                json!({"type": "RECEIVER_STATUS", "requestId": id,
                    "status": {"applications": app, "volume": {"level": 0.5}}}),
            )),
            (RECEIVER, "SET_VOLUME") => out.push(reply(
                RECEIVER,
                "receiver-0",
                json!({"type": "RECEIVER_STATUS", "requestId": id,
                    "status": {"applications": app, "volume": payload["volume"]}}),
            )),
            (MEDIA, "GET_STATUS") => out.push(reply(
                MEDIA,
                "web-1",
                json!({"type": "MEDIA_STATUS", "requestId": id, "status": []}),
            )),
            (MEDIA, "LOAD") if payload["media"]["contentType"] == "audio/x-bad" => out.push(reply(
                MEDIA,
                "web-1",
                json!({"type": "LOAD_FAILED", "requestId": id}),
            )),
            (MEDIA, "LOAD") => out.push(reply(
                MEDIA,
                "web-1",
                json!({"type": "MEDIA_STATUS", "requestId": id, "status": [{
                    "mediaSessionId": 1, "playerState": "PAUSED", "currentTime": 0,
                    "media": {"duration": 180.0}}]}),
            )),
            (MEDIA, "PLAY") => {
                out.push(reply(
                    MEDIA,
                    "web-1",
                    json!({"type": "MEDIA_STATUS", "requestId": id, "status": [{
                        "mediaSessionId": 1, "playerState": "PLAYING", "currentTime": 3.0}]}),
                ));
                // The song ends; receivers drop the media object here.
                out.push(reply(
                    MEDIA,
                    "web-1",
                    json!({"type": "MEDIA_STATUS", "requestId": 0, "status": [{
                        "mediaSessionId": 1, "playerState": "IDLE", "idleReason": "FINISHED"}]}),
                ));
            }
            (HEARTBEAT, "PING") => {
                out.push(reply(HEARTBEAT, "receiver-0", json!({"type": "PONG"})));
            }
            _ => {}
        }
        seen.send((message.namespace.clone(), payload)).unwrap();
        for frame in out {
            stream.write_all(&frame).await.unwrap();
        }
    }
}

fn device(port: u16) -> Device {
    Device {
        id: "device-1".into(),
        name: "Living Room".into(),
        model: "Speaker".into(),
        host: "127.0.0.1".parse().unwrap(),
        port,
    }
}

#[tokio::test]
async fn a_session_launches_loads_plays_and_stops_the_receiver() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (seen, mut received) = mpsc::unbounded_channel();
    tokio::spawn(receiver(listener, seen));
    let events = Arc::new(Mutex::new(Vec::<Value>::new()));
    let log = Arc::clone(&events);
    let status = Arc::new(Mutex::new(Status::default()));
    let session = sender::connect(
        device(port),
        Arc::clone(&status),
        Arc::new(move |name: &str, payload: Value| {
            assert_eq!(name, "castStatus");
            log.lock().unwrap().push(payload);
        }),
    )
    .await
    .unwrap();
    let connected = status.lock().unwrap().snapshot();
    assert_eq!(connected["connected"], true);
    assert_eq!(connected["volume"], 0.5);
    assert_eq!(connected["revision"], 1);

    session
        .load(
            &json!({"url": "http://192.0.2.1/media/x", "mime": "audio/flac",
            "token": 42, "title": "Song", "artist": "Artist", "duration": 180_000}),
        )
        .await
        .unwrap();
    assert_eq!(status.lock().unwrap().snapshot()["token"], 42);
    session.media("PLAY", json!({})).await.unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let finished = events
        .lock()
        .unwrap()
        .iter()
        .any(|event| event["finished"] == true && event["token"] == 42);
    assert!(
        finished,
        "the end of the song reaches the app with its token"
    );

    session.volume(0.25).await.unwrap();
    assert_eq!(status.lock().unwrap().snapshot()["volume"], 0.25);
    let rejected = session
        .load(&json!({"url": "http://192.0.2.1/media/y", "mime": "audio/x-bad", "token": 43}))
        .await;
    assert!(rejected.is_err());

    session.disconnect().await.unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let mut messages = Vec::new();
    while let Ok(message) = received.try_recv() {
        messages.push(message);
    }
    let load = messages
        .iter()
        .find(|(_, payload)| payload["type"] == "LOAD")
        .map(|(_, payload)| payload)
        .unwrap();
    assert_eq!(load["sessionId"], "session-1");
    assert_eq!(load["autoplay"], false);
    assert_eq!(load["media"]["metadata"]["title"], "Song");
    assert_eq!(load["media"]["duration"], 180.0);
    assert!(
        messages
            .iter()
            .any(|(namespace, payload)| namespace == RECEIVER && payload["type"] == "STOP")
    );
    assert!(
        messages
            .iter()
            .any(|(namespace, payload)| namespace == CONNECTION && payload["type"] == "CLOSE")
    );
    assert_eq!(events.lock().unwrap().last().unwrap()["connected"], false);
}

#[tokio::test]
async fn an_unreachable_receiver_fails_without_a_session() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let status = Arc::new(Mutex::new(Status::default()));
    let result =
        sender::connect(device(port), Arc::clone(&status), Arc::new(|_: &str, _| {})).await;
    assert!(result.is_err());
    assert_eq!(status.lock().unwrap().snapshot()["connected"], false);
}
