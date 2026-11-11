//! All raw libusb pointers belong to one thread. Transfer buffers remain at
//! stable addresses until callbacks complete, including cancellation on drop.
use super::{
    UsbHardwareVolume, UsbOutputFormat,
    descriptors::{self, Alternate, Endpoint, PacketClock},
    volume::{self, Volume},
};
use libusb1_sys as usb;
use std::{
    collections::VecDeque,
    ptr,
    sync::{Arc, Condvar, Mutex, mpsc},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

#[derive(Default)]
struct State {
    bytes: VecDeque<u8>,
    playing: bool,
    closed: bool,
    frames: u64,
    flush: u64,
    flushed: u64,
    error: Option<String>,
    volume: UsbHardwareVolume,
    volume_requests: VecDeque<VolumeRequest>,
}
struct VolumeRequest {
    db: f64,
    deadline: Instant,
    reply: mpsc::SyncSender<Result<UsbHardwareVolume, String>>,
}
type Shared = Arc<(Mutex<State>, Condvar)>;

pub struct Output {
    pub format: UsbOutputFormat,
    shared: Shared,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl Output {
    pub fn open(
        fd: i32,
        raw: Vec<u8>,
        rate: u32,
        channels: u8,
        bits: u8,
        dsd: bool,
        dop: bool,
    ) -> Result<Self, String> {
        let device = descriptors::parse(&raw)?;
        let candidates = descriptors::formats(&device, rate, channels, bits, dsd, dop);
        if fd < 0 || candidates.len() > 32 {
            return Err("Invalid USB device/configuration".into());
        }
        if candidates.is_empty() {
            return Err(descriptors::mismatch(&device, rate, channels, bits, dsd));
        }
        let shared = Arc::new((Mutex::new(State::default()), Condvar::new()));
        let state = shared.clone();
        let (tx, rx) = mpsc::sync_channel(1);
        let handle = thread::Builder::new()
            .name("Mornye-USB-iso".into())
            .spawn(move || {
                // Best effort; failure changes scheduling only, never audio data.
                unsafe {
                    libc::setpriority(libc::PRIO_PROCESS, 0, -16);
                }
                // SAF/device descriptors are opened by Android and stay owned by
                // Kotlin until this worker has joined. No device discovery/root.
                let result = Session::open(fd, candidates, &raw);
                match result {
                    Ok(mut session) => {
                        state.0.lock().unwrap().volume = session
                            .volume
                            .as_ref()
                            .map(Volume::snapshot)
                            .unwrap_or_default();
                        let _ = tx.send(Ok(session.format.clone()));
                        if let Err(error) = session.run(&state) {
                            let mut s = state.0.lock().unwrap();
                            s.error = Some(error);
                            s.playing = false;
                        }
                    }
                    Err(error) => {
                        let _ = tx.send(Err(error));
                    }
                }
                state.1.notify_all();
            })
            .map_err(|e| e.to_string())?;
        match rx.recv().map_err(|e| e.to_string())? {
            Ok(format) => Ok(Self {
                format,
                shared,
                thread: Mutex::new(Some(handle)),
            }),
            Err(e) => {
                let _ = handle.join();
                Err(e)
            }
        }
    }
    pub fn write(&self, data: Vec<u8>) -> Result<u32, String> {
        let frame = self.format.subslot as usize * self.format.channels as usize;
        if data.len() > 256 * 1024 || !data.len().is_multiple_of(frame) {
            return Err("Invalid USB frame buffer".into());
        }
        let mut s = self.shared.0.lock().unwrap();
        if let Some(e) = &s.error {
            return Err(e.clone());
        }
        if s.closed {
            return Err("USB output closed".into());
        }
        let capacity = (self.format.sample_rate as usize * frame / 5).max(256 * 1024);
        let n = data.len().min(capacity.saturating_sub(s.bytes.len())) / frame * frame;
        s.bytes.extend(&data[..n]);
        self.shared.1.notify_all();
        Ok(n as u32)
    }
    pub fn available_bytes(&self) -> Result<u32, String> {
        let frame = self.format.subslot as usize * self.format.channels as usize;
        let s = self.shared.0.lock().unwrap();
        if let Some(e) = &s.error {
            return Err(e.clone());
        }
        if s.closed {
            return Err("USB output closed".into());
        }
        let capacity = (self.format.sample_rate as usize * frame / 5).max(256 * 1024);
        Ok((capacity.saturating_sub(s.bytes.len()) / frame * frame) as u32)
    }
    pub fn start(&self) -> Result<(), String> {
        let mut s = self.shared.0.lock().unwrap();
        if let Some(e) = &s.error {
            return Err(e.clone());
        }
        if s.closed {
            return Err("USB output closed".into());
        }
        s.playing = true;
        self.shared.1.notify_all();
        Ok(())
    }
    pub fn flush(&self) -> Result<(), String> {
        let mut s = self.shared.0.lock().unwrap();
        s.playing = false;
        s.flush += 1;
        self.shared.1.notify_all();
        let (s, timeout) = self
            .shared
            .1
            .wait_timeout_while(s, Duration::from_secs(2), |s| {
                s.flushed != s.flush && s.error.is_none() && !s.closed
            })
            .unwrap();
        if let Some(e) = &s.error {
            return Err(e.clone());
        }
        if timeout.timed_out() {
            return Err("USB cancellation timed out".into());
        }
        Ok(())
    }
    pub fn frames(&self) -> Result<u64, String> {
        let s = self.shared.0.lock().unwrap();
        if let Some(e) = &s.error {
            return Err(e.clone());
        }
        Ok(s.frames)
    }
    pub fn close(&self) {
        {
            let mut s = self.shared.0.lock().unwrap();
            s.closed = true;
            self.shared.1.notify_all();
        }
        if let Some(t) = self.thread.lock().unwrap().take() {
            let _ = t.join();
        }
    }
    pub fn volume(&self) -> UsbHardwareVolume {
        self.shared.0.lock().unwrap().volume.clone()
    }
    pub fn set_volume(&self, db: f64) -> Result<UsbHardwareVolume, String> {
        let (reply, result) = mpsc::sync_channel(1);
        {
            let mut s = self.shared.0.lock().unwrap();
            if s.closed || s.error.is_some() || !s.volume.available {
                return Err("USB hardware volume unavailable".into());
            }
            if s.volume_requests.len() >= 8 {
                return Err("USB volume requests busy".into());
            }
            s.volume_requests.push_back(VolumeRequest {
                db,
                deadline: Instant::now() + Duration::from_secs(2),
                reply,
            });
            self.shared.1.notify_all();
        }
        result
            .recv_timeout(Duration::from_secs(4))
            .map_err(|_| "USB volume request timed out".to_string())?
    }
}
impl Drop for Output {
    fn drop(&mut self) {
        self.close();
    }
}

fn check(code: i32) -> Result<(), String> {
    if code < 0 {
        Err(format!("USB error {code}"))
    } else {
        Ok(())
    }
}

struct Slot {
    transfer: *mut usb::libusb_transfer,
    bytes: Vec<u8>,
    pending: bool,
    music_frames: u64,
    submitted: bool,
}
extern "system" fn completed(transfer: *mut usb::libusb_transfer) {
    // SAFETY: user_data points to its stable Box<Slot>; libusb callbacks are
    // invoked only while this worker is handling events, before drop/free.
    unsafe {
        (*((*transfer).user_data as *mut Slot)).pending = false;
    }
}
impl Slot {
    fn new(packets: usize, max_bytes: usize) -> Result<Box<Self>, String> {
        // SAFETY: libusb allocates space for exactly this many descriptors.
        let transfer = unsafe { usb::libusb_alloc_transfer(packets as i32) };
        if transfer.is_null() {
            return Err("USB transfer allocation failed".into());
        }
        Ok(Box::new(Self {
            transfer,
            bytes: vec![0; packets * max_bytes],
            pending: false,
            music_frames: 0,
            submitted: false,
        }))
    }
    fn submit(
        &mut self,
        handle: *mut usb::libusb_device_handle,
        address: u8,
        lengths: &[usize],
    ) -> Result<(), String> {
        // SAFETY: Box and Vec allocations never move/resize while pending;
        // lengths are checked against the endpoint capacity before submission.
        unsafe {
            usb::libusb_fill_iso_transfer(
                self.transfer,
                handle,
                address,
                self.bytes.as_mut_ptr(),
                lengths.iter().sum::<usize>() as i32,
                lengths.len() as i32,
                completed,
                self as *mut Self as *mut _,
                500,
            );
            for (i, n) in lengths.iter().enumerate() {
                (*(*self.transfer).iso_packet_desc.as_mut_ptr().add(i)).length = *n as u32;
            }
            check(usb::libusb_submit_transfer(self.transfer))?;
        }
        self.pending = true;
        self.submitted = true;
        Ok(())
    }
    fn success(&self) -> bool {
        unsafe {
            (*self.transfer).status == 0
                && (0..(*self.transfer).num_iso_packets as usize).all(|i| {
                    let packet = &*(*self.transfer).iso_packet_desc.as_ptr().add(i);
                    packet.status == 0
                        && ((*self.transfer).endpoint & 0x80 != 0
                            || packet.actual_length == packet.length)
                })
        }
    }
    fn actual(&self) -> usize {
        unsafe { (*(*self.transfer).iso_packet_desc.as_ptr()).actual_length as usize }
    }
}
impl Drop for Slot {
    fn drop(&mut self) {
        assert!(
            !self.pending,
            "USB transfer freed before cancellation completed"
        );
        unsafe {
            usb::libusb_free_transfer(self.transfer);
        }
    }
}

struct Session {
    context: *mut usb::libusb_context,
    handle: *mut usb::libusb_device_handle,
    claimed: Vec<i32>,
    alternate: Alternate,
    endpoint: Endpoint,
    feedback: Option<Endpoint>,
    bus_speed: i32,
    high_speed: bool,
    interval: u32,
    #[allow(clippy::vec_box)] // libusb user_data must survive Vec moves/reallocation.
    slots: Vec<Box<Slot>>,
    feedback_slot: Option<Box<Slot>>,
    format: UsbOutputFormat,
    volume: Option<Volume>,
}
impl volume::Control for Session {
    fn transfer(
        &self,
        input: bool,
        request: u8,
        value: u16,
        index: u16,
        data: &mut [u8],
    ) -> Result<(), String> {
        self.control(input, request, value, index, data, false)
    }
}
impl Session {
    fn open(
        fd: i32,
        candidates: Vec<(Alternate, UsbOutputFormat)>,
        raw: &[u8],
    ) -> Result<Self, String> {
        let mut s = Self {
            context: ptr::null_mut(),
            handle: ptr::null_mut(),
            claimed: vec![],
            alternate: Alternate::default(),
            endpoint: Endpoint::default(),
            feedback: None,
            bus_speed: 0,
            high_speed: false,
            interval: 0,
            slots: vec![],
            feedback_slot: None,
            format: candidates[0].1.clone(),
            volume: None,
        };
        unsafe {
            // NO_DEVICE_DISCOVERY is required on Android; the USB permission
            // grant is represented by the file descriptor, not /dev scanning.
            check(usb::libusb_set_option(ptr::null_mut(), 2))?;
            check(usb::libusb_init(&mut s.context))?;
            check(usb::libusb_wrap_sys_device(
                s.context,
                fd as _,
                &mut s.handle,
            ))?;
            s.bus_speed = usb::libusb_get_device_speed(usb::libusb_get_device(s.handle));
            check(usb::libusb_set_auto_detach_kernel_driver(s.handle, 1))?;
        }
        let mut failure = "No supported USB endpoint".to_string();
        for (a, f) in candidates {
            if let Err(e) = s.configure(a, f) {
                failure = e;
                s.release();
                continue;
            }
            let packets = (4000 / s.interval).clamp(1, 32) as usize;
            for _ in 0..4 {
                s.slots.push(Slot::new(packets, s.endpoint.max_packet)?);
            }
            if let Some(ep) = &s.feedback {
                s.feedback_slot = Some(Slot::new(1, ep.max_packet)?);
            }
            s.volume = volume::feature(
                raw,
                s.alternate.control,
                s.alternate.terminal,
                s.format.channels,
            )
            .and_then(|feature| Volume::open(&s, feature).ok());
            return Ok(s);
        }
        Err(failure)
    }
    fn control(
        &self,
        input: bool,
        request: u8,
        value: u16,
        index: u16,
        data: &mut [u8],
        endpoint: bool,
    ) -> Result<(), String> {
        let kind = (if input { 0x80 } else { 0 }) | 0x20 | if endpoint { 2 } else { 1 };
        let n = unsafe {
            usb::libusb_control_transfer(
                self.handle,
                kind,
                request,
                value,
                index,
                data.as_mut_ptr(),
                data.len() as u16,
                500,
            )
        };
        check(n)?;
        if n as usize != data.len() {
            return Err("Short USB control response".into());
        }
        Ok(())
    }
    fn configure(&mut self, a: Alternate, f: UsbOutputFormat) -> Result<(), String> {
        let ep = a
            .endpoints
            .iter()
            .find(|e| e.address & 0x80 == 0 && e.attributes & 3 == 1 && e.attributes & 0x30 == 0)
            .ok_or("No isochronous audio output")?
            .clone();
        if ep.max_packet == 0 || ep.max_packet > 3072 {
            return Err("Unsupported USB interval/packet size".into());
        }
        let timing = descriptors::packet_timing(self.bus_speed, ep.interval)?;
        let interval = timing.interval_us;
        let maximum_frames = (f.sample_rate as u64 * interval as u64).div_ceil(1_000_000) as usize;
        if maximum_frames * f.channels as usize * f.subslot as usize > ep.max_packet {
            return Err("USB endpoint bandwidth too small".into());
        }
        let feedback = a
            .endpoints
            .iter()
            .find(|e| {
                e.address & 0x80 != 0
                    && e.attributes & 3 == 1
                    && (e.address == ep.sync_address || e.attributes & 0x30 == 0x10)
            })
            .cloned();
        if (ep.attributes >> 2) & 3 == 1 && feedback.is_none() {
            return Err("Implicit feedback is not supported".into());
        }
        if let Some(e) = &feedback
            && !(3..=64).contains(&e.max_packet)
        {
            return Err("Invalid feedback endpoint".into());
        }
        for interface in [a.control, a.interface] {
            if self.claimed.contains(&(interface as i32)) {
                continue;
            }
            unsafe {
                check(usb::libusb_claim_interface(self.handle, interface as i32))?;
            }
            self.claimed.push(interface as i32);
        }
        self.alternate = a.clone();
        unsafe {
            check(usb::libusb_set_interface_alt_setting(
                self.handle,
                a.interface as i32,
                0,
            ))?;
        }
        if a.uac2 {
            // The rate belongs to the clock source; a selector in front of it
            // answers this request with its 1-byte input pin instead.
            let clock = descriptors::clock_source(&a, |selector| {
                let mut pin = [0];
                let index = ((selector as u16) << 8) | a.control as u16;
                self.control(true, 1, 0x100, index, &mut pin, false)?;
                Ok(pin[0])
            })?;
            let index = ((clock as u16) << 8) | a.control as u16;
            let mut rate = f.sample_rate.to_le_bytes();
            // A read-only clock already at the exact rate needs no SET_CUR.
            let mut current = [0; 4];
            self.control(true, 1, 0x100, index, &mut current, false)?;
            if current != rate {
                self.control(false, 1, 0x100, index, &mut rate, false)?;
            }
            self.control(true, 1, 0x100, index, &mut current, false)?;
            if current != rate {
                return Err("USB clock rate could not be verified".into());
            }
        }
        unsafe {
            check(usb::libusb_set_interface_alt_setting(
                self.handle,
                a.interface as i32,
                a.alternate as i32,
            ))?;
        }
        if !a.uac2 && ep.rate_control {
            let mut rate = f.sample_rate.to_le_bytes()[..3].to_vec();
            let mut current = [0; 3];
            self.control(false, 1, 0x100, ep.address as u16, &mut rate, true)?;
            self.control(true, 0x81, 0x100, ep.address as u16, &mut current, true)?;
            if current != rate.as_slice() {
                return Err("USB clock rate could not be verified".into());
            }
        } else if !a.uac2 && a.rates.as_slice() != [(f.sample_rate, f.sample_rate)] {
            return Err("Variable USB clock has no rate control".into());
        }
        self.alternate = a;
        self.endpoint = ep;
        self.feedback = feedback;
        self.high_speed = timing.high_speed;
        self.interval = interval;
        self.format = f;
        Ok(())
    }
    fn events(&self) -> Result<(), String> {
        let timeout = libc::timeval {
            tv_sec: 0,
            tv_usec: 1000,
        };
        check(unsafe { usb::libusb_handle_events_timeout(self.context, &timeout) })
    }
    fn drain(&mut self) {
        for slot in self.slots.iter_mut().chain(self.feedback_slot.iter_mut()) {
            if slot.pending {
                unsafe {
                    usb::libusb_cancel_transfer(slot.transfer);
                }
            }
        }
        // Cancellation is asynchronous. Keep every buffer and the context alive
        // until libusb acknowledges it, including USB detach and error paths.
        while self
            .slots
            .iter()
            .chain(self.feedback_slot.iter())
            .any(|s| s.pending)
        {
            let _ = self.events();
        }
    }
    fn run(&mut self, shared: &Shared) -> Result<(), String> {
        let frame = self.format.subslot as usize * self.format.channels as usize;
        let packets = (4000 / self.interval).clamp(1, 32) as usize;
        let mut clock = PacketClock::new(self.format.sample_rate, self.interval);
        let mut marker = 0x05;
        let mut last_feedback = Instant::now();
        let mut started = false;
        loop {
            self.events()?;
            let mut s = shared.0.lock().unwrap();
            if s.closed {
                break;
            }
            if let Some(request) = s.volume_requests.pop_front() {
                drop(s);
                if Instant::now() > request.deadline {
                    let _ = request.reply.send(Err("USB volume request expired".into()));
                } else {
                    let mut volume = self
                        .volume
                        .take()
                        .ok_or("USB hardware volume unavailable")?;
                    let result = volume.set(self, request.db);
                    self.volume = Some(volume);
                    if let Ok(snapshot) = &result {
                        shared.0.lock().unwrap().volume = snapshot.clone();
                    }
                    let error = result.as_ref().err().cloned();
                    let _ = request.reply.send(result);
                    if let Some(error) = error {
                        return Err(error);
                    }
                }
                s = shared.0.lock().unwrap();
            }
            if s.flush != s.flushed {
                drop(s);
                self.drain();
                s = shared.0.lock().unwrap();
                s.bytes.clear();
                s.frames = 0;
                s.flushed = s.flush;
                for slot in &mut self.slots {
                    slot.music_frames = 0;
                    slot.submitted = false;
                }
                clock = PacketClock::new(self.format.sample_rate, self.interval);
                marker = 0x05;
                started = false;
                shared.1.notify_all();
            }
            if !s.playing {
                drop(shared.1.wait_timeout(s, Duration::from_millis(20)).unwrap());
                continue;
            }
            if !started {
                last_feedback = Instant::now();
                started = true;
            }
            if let (Some(ep), Some(slot)) = (&self.feedback, &mut self.feedback_slot) {
                if !slot.pending {
                    if slot.actual() > 0
                        && slot.success()
                        && clock.feedback(
                            &slot.bytes[..slot.actual().min(slot.bytes.len())],
                            self.high_speed,
                            self.interval,
                        )
                    {
                        last_feedback = Instant::now();
                    }
                    slot.submit(self.handle, ep.address, &[ep.max_packet])?;
                }
                if last_feedback.elapsed() > Duration::from_secs(2) {
                    return Err("USB feedback stopped or invalid".into());
                }
            }
            for slot in &mut self.slots {
                if slot.pending {
                    continue;
                }
                if slot.submitted {
                    if !slot.success() {
                        return Err("USB audio transfer failed".into());
                    }
                    s.frames += slot.music_frames;
                    slot.music_frames = 0;
                }
                let mut packet_lengths = [0usize; 32];
                let lengths = &mut packet_lengths[..packets];
                for length in lengths.iter_mut() {
                    *length = clock.next() * frame;
                }
                if lengths.iter().any(|n| *n > self.endpoint.max_packet) {
                    return Err("USB feedback exceeded endpoint capacity".into());
                }
                let total: usize = lengths.iter().sum();
                let available = total.min(s.bytes.len()) / frame * frame;
                {
                    let (first, second) = s.bytes.as_slices();
                    let first_len = available.min(first.len());
                    slot.bytes[..first_len].copy_from_slice(&first[..first_len]);
                    slot.bytes[first_len..available]
                        .copy_from_slice(&second[..available - first_len]);
                }
                s.bytes.drain(..available);
                super::framing::finish_transfer(
                    &mut slot.bytes[..total],
                    available,
                    &self.format,
                    &mut marker,
                );
                slot.music_frames = (available / frame) as u64;
                slot.submit(self.handle, self.endpoint.address, lengths)?;
            }
        }
        self.drain();
        Ok(())
    }
    fn release(&mut self) {
        if self.handle.is_null() {
            return;
        }
        unsafe {
            if self.alternate.alternate > 0 {
                usb::libusb_set_interface_alt_setting(
                    self.handle,
                    self.alternate.interface as i32,
                    0,
                );
            }
            for interface in self.claimed.drain(..).rev() {
                usb::libusb_release_interface(self.handle, interface);
            }
        }
        self.alternate = Alternate::default();
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.drain();
        self.slots.clear();
        self.feedback_slot = None;
        self.release();
        unsafe {
            if !self.handle.is_null() {
                usb::libusb_close(self.handle);
            }
            if !self.context.is_null() {
                usb::libusb_exit(self.context);
            }
        }
    }
}
