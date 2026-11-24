//! USB audio descriptor parsing: devices, endpoints, alternate settings, output formats, and packet clocking.

use super::UsbOutputFormat;
use std::collections::HashMap;

#[derive(Clone, Debug, Default)]
pub struct Endpoint {
    pub address: u8,
    pub attributes: u8,
    pub max_packet: usize,
    pub interval: u8,
    pub sync_address: u8,
    pub rate_control: bool,
}

/// A UAC2 clock entity of an audio control interface (UAC2 4.7.2.1 to 4.7.2.3).
#[derive(Clone, Debug, PartialEq)]
pub enum ClockEntity {
    Source,
    /// Source IDs by input pin; pin 1 is the first.
    Selector(Vec<u8>),
    Multiplier(u8),
}

#[derive(Clone, Debug, Default)]
pub struct Alternate {
    pub control: u8,
    pub interface: u8,
    pub alternate: u8,
    pub uac2: bool,
    pub terminal: u8,
    /// The clock entity the terminal names: a source, or a selector or
    /// multiplier in front of one (see [`clock_source`]).
    pub clock: u8,
    /// The clock entities of this alternate's audio control interface.
    pub clocks: Vec<(u8, ClockEntity)>,
    pub channels: u8,
    pub bits: u8,
    pub subslot: u8,
    pub pcm: bool,
    pub rates: Vec<(u32, u32)>,
    pub endpoints: Vec<Endpoint>,
}

#[derive(Default)]
pub struct Device {
    pub vendor: u16,
    pub product: u16,
    pub revision: u16,
    pub alternates: Vec<Alternate>,
}

pub struct PacketTiming {
    pub high_speed: bool,
    pub interval_us: u32,
}

/// libusb speed codes describe the negotiated link, not the USB descriptor version.
/// An unreported speed cannot safely select between frames and microframes.
pub fn packet_timing(speed: i32, interval: u8) -> Result<PacketTiming, String> {
    let high_speed = match speed {
        2 => false,
        3..=6 => true,
        _ => return Err("USB bus speed unavailable or unsupported".into()),
    };
    if !(1..=4).contains(&interval) {
        return Err("Unsupported USB packet interval".into());
    }
    Ok(PacketTiming {
        high_speed,
        interval_us: (if high_speed { 125 } else { 1000 }) * (1 << (interval - 1)),
    })
}

fn u16le(b: &[u8]) -> u16 {
    u16::from_le_bytes([b[0], b[1]])
}
fn u24le(b: &[u8]) -> u32 {
    u32::from_le_bytes([b[0], b[1], b[2], 0])
}

/// Only UAC1/2 Type I, mono/stereo output. Clock selectors are followed to
/// their current input (see [`clock_source`]); implicit feedback is rejected
/// instead of guessing a configuration.
pub fn parse(bytes: &[u8]) -> Result<Device, String> {
    let mut device = Device::default();
    let mut current: Option<Alternate> = None;
    let mut control = 0;
    let mut is_control = false;
    let mut clocks = HashMap::new();
    let mut entities: Vec<(u8, u8, ClockEntity)> = Vec::new();
    let mut offset = 0;
    let mut configurations = 0;
    while offset < bytes.len() {
        let length = *bytes.get(offset).ok_or("truncated descriptor")? as usize;
        if length < 2 || offset + length > bytes.len() {
            return Err("malformed USB descriptor".into());
        }
        let d = &bytes[offset..offset + length];
        offset += length;
        match d[1] {
            2 => {
                configurations += 1;
                if configurations > 1 {
                    return Err("Multiple USB configurations are not supported".into());
                }
            }
            1 if length >= 18 => {
                device.vendor = u16le(&d[8..]);
                device.product = u16le(&d[10..]);
                device.revision = u16le(&d[12..]);
            }
            4 if length >= 9 => {
                if let Some(a) = current.take() {
                    device.alternates.push(a);
                }
                is_control = d[5] == 1 && d[6] == 1 && d[7] == 0x20;
                if d[5] == 1 && d[6] == 1 {
                    control = d[2];
                }
                if d[5] == 1 && d[6] == 2 && d[3] > 0 && (d[7] == 0 || d[7] == 0x20) {
                    current = Some(Alternate {
                        control,
                        interface: d[2],
                        alternate: d[3],
                        uac2: d[7] == 0x20,
                        ..Default::default()
                    });
                }
            }
            0x24 if is_control && length >= 9 && d[2] == 2 => {
                clocks.insert((control, d[3]), d[7]);
            }
            // Clock source, selector and multiplier: XMOS-based DACs put a
            // selector between the terminals and their clock source.
            0x24 if is_control && length >= 7 && matches!(d[2], 0x0a..=0x0c) => {
                let entity = match d[2] {
                    0x0a => (length >= 8).then_some(ClockEntity::Source),
                    0x0b => {
                        let pins = d[4] as usize;
                        (length >= 7 + pins).then(|| ClockEntity::Selector(d[5..5 + pins].to_vec()))
                    }
                    _ => Some(ClockEntity::Multiplier(d[4])),
                };
                if let Some(entity) = entity {
                    entities.push((control, d[3], entity));
                }
            }
            0x24 => {
                if let Some(a) = current.as_mut() {
                    if length >= 7 && d[2] == 1 {
                        a.terminal = d[3];
                        if a.uac2 && length >= 16 && d[5] == 1 {
                            let formats = u32::from_le_bytes(d[6..10].try_into().unwrap());
                            a.pcm = formats & 1 != 0;
                            a.channels = d[10];
                        } else if !a.uac2 {
                            a.pcm = u16le(&d[5..]) == 1;
                        }
                    }
                    if length >= 6 && d[2] == 2 && d[3] == 1 {
                        if a.uac2 {
                            a.subslot = d[4];
                            a.bits = d[5];
                        } else if length >= 8 {
                            a.channels = d[4];
                            a.subslot = d[5];
                            a.bits = d[6];
                            let count = d[7] as usize;
                            if count == 0 && length >= 14 {
                                a.rates.push((u24le(&d[8..]), u24le(&d[11..])));
                            } else if length >= 8 + count * 3 {
                                for f in d[8..8 + count * 3].as_chunks::<3>().0 {
                                    let rate = u24le(f);
                                    a.rates.push((rate, rate));
                                }
                            }
                        }
                    }
                }
            }
            5 if length >= 7 => {
                if let Some(a) = current.as_mut() {
                    let packet = u16le(&d[4..]);
                    a.endpoints.push(Endpoint {
                        address: d[2],
                        attributes: d[3],
                        max_packet: (packet & 0x7ff) as usize * (1 + ((packet >> 11) & 3) as usize),
                        interval: d[6],
                        sync_address: d.get(8).copied().unwrap_or(0),
                        rate_control: false,
                    });
                }
            }
            0x25 if length >= 4 && d[2] == 1 => {
                if let Some(a) = current.as_mut()
                    && !a.uac2
                    && let Some(endpoint) = a.endpoints.last_mut()
                {
                    endpoint.rate_control = d[3] & 1 != 0;
                }
            }
            _ => {}
        }
    }
    if let Some(a) = current {
        device.alternates.push(a);
    }
    for a in &mut device.alternates {
        a.clock = clocks.get(&(a.control, a.terminal)).copied().unwrap_or(0);
        a.clocks = entities
            .iter()
            .filter(|(control, _, _)| *control == a.control)
            .map(|(_, id, entity)| (*id, entity.clone()))
            .collect();
    }
    Ok(device)
}

/// The clock source whose sample rate the terminal follows, reached through
/// selectors and multipliers. A selector's current input pin (1-based) comes
/// from `selected`; one with a single input needs no request. An ID without a
/// clock descriptor is taken as the source, as before.
pub fn clock_source(
    a: &Alternate,
    mut selected: impl FnMut(u8) -> Result<u8, String>,
) -> Result<u8, String> {
    let mut id = a.clock;
    for _ in 0..8 {
        match a.clocks.iter().find(|(entity, _)| *entity == id) {
            None | Some((_, ClockEntity::Source)) => return Ok(id),
            Some((_, ClockEntity::Multiplier(source))) => id = *source,
            Some((_, ClockEntity::Selector(pins))) => {
                let pin = if pins.len() == 1 { 1 } else { selected(id)? };
                id = *(pin as usize)
                    .checked_sub(1)
                    .and_then(|index| pins.get(index))
                    .ok_or_else(|| {
                        format!(
                            "USB clock selector {id} reports input {pin} of {}",
                            pins.len()
                        )
                    })?;
            }
        }
    }
    Err("USB clock topology loops".into())
}

/// Bytes of queued audio for 1.5 s at `rate` frames a second, whole frames.
pub fn queue_bytes(rate: u32, frame: usize) -> usize {
    (rate as usize * 3 / 2 * frame).max(256 * 1024) / frame.max(1) * frame.max(1)
}

/// The rates a UAC2 clock source lists in its RANGE reply: a 2-byte count,
/// then MIN, MAX and RES of 4 bytes each. A malformed or empty reply gives
/// none, which [`clock_offers`] takes as a clock that did not say.
pub fn clock_ranges(reply: &[u8]) -> Vec<(u32, u32, u32)> {
    let Some((count, triplets)) = reply.split_first_chunk::<2>() else {
        return Vec::new();
    };
    let count = u16::from_le_bytes(*count) as usize;
    let (triplets, _) = triplets.as_chunks::<12>();
    if count == 0 || triplets.len() < count {
        return Vec::new();
    }
    let word = |bytes: &[u8]| u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    triplets[..count]
        .iter()
        .map(|t| (word(&t[..4]), word(&t[4..8]), word(&t[8..])))
        .filter(|(min, max, _)| *max > 0 && min <= max)
        .collect()
}

/// Whether a clock with these ranges runs at `rate`. A range with a step
/// holds only the rates the step lands on.
pub fn clock_offers(ranges: &[(u32, u32, u32)], rate: u32) -> bool {
    ranges.is_empty()
        || ranges.iter().any(|&(min, max, step)| {
            (min..=max).contains(&rate) && (step <= 1 || (rate - min).is_multiple_of(step))
        })
}

/// A deliberately small exact-match registry based on documented USB transport
/// identities in Linux sound/usb/quirks.c, not a product-name heuristic.
fn native_encoding(device: &Device, a: &Alternate) -> Option<&'static str> {
    if !a.uac2 || a.subslot != 4 {
        return None;
    }
    match (device.vendor, device.product, a.alternate, device.revision) {
        (0x16d0, 0x071a, 2, 0x0199) => Some("dsd_le"),
        (0x16d0, 0x071a, 2, 0x019b | 0x0203) => Some("dsd_be"),
        (0x2772, 0x0230, 2, _) | (0x20b1, 0x3089, 2, _) => Some("dsd_be"),
        _ => None,
    }
}

pub fn formats(
    device: &Device,
    rate: u32,
    channels: u8,
    bits: u8,
    dsd: bool,
    dop: bool,
) -> Vec<(Alternate, UsbOutputFormat)> {
    let mut result = Vec::new();
    for a in &device.alternates {
        if a.channels != channels || !(1..=2).contains(&channels) || !(2..=4).contains(&a.subslot) {
            continue;
        }
        let native = native_encoding(device, a);
        let (wire_rate, encoding, precision) = if dsd {
            if let Some(encoding) = native {
                (rate / 32, encoding, 1)
            } else if dop && a.pcm && a.bits >= 24 && a.subslot >= 3 {
                (rate / 16, "dop", 24)
            } else {
                continue;
            }
        } else {
            if !a.pcm || native.is_some() || !matches!(bits, 16 | 24 | 32) || a.bits < bits {
                continue;
            }
            (rate, "pcm", a.bits)
        };
        if wire_rate == 0 || a.bits > a.subslot * 8 || (a.uac2 && a.clock == 0) {
            continue;
        }
        if !a.uac2
            && !a
                .rates
                .iter()
                .any(|(min, max)| wire_rate >= *min && wire_rate <= *max)
        {
            continue;
        }
        result.push((
            a.clone(),
            UsbOutputFormat {
                sample_rate: wire_rate,
                channels,
                bits: precision,
                subslot: a.subslot,
                encoding: encoding.into(),
            },
        ));
    }
    result.sort_by_key(|(_, f)| {
        (
            if f.encoding.starts_with("dsd_") { 0 } else { 1 },
            f.subslot,
        )
    });
    result
}

/// Names the request and the PCM layouts the DAC offers when no alternate
/// setting matched, so a log explains a refused stream format.
pub fn mismatch(device: &Device, rate: u32, channels: u8, bits: u8, dsd: bool) -> String {
    let mut offered: Vec<String> = Vec::new();
    for a in device.alternates.iter().filter(|a| a.pcm && a.channels > 0) {
        let mut entry = format!("{}ch {}-bit", a.channels, a.bits);
        if !a.uac2 && !a.rates.is_empty() {
            let rates: Vec<String> = a
                .rates
                .iter()
                .map(|(min, max)| {
                    if min == max {
                        min.to_string()
                    } else {
                        format!("{min}-{max}")
                    }
                })
                .collect();
            entry.push_str(&format!(" at {} Hz", rates.join("/")));
        }
        if !offered.contains(&entry) {
            offered.push(entry);
        }
    }
    let request = if dsd {
        format!("{channels}ch DSD {rate} Hz")
    } else {
        format!("{channels}ch {bits}-bit {rate} Hz")
    };
    if offered.is_empty() {
        format!("No compatible USB format for {request}; DAC offers no PCM output")
    } else {
        format!(
            "No compatible USB format for {request}; DAC offers {}",
            offered.join(", ")
        )
    }
}

pub struct PacketClock {
    nominal: f64,
    feedback: Option<f64>,
    remainder: f64,
}
impl PacketClock {
    pub fn new(rate: u32, interval_us: u32) -> Self {
        Self {
            nominal: rate as f64 * interval_us as f64 / 1_000_000.0,
            feedback: None,
            remainder: 0.0,
        }
    }
    pub fn feedback(&mut self, bytes: &[u8], high_speed: bool, interval_us: u32) -> bool {
        let frames = match bytes.len() {
            3 if !high_speed => u24le(bytes) as f64 / 16384.0,
            4 => u32::from_le_bytes(bytes.try_into().unwrap()) as f64 / 65536.0,
            _ => return false,
        } * interval_us as f64
            / if high_speed { 125.0 } else { 1000.0 };
        if !frames.is_finite() || (frames - self.nominal).abs() > self.nominal * 0.02 {
            return false;
        }
        self.feedback = Some(frames);
        true
    }
    pub fn next(&mut self) -> usize {
        self.remainder += self.feedback.unwrap_or(self.nominal);
        let frames = self.remainder.floor() as usize;
        self.remainder -= frames as f64;
        frames
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_uac1_fixed_rate_headset_without_clock_controls() {
        let raw = [
            9, 4, 0, 0, 0, 1, 1, 0, 0, 9, 4, 1, 1, 1, 1, 2, 0, 0, 7, 0x24, 1, 1, 1, 1, 0, 11, 0x24,
            2, 1, 2, 2, 16, 1, 0x80, 0xbb, 0, 9, 5, 1, 0x0d, 192, 0, 1, 0, 0, 7, 0x25, 1, 0, 0, 0,
            0,
        ];
        let device = parse(&raw).unwrap();
        let matches = formats(&device, 48000, 2, 16, false, false);
        assert_eq!(matches.len(), 1);
        let a = &matches[0].0;
        assert_eq!(a.interface, 1);
        assert!(!a.endpoints[0].rate_control);
        assert_eq!(a.endpoints[0].address, 1);
        assert_eq!(a.endpoints[0].max_packet, 192);
        assert_eq!(a.endpoints[0].interval, 1);
        assert_eq!(a.endpoints[0].attributes, 0x0d);
        assert_eq!(a.endpoints[0].sync_address, 0);
        assert!(formats(&device, 44100, 2, 16, false, false).is_empty());
    }
    #[test]
    fn resolves_uac2_terminal_clock_and_explicit_feedback() {
        let raw = [
            9, 4, 2, 0, 0, 1, 1, 0x20, 0, 17, 0x24, 2, 7, 1, 1, 0, 9, 2, 3, 0, 0, 0, 0, 0, 0, 0, 9,
            4, 3, 1, 2, 1, 2, 0x20, 0, 16, 0x24, 1, 7, 0, 1, 1, 0, 0, 0, 2, 3, 0, 0, 0, 0, 6, 0x24,
            2, 1, 4, 24, 7, 5, 1, 5, 0, 4, 1, 7, 5, 0x81, 0x11, 4, 0, 4,
        ];
        let device = parse(&raw).unwrap();
        let matches = formats(&device, 96000, 2, 24, false, false);
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].0.control, 2);
        assert_eq!(matches[0].0.clock, 9);
        assert_eq!(matches[0].0.endpoints[1].address, 0x81);
        assert_eq!(matches[0].1.subslot, 4);
        assert!(formats(&device, 96000, 2, 32, false, false).is_empty());
        // No clock descriptors: the terminal's clock ID is the source.
        assert_eq!(
            clock_source(&matches[0].0, |_| panic!("no selector")),
            Ok(9)
        );
    }
    #[test]
    fn follows_an_xmos_clock_selector_to_its_source() {
        // Clock source 41 behind selector 40, which the input terminal names.
        let raw = [
            9, 4, 2, 0, 0, 1, 1, 0x20, 0, 8, 0x24, 0x0a, 41, 1, 7, 0, 0, 8, 0x24, 0x0b, 40, 1, 41,
            3, 0, 17, 0x24, 2, 7, 1, 1, 0, 40, 2, 3, 0, 0, 0, 0, 0, 0, 0, 9, 4, 3, 1, 2, 1, 2,
            0x20, 0, 16, 0x24, 1, 7, 0, 1, 1, 0, 0, 0, 2, 3, 0, 0, 0, 0, 6, 0x24, 2, 1, 2, 16, 7,
            5, 1, 5, 0, 4, 1, 7, 5, 0x81, 0x11, 4, 0, 4,
        ];
        let device = parse(&raw).unwrap();
        let matches = formats(&device, 44100, 2, 16, false, false);
        assert_eq!(matches.len(), 1);
        let a = &matches[0].0;
        assert_eq!(a.clock, 40);
        assert_eq!(
            a.clocks,
            vec![
                (41, ClockEntity::Source),
                (40, ClockEntity::Selector(vec![41]))
            ]
        );
        // A single input needs no GET_CUR.
        assert_eq!(clock_source(a, |_| panic!("single input")), Ok(41));
    }
    #[test]
    fn reads_a_multi_input_selector_and_rejects_bad_topologies() {
        let a = Alternate {
            uac2: true,
            clock: 40,
            clocks: vec![
                (40, ClockEntity::Selector(vec![41, 42])),
                (41, ClockEntity::Source),
                (42, ClockEntity::Multiplier(43)),
                (43, ClockEntity::Source),
            ],
            ..Default::default()
        };
        assert_eq!(
            clock_source(&a, |id| Ok(if id == 40 { 1 } else { 0 })),
            Ok(41)
        );
        assert_eq!(clock_source(&a, |_| Ok(2)), Ok(43));
        assert!(clock_source(&a, |_| Ok(0)).is_err());
        assert!(clock_source(&a, |_| Ok(3)).is_err());
        assert_eq!(
            clock_source(&a, |_| Err("USB error -9".into())),
            Err("USB error -9".into())
        );
        let looped = Alternate {
            clock: 40,
            clocks: vec![(40, ClockEntity::Selector(vec![40]))],
            ..a
        };
        assert_eq!(
            clock_source(&looped, |_| Ok(1)),
            Err("USB clock topology loops".into())
        );
    }
    #[test]
    fn fractional_rates_do_not_drift() {
        for (rate, interval, packets) in
            [(44100, 125, 8000), (88200, 1000, 1000), (176400, 125, 8000)]
        {
            let mut clock = PacketClock::new(rate, interval);
            assert_eq!(
                (0..packets).map(|_| clock.next()).sum::<usize>(),
                rate as usize
            );
        }
    }

    #[test]
    fn negotiated_link_speed_keeps_packet_clock_at_the_source_rate() {
        for speed in 2..=6 {
            for interval in 1..=4 {
                let timing = packet_timing(speed, interval).unwrap();
                let packets = 1_000_000 / timing.interval_us;
                let mut clock = PacketClock::new(44100, timing.interval_us);
                let frames: usize = (0..packets).map(|_| clock.next()).sum();
                assert_eq!(frames, 44100);
                assert_eq!(timing.high_speed, speed >= 3);
            }
        }
        assert_eq!(packet_timing(2, 1).unwrap().interval_us, 1000);
        assert_eq!(packet_timing(3, 1).unwrap().interval_us, 125);
    }

    #[test]
    fn unknown_or_unsupported_bus_timing_cannot_start_a_packet_clock() {
        for speed in [-1, 0, 1, 7] {
            assert!(packet_timing(speed, 1).is_err());
        }
        for interval in [0, 5, 255] {
            assert!(packet_timing(2, interval).is_err());
            assert!(packet_timing(3, interval).is_err());
        }
    }
    #[test]
    fn invalid_feedback_cannot_overrun_endpoint() {
        let mut clock = PacketClock::new(48000, 125);
        assert!(!clock.feedback(&[255; 4], true, 125));
        assert!(!clock.feedback(&[0; 4], true, 125));
        assert!(clock.feedback(&(6u32 << 16).to_le_bytes(), true, 125));
        assert_eq!(clock.next(), 6);
    }
    #[test]
    fn untrusted_descriptors_are_bounded() {
        for data in [vec![0, 4], vec![9, 4, 0], vec![1], vec![255; 18]] {
            assert!(parse(&data).is_err());
        }
        assert!(parse(&[]).unwrap().alternates.is_empty());
    }
    #[test]
    fn unknown_dsd_device_requires_explicit_dop() {
        let a = Alternate {
            uac2: true,
            clock: 1,
            channels: 2,
            bits: 24,
            subslot: 3,
            pcm: true,
            ..Default::default()
        };
        let device = Device {
            alternates: vec![a],
            ..Default::default()
        };
        assert!(formats(&device, 2822400, 2, 1, true, false).is_empty());
        let f = formats(&device, 2822400, 2, 1, true, true);
        assert_eq!(f[0].1.sample_rate, 176400);
        assert_eq!(f[0].1.encoding, "dop");
        assert!(formats(&device, 96000, 2, 32, false, false).is_empty());
    }
    #[test]
    fn mismatch_names_the_request_and_the_offered_layouts() {
        let stereo = Alternate {
            channels: 2,
            bits: 16,
            subslot: 2,
            pcm: true,
            rates: vec![(44100, 44100), (48000, 96000)],
            ..Default::default()
        };
        let deep = Alternate {
            bits: 24,
            subslot: 3,
            ..stereo.clone()
        };
        let device = Device {
            alternates: vec![stereo.clone(), deep, stereo],
            ..Default::default()
        };
        assert_eq!(
            mismatch(&device, 44100, 1, 16, false),
            "No compatible USB format for 1ch 16-bit 44100 Hz; DAC offers \
             2ch 16-bit at 44100/48000-96000 Hz, 2ch 24-bit at 44100/48000-96000 Hz"
        );
        assert_eq!(
            mismatch(&Device::default(), 2822400, 2, 1, true),
            "No compatible USB format for 2ch DSD 2822400 Hz; DAC offers no PCM output"
        );
    }
    #[test]
    fn native_requires_exact_firmware_and_altsetting() {
        let a = Alternate {
            uac2: true,
            alternate: 2,
            clock: 1,
            channels: 2,
            subslot: 4,
            bits: 32,
            pcm: true,
            ..Default::default()
        };
        let mut d = Device {
            vendor: 0x16d0,
            product: 0x071a,
            revision: 0x0199,
            alternates: vec![a],
        };
        assert_eq!(
            formats(&d, 2822400, 2, 1, true, false)[0].1.encoding,
            "dsd_le"
        );
        d.revision = 0x100;
        assert!(formats(&d, 2822400, 2, 1, true, false).is_empty());
    }
    fn range_reply(count: u16, ranges: &[(u32, u32, u32)]) -> Vec<u8> {
        let mut reply = count.to_le_bytes().to_vec();
        for (min, max, step) in ranges {
            for value in [min, max, step] {
                reply.extend(value.to_le_bytes());
            }
        }
        reply
    }
    #[test]
    fn the_queue_holds_the_same_time_at_every_rate() {
        // 96 kHz in 32-bit stereo once got a third of a second.
        assert_eq!(queue_bytes(96000, 8), 96000 * 8 * 3 / 2);
        assert_eq!(queue_bytes(192000, 8), 192000 * 8 * 3 / 2);
        assert_eq!(queue_bytes(44100, 4), 264600);
        // Never below the old floor, and always whole frames.
        assert_eq!(queue_bytes(8000, 2), 262144);
        assert_eq!(queue_bytes(8000, 6) % 6, 0);
    }
    #[test]
    fn a_clock_is_only_set_to_a_rate_it_lists() {
        // A DAC whose DSP stops at 48 kHz lists two discrete rates.
        let listed = [(44100, 44100, 0), (48000, 48000, 0)];
        let ranges = clock_ranges(&range_reply(2, &listed));
        assert_eq!(ranges, listed);
        assert!(clock_offers(&ranges, 44100));
        assert!(clock_offers(&ranges, 48000));
        assert!(!clock_offers(&ranges, 96000));
        assert!(!clock_offers(&ranges, 88200));
        // A continuous range, and one that only holds the rates its step lands on.
        assert!(clock_offers(&[(8000, 96000, 1)], 44100));
        assert!(!clock_offers(&[(8000, 96000, 1)], 192000));
        assert!(clock_offers(&[(44100, 176400, 44100)], 88200));
        assert!(!clock_offers(&[(44100, 176400, 44100)], 96000));
    }
    #[test]
    fn a_clock_that_does_not_say_is_tried_at_any_rate() {
        // No answer, a count of zero, fewer ranges than counted, or only
        // ranges that cannot be: nothing is known, so nothing is ruled out.
        for reply in [
            vec![],
            vec![1],
            range_reply(0, &[]),
            range_reply(2, &[(48000, 48000, 0)]),
            range_reply(1, &[(0, 0, 0)]),
            range_reply(1, &[(96000, 48000, 0)]),
        ] {
            let ranges = clock_ranges(&reply);
            assert!(ranges.is_empty(), "{reply:?}");
            assert!(clock_offers(&ranges, 384000));
        }
        // Bytes past the counted ranges are ignored.
        let padded = range_reply(1, &[(48000, 48000, 0), (96000, 96000, 0)]);
        assert_eq!(clock_ranges(&padded), [(48000, 48000, 0)]);
    }
}
