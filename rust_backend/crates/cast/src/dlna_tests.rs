//! The DLNA sender and discovery against a scripted renderer answering its
//! description and SOAP over loopback HTTP, with sloppy XML as real ones do.

use crate::discovery::{Device, Kind, Registry};
use crate::dlna::{self, Catalog, Timing};
use crate::session::{Control, Item, Remote};
use crate::ssdp::{Announce, Message};
use crate::status::Status;
use crate::xml;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

const DESCRIPTION: &str = "<?xml version=\"1.0\"?>\r\n<root xmlns=\"urn:schemas-upnp-org:device-1-0\">\
    <device><deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType><friendlyName>Box</friendlyName>\
    <deviceList><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>\
    <friendlyName>Living Room & Hall</friendlyName><modelName>Renderer 9</modelName>\
    <UDN>uuid:renderer-1</UDN><iconList><icon><url>/icon.png</icon></iconList><serviceList>\
    <service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>\
    <controlURL>avt</controlURL><SCPDURL>/avt.xml</SCPDURL></service>\
    <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>\
    <controlURL>/rc</controlURL><SCPDURL>rc.xml</SCPDURL></service>\
    <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>\
    <controlURL>/cm</controlURL></service></serviceList></device></deviceList></device></root>";

/// A renderer with only AVTransport: no volume, no protocol list.
const BARE: &str = "<root><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1\
    </deviceType><friendlyName>Shelf</friendlyName><UDN>uuid:renderer-1</UDN><serviceList><service>\
    <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/avt</controlURL>\
    </service></serviceList></device></root>";

const SCPD: &str = "<scpd><serviceStateTable><stateVariable><name>Volume</name>\
    <allowedValueRange><minimum>0</minimum><maximum>60</maximum></allowedValueRange>\
    </stateVariable></serviceStateTable></scpd>";

struct Fake {
    transport: &'static str,
    healthy: bool,
    position: f64,
    volume: u32,
    actions: Vec<(String, BTreeMap<String, String>)>,
    /// Pause is optional in AVTransport; this renderer lacks it.
    no_pause: bool,
    /// Starts playing on `SetAVTransportURI`.
    autoplay: bool,
    /// Accepts connections and answers nothing.
    silent: bool,
    /// Accepts play and stays stopped, as one that cannot fetch the song.
    stuck: bool,
}

impl Fake {
    fn new() -> Arc<Mutex<Self>> {
        Arc::new(Mutex::new(Self {
            transport: "NO_MEDIA_PRESENT",
            healthy: true,
            position: 0.0,
            volume: 30,
            actions: Vec::new(),
            no_pause: false,
            autoplay: false,
            silent: false,
            stuck: false,
        }))
    }

    fn actions(&self, name: &str) -> Vec<BTreeMap<String, String>> {
        self.actions
            .iter()
            .filter(|(action, _)| action == name)
            .map(|(_, arguments)| arguments.clone())
            .collect()
    }
}

fn clock(seconds: f64) -> String {
    let total = seconds as u64;
    format!(
        "{}:{:02}:{:02}.000",
        total / 3600,
        (total / 60) % 60,
        total % 60
    )
}

fn fault(code: u32) -> (u16, String) {
    (
        500,
        format!(
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><s:Fault>\
             <faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>\
             <UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>{code}</errorCode>\
             <errorDescription>Refused</errorDescription></UPnPError></detail></s:Fault></s:Body>\
             </s:Envelope>"
        ),
    )
}

/// The answer to one SOAP action, sloppy where real renderers are.
fn act(fake: &mut Fake, action: &str, arguments: &BTreeMap<String, String>) -> (u16, String) {
    let argument = |name: &str| arguments.get(name).cloned().unwrap_or_default();
    let outputs = match action {
        "GetTransportInfo" => format!(
            "<CurrentTransportState>{}</CurrentTransportState><CurrentTransportStatus>{}\
             </CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed>",
            fake.transport,
            if fake.healthy { "OK" } else { "ERROR_OCCURRED" }
        ),
        "GetPositionInfo" => format!(
            "<Track>1</Track><TrackDuration>0:03:00</TrackDuration><TrackMetaData>&lt;DIDL-Lite \
             xmlns=&quot;urn:x&quot;&gt;&lt;item&gt;Rock & Roll&lt;/item&gt;&lt;/DIDL-Lite&gt;\
             </TrackMetaData><TrackURI>x</TrackURI><RelTime>{}</RelTime><AbsTime>NOT_IMPLEMENTED\
             </AbsTime><RelCount>2147483647</RelCount><AbsCount>2147483647</AbsCount>",
            clock(fake.position)
        ),
        "SetAVTransportURI" => {
            if argument("CurrentURIMetaData").contains("audio/x-bad") {
                return fault(714);
            }
            fake.transport = if fake.autoplay { "PLAYING" } else { "STOPPED" };
            fake.position = 0.0;
            String::new()
        }
        "Play" => {
            if !fake.stuck {
                fake.transport = "PLAYING";
            }
            String::new()
        }
        "Pause" if fake.no_pause => return fault(401),
        "Pause" => {
            fake.transport = "PAUSED_PLAYBACK";
            String::new()
        }
        "Stop" => {
            fake.transport = "STOPPED";
            String::new()
        }
        "Seek" => {
            let target = argument("Target");
            let parts: Vec<f64> = target
                .split(':')
                .filter_map(|part| part.parse().ok())
                .collect();
            fake.position = parts.iter().fold(0.0, |total, part| total * 60.0 + part);
            String::new()
        }
        "GetVolume" => format!("<CurrentVolume>{}</CurrentVolume>", fake.volume),
        "SetVolume" => {
            fake.volume = argument("DesiredVolume").parse().unwrap();
            String::new()
        }
        "GetProtocolInfo" => "<Source></Source><Sink>http-get:*:audio/x-flac:*,\
            http-get:*:audio/mpeg:DLNA.ORG_PN=MP3</Sink>"
            .into(),
        _ => return fault(401),
    };
    (
        200,
        format!(
            "<?xml version=\"1.0\"?><SOAP-ENV:Envelope xmlns:SOAP-ENV=\"http://schemas.xmlsoap.org/soap/envelope/\">\
             <SOAP-ENV:Body><m:{action}Response xmlns:m=\"urn:schemas-upnp-org:service:x:1\">{outputs}\
             </m:{action}Response></SOAP-ENV:Body></SOAP-ENV:Envelope>"
        ),
    )
}

async fn answer(mut stream: TcpStream, fake: Arc<Mutex<Fake>>) {
    let mut raw = Vec::new();
    let mut buffer = [0u8; 4096];
    let split = loop {
        let Ok(read) = stream.read(&mut buffer).await else {
            return;
        };
        if read == 0 {
            return;
        }
        raw.extend_from_slice(&buffer[..read]);
        if let Some(split) = raw.windows(4).position(|window| window == b"\r\n\r\n") {
            break split;
        }
    };
    let head = String::from_utf8_lossy(&raw[..split]).into_owned();
    let header = |name: &str| {
        head.lines()
            .filter_map(|line| line.split_once(':'))
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.trim().to_owned())
    };
    let length: usize = header("content-length")
        .and_then(|n| n.parse().ok())
        .unwrap_or(0);
    while raw.len() < split + 4 + length {
        let Ok(read) = stream.read(&mut buffer).await else {
            return;
        };
        if read == 0 {
            return;
        }
        raw.extend_from_slice(&buffer[..read]);
    }
    if fake.lock().unwrap().silent {
        tokio::time::sleep(Duration::from_secs(10)).await;
        return;
    }
    let body = String::from_utf8_lossy(&raw[split + 4..]).into_owned();
    let path = head
        .split_whitespace()
        .nth(1)
        .unwrap_or_default()
        .to_owned();
    let (status, text) = match path.as_str() {
        "/description.xml" => (200, DESCRIPTION.to_owned()),
        "/bare.xml" => (200, BARE.to_owned()),
        "/rc.xml" => (200, SCPD.to_owned()),
        "/avt" | "/rc" | "/cm" => {
            let action = header("soapaction").unwrap_or_default();
            let action = action
                .trim_matches('"')
                .rsplit('#')
                .next()
                .unwrap_or_default()
                .to_owned();
            let root = xml::parse(&body);
            let arguments: BTreeMap<String, String> = root
                .find(&action)
                .map(|element| {
                    element
                        .children
                        .iter()
                        .map(|argument| (argument.name.clone(), xml::decode(&argument.text)))
                        .collect()
                })
                .unwrap_or_default();
            let mut fake = fake.lock().unwrap();
            fake.actions.push((action.clone(), arguments.clone()));
            act(&mut fake, &action, &arguments)
        }
        _ => (404, String::new()),
    };
    let reply = format!(
        "HTTP/1.1 {status} X\r\nCONTENT-TYPE: text/xml; charset=\"utf-8\"\r\nContent-Length: {}\r\n\
         Connection: close\r\nEXT:\r\n\r\n{text}",
        text.len()
    );
    let _ = stream.write_all(reply.as_bytes()).await;
}

async fn renderer(fake: Arc<Mutex<Fake>>) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(answer(stream, Arc::clone(&fake)));
        }
    });
    port
}

fn device(port: u16) -> Device {
    let mut device = Device::new(
        Kind::Dlna,
        "dlna:uuid:renderer-1",
        "Living Room & Hall",
        "Renderer 9",
        "127.0.0.1".parse().unwrap(),
        port,
    );
    device.location = Some(format!("http://127.0.0.1:{port}/description.xml"));
    device
}

fn timing() -> Timing {
    Timing {
        poll: Duration::from_millis(20),
        idle_every: 1,
        progress: Duration::from_millis(20),
        call: Duration::from_secs(1),
        poll_timeout: Duration::from_millis(300),
        load: Duration::from_secs(1),
        give_up: 3,
        start_limit: Duration::from_millis(500),
    }
}

type Events = Arc<Mutex<Vec<Value>>>;

async fn session(fake: &Arc<Mutex<Fake>>) -> (Remote, Arc<Mutex<Status>>, Events) {
    let port = renderer(Arc::clone(fake)).await;
    let events = Events::default();
    let log = Arc::clone(&events);
    let status = Arc::new(Mutex::new(Status::default()));
    let remote = dlna::connect_with(
        device(port),
        Arc::clone(&status),
        Arc::new(move |name: &str, payload: Value| {
            assert_eq!(name, "castStatus");
            log.lock().unwrap().push(payload);
        }),
        timing(),
    )
    .await
    .unwrap();
    (remote, status, events)
}

fn item(token: i64, mime: &str) -> Box<Item> {
    Box::new(
        Item::from_request(&json!({
            "url": format!("http://192.0.2.1:4000/media/{token}"), "mime": mime, "token": token,
            "title": "Song & Co", "artist": "Artist", "album": "Album",
            "artwork": "http://192.0.2.1:4000/media/art", "duration": 180_000,
        }))
        .unwrap(),
    )
}

/// Waits until `check` holds for the status, or fails the test.
async fn until(status: &Arc<Mutex<Status>>, what: &str, check: impl Fn(&Value) -> bool) {
    for _ in 0..150 {
        if check(&status.lock().unwrap().snapshot()) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("{what}: {}", status.lock().unwrap().snapshot());
}

#[tokio::test]
async fn a_renderer_loads_plays_seeks_and_tells_a_natural_end_from_a_stop() {
    let fake = Fake::new();
    let (remote, status, events) = session(&fake).await;
    let connected = status.lock().unwrap().snapshot();
    assert_eq!(connected["connected"], true);
    assert_eq!(connected["kind"], "dlna");
    assert_eq!(connected["deviceId"], "dlna:uuid:renderer-1");
    assert_eq!(connected["volume"], 0.5, "30 of a 60 step volume");

    remote
        .ask(Control::Load(item(42, "audio/flac")))
        .await
        .unwrap();
    let snapshot = status.lock().unwrap().snapshot();
    assert_eq!(
        (snapshot["token"].clone(), snapshot["state"].clone()),
        (json!(42), json!(3))
    );
    assert_eq!(snapshot["duration"], 180_000);
    let set = fake.lock().unwrap().actions("SetAVTransportURI").remove(0);
    assert_eq!(set["CurrentURI"], "http://192.0.2.1:4000/media/42");
    let didl = xml::parse(&set["CurrentURIMetaData"]);
    let entry = didl.find("item").unwrap();
    assert_eq!(entry.text_of("title"), "Song & Co");
    assert_eq!(entry.text_of("album"), "Album");
    assert_eq!(
        entry.text_of("albumArtURI"),
        "http://192.0.2.1:4000/media/art"
    );
    let protocol = entry
        .child("res")
        .unwrap()
        .attribute("protocolInfo")
        .unwrap()
        .to_owned();
    assert!(
        protocol.starts_with("http-get:*:audio/x-flac:DLNA.ORG_OP=01"),
        "{protocol}"
    );

    // A seek before play waits for the renderer to play.
    remote.ask(Control::Seek(30.0)).await.unwrap();
    assert!(fake.lock().unwrap().actions("Seek").is_empty());
    assert_eq!(status.lock().unwrap().snapshot()["position"], 30_000);
    remote.ask(Control::Play).await.unwrap();
    until(&status, "playing", |s| s["state"] == 2).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let seeks = fake.lock().unwrap().actions("Seek");
    assert_eq!(seeks.len(), 1);
    assert_eq!(
        (seeks[0]["Unit"].as_str(), seeks[0]["Target"].as_str()),
        ("REL_TIME", "0:00:30")
    );

    fake.lock().unwrap().position = 60.0;
    until(&status, "position", |s| {
        (60_000..62_000).contains(&s["position"].as_i64().unwrap())
    })
    .await;
    remote.ask(Control::Pause).await.unwrap();
    until(&status, "paused", |s| s["state"] == 3).await;
    remote.ask(Control::Volume(0.25)).await.unwrap();
    assert_eq!(fake.lock().unwrap().volume, 15);
    assert_eq!(status.lock().unwrap().snapshot()["volume"], 0.25);
    remote.ask(Control::Play).await.unwrap();
    until(&status, "resumed", |s| s["state"] == 2).await;

    // The renderer stops by itself at the end of the song.
    fake.lock().unwrap().position = 179.0;
    tokio::time::sleep(Duration::from_millis(60)).await;
    fake.lock().unwrap().transport = "STOPPED";
    until(&status, "finished", |s| s["finished"] == true).await;
    assert_eq!(status.lock().unwrap().snapshot()["token"], 42);

    // A stop the app asks for is not an end.
    remote
        .ask(Control::Load(item(43, "audio/mpeg")))
        .await
        .unwrap();
    remote.ask(Control::Play).await.unwrap();
    until(&status, "playing again", |s| {
        s["state"] == 2 && s["token"] == 43
    })
    .await;
    fake.lock().unwrap().position = 20.0;
    remote.ask(Control::Stop).await.unwrap();
    tokio::time::sleep(Duration::from_millis(150)).await;
    let snapshot = status.lock().unwrap().snapshot();
    assert_eq!(
        (snapshot["state"].clone(), snapshot["finished"].clone()),
        (json!(1), json!(false))
    );
    assert!(
        events
            .lock()
            .unwrap()
            .iter()
            .filter(|event| event["token"] == 43)
            .all(|event| event["finished"] == false)
    );

    remote.ask(Control::Disconnect).await.unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(events.lock().unwrap().last().unwrap()["connected"], false);
    assert_eq!(
        fake.lock().unwrap().actions("Stop").len(),
        2,
        "disconnect stops the song"
    );
    assert!(remote.ask(Control::Play).await.is_err());
}

#[tokio::test]
async fn quirky_renderers_are_held_resumed_and_failed() {
    let fake = Fake::new();
    {
        let mut fake = fake.lock().unwrap();
        fake.autoplay = true;
        fake.no_pause = true;
    }
    let (remote, status, _) = session(&fake).await;

    // A renderer that starts on load is held, as loads do not play.
    remote
        .ask(Control::Load(item(1, "audio/flac")))
        .await
        .unwrap();
    until(&status, "held", |s| s["state"] == 3).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(fake.lock().unwrap().actions("Pause").len(), 1);
    assert_eq!(fake.lock().unwrap().transport, "STOPPED", "held by a stop");
    assert_eq!(status.lock().unwrap().snapshot()["state"], 3);

    // Without Pause, pausing stops and resuming seeks back.
    remote.ask(Control::Play).await.unwrap();
    fake.lock().unwrap().position = 50.0;
    until(&status, "at 50 s", |s| {
        s["position"].as_i64().unwrap() >= 50_000
    })
    .await;
    remote.ask(Control::Pause).await.unwrap();
    assert_eq!(fake.lock().unwrap().transport, "STOPPED");
    tokio::time::sleep(Duration::from_millis(100)).await;
    let snapshot = status.lock().unwrap().snapshot();
    assert_eq!(
        (snapshot["state"].clone(), snapshot["finished"].clone()),
        (json!(3), json!(false))
    );
    remote.ask(Control::Play).await.unwrap();
    until(&status, "resumed", |s| s["state"] == 2).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let seeks = fake.lock().unwrap().actions("Seek");
    assert_eq!(seeks.last().unwrap()["Target"], "0:00:50");

    // A format the renderer refuses fails the load in plain words.
    let refused = remote.ask(Control::Load(item(2, "audio/x-bad"))).await;
    assert_eq!(
        refused.unwrap_err(),
        "Living Room & Hall cannot play this audio format"
    );

    // A renderer reporting an error fails the song.
    fake.lock().unwrap().autoplay = false;
    remote
        .ask(Control::Load(item(3, "audio/flac")))
        .await
        .unwrap();
    remote.ask(Control::Play).await.unwrap();
    until(&status, "playing", |s| s["state"] == 2).await;
    {
        let mut fake = fake.lock().unwrap();
        fake.transport = "STOPPED";
        fake.healthy = false;
    }
    until(&status, "failed", |s| {
        s["failed"] == true && s["token"] == 3
    })
    .await;

    // A renderer that stops answering ends the session.
    fake.lock().unwrap().silent = true;
    until(&status, "disconnected", |s| s["connected"] == false).await;
    assert!(remote.ask(Control::Play).await.is_err());
}

#[tokio::test]
async fn a_renderer_that_never_starts_fails_the_song() {
    let fake = Fake::new();
    let (remote, status, _) = session(&fake).await;
    fake.lock().unwrap().stuck = true;
    remote
        .ask(Control::Load(item(5, "audio/flac")))
        .await
        .unwrap();
    remote.ask(Control::Play).await.unwrap();
    until(&status, "buffering", |s| s["state"] == 4).await;
    until(&status, "failed", |s| s["failed"] == true).await;
    assert_eq!(status.lock().unwrap().snapshot()["finished"], false);
}

#[tokio::test]
async fn a_renderer_without_volume_control_reports_no_volume() {
    let port = renderer(Fake::new()).await;
    let mut bare = device(port);
    bare.location = Some(format!("http://127.0.0.1:{port}/bare.xml"));
    let status = Arc::new(Mutex::new(Status::default()));
    let remote = dlna::connect_with(
        bare,
        Arc::clone(&status),
        Arc::new(|_: &str, _| {}),
        timing(),
    )
    .await
    .unwrap();
    remote
        .ask(Control::Load(item(9, "audio/flac")))
        .await
        .unwrap();
    let snapshot = status.lock().unwrap().snapshot();
    assert_eq!(snapshot["connected"], true);
    assert!(snapshot.get("volume").is_none(), "{snapshot}");
    let refused = remote.ask(Control::Volume(0.5)).await;
    assert_eq!(
        refused.unwrap_err(),
        "Living Room & Hall does not let the app change its volume"
    );
    assert!(status.lock().unwrap().snapshot().get("volume").is_none());
}

#[tokio::test]
async fn an_unreachable_renderer_fails_to_connect() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let status = Arc::new(Mutex::new(Status::default()));
    let result = dlna::connect_with(
        device(port),
        Arc::clone(&status),
        Arc::new(|_: &str, _| {}),
        timing(),
    )
    .await;
    assert_eq!(result.err().unwrap(), "Could not reach Living Room & Hall");
    assert_eq!(status.lock().unwrap().snapshot()["connected"], false);
}

#[tokio::test]
async fn discovery_lists_renderers_from_ssdp_and_drops_them_on_byebye() {
    let fake = Fake::new();
    let port = renderer(fake).await;
    let lists = Arc::new(Mutex::new(Vec::<Vec<Device>>::new()));
    let seen = Arc::clone(&lists);
    let registry = Registry::new(Arc::default(), move |list| seen.lock().unwrap().push(list));
    let (found, messages) = mpsc::channel(8);
    let stop = CancellationToken::new();
    let catalog = tokio::spawn(Catalog::new(registry).run(messages, stop.clone()));
    let message = |announce, target: &str, location: String| Message {
        announce,
        target: target.into(),
        usn: format!("uuid:renderer-1::{target}"),
        location: Some(location),
        max_age: Some(1800),
        from: "127.0.0.1".parse().unwrap(),
    };
    let location = format!("http://127.0.0.1:{port}/description.xml");
    let renderer = "urn:schemas-upnp-org:device:MediaRenderer:1";
    // Not a renderer, and a description elsewhere than the answering device.
    found
        .send(message(
            Announce::Alive,
            "upnp:rootdevice",
            location.clone(),
        ))
        .await
        .unwrap();
    found
        .send(message(
            Announce::Alive,
            renderer,
            "http://198.51.100.7/d.xml".into(),
        ))
        .await
        .unwrap();
    found
        .send(message(Announce::Alive, renderer, location.clone()))
        .await
        .unwrap();
    found
        .send(message(Announce::Alive, renderer, location.clone()))
        .await
        .unwrap();
    for _ in 0..100 {
        if !lists.lock().unwrap().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    {
        let lists = lists.lock().unwrap();
        assert_eq!(lists.len(), 1, "one device, announced twice, listed once");
        let device = &lists[0][0];
        assert_eq!(device.id, "dlna:uuid:renderer-1");
        assert_eq!(device.name, "Living Room & Hall");
        assert_eq!(device.model, "Renderer 9");
        assert_eq!((device.kind, device.port), (Kind::Dlna, port));
        assert_eq!(device.location.as_deref(), Some(location.as_str()));
    }
    found
        .send(message(Announce::ByeBye, renderer, location))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(lists.lock().unwrap().last().unwrap().is_empty());
    stop.cancel();
    catalog.await.unwrap();
}
