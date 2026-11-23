//! DLNA and UPnP AV media renderers: found over SSDP, read from their device
//! description, driven over SOAP (AVTransport and RenderingControl) and
//! polled, since UPnP never sends position changes.

mod description;
mod soap;

use crate::discovery::{Device, Kind, Registry};
use crate::http;
use crate::sender::Emit;
use crate::session::{Commands, Control, Item, Remote};
use crate::ssdp::{self, Announce, Message};
use crate::status::{self, Status, state};
use description::{Renderer, Service};
use soap::{Answer, Failure, value};
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::runtime::Handle;
use tokio::sync::mpsc;
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;
use url::Url;

pub(crate) const RENDERER: &str = "urn:schemas-upnp-org:device:MediaRenderer:1";
/// Any MediaRenderer version answers a search for version 1.
const RENDERER_PREFIX: &str = "urn:schemas-upnp-org:device:mediarenderer:";
const MAX_DESCRIPTION: usize = 256 * 1024;
const DESCRIPTION_TIMEOUT: Duration = Duration::from_secs(5);
/// How often discovery searches again.
const ROUND: Duration = Duration::from_secs(15);
/// A renderer unheard this long is gone, whatever its max-age says: a
/// switched off device sends no byebye.
const STALE: Duration = Duration::from_secs(50);
/// A description that failed is fetched again after this long.
const RETRY: Duration = Duration::from_secs(30);
const MAX_FETCHES: usize = 8;
const INSTANCE: (&str, &str) = ("InstanceID", "0");

fn id(udn: &str) -> String {
    format!("dlna:{udn}")
}

/// A running SSDP browse for renderers; dropping it stops every task.
pub(crate) struct Browse {
    stop: CancellationToken,
}

impl Browse {
    pub(crate) fn start(runtime: &Handle, registry: Registry) -> Result<Self, String> {
        let stop = CancellationToken::new();
        let (found, messages) = mpsc::channel(256);
        runtime.spawn(ssdp::listen(found.clone(), stop.clone()));
        let searching = stop.clone();
        runtime.spawn(async move {
            loop {
                let addresses = ssdp::lan_addresses();
                let search = ssdp::search(&addresses, ssdp::GROUP, RENDERER, ssdp::WINDOW, &found);
                tokio::select! {
                    () = searching.cancelled() => return,
                    () = search => {}
                }
                tokio::select! {
                    () = searching.cancelled() => return,
                    () = tokio::time::sleep(ROUND.saturating_sub(ssdp::WINDOW)) => {}
                }
            }
        });
        runtime.spawn(Catalog::new(registry).run(messages, stop.clone()));
        Ok(Self { stop })
    }
}

impl Drop for Browse {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

struct Known {
    location: String,
    seen: Instant,
    lifetime: Duration,
    listed: bool,
    fetching: bool,
    retry: Option<Instant>,
}

/// Turns SSDP messages into the device list, fetching each new renderer's
/// description once.
pub(crate) struct Catalog {
    registry: Registry,
    known: HashMap<String, Known>,
    fetches: JoinSet<(String, String, Option<Device>)>,
}

impl Catalog {
    pub(crate) fn new(registry: Registry) -> Self {
        Self {
            registry,
            known: HashMap::new(),
            fetches: JoinSet::new(),
        }
    }

    pub(crate) async fn run(
        mut self,
        mut messages: mpsc::Receiver<Message>,
        stop: CancellationToken,
    ) {
        let mut sweep = tokio::time::interval(Duration::from_secs(5));
        loop {
            tokio::select! {
                () = stop.cancelled() => return,
                message = messages.recv() => match message {
                    Some(message) => self.handle(message),
                    None => return,
                },
                Some(Ok(done)) = self.fetches.join_next(), if !self.fetches.is_empty() => {
                    self.fetched(done);
                }
                _ = sweep.tick() => self.sweep(),
            }
        }
    }

    fn handle(&mut self, message: Message) {
        if !message
            .target
            .to_ascii_lowercase()
            .starts_with(RENDERER_PREFIX)
        {
            return;
        }
        let udn = message.udn().to_owned();
        if udn.is_empty() {
            return;
        }
        if message.announce == Announce::ByeBye {
            if self.known.remove(&udn).is_some_and(|known| known.listed) {
                self.registry.remove(&id(&udn));
            }
            return;
        }
        let Some(location) = message
            .location
            .filter(|location| valid_location(location, message.from))
        else {
            return;
        };
        let lifetime = message
            .max_age
            .map_or(STALE, Duration::from_secs)
            .min(STALE);
        let now = Instant::now();
        let known = self.known.entry(udn.clone()).or_insert_with(|| Known {
            location: location.clone(),
            seen: now,
            lifetime,
            listed: false,
            fetching: false,
            retry: None,
        });
        known.seen = now;
        known.lifetime = lifetime;
        if known.location != location {
            known.location.clone_from(&location);
            known.retry = None;
        } else if known.listed || known.retry.is_some_and(|at| now < at) {
            return;
        }
        if known.fetching || self.fetches.len() >= MAX_FETCHES {
            return;
        }
        known.fetching = true;
        self.fetches.spawn(describe(udn, location));
    }

    fn fetched(&mut self, (udn, location, device): (String, String, Option<Device>)) {
        let Some(known) = self.known.get_mut(&udn) else {
            return;
        };
        known.fetching = false;
        if known.location != location {
            return;
        }
        match device {
            Some(device) => {
                known.listed = true;
                self.registry.upsert(device);
            }
            None => known.retry = Some(Instant::now() + RETRY),
        }
    }

    fn sweep(&mut self) {
        let registry = &self.registry;
        self.known.retain(|udn, known| {
            let alive = known.seen.elapsed() <= known.lifetime;
            if !alive && known.listed {
                registry.remove(&id(udn));
            }
            alive
        });
    }
}

/// A description URL on the device that answered or on the LAN.
fn valid_location(location: &str, from: IpAddr) -> bool {
    let Ok(address) = Url::parse(location)
        .and_then(|url| http::address(&url).map_err(|_| url::ParseError::InvalidIpv4Address))
    else {
        return false;
    };
    let ip = address.ip();
    ip == from || matches!(ip, IpAddr::V4(v4) if v4.is_private() || v4.is_link_local())
}

async fn describe(udn: String, location: String) -> (String, String, Option<Device>) {
    let device = async {
        let url = Url::parse(&location).ok()?;
        let reply = http::request(
            ::http::Method::GET,
            &url,
            &[],
            String::new(),
            MAX_DESCRIPTION,
            DESCRIPTION_TIMEOUT,
        )
        .await
        .ok()
        .filter(|reply| reply.status.is_success())?;
        let renderer = description::parse(&reply.body, &url, Some(&udn))?;
        let address = http::address(&url).ok()?;
        let mut device = Device::new(
            Kind::Dlna,
            &id(&udn),
            &renderer.name,
            &renderer.model,
            address.ip(),
            address.port(),
        );
        device.location = Some(location.clone());
        Some(device)
    }
    .await;
    (udn, location, device)
}

/// Intervals of a session; tests run them faster.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Timing {
    /// Status polls while playing or starting, as the AVTransport spec
    /// suggests (once a second).
    pub(crate) poll: Duration,
    /// Every this many poll ticks while paused or stopped.
    pub(crate) idle_every: u32,
    /// Position updates to the app while playing, as the Cast path.
    pub(crate) progress: Duration,
    pub(crate) call: Duration,
    pub(crate) poll_timeout: Duration,
    /// Renderers fetch the song during `SetAVTransportURI`.
    pub(crate) load: Duration,
    /// Unanswered polls in a row that end the session.
    pub(crate) give_up: u32,
    /// Play asked but nothing playing after this long fails the song.
    pub(crate) start_limit: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            poll: Duration::from_secs(1),
            idle_every: 3,
            progress: Duration::from_millis(500),
            call: Duration::from_secs(8),
            poll_timeout: Duration::from_secs(3),
            load: Duration::from_secs(20),
            give_up: 3,
            start_limit: Duration::from_secs(20),
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
    let unreachable = || format!("Could not reach {name}");
    let location = (device.location.as_deref())
        .and_then(|location| Url::parse(location).ok())
        .ok_or_else(unreachable)?;
    let udn = device.id.strip_prefix("dlna:").unwrap_or(&device.id);
    let reply = http::request(
        ::http::Method::GET,
        &location,
        &[],
        String::new(),
        MAX_DESCRIPTION,
        timing.call,
    )
    .await
    .ok()
    .filter(|reply| reply.status.is_success())
    .ok_or_else(unreachable)?;
    let renderer = description::parse(&reply.body, &location, Some(udn))
        .ok_or_else(|| format!("{name} cannot play audio from this app"))?;
    // A fault still proves the renderer answers control requests.
    let info = match soap::call(
        &renderer.transport,
        "GetTransportInfo",
        &[INSTANCE],
        timing.call,
    )
    .await
    {
        Ok(info) => info,
        Err(Failure::Fault(..)) => Vec::new(),
        Err(Failure::Unreachable) => return Err(format!("{name} did not answer")),
    };
    let volume_max = match &renderer.rendering {
        Some(rendering) => volume_maximum(rendering, timing.call).await,
        None => 100.0,
    };
    let mut actor = Actor {
        name,
        renderer,
        timing,
        status,
        emit,
        commands: None,
        volume_max,
        sink: String::new(),
        item: None,
        transport: value(&info, "CurrentTransportState").to_ascii_uppercase(),
        play: Playback::default(),
        failures: 0,
    };
    if let Some(connection) = &actor.renderer.connection
        && let Ok(answer) = soap::call(connection, "GetProtocolInfo", &[], timing.call).await
    {
        actor.sink = value(&answer, "Sink").to_owned();
    }
    let volume = actor.read_volume().await;
    {
        let mut status = actor.status.lock().expect("cast status");
        status.start(device, volume);
        (actor.emit)("castStatus", status.snapshot());
    }
    let (remote, commands) = Remote::channel();
    actor.commands = Some(commands);
    tokio::spawn(actor.run());
    Ok(remote)
}

async fn volume_maximum(rendering: &Service, timeout: Duration) -> f64 {
    let Some(scpd) = &rendering.scpd else {
        return 100.0;
    };
    let reply = http::request(
        ::http::Method::GET,
        scpd,
        &[],
        String::new(),
        MAX_DESCRIPTION,
        timeout,
    )
    .await;
    reply
        .ok()
        .filter(|reply| reply.status.is_success())
        .and_then(|reply| description::volume_maximum(&reply.body))
        .map_or(100.0, f64::from)
}

/// What the app asked of the current song, which tells a renderer's own
/// stop (the song ended) from one the app asked for.
#[derive(Default)]
struct Playback {
    /// Play was asked, and when; cleared by pause and stop.
    asked_play: Option<Instant>,
    asked_pause: bool,
    asked_stop: bool,
    /// The renderer reported playing since play was last asked.
    played: bool,
    /// The song finished or failed; later reports are not about it.
    done: bool,
    /// Some renderers start on `SetAVTransportURI`; such a start is paused
    /// once, as the app loads without playing.
    held_autoplay: bool,
    pending_seek: Option<f64>,
    /// The position estimated from playing time, for renderers that report
    /// none or a frozen one.
    clock: f64,
    clock_at: Option<Instant>,
}

/// What a status poll asks to do next.
enum Follow {
    Pause,
    Seek(f64),
}

struct Actor {
    name: String,
    renderer: Renderer,
    timing: Timing,
    status: Arc<Mutex<Status>>,
    emit: Emit,
    commands: Option<Commands>,
    volume_max: f64,
    sink: String,
    item: Option<Item>,
    transport: String,
    play: Playback,
    failures: u32,
}

impl Actor {
    async fn run(mut self) {
        let Some(mut commands) = self.commands.take() else {
            return;
        };
        let mut poll = tokio::time::interval(self.timing.poll);
        poll.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut progress = tokio::time::interval(self.timing.progress);
        let mut ticks: u32 = 0;
        loop {
            tokio::select! {
                command = commands.recv() => {
                    let Some((control, reply)) = command else { break };
                    let leaving = matches!(control, Control::Disconnect);
                    let result = self.command(control).await;
                    let _ = reply.send(result);
                    if leaving {
                        break;
                    }
                }
                _ = poll.tick() => {
                    ticks = ticks.wrapping_add(1);
                    let busy = matches!(self.transport.as_str(), "PLAYING" | "TRANSITIONING")
                        || (self.play.asked_play.is_some() && !self.play.played);
                    if (busy || ticks.is_multiple_of(self.timing.idle_every.max(1)))
                        && !self.poll(ticks).await
                    {
                        break;
                    }
                }
                _ = progress.tick() => {
                    let status = self.status.lock().expect("cast status");
                    if status.player_state == state::PLAYING {
                        (self.emit)("castStatus", status.snapshot());
                    }
                }
            }
        }
        let mut status = self.status.lock().expect("cast status");
        status.connected = false;
        (self.emit)("castStatus", status.snapshot());
    }

    async fn call(
        &self,
        service: &Service,
        action: &str,
        arguments: &[(&str, &str)],
        timeout: Duration,
    ) -> Result<Answer, Failure> {
        soap::call(service, action, arguments, timeout).await
    }

    fn refused(&self, failure: &Failure) -> String {
        match failure {
            Failure::Unreachable => format!("{} did not answer", self.name),
            Failure::Fault(code, _) => format!("{} refused the request (error {code})", self.name),
        }
    }

    fn emit_status(&self) {
        let status = self.status.lock().expect("cast status");
        (self.emit)("castStatus", status.snapshot());
    }

    /// Polls the renderer; `false` when it stopped answering.
    async fn poll(&mut self, ticks: u32) -> bool {
        let transport = &self.renderer.transport;
        let timeout = self.timing.poll_timeout;
        let info = match self
            .call(transport, "GetTransportInfo", &[INSTANCE], timeout)
            .await
        {
            Ok(info) => info,
            Err(Failure::Fault(..)) => {
                self.failures = 0;
                return true;
            }
            Err(Failure::Unreachable) => {
                self.failures += 1;
                return self.failures < self.timing.give_up;
            }
        };
        self.failures = 0;
        let transport_state = value(&info, "CurrentTransportState").to_ascii_uppercase();
        let healthy =
            !value(&info, "CurrentTransportStatus").eq_ignore_ascii_case("ERROR_OCCURRED");
        let (position, length) = if self.item.is_some() {
            match self
                .call(transport, "GetPositionInfo", &[INSTANCE], timeout)
                .await
            {
                Ok(answer) => (
                    soap::seconds(value(&answer, "RelTime")),
                    soap::seconds(value(&answer, "TrackDuration")).filter(|length| *length > 0.0),
                ),
                Err(_) => (None, None),
            }
        } else {
            (None, None)
        };
        // The volume can change on the device's own remote.
        if ticks.is_multiple_of(5)
            && let Some(volume) = self.read_volume().await
        {
            self.status.lock().expect("cast status").volume = Some(volume);
        }
        let follow = self.observe(&transport_state, healthy, position, length);
        self.transport = transport_state;
        match follow {
            Some(Follow::Pause) => {
                let transport = &self.renderer.transport;
                let held = match self.call(transport, "Pause", &[INSTANCE], timeout).await {
                    Ok(_) => true,
                    // Without Pause, a stop holds it at the start just as well.
                    Err(Failure::Fault(..)) => {
                        let stop = self.call(transport, "Stop", &[INSTANCE], timeout);
                        stop.await.is_ok()
                    }
                    Err(Failure::Unreachable) => false,
                };
                if held {
                    self.status.lock().expect("cast status").player_state = state::PAUSED;
                }
            }
            Some(Follow::Seek(seconds)) => {
                let _ = self.send_seek(seconds).await;
            }
            None => {}
        }
        self.emit_status();
        true
    }

    async fn read_volume(&self) -> Option<f64> {
        let rendering = self.renderer.rendering.as_ref()?;
        let answer = self
            .call(
                rendering,
                "GetVolume",
                &[INSTANCE, ("Channel", "Master")],
                self.timing.poll_timeout,
            )
            .await
            .ok()?;
        let volume: f64 = value(&answer, "CurrentVolume").parse().ok()?;
        Some((volume / self.volume_max).clamp(0.0, 1.0))
    }

    fn observe(
        &mut self,
        transport: &str,
        healthy: bool,
        position: Option<f64>,
        length: Option<f64>,
    ) -> Option<Follow> {
        let shared = Arc::clone(&self.status);
        let mut status = shared.lock().expect("cast status");
        if let Some(length) = length {
            status.duration = length;
        }
        if self.item.is_none() || self.play.done {
            return None;
        }
        let start_limit = self.timing.start_limit;
        let play = &mut self.play;
        let trusted = position.filter(|position| *position > 0.5);
        // Where a playing song got to by now, by the renderer or the clock.
        let reached = play.clock + play.clock_at.map_or(0.0, |at| at.elapsed().as_secs_f64());
        let duration = status.duration;
        let near_end = move |at: f64, slack: f64| duration <= 0.0 || at >= duration - slack;
        match transport {
            "PLAYING" => {
                if play.asked_play.is_none() && !play.held_autoplay {
                    play.held_autoplay = true;
                    return Some(Follow::Pause);
                }
                play.clock = trusted.unwrap_or(reached);
                play.clock_at = Some(Instant::now());
                play.played = true;
                status.player_state = state::PLAYING;
                status.report(reading(position, play.clock));
                if let Some(seconds) = play.pending_seek.take() {
                    return Some(Follow::Seek(seconds));
                }
            }
            "TRANSITIONING" => {
                play.clock = trusted.unwrap_or(reached);
                play.clock_at = None;
                status.player_state = state::BUFFERING;
            }
            "PAUSED_PLAYBACK" | "PAUSED_RECORDING" => {
                play.clock = trusted.unwrap_or(reached);
                play.clock_at = None;
                // A song that ends paused at its last second has ended.
                if play.played && !play.asked_pause && duration > 0.0 && near_end(play.clock, 2.0) {
                    finish(&mut status, play);
                } else {
                    status.player_state = state::PAUSED;
                    status.report(reading(position, play.clock));
                }
            }
            "STOPPED" | "NO_MEDIA_PRESENT" => {
                play.clock_at = None;
                if play.asked_stop {
                    // Paused by stopping, on renderers without Pause.
                    status.player_state = if play.pending_seek.is_some() {
                        state::PAUSED
                    } else {
                        state::IDLE
                    };
                } else if !healthy && (play.played || play.asked_play.is_some()) {
                    fail(&mut status, play);
                } else if play.played {
                    // Lengths of variable bit rate songs are estimates.
                    if near_end(reached, (duration * 0.1).max(10.0)) {
                        finish(&mut status, play);
                    } else {
                        // Stopped on the device itself: not the song's end.
                        play.played = false;
                        play.asked_play = None;
                        play.asked_stop = true;
                        status.player_state = state::IDLE;
                    }
                } else if play.asked_play.is_some_and(|at| at.elapsed() > start_limit) {
                    fail(&mut status, play);
                } else {
                    status.player_state = if play.asked_play.is_some() {
                        state::BUFFERING
                    } else {
                        state::PAUSED
                    };
                    status.report(play.pending_seek.unwrap_or(play.clock));
                }
            }
            _ => {}
        }
        None
    }

    async fn command(&mut self, control: Control) -> Result<(), String> {
        match control {
            Control::Load(item) => self.load(*item).await,
            Control::Play => self.play().await,
            Control::Pause => self.pause().await,
            Control::Stop => self.stop().await,
            Control::Seek(seconds) => self.seek(seconds).await,
            Control::Volume(level) => self.volume(level).await,
            Control::Disconnect => {
                // Stop the song on the renderer, as the Cast path does.
                if self.item.is_some() {
                    let transport = &self.renderer.transport;
                    let _ = self
                        .call(transport, "Stop", &[INSTANCE], Duration::from_secs(3))
                        .await;
                }
                Ok(())
            }
        }
    }

    fn loaded(&self) -> Result<(), String> {
        match &self.item {
            Some(_) if !self.play.done => Ok(()),
            _ => Err("Nothing is loaded on the device".into()),
        }
    }

    async fn set_uri(&self, url: &str, metadata: &str) -> Result<Answer, Failure> {
        let arguments = [
            INSTANCE,
            ("CurrentURI", url),
            ("CurrentURIMetaData", metadata),
        ];
        let transport = &self.renderer.transport;
        self.call(transport, "SetAVTransportURI", &arguments, self.timing.load)
            .await
    }

    async fn load(&mut self, item: Item) -> Result<(), String> {
        let transport = &self.renderer.transport;
        if matches!(
            self.transport.as_str(),
            "PLAYING" | "PAUSED_PLAYBACK" | "TRANSITIONING"
        ) {
            self.play.asked_stop = true;
            let _ = self
                .call(transport, "Stop", &[INSTANCE], self.timing.call)
                .await;
        }
        let mime = soap::sink_mime(&self.sink, &item.mime);
        let mut result = self.set_uri(&item.url, &soap::didl(&item, &mime)).await;
        // A renderer refusing the metadata itself may take the bare URL.
        if let Err(Failure::Fault(code, _)) = &result
            && !matches!(code, 714 | 716)
        {
            result = self.set_uri(&item.url, "").await;
        }
        if let Err(failure) = result {
            return Err(match failure.code() {
                Some(714) => format!("{} cannot play this audio format", self.name),
                Some(716) => format!("{} could not open the song", self.name),
                Some(code) => format!("{} could not load the song (error {code})", self.name),
                None => format!("{} did not answer", self.name),
            });
        }
        {
            let mut status = self.status.lock().expect("cast status");
            status.begin_item(item.token, item.duration_seconds());
            (self.emit)("castStatus", status.snapshot());
        }
        self.item = Some(item);
        self.play = Playback::default();
        self.transport = "STOPPED".into();
        Ok(())
    }

    async fn play(&mut self) -> Result<(), String> {
        self.loaded()?;
        let transport = &self.renderer.transport;
        self.call(
            transport,
            "Play",
            &[INSTANCE, ("Speed", "1")],
            self.timing.call,
        )
        .await
        .map_err(|failure| self.refused(&failure))?;
        let play = &mut self.play;
        if self.transport != "PAUSED_PLAYBACK" {
            play.played = false;
            if play.pending_seek.is_none() && play.asked_stop {
                play.clock = 0.0;
            }
        }
        play.asked_play = Some(Instant::now());
        play.asked_pause = false;
        play.asked_stop = false;
        play.held_autoplay = true;
        Ok(())
    }

    async fn pause(&mut self) -> Result<(), String> {
        self.loaded()?;
        if !self.play.played && self.transport != "PLAYING" {
            self.play.asked_play = None;
            return Ok(());
        }
        let position = self.status.lock().expect("cast status").position_seconds();
        let transport = &self.renderer.transport;
        match self
            .call(transport, "Pause", &[INSTANCE], self.timing.call)
            .await
        {
            Ok(_) => {}
            // Pause is optional in AVTransport: stop, and resume by seeking.
            Err(Failure::Fault(401 | 602 | 701, _)) => {
                self.call(transport, "Stop", &[INSTANCE], self.timing.call)
                    .await
                    .map_err(|failure| self.refused(&failure))?;
                self.play.asked_stop = true;
                self.play.pending_seek = Some(position);
                self.play.clock = position;
            }
            Err(failure) => return Err(self.refused(&failure)),
        }
        self.play.asked_pause = true;
        self.play.asked_play = None;
        let mut status = self.status.lock().expect("cast status");
        status.player_state = state::PAUSED;
        status.report(position);
        (self.emit)("castStatus", status.snapshot());
        Ok(())
    }

    async fn stop(&mut self) -> Result<(), String> {
        if self.item.is_none() {
            return Ok(());
        }
        let transport = &self.renderer.transport;
        match self
            .call(transport, "Stop", &[INSTANCE], self.timing.call)
            .await
        {
            // Already stopped.
            Ok(_) | Err(Failure::Fault(701, _)) => {}
            Err(failure) => return Err(self.refused(&failure)),
        }
        self.play.asked_stop = true;
        self.play.asked_play = None;
        self.play.pending_seek = None;
        let mut status = self.status.lock().expect("cast status");
        if !self.play.done {
            status.player_state = state::IDLE;
        }
        (self.emit)("castStatus", status.snapshot());
        Ok(())
    }

    async fn seek(&mut self, seconds: f64) -> Result<(), String> {
        self.loaded()?;
        let seconds = seconds.max(0.0);
        let started =
            self.play.played || matches!(self.transport.as_str(), "PLAYING" | "PAUSED_PLAYBACK");
        if started {
            self.send_seek(seconds).await?;
        } else {
            // Not playing yet: many renderers only seek once playing.
            self.play.pending_seek = Some(seconds);
        }
        self.play.clock = seconds;
        if self.play.clock_at.is_some() {
            self.play.clock_at = Some(Instant::now());
        }
        let mut status = self.status.lock().expect("cast status");
        status.report(seconds);
        (self.emit)("castStatus", status.snapshot());
        Ok(())
    }

    async fn seek_by(&self, unit: &str, target: &str) -> Result<Answer, Failure> {
        let arguments = [INSTANCE, ("Unit", unit), ("Target", target)];
        let transport = &self.renderer.transport;
        self.call(transport, "Seek", &arguments, self.timing.call)
            .await
    }

    async fn send_seek(&mut self, seconds: f64) -> Result<(), String> {
        let target = soap::time(seconds);
        let mut result = self.seek_by("REL_TIME", &target).await;
        if matches!(result, Err(Failure::Fault(710, _))) {
            result = self.seek_by("ABS_TIME", &target).await;
        }
        match result {
            Ok(_) => Ok(()),
            // Not in this state (paused, say): seek once playing.
            Err(Failure::Fault(701, _)) => {
                self.play.pending_seek = Some(seconds);
                Ok(())
            }
            Err(failure) => Err(self.refused(&failure)),
        }
    }

    async fn volume(&mut self, level: f64) -> Result<(), String> {
        let Some(rendering) = &self.renderer.rendering else {
            return Err(format!(
                "{} does not let the app change its volume",
                self.name
            ));
        };
        let desired = (level.clamp(0.0, 1.0) * self.volume_max)
            .round()
            .to_string();
        let arguments = [
            INSTANCE,
            ("Channel", "Master"),
            ("DesiredVolume", desired.as_str()),
        ];
        self.call(rendering, "SetVolume", &arguments, self.timing.call)
            .await
            .map_err(|failure| self.refused(&failure))?;
        let mut status = self.status.lock().expect("cast status");
        status.volume = Some(level.clamp(0.0, 1.0));
        (self.emit)("castStatus", status.snapshot());
        Ok(())
    }
}

/// The position to show: the renderer's, unless it reports none or stays at
/// zero while time passes, when the playing clock stands in.
fn reading(position: Option<f64>, clock: f64) -> f64 {
    match position {
        Some(position) if position > 0.5 || clock < 3.0 => position,
        _ => clock,
    }
}

fn finish(status: &mut Status, play: &mut Playback) {
    play.done = true;
    status.player_state = state::IDLE;
    status.idle_reason = Some(status::FINISHED.into());
    if status.duration > 0.0 {
        let end = status.duration;
        status.report(end);
    }
}

fn fail(status: &mut Status, play: &mut Playback) {
    play.done = true;
    status.player_state = state::IDLE;
    status.idle_reason = Some(status::ERROR.into());
}
