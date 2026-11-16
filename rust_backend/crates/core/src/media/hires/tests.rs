//! Port of the Python reference checker's test_hires_check.py. Signals are
//! synthesised rather than fixtured: a "fake Hi-Res" file is exactly a
//! band-limited 44.1 kHz signal carried at a higher rate, which a few lines
//! build more clearly than any committed binary could describe.

mod inspect;

use super::fft::Radix2Fft;
use super::*;
use std::path::{Path, PathBuf};

const HIRES_SR: u32 = 176_400;
const CD_SR: u32 = 44_100;
/// A power of two so the frequency-domain construction can use the checker's
/// own FFT; ~3 s at 176.4 kHz.
const HIRES_FRAMES: usize = 1 << 19;
/// ~3 s at 44.1 kHz; x4 is HIRES_FRAMES.
const CD_SOURCE_FRAMES: usize = HIRES_FRAMES / 4;

/// SplitMix64: deterministic noise without a dependency.
struct Rng(u64);

impl Rng {
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    fn uniform(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }

    /// Standard normal via Box-Muller.
    fn normal(&mut self) -> f64 {
        let u1 = self.uniform().max(1e-300);
        let u2 = self.uniform();
        (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
    }
}

fn full_band_noise(n: usize, seed: u64) -> Vec<f64> {
    let mut rng = Rng(seed);
    (0..n).map(|_| rng.normal() * 0.2).collect()
}

/// Applies `gain(freq)` to `y`'s spectrum; `y.len()` must be a power of two.
fn shape_spectrum(y: &[f64], sample_rate: u32, gain: impl Fn(f64) -> f64) -> Vec<f64> {
    let n = y.len();
    let mut re = y.to_vec();
    let mut im = vec![0.0; n];
    let fft = Radix2Fft::new(n);
    fft.transform(&mut re, &mut im);
    for k in 0..=n / 2 {
        let g = gain(k as f64 * f64::from(sample_rate) / n as f64);
        re[k] *= g;
        im[k] *= g;
        if k > 0 && k < n / 2 {
            re[n - k] = re[k];
            im[n - k] = -im[k];
        }
    }
    // Inverse FFT via conjugation.
    im.iter_mut().for_each(|v| *v = -*v);
    fft.transform(&mut re, &mut im);
    re.iter().map(|v| v / n as f64).collect()
}

/// CD-bandwidth noise in a 176.4 kHz container. Everything above 22.05 kHz is
/// zeroed, then a raised-cosine taper runs up to ~24.5 kHz: the
/// transition-band tail a real resampler leaves behind.
fn upsampled_from_cd() -> Vec<f64> {
    let (cd_nyquist, taper_end) = (f64::from(CD_SR) / 2.0, 24_500.0);
    shape_spectrum(&full_band_noise(HIRES_FRAMES, 0), HIRES_SR, |freq| {
        if freq >= taper_end {
            0.0
        } else if freq >= cd_nyquist {
            let ramp = (freq - cd_nyquist) / (taper_end - cd_nyquist);
            0.5 * (1.0 + (std::f64::consts::PI * ramp).cos()) * 1e-3
        } else {
            1.0
        }
    })
}

/// Band-limited interpolation by an integer ratio: nothing at all above the
/// source Nyquist.
fn ideal_upsample(x: &[f64], ratio: usize) -> Vec<f64> {
    let (n, m) = (x.len(), x.len() * ratio);
    let mut re = x.to_vec();
    let mut im = vec![0.0; n];
    Radix2Fft::new(n).transform(&mut re, &mut im);
    let (mut out_re, mut out_im) = (vec![0.0; m], vec![0.0; m]);
    for k in 0..n / 2 {
        out_re[k] = re[k];
        out_im[k] = im[k];
        if k > 0 {
            out_re[m - k] = re[n - k];
            out_im[m - k] = im[n - k];
        }
    }
    out_re[n / 2] = re[n / 2] / 2.0;
    out_re[m - n / 2] = re[n / 2] / 2.0;
    out_im.iter_mut().for_each(|v| *v = -*v);
    Radix2Fft::new(m).transform(&mut out_re, &mut out_im);
    out_re.iter().map(|v| v / n as f64).collect()
}

/// Loud noise, then a half holding only `quiet_noise`: the gaps real music
/// leaves, where a noise floor shows through.
fn cd_source_with_quiet_half(quiet_noise: f64) -> Vec<f64> {
    let mut rng = Rng(3);
    (0..CD_SOURCE_FRAMES)
        .map(|i| {
            rng.normal()
                * if i < CD_SOURCE_FRAMES / 2 {
                    0.2
                } else {
                    quiet_noise
                }
        })
        .collect()
}

/// What a CD master is: TPDF-dithered 16-bit, as floats.
fn dither_to_16_bit(y: &[f64]) -> Vec<f64> {
    let mut rng = Rng(4);
    y.iter()
        .map(|v| {
            let dither = (rng.uniform() - rng.uniform()) / 32768.0;
            ((v + dither) * 32768.0).round() / 32768.0
        })
        .collect()
}

/// Maps [-1, 1) floats to integers of the given depth.
fn quantize(y: &[f64], bits: u32) -> Vec<i32> {
    let full = 2f64.powi(bits as i32 - 1);
    y.iter()
        .map(|v| (v * full).round().clamp(-full, full - 1.0) as i32)
        .collect()
}

/// Noise occupying exactly `used_bits`, stored right-justified at
/// `container_bits`: a 16-bit master padded into 24 bits has its low 8 bits
/// zero.
fn pcm_using_bits(used_bits: u32, container_bits: u32, n: usize, seed: u64) -> Vec<i32> {
    let mut rng = Rng(seed);
    let span = 1i64 << used_bits;
    (0..n)
        .map(|_| {
            let v = (rng.next_u64() % span as u64) as i64 - span / 2;
            (v << (container_bits - used_bits)) as i32
        })
        .collect()
}

fn fade(signal: &mut [f64]) {
    const FADE: usize = 2048;
    let n = signal.len();
    for i in 0..FADE {
        let ramp = 0.5 - 0.5 * (std::f64::consts::PI * i as f64 / FADE as f64).cos();
        signal[i] *= ramp;
        signal[n - 1 - i] *= ramp;
    }
}

struct TempDir(PathBuf);

impl TempDir {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "mornye-hires-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_nanos())
        ));
        std::fs::create_dir_all(&path).expect("temp dir");
        Self(path)
    }

    fn file(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct BitWriter {
    bytes: Vec<u8>,
    bit: u32,
}

impl BitWriter {
    fn new() -> Self {
        Self {
            bytes: Vec::new(),
            bit: 0,
        }
    }

    fn put(&mut self, value: u64, width: u32) {
        for shift in (0..width).rev() {
            if self.bit == 0 {
                self.bytes.push(0);
            }
            let last = self.bytes.len() - 1;
            self.bytes[last] |= (((value >> shift) & 1) as u8) << (7 - self.bit);
            self.bit = (self.bit + 1) % 8;
        }
    }
}

fn crc8(data: &[u8]) -> u8 {
    data.iter().fold(0u8, |mut crc, &byte| {
        crc ^= byte;
        for _ in 0..8 {
            crc = if crc & 0x80 != 0 {
                (crc << 1) ^ 0x07
            } else {
                crc << 1
            };
        }
        crc
    })
}

fn crc16(data: &[u8]) -> u16 {
    data.iter().fold(0u16, |mut crc, &byte| {
        crc ^= u16::from(byte) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 {
                (crc << 1) ^ 0x8005
            } else {
                crc << 1
            };
        }
        crc
    })
}

/// FLAC's UTF-8-like coding of the frame number.
fn utf8_number(value: u64) -> Vec<u8> {
    if value < 0x80 {
        return vec![value as u8];
    }
    let mut continuation = Vec::new();
    let mut rest = value;
    let mut payload_bits = 6; // bits left for the leading byte's payload
    while rest >= 1 << payload_bits {
        continuation.push(0x80 | (rest & 0x3F) as u8);
        rest >>= 6;
        payload_bits -= 1;
    }
    let count = continuation.len() + 1;
    let lead = (0xFFu16 << (8 - count)) as u8 | rest as u8;
    std::iter::once(lead)
        .chain(continuation.into_iter().rev())
        .collect()
}

/// Encodes `samples` (identical on every channel) as FLAC with verbatim
/// subframes: no compression, but every CRC valid, so any decoder reads it.
fn write_flac(path: &Path, samples: &[i32], sample_rate: u32, bits: u32, channels: u32) {
    const BLOCK: usize = 4096;
    let mut out = b"fLaC".to_vec();
    let mut info = BitWriter::new();
    info.put(BLOCK as u64, 16);
    info.put(BLOCK as u64, 16);
    info.put(0, 24);
    info.put(0, 24);
    info.put(u64::from(sample_rate), 20);
    info.put(u64::from(channels - 1), 3);
    info.put(u64::from(bits - 1), 5);
    info.put(samples.len() as u64, 36);
    info.put(0, 64);
    info.put(0, 64);
    out.extend_from_slice(&[0x80, 0, 0, 34]); // last metadata block, STREAMINFO
    out.extend_from_slice(&info.bytes);

    for (number, block) in samples.chunks(BLOCK).enumerate() {
        // Fixed blocking; 16-bit block size; sample rate from STREAMINFO;
        // independent channels; the depth spelled out, as encoders do.
        let depth_code = match bits {
            8 => 0b001,
            12 => 0b010,
            16 => 0b100,
            20 => 0b101,
            _ => 0b110, // 24
        };
        let mut frame = vec![
            0xFF,
            0xF8,
            0x70,
            (((channels - 1) << 4) | (depth_code << 1)) as u8,
        ];
        frame.extend(utf8_number(number as u64));
        frame.extend_from_slice(&((block.len() - 1) as u16).to_be_bytes());
        frame.push(crc8(&frame));
        let mut body = BitWriter::new();
        for _ in 0..channels {
            body.put(0b0000_0010, 8); // verbatim, no wasted bits
            for &sample in block {
                body.put(u64::from(sample as u32) & ((1u64 << bits) - 1), bits);
            }
        }
        frame.extend(body.bytes);
        let crc = crc16(&frame);
        frame.extend_from_slice(&crc.to_be_bytes());
        out.extend(frame);
    }
    std::fs::write(path, out).expect("write flac");
}

fn write_wav(path: &Path, samples: &[i32], sample_rate: u32, bits: u32) {
    let bytes_per = (bits / 8) as usize;
    let data: Vec<u8> = samples
        .iter()
        .flat_map(|v| v.to_le_bytes()[..bytes_per].to_vec())
        .collect();
    let mut out = Vec::new();
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&(sample_rate * bytes_per as u32).to_le_bytes());
    out.extend_from_slice(&(bytes_per as u16).to_le_bytes());
    out.extend_from_slice(&(bits as u16).to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(data.len() as u32).to_le_bytes());
    out.extend(data);
    std::fs::write(path, out).expect("write wav");
}

fn run_check(
    path: &Path,
    options: &HiResCheckOptions,
) -> Result<HiResCheckResult, HiResCheckError> {
    let file = File::open(path).expect("open fixture");
    check_file(file, &path.to_string_lossy(), options, &|| Ok(()))
}

fn check(path: &Path) -> HiResCheckResult {
    run_check(path, &HiResCheckOptions::default()).expect("check")
}

fn flac(dir: &TempDir, name: &str, samples: &[i32], sample_rate: u32, bits: u32) -> PathBuf {
    let path = dir.file(name);
    write_flac(&path, samples, sample_rate, bits, 1);
    path
}

#[test]
fn radix2_fft_matches_a_direct_dft() {
    const N: usize = 64;
    let mut rng = Rng(2);
    let input: Vec<f64> = (0..N).map(|_| rng.uniform() - 0.5).collect();
    let (mut re, mut im) = (input.clone(), vec![0.0; N]);
    Radix2Fft::new(N).transform(&mut re, &mut im);
    for k in 0..N {
        let (mut want_re, mut want_im) = (0.0, 0.0);
        for (j, v) in input.iter().enumerate() {
            let angle = -2.0 * std::f64::consts::PI * (k * j) as f64 / N as f64;
            want_re += v * angle.cos();
            want_im += v * angle.sin();
        }
        assert!((re[k] - want_re).hypot(im[k] - want_im) < 1e-9, "bin {k}");
    }
}

#[test]
fn flac_frame_numbers_use_the_utf8_like_coding() {
    assert_eq!(utf8_number(0x7F), vec![0x7F]);
    assert_eq!(utf8_number(0x80), vec![0xC2, 0x80]);
    assert_eq!(utf8_number(0x7FF), vec![0xDF, 0xBF]);
    assert_eq!(utf8_number(0x800), vec![0xE0, 0xA0, 0x80]);
}

#[test]
fn genuine_hires_is_not_flagged() {
    let dir = TempDir::new("genuine");
    let samples = quantize(&full_band_noise(HIRES_FRAMES, 0), 24);
    let r = check(&flac(&dir, "genuine.flac", &samples, HIRES_SR, 24));
    assert_eq!(r.verdict, VERDICT_GENUINE);
    assert_eq!(r.upsampling_artifact, "");
    assert_eq!(r.brickwall_hz, 0.0);
    assert_eq!(r.confidence, "");
}

#[test]
fn full_bandwidth_is_measured_relative_to_each_sample_rate() {
    let dir = TempDir::new("rates");
    for sr in [44_100, 48_000, 88_200, 96_000, 176_400, 192_000] {
        let samples = quantize(&full_band_noise(65_536, 21), 24);
        let r = check(&flac(&dir, &format!("{sr}.flac"), &samples, sr, 24));
        assert_eq!(r.verdict, VERDICT_GENUINE, "{sr}: {}", r.reason);
        assert!((r.cutoff_frequency_hz - f64::from(sr) / 2.0).abs() < 50.0);
        assert_eq!(r.effective_bit_depth, 24);
    }
}

#[test]
fn a_96k_master_filtered_at_27k_is_not_evidence_of_upsampling() {
    let dir = TempDir::new("filtered96");
    let signal = shape_spectrum(&full_band_noise(131_072, 22), 96_000, |hz| {
        if hz < 27_000.0 { 1.0 } else { 0.0 }
    });
    let r = check(&flac(
        &dir,
        "filtered.flac",
        &quantize(&signal, 24),
        96_000,
        24,
    ));
    assert_eq!(r.verdict, VERDICT_BAND_LIMITED);
    assert!((r.cutoff_frequency_hz - 27_000.0).abs() < 1000.0);
    assert_eq!(r.effective_bit_depth, 24);
    assert!(!r.is_suspicious());
    assert!(!r.redownload_safe());
}

fn write_stereo_wav(path: &Path, left: &[i32], right: &[i32], sr: u32) {
    assert_eq!(left.len(), right.len());
    let interleaved: Vec<i32> = left.iter().zip(right).flat_map(|(&l, &r)| [l, r]).collect();
    write_wav(path, &interleaved, sr, 24);
    let mut bytes = std::fs::read(path).expect("wav");
    bytes[22..24].copy_from_slice(&2u16.to_le_bytes());
    bytes[28..32].copy_from_slice(&(sr * 6).to_le_bytes());
    bytes[32..34].copy_from_slice(&6u16.to_le_bytes());
    std::fs::write(path, bytes).expect("stereo header");
}

fn assert_streamed_window_matches_reference(path: &Path, start: u64, frames: u64) -> usize {
    let mut file = File::open(path).unwrap();
    let mut source = Source::open(&mut file).unwrap();
    let rate = source.sample_rate();
    let mut plan = StftPlan::new(1024, rate);
    let streamed = source
        .analyze_window(start, frames, &mut plan, &|| Ok(()))
        .unwrap();
    for (index, channel) in streamed.channels.into_iter().enumerate() {
        let mut file = File::open(path).unwrap();
        let mut reference = Source::open(&mut file).unwrap();
        let window = reference
            .read_window(start, frames, index as u32, &|| Ok(()))
            .unwrap();
        assert_eq!(channel.count, window.signal.len());
        assert_eq!(
            channel.non_silent,
            window
                .signal
                .iter()
                .any(|sample| f64::from(sample.abs()) > 1e-9)
        );
        assert_eq!(channel.integers.or_bits, window.or_bits);
        assert_eq!(
            channel.integers.artifact(),
            evidence::detect_integer_upsampling(&window.samples, window.or_bits, rate)
        );
        let expected = evidence::analyze_stft(&window.signal, 1024, rate, &|| Ok(())).unwrap();
        let actual = channel.stft.finish(&plan);
        assert_eq!(actual.avg_magnitude, expected.avg_magnitude);
        assert_eq!(
            actual.quiet_floor_var.to_bits(),
            expected.quiet_floor_var.to_bits()
        );
        assert_eq!(actual.music_band_spreads, expected.music_band_spreads);
    }
    streamed.decoded_blocks
}

#[test]
fn one_flac_decode_pass_serves_all_eight_channels_with_exact_window_evidence() {
    let dir = TempDir::new("streamed-flac");
    let path = dir.file("eight-channels.flac");
    let samples = pcm_using_bits(16, 24, 4096 * 6, 29);
    write_flac(&path, &samples, 96_000, 24, 8);
    // Three prefix blocks plus the end of the sampled window: four decoded
    // blocks total, rather than four separately for every channel.
    assert_eq!(
        assert_streamed_window_matches_reference(&path, 8500, 5000),
        4
    );
    assert_eq!(assert_streamed_window_matches_reference(&path, 0, 700), 1);
    assert_eq!(
        assert_streamed_window_matches_reference(&path, 20_000, 8000),
        6
    );
}

#[test]
fn streaming_wav_preserves_independent_antiphase_channels_and_partial_windows() {
    let dir = TempDir::new("streamed-wav");
    let left = quantize(&full_band_noise(20_003, 23), 24);
    let right: Vec<i32> = left.iter().map(|sample| -*sample).collect();
    let path = dir.file("antiphase.wav");
    write_stereo_wav(&path, &left, &right, 96_000);
    assert_eq!(
        assert_streamed_window_matches_reference(&path, 17, 13_013),
        0
    );
    assert_eq!(
        assert_streamed_window_matches_reference(&path, 18_000, 6000),
        0
    );
}

#[test]
fn streaming_wav_matches_all_integer_and_float_sample_encodings() {
    let dir = TempDir::new("streamed-encodings");
    for bits in [8, 16, 24, 32] {
        let path = dir.file(&format!("integer-{bits}.wav"));
        let samples: Vec<i32> = (0..4099).map(|i| (i * 37 % 127) - 63).collect();
        write_wav(&path, &samples, 96_000, bits);
        assert_streamed_window_matches_reference(&path, 31, 3500);
    }
    for bits in [32, 64] {
        let path = dir.file(&format!("float-{bits}.wav"));
        write_wav(&path, &[0], 96_000, 32);
        let mut bytes = std::fs::read(&path).unwrap();
        bytes.truncate(44);
        bytes[20..22].copy_from_slice(&3u16.to_le_bytes());
        bytes[28..32].copy_from_slice(&(96_000_u32 * bits / 8).to_le_bytes());
        bytes[32..34].copy_from_slice(&((bits / 8) as u16).to_le_bytes());
        bytes[34..36].copy_from_slice(&(bits as u16).to_le_bytes());
        for i in 0..4099 {
            let value = ((i * 37 % 127) as f64 - 63.0) / 128.0;
            if bits == 32 {
                bytes.extend_from_slice(&(value as f32).to_le_bytes());
            } else {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
        }
        let data_size = (bytes.len() - 44) as u32;
        bytes[4..8].copy_from_slice(&(36 + data_size).to_le_bytes());
        bytes[40..44].copy_from_slice(&data_size.to_le_bytes());
        std::fs::write(&path, bytes).unwrap();
        assert_streamed_window_matches_reference(&path, 31, 3500);
    }
}

#[test]
fn antiphase_channels_do_not_cancel_spectral_evidence() {
    let dir = TempDir::new("antiphase");
    let left = quantize(&full_band_noise(65_536, 23), 24);
    let right: Vec<i32> = left.iter().map(|v| -*v).collect();
    let path = dir.file("antiphase.wav");
    write_stereo_wav(&path, &left, &right, 96_000);
    let r = check(&path);
    assert_eq!(r.verdict, VERDICT_GENUINE);
    assert!(r.cutoff_frequency_hz > 47_000.0);
    assert_eq!(r.effective_bit_depth, 24);
}

#[test]
fn a_full_resolution_channel_prevents_a_false_padding_or_pattern_verdict() {
    let dir = TempDir::new("independent-channels");
    let source = pcm_using_bits(16, 24, 16_384, 24);
    let left: Vec<i32> = source.iter().flat_map(|&v| [v; 4]).collect();
    let right = pcm_using_bits(24, 24, left.len(), 25);
    let path = dir.file("independent.wav");
    write_stereo_wav(&path, &left, &right, HIRES_SR);
    let r = check(&path);
    assert_eq!(r.verdict, VERDICT_GENUINE);
    assert_eq!(r.upsampling_artifact, "");
    assert_eq!(r.effective_bit_depth, 24);
    assert!(r.cutoff_frequency_hz > 80_000.0);
}

#[test]
fn cropped_segment_edges_do_not_create_ultrasonic_energy() {
    let signal: Vec<f32> = (0..10_000)
        .map(|i| (2.0 * std::f64::consts::PI * 3000.0 * i as f64 / 96_000.0).cos() as f32)
        .collect();
    let stats = analyze_stft(&signal, 4096, 96_000, &|| Ok(())).expect("stft");
    let db = spectrum_db(&stats.avg_magnitude);
    assert!(db[1024..].iter().all(|v| *v < -100.0));
}

#[test]
fn a_16bit_noise_floor_in_one_channel_does_not_hide_quieter_detail_in_another() {
    let dir = TempDir::new("mixed-floors");
    let left = ideal_upsample(&dither_to_16_bit(&cd_source_with_quiet_half(0.0)), 4);
    let right = ideal_upsample(&cd_source_with_quiet_half(1e-6), 4);
    let path = dir.file("mixed.wav");
    write_stereo_wav(&path, &quantize(&left, 24), &quantize(&right, 24), HIRES_SR);
    let r = check(&path);
    assert_eq!(r.brickwall_hz, 22_050.0);
    assert_eq!(r.verdict, VERDICT_BAND_LIMITED);
    assert!(!r.redownload_safe());
}

#[test]
fn bandwidth_alone_cannot_identify_an_upsampled_cd() {
    let dir = TempDir::new("upsampled");
    let samples = quantize(&upsampled_from_cd(), 24);
    let r = check(&flac(&dir, "fake.flac", &samples, HIRES_SR, 24));
    assert_eq!(r.verdict, VERDICT_BAND_LIMITED);
    assert!(!r.is_suspicious());
    assert!(
        r.cutoff_frequency_hz > 22_000.0 && r.cutoff_frequency_hz < 28_000.0,
        "{}",
        r.cutoff_frequency_hz
    );
    assert!(r.reason.contains("content stops"), "{}", r.reason);
    // Loud from start to end: the floor cannot be read, so a genuine master
    // filtered at 22 kHz would look the same. Report bandwidth, not provenance.
    assert_eq!(r.brickwall_hz, 22_050.0);
    assert_eq!(r.noise_floor_class, FLOOR_MASKED);
    assert_eq!(r.confidence, "");
    assert!(!r.redownload_safe());
}

#[test]
fn a_cd_file_claims_nothing() {
    let dir = TempDir::new("cd");
    let samples = quantize(&full_band_noise(CD_SR as usize * 3, 0), 16);
    let r = check(&flac(&dir, "cd.flac", &samples, CD_SR, 16));
    assert_eq!(r.verdict, VERDICT_STANDARD);
    assert!(!r.is_suspicious());
}

/// 24-bit/44.1 kHz claims Hi-Res by depth alone, which no spectral test can
/// judge: what gives a padded CD master away is its always-zero low 8 bits.
#[test]
fn a_padded_24_bit_cd_master_is_certain() {
    let dir = TempDir::new("padded");
    let samples = pcm_using_bits(16, 24, CD_SR as usize * 3, 1);
    let r = check(&flac(&dir, "padded.flac", &samples, CD_SR, 24));
    assert_eq!(r.verdict, VERDICT_FAKE);
    assert_eq!((r.declared_bit_depth, r.effective_bit_depth), (24, 16));
    assert!(r.padded_bit_depth());
    assert!(
        r.reason.contains("24-bit") && r.reason.contains("16 bits"),
        "{}",
        r.reason
    );
    // The spectral half made no finding, so it must not appear in the reason.
    assert!(!r.reason.contains("content stops"), "{}", r.reason);
    assert_eq!(r.confidence, CONFIDENCE_CERTAIN);
    assert!(r.redownload_safe());
}

#[test]
fn a_real_24_bit_cd_rate_file_is_not_flagged() {
    let dir = TempDir::new("real24");
    let samples = pcm_using_bits(24, 24, CD_SR as usize * 3, 1);
    let r = check(&flac(&dir, "real24.flac", &samples, CD_SR, 24));
    assert_eq!(r.verdict, VERDICT_GENUINE);
    assert_eq!((r.declared_bit_depth, r.effective_bit_depth), (24, 24));
    assert!(!r.padded_bit_depth());
}

/// A 16-bit container declares no Hi-Res depth, so the spectral verdict is the
/// whole answer.
#[test]
fn sixteen_bit_makes_no_depth_claim() {
    let dir = TempDir::new("hires16");
    let samples = quantize(&full_band_noise(HIRES_FRAMES, 0), 16);
    let r = check(&flac(&dir, "hires16.flac", &samples, HIRES_SR, 16));
    assert_eq!(r.declared_bit_depth, 16);
    assert!(!r.padded_bit_depth());
    assert_eq!(r.verdict, VERDICT_GENUINE);
}

#[test]
fn silence_is_inconclusive() {
    let dir = TempDir::new("silent");
    let r = check(&flac(
        &dir,
        "silent.flac",
        &vec![0; HIRES_FRAMES],
        HIRES_SR,
        24,
    ));
    assert_eq!(r.verdict, VERDICT_INCONCLUSIVE);
}

/// A floor below -80 dB must still measure the spectrum rather than report
/// the full Nyquist frequency as content for every file.
#[test]
fn a_lower_noise_floor_still_measures() {
    let dir = TempDir::new("floor");
    let samples = quantize(&upsampled_from_cd(), 24);
    let path = flac(&dir, "fake.flac", &samples, HIRES_SR, 24);
    let options = HiResCheckOptions {
        noise_floor_db: -90.0,
        ..HiResCheckOptions::default()
    };
    let r = run_check(&path, &options).expect("check");
    assert!(
        r.cutoff_frequency_hz < f64::from(HIRES_SR) / 2.0,
        "{}",
        r.cutoff_frequency_hz
    );
}

/// Real-world FLACs are stereo and longer than the 30 s window, which must be
/// taken from the middle.
#[test]
fn a_long_stereo_flac_is_read_from_the_middle() {
    let dir = TempDir::new("stereo");
    let path = dir.file("stereo.flac");
    let samples = pcm_using_bits(16, 24, CD_SR as usize * 70, 1);
    write_flac(&path, &samples, CD_SR, 24, 2);
    let r = check(&path);
    assert_eq!(r.analyzed_duration_s, 30.0);
    assert_eq!(r.verdict, VERDICT_FAKE);
    assert_eq!(r.effective_bit_depth, 16);
}

#[test]
fn wav_is_checked_too() {
    let dir = TempDir::new("wav");
    let padded = dir.file("padded.wav");
    write_wav(
        &padded,
        &pcm_using_bits(16, 24, CD_SR as usize * 3, 1),
        CD_SR,
        24,
    );
    let r = check(&padded);
    assert_eq!(
        (r.verdict.as_str(), r.effective_bit_depth),
        (VERDICT_FAKE, 16)
    );

    let fake = dir.file("fake.wav");
    write_wav(&fake, &quantize(&upsampled_from_cd(), 24), HIRES_SR, 24);
    let r = check(&fake);
    assert_eq!(
        (r.verdict.as_str(), r.effective_bit_depth),
        (VERDICT_BAND_LIMITED, 24)
    );
}

#[test]
fn errors_and_unsupported_formats() {
    let dir = TempDir::new("errors");
    let empty = dir.file("empty.flac");
    std::fs::write(&empty, b"").expect("write");
    let mp3 = dir.file("song.mp3");
    std::fs::write(&mp3, b"ID3\x04\x00\x00\x00\x00\x00\x00junk").expect("write");
    let corrupt = dir.file("corrupt.flac");
    std::fs::write(&corrupt, b"fLaC\x00\x00").expect("write");
    let options = HiResCheckOptions::default();

    assert!(matches!(
        run_check(&empty, &options),
        Err(HiResCheckError::Failed(_))
    ));
    assert_eq!(run_check(&mp3, &options), Err(HiResCheckError::Unsupported));
    assert!(matches!(
        run_check(&corrupt, &options),
        Err(HiResCheckError::Failed(_))
    ));
    let bad = HiResCheckOptions {
        n_fft: 1000,
        ..HiResCheckOptions::default()
    };
    assert!(matches!(
        run_check(&mp3, &bad),
        Err(HiResCheckError::Failed(_))
    ));
}

#[test]
fn a_cancelled_check_stops() {
    let dir = TempDir::new("cancel");
    let samples = quantize(&full_band_noise(HIRES_FRAMES, 0), 24);
    let path = flac(&dir, "genuine.flac", &samples, HIRES_SR, 24);
    let file = File::open(&path).expect("open");
    let result = check_file(file, "x", &HiResCheckOptions::default(), &|| {
        Err("cancelled".into())
    });
    assert_eq!(result, Err(HiResCheckError::Failed("cancelled".into())));
}

/// A dithered 16-bit CD master upsampled cleanly: the cliff sits at 22.05 kHz
/// and the quiet half shows 16-bit dither noise. This supports a likely
/// verdict, but cannot prove that a separately downloaded copy is equivalent.
#[test]
fn an_upsampled_16_bit_master_is_likely() {
    let dir = TempDir::new("likely");
    let signal = ideal_upsample(&dither_to_16_bit(&cd_source_with_quiet_half(0.0)), 4);
    let r = check(&flac(
        &dir,
        "cd16.flac",
        &quantize(&signal, 24),
        HIRES_SR,
        24,
    ));
    assert_eq!(r.verdict, VERDICT_FAKE);
    assert_eq!(r.brickwall_hz, 22_050.0);
    assert_eq!(
        r.noise_floor_class, FLOOR_AT_16BIT,
        "{} dB",
        r.noise_floor_vs_16bit_db
    );
    assert_eq!(r.confidence, CONFIDENCE_LIKELY);
    assert!(
        !r.redownload_safe(),
        "Spectral evidence cannot authorize replacement"
    );
}

/// The same cliff, but the quiet half carries detail far below 16-bit noise:
/// a 24-bit master made at 44.1 kHz. LOSSLESS would lose that depth.
#[test]
fn a_24_bit_master_made_at_44k_has_limited_bandwidth() {
    let dir = TempDir::new("master24");
    let signal = ideal_upsample(&cd_source_with_quiet_half(1e-6), 4);
    let r = check(&flac(
        &dir,
        "master24.flac",
        &quantize(&signal, 24),
        HIRES_SR,
        24,
    ));
    assert_eq!(r.verdict, VERDICT_BAND_LIMITED);
    assert_eq!(
        r.noise_floor_class, FLOOR_BELOW_16BIT,
        "{} dB",
        r.noise_floor_vs_16bit_db
    );
    assert_eq!(r.confidence, "");
    assert!(!r.redownload_safe());
    assert!(r.reason.contains("provenance"), "{}", r.reason);
}

/// A gradual mastering roll-off that still ends below 28 kHz: no resampler
/// cliff, so no evidence of upsampling. An abrupt start inside the
/// analyzed window is a step, whose broadband splatter reads as content.
#[test]
fn a_gradual_mastering_roll_off_is_not_flagged_as_fake() {
    let dir = TempDir::new("lpf");
    let mut signal = shape_spectrum(&full_band_noise(HIRES_FRAMES, 0), HIRES_SR, |freq| {
        let gain_db = if freq > 16_000.0 {
            -10.0 * (freq - 16_000.0) / 1000.0
        } else {
            0.0
        };
        10f64.powf(gain_db / 20.0)
    });
    fade(&mut signal);
    let r = check(&flac(
        &dir,
        "lpf.flac",
        &quantize(&signal, 24),
        HIRES_SR,
        24,
    ));
    assert_eq!(r.verdict, VERDICT_BAND_LIMITED);
    assert_eq!(r.brickwall_hz, 0.0);
    assert_eq!(r.confidence, "");
}

/// 24-bit source samples (so the depth test passes) taken to 176.4 kHz by the
/// cheap upsamplers whose output is an exact, checkable pattern.
#[test]
fn integer_patterns_are_certain_but_spectral_imaging_is_likely() {
    let source = pcm_using_bits(24, 24, CD_SOURCE_FRAMES + 1, 1);
    let (mut hold, mut line, mut zero_stuffed) = (Vec::new(), Vec::new(), Vec::new());
    for pair in source.windows(2) {
        let (a, b) = (f64::from(pair[0]), f64::from(pair[1]));
        for j in 0..4 {
            hold.push(pair[0]);
            line.push((a + (b - a) * f64::from(j) / 4.0).round() as i32);
            zero_stuffed.push(if j == 0 { pair[0] / 2 } else { 0 });
        }
    }
    let dir = TempDir::new("artifacts");
    for (name, samples, artifact) in [
        ("hold", hold, ARTIFACT_SAMPLE_HOLD),
        ("linear", line, ARTIFACT_INTERPOLATION),
        ("zero", zero_stuffed, ARTIFACT_IMAGING),
    ] {
        let r = check(&flac(&dir, &format!("{name}.flac"), &samples, HIRES_SR, 24));
        assert_eq!(r.upsampling_artifact, artifact, "{name}");
        assert_eq!(r.verdict, VERDICT_FAKE, "{name}");
        let confidence = if artifact == ARTIFACT_IMAGING {
            CONFIDENCE_LIKELY
        } else {
            CONFIDENCE_CERTAIN
        };
        assert_eq!(r.confidence, confidence, "{name}");
    }
}

/// A DSD or analog-tape transfer: music that stops around 30 kHz, and a steady
/// ultrasonic noise hump running on to ~80 kHz. The active-content cutoff
/// marks the end of the hump; the music bandwidth must not, and the useful
/// rate is the 88.2 kHz that holds all the music.
#[test]
fn music_is_told_apart_from_ultrasonic_noise() {
    let band = |seed, low: f64, high: f64| {
        shape_spectrum(&full_band_noise(HIRES_FRAMES, seed), HIRES_SR, |freq| {
            if (low..=high).contains(&freq) {
                1.0
            } else {
                0.0
            }
        })
    };
    let (music, hump) = (band(5, 20.0, 30_000.0), band(6, 40_000.0, 80_000.0));
    let mut signal: Vec<f64> = music
        .iter()
        .zip(&hump)
        .enumerate()
        .map(|(i, (m, h))| {
            // A 3 Hz swell swings the music ~20 dB; the hump never moves.
            let phase = 2.0 * std::f64::consts::PI * 3.0 * i as f64 / f64::from(HIRES_SR);
            m * (0.55 + 0.45 * phase.cos()) + 0.02 * h
        })
        .collect();
    fade(&mut signal);
    let dir = TempDir::new("dsd");
    let r = check(&flac(
        &dir,
        "dsd.flac",
        &quantize(&signal, 24),
        HIRES_SR,
        24,
    ));
    assert_eq!(r.verdict, VERDICT_GENUINE);
    assert!(
        r.cutoff_frequency_hz > 70_000.0,
        "{}",
        r.cutoff_frequency_hz
    );
    assert!(
        (28_000.0..=33_000.0).contains(&r.music_cutoff_hz),
        "{}",
        r.music_cutoff_hz
    );
    assert!(r.ultrasonic_noise_only);
    assert_eq!(r.useful_sample_rate, 88_200);
}

#[test]
fn padded_depth_does_not_make_high_rate_content_safe_to_replace_with_cd() {
    let dir = TempDir::new("review-high-rate");
    let samples: Vec<i32> = quantize(&full_band_noise(HIRES_FRAMES, 17), 16)
        .into_iter()
        .map(|sample| sample << 8)
        .collect();
    let result = check(&flac(&dir, "high-rate-padded.flac", &samples, HIRES_SR, 24));
    assert_eq!(result.effective_bit_depth, 16);
    assert!(result.cutoff_frequency_hz > 30_000.0);
    assert!(
        !result.redownload_safe(),
        "Full-rate content would be lost: {result:?}"
    );
}

#[test]
fn rate_upsampling_does_not_make_real_24_bit_depth_safe_to_replace_with_cd() {
    let dir = TempDir::new("review-full-depth");
    let source = pcm_using_bits(24, 24, CD_SOURCE_FRAMES, 1);
    let samples: Vec<i32> = source.into_iter().flat_map(|sample| [sample; 4]).collect();
    let result = check(&flac(
        &dir,
        "full-depth-upsampled.flac",
        &samples,
        HIRES_SR,
        24,
    ));
    assert_eq!(result.effective_bit_depth, 24);
    assert_eq!(result.upsampling_artifact, ARTIFACT_SAMPLE_HOLD);
    assert!(
        !result.redownload_safe(),
        "Real 24-bit depth would be lost: {result:?}"
    );
}

fn preserves(original: &Path, replacement: &Path) -> bool {
    replacement_preserves_audio(
        File::open(original).expect("original"),
        File::open(replacement).expect("replacement"),
        &|| Ok(()),
    )
    .unwrap_or(false)
}

#[test]
fn replacement_verifies_padding_and_sample_repetition_across_every_frame() {
    let dir = TempDir::new("replacement-pcm");
    let source = pcm_using_bits(16, 16, 20_001, 8);
    let replacement = flac(&dir, "cd.flac", &source, CD_SR, 16);
    for ratio in [1, 2, 4] {
        let padded: Vec<i32> = source
            .iter()
            .flat_map(|v| std::iter::repeat_n(v << 8, ratio))
            .collect();
        let original = flac(&dir, "original.flac", &padded, CD_SR * ratio as u32, 24);
        assert!(preserves(&original, &replacement));
        let wav = dir.file("original.wav");
        write_wav(&wav, &padded, CD_SR * ratio as u32, 24);
        assert!(preserves(&wav, &replacement));
    }
}

#[test]
fn replacement_rejects_real_precision_outside_the_sampled_window() {
    let dir = TempDir::new("replacement-tail");
    let source = pcm_using_bits(16, 16, 20_001, 9);
    let replacement = flac(&dir, "cd.flac", &source, CD_SR, 16);
    let padded: Vec<i32> = source.iter().map(|v| v << 8).collect();
    for index in [0, 10_000, 20_000] {
        let mut original = padded.clone();
        original[index] += 1;
        let original = flac(&dir, "original.flac", &original, CD_SR, 24);
        assert!(!preserves(&original, &replacement), "frame {index}");
    }
}

#[test]
fn replacement_rejects_changed_master_rate_duration_and_truncation() {
    let dir = TempDir::new("replacement-invalid");
    let source = pcm_using_bits(16, 16, 20_001, 10);
    let padded: Vec<i32> = source.iter().map(|v| v << 8).collect();
    let original = flac(&dir, "original.flac", &padded, CD_SR, 24);
    let other = pcm_using_bits(16, 16, source.len(), 11);
    for (samples, rate) in [
        (&other[..], CD_SR),
        (&source[..], 48_000),
        (&source[..20_000], CD_SR),
    ] {
        let replacement = flac(&dir, "other.flac", samples, rate, 16);
        assert!(!preserves(&original, &replacement));
    }
    let replacement = flac(&dir, "truncated.flac", &source, CD_SR, 16);
    let file = std::fs::OpenOptions::new()
        .write(true)
        .open(&replacement)
        .expect("open");
    file.set_len(file.metadata().expect("stat").len() - 3)
        .expect("truncate");
    assert!(!preserves(&original, &replacement));
}

#[test]
fn replacement_checks_every_channel() {
    let dir = TempDir::new("replacement-stereo");
    let source = pcm_using_bits(16, 16, 20_001, 12);
    let padded: Vec<i32> = source.iter().map(|v| v << 8).collect();
    let original = dir.file("stereo.flac");
    write_flac(&original, &padded, CD_SR, 24, 2);
    let stereo = dir.file("stereo.wav");
    let interleaved: Vec<i32> = source.iter().flat_map(|&v| [v, v]).collect();
    write_wav(&stereo, &interleaved, CD_SR, 16);
    let mut bytes = std::fs::read(&stereo).expect("wav");
    bytes[22..24].copy_from_slice(&2u16.to_le_bytes());
    bytes[28..32].copy_from_slice(&(CD_SR * 4).to_le_bytes());
    bytes[32..34].copy_from_slice(&4u16.to_le_bytes());
    std::fs::write(&stereo, &bytes).expect("stereo header");
    assert!(preserves(&original, &stereo));
    // Only the last frame's right channel changes.
    let last = bytes.len() - 2;
    bytes[last] ^= 1;
    std::fs::write(&stereo, &bytes).expect("different right channel");
    assert!(!preserves(&original, &stereo));
    let mono = flac(&dir, "mono.flac", &source, CD_SR, 16);
    assert!(!preserves(&original, &mono));
}

#[test]
fn replacement_comparison_is_cancellable() {
    let dir = TempDir::new("replacement-cancel");
    let original = flac(&dir, "original.flac", &vec![256; 20_000], CD_SR, 24);
    let replacement = flac(&dir, "cd.flac", &vec![1; 20_000], CD_SR, 16);
    let calls = std::cell::Cell::new(0);
    let result = replacement_preserves_audio(
        File::open(original).expect("original"),
        File::open(replacement).expect("replacement"),
        &|| {
            calls.set(calls.get() + 1);
            if calls.get() > 2 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        },
    );
    assert!(matches!(result, Err(HiResCheckError::Failed(message)) if message == "cancelled"));
}

#[test]
fn wav_rejects_oversized_and_truncated_chunks_without_allocating_them() {
    let dir = TempDir::new("wav-malformed");
    let path = dir.file("bad.wav");
    for id in [b"fmt ", b"JUNK"] {
        let mut bytes = b"RIFF\xff\xff\xff\xffWAVE".to_vec();
        bytes.extend_from_slice(id);
        bytes.extend_from_slice(&u32::MAX.to_le_bytes());
        bytes.extend_from_slice(&[0; 40]);
        std::fs::write(&path, bytes).expect("malformed WAV");
        assert!(run_check(&path, &HiResCheckOptions::default()).is_err());
    }
    write_wav(&path, &[0; 100], CD_SR, 16);
    let mut bytes = std::fs::read(&path).expect("wav");
    bytes.truncate(bytes.len() - 2);
    std::fs::write(&path, bytes).expect("truncated data");
    assert!(run_check(&path, &HiResCheckOptions::default()).is_err());
}

#[test]
fn wav_skips_extra_format_bytes_and_odd_chunk_padding() {
    let dir = TempDir::new("wav-extra-fmt");
    let path = dir.file("extended.wav");
    write_wav(&path, &pcm_using_bits(16, 24, 20_000, 13), CD_SR, 24);
    let mut bytes = std::fs::read(&path).expect("wav");
    bytes[16..20].copy_from_slice(&41u32.to_le_bytes());
    bytes.splice(36..36, [0; 26]); // 25 extra format bytes plus one pad byte
    let len = bytes.len() as u32 - 8;
    bytes[4..8].copy_from_slice(&len.to_le_bytes());
    std::fs::write(&path, bytes).expect("extra fmt bytes");
    assert!(check(&path).padded_bit_depth());
}
