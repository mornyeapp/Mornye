use super::*;
use std::f64::consts::{PI, TAU};

const RATE: f64 = SIGNATURE_SAMPLE_RATE as f64;

fn ok() -> Result<(), String> {
    Ok(())
}

fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}

/// Short tone bursts with a smooth envelope, one per second, centered at
/// half a second past each second. A steady tone has no peak in time, so it
/// would never stand out from its own neighboring frames.
fn bursts(hz: f64, seconds: usize) -> Vec<i16> {
    let burst = 0.3 * RATE;
    (0..seconds * SIGNATURE_SAMPLE_RATE)
        .map(|index| {
            let into_second = (index % SIGNATURE_SAMPLE_RATE) as f64 - 0.35 * RATE;
            if !(0.0..burst).contains(&into_second) {
                return 0;
            }
            let envelope = 0.5 - 0.5 * (TAU * into_second / burst).cos();
            let value = envelope * (TAU * hz * index as f64 / RATE).sin();
            (value * 12_000.0).round() as i16
        })
        .collect()
}

fn signature(samples: &[i16]) -> Signature {
    signature_from_pcm16(samples, &ok).unwrap()
}

fn peak(pass: u32) -> Peak {
    Peak {
        pass,
        magnitude: 0x1234,
        corrected_bin: 0x0ABC,
    }
}

/// Reads a container back, checking the header and CRC, for layout tests.
fn decode(bytes: &[u8]) -> (u32, Vec<(u32, Vec<u8>)>) {
    assert_eq!(u32_at(bytes, 0), MAGIC);
    assert_eq!(u32_at(bytes, 4), crc32(&bytes[8..]));
    let size = u32_at(bytes, 8) as usize;
    assert_eq!(size, bytes.len() - HEADER_LEN);
    assert_eq!(u32_at(bytes, 12), MAGIC_2);
    assert!(bytes[16..28].iter().all(|&byte| byte == 0));
    assert_eq!(u32_at(bytes, 28), 3 << 27);
    assert!(bytes[32..40].iter().all(|&byte| byte == 0));
    let samples = u32_at(bytes, 40) - 3840;
    assert_eq!(u32_at(bytes, 44), (15 << 19) + 0x40000);
    assert_eq!(u32_at(bytes, 48), 0x4000_0000);
    assert_eq!(u32_at(bytes, 52) as usize, size);
    let mut entries = Vec::new();
    let mut offset = 56;
    while offset < bytes.len() {
        let tag = u32_at(bytes, offset);
        let length = u32_at(bytes, offset + 4) as usize;
        entries.push((tag, bytes[offset + 8..offset + 8 + length].to_vec()));
        offset += 8 + length.next_multiple_of(4);
    }
    assert_eq!(offset, bytes.len());
    (samples, entries)
}

#[test]
fn crc32_matches_zlib() {
    assert_eq!(crc32(b""), 0);
    assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    assert_eq!(
        crc32(b"The quick brown fox jumps over the lazy dog"),
        0x414F_A339
    );
}

#[test]
fn header_and_bands_follow_the_container_layout() {
    let mut signature = Signature {
        sample_count: 64_000,
        ..Signature::default()
    };
    signature.bands[0] = vec![peak(0), peak(2)];
    signature.bands[2] = vec![peak(7)];
    let bytes = signature.encode();
    let (samples, entries) = decode(&bytes);
    assert_eq!(samples, 64_000);
    assert_eq!(
        entries.iter().map(|(tag, _)| *tag).collect::<Vec<_>>(),
        [0x6003_0040, 0x6003_0042]
    );
    // Ten bytes of peaks pad to twelve; five pad to eight.
    assert_eq!(entries[0].1.len(), 10);
    assert_eq!(entries[1].1.len(), 5);
    assert_eq!(bytes.len(), HEADER_LEN + 8 + (8 + 12) + (8 + 8));
    assert_eq!(&bytes[56 + 8 + 10..56 + 8 + 12], &[0, 0]);
    assert_eq!(
        entries[0].1,
        [0, 0x34, 0x12, 0xBC, 0x0A, 2, 0x34, 0x12, 0xBC, 0x0A]
    );

    let empty = Signature::default().encode();
    assert_eq!(empty.len(), HEADER_LEN + 8);
    assert_eq!(decode(&empty).1, []);
}

#[test]
fn large_pass_gaps_are_escaped_with_the_absolute_pass() {
    let mut signature = Signature::default();
    signature.bands[1] = vec![peak(3), peak(257), peak(258), peak(1000)];
    let (_, entries) = decode(&signature.encode());
    let mut expected = vec![3, 0x34, 0x12, 0xBC, 0x0A];
    // 257 - 3 = 254 still fits in the delta byte.
    expected.extend([254, 0x34, 0x12, 0xBC, 0x0A]);
    expected.extend([1, 0x34, 0x12, 0xBC, 0x0A]);
    expected.extend([0xFF, 0xE8, 0x03, 0, 0]);
    expected.extend([0, 0x34, 0x12, 0xBC, 0x0A]);
    assert_eq!(entries, [(0x6003_0041, expected)]);

    // A gap of exactly 255 from the start is escaped too.
    signature.bands[1] = vec![peak(255)];
    let (_, entries) = decode(&signature.encode());
    assert_eq!(
        entries[0].1,
        [0xFF, 255, 0, 0, 0, 0, 0x34, 0x12, 0xBC, 0x0A]
    );
}

#[test]
fn data_uri_carries_the_encoded_container() {
    let mut signature = Signature {
        sample_count: 16_000,
        ..Signature::default()
    };
    signature.bands[3] = vec![peak(4)];
    let uri = signature.data_uri();
    let encoded = uri
        .strip_prefix("data:audio/vnd.shazam.sig;base64,")
        .unwrap();
    assert_eq!(
        base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .unwrap(),
        signature.encode()
    );
    assert_eq!(signature.sample_ms(), 1000);
    assert_eq!(signature.peak_count(), 1);
}

#[test]
fn tone_bursts_land_in_their_band_at_their_frequency() {
    for (hz, band) in [(400.0, 0), (1000.0, 1), (2500.0, 2), (4500.0, 3)] {
        let found = signature(&bursts(hz, 4));
        assert_eq!(found.sample_count, 4 * SIGNATURE_SAMPLE_RATE as u32);
        for (index, peaks) in found.bands.iter().enumerate() {
            if index != band {
                assert!(peaks.is_empty(), "{hz} Hz leaked into band {index}");
            }
        }
        let peaks = &found.bands[band];
        // One peak per burst whose look ahead fits in four seconds.
        assert!((2..=4).contains(&peaks.len()), "{hz} Hz: {peaks:?}");
        for peak in peaks {
            assert!(
                (peak.frequency_hz() - hz).abs() < RATE / 2048.0,
                "{hz} Hz found at {}",
                peak.frequency_hz()
            );
        }
        // A burst peaks half a second into its second; the frame whose
        // window is centered there is that pass.
        for (second, peak) in peaks.iter().enumerate() {
            let center = (second as f64 + 0.5) * RATE;
            let pass = ((center + 1024.0) / 128.0 - 1.0).round();
            assert!(
                (f64::from(peak.pass) - pass).abs() <= 3.0,
                "{hz} Hz burst {second} at pass {}",
                peak.pass
            );
        }
    }
}

#[test]
fn silence_steady_tones_and_out_of_band_tones_have_no_peaks() {
    assert_eq!(
        signature(&vec![0; 4 * SIGNATURE_SAMPLE_RATE]).peak_count(),
        0
    );
    for hz in [150.0, 7000.0] {
        assert_eq!(signature(&bursts(hz, 4)).peak_count(), 0, "{hz} Hz");
    }
    let steady = (0..4 * SIGNATURE_SAMPLE_RATE)
        .map(|index| ((TAU * 1000.0 * index as f64 / RATE).sin() * 12_000.0) as i16)
        .collect::<Vec<_>>();
    assert_eq!(signature(&steady).peak_count(), 0);
}

#[test]
fn signatures_are_deterministic_and_capped_at_twelve_seconds() {
    let mut seed = 0x1234_5678_u32;
    let noisy = (0..14 * SIGNATURE_SAMPLE_RATE)
        .map(|index| {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let noise = f64::from(seed >> 16) / 65536.0 - 0.5;
            let tone = (TAU * 700.0 * index as f64 / RATE).sin() * (PI * index as f64 / RATE).sin();
            ((noise * 0.3 + tone * 0.5) * 20_000.0) as i16
        })
        .collect::<Vec<_>>();
    let first = signature(&noisy);
    assert_eq!(first.encode(), signature(&noisy).encode());
    assert_eq!(first.sample_count, 12 * SIGNATURE_SAMPLE_RATE as u32);
    assert_eq!(first, signature(&noisy[..12 * SIGNATURE_SAMPLE_RATE]));
    assert!(first.peak_count() > 0);
    for peaks in &first.bands {
        assert!(peaks.windows(2).all(|pair| pair[0].pass <= pair[1].pass));
    }
    // A partial trailing hop is not counted.
    assert_eq!(signature(&noisy[..1000]).sample_count, 896);
}

#[test]
fn cancellation_stops_the_fingerprint() {
    let error = signature_from_pcm16(&bursts(400.0, 2), &|| Err("cancelled".into()));
    assert_eq!(error, Err("cancelled".into()));
}

#[test]
fn level_is_reported_in_dbfs() {
    assert_eq!(rms_dbfs(&[]), f64::NEG_INFINITY);
    assert_eq!(rms_dbfs(&[0; 100]), f64::NEG_INFINITY);
    assert!(rms_dbfs(&[-32768; 100]).abs() < 1e-9);
    let sine = (0..16_000)
        .map(|index| ((TAU * 440.0 * index as f64 / RATE).sin() * 16_384.0) as i16)
        .collect::<Vec<_>>();
    // A half scale sine sits 3 dB under half scale (-6 dB).
    assert!((rms_dbfs(&sine) + 9.03).abs() < 0.05, "{}", rms_dbfs(&sine));
}
