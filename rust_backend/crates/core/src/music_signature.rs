//! Audio fingerprints for recognizing a song heard through the microphone.
//!
//! The layout is the one Shazam's recognition service reads: spectral peaks of
//! 16 kHz mono audio, grouped into four frequency bands and packed into a small
//! little endian container with a CRC32. Only peaks leave the device, never
//! the audio itself. Everything here is deterministic so tests can pin it.

use crate::media::hires::fft::Radix2Fft;
use base64::Engine;

pub const SIGNATURE_SAMPLE_RATE: usize = 16_000;
/// The service reads about twelve seconds of audio at most per signature.
pub const MAX_SIGNATURE_SECONDS: usize = 12;
const MAX_SAMPLES: usize = SIGNATURE_SAMPLE_RATE * MAX_SIGNATURE_SECONDS;
const HOP: usize = 128;
const WINDOW: usize = 2048;
const BINS: usize = WINDOW / 2 + 1;
/// Frames kept for the look back and look ahead of the peak tests.
const HISTORY: usize = 256;
/// A frame is tested for peaks once later frames have spread over it.
const PEAK_DELAY: usize = 46;
const SPREAD_DELAY: usize = 49;
const MIN_ENERGY: f64 = 1.0 / 64.0;
const NEIGHBOR_BINS: [isize; 8] = [-10, -7, -4, -3, 1, 2, 5, 8];
const NEIGHBOR_FRAMES: [isize; 14] = [
    -53, -45, 165, 172, 179, 186, 193, 200, 214, 221, 228, 235, 242, 249,
];
/// Spread frames that each new frame also raises, counted back from it.
const SPREAD_BACK: [usize; 3] = [1, 3, 6];
/// Band edges in Hz; peaks outside them are not sent.
const BANDS: [(f64, f64); 4] = [
    (250.0, 520.0),
    (520.0, 1450.0),
    (1450.0, 3500.0),
    (3500.0, 5500.0),
];
/// Hz per unit of a peak's corrected bin (64 steps per FFT bin).
const HZ_PER_CORRECTED_BIN: f64 = SIGNATURE_SAMPLE_RATE as f64 / 2.0 / 1024.0 / 64.0;

const MAGIC: u32 = 0xCAFE_2580;
const MAGIC_2: u32 = 0x9411_9C00;
const SAMPLE_RATE_ID_16K: u32 = 3 << 27;
const FIXED_HEADER_VALUE: u32 = (15 << 19) + 0x40000;
const CONTENTS_TAG: u32 = 0x4000_0000;
const BAND_TAG: u32 = 0x6003_0040;
pub const HEADER_LEN: usize = 48;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Peak {
    /// The hop the peak belongs to, counted from the first tested frame.
    pub pass: u32,
    pub magnitude: u16,
    /// The FFT bin times 64, refined between bins by a parabola.
    pub corrected_bin: u16,
}

impl Peak {
    pub fn frequency_hz(&self) -> f64 {
        f64::from(self.corrected_bin) * HZ_PER_CORRECTED_BIN
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Signature {
    /// Samples the peaks were taken from.
    pub sample_count: u32,
    /// Peaks of each band in pass order.
    pub bands: [Vec<Peak>; 4],
}

impl Signature {
    pub fn peak_count(&self) -> usize {
        self.bands.iter().map(Vec::len).sum()
    }

    pub fn sample_ms(&self) -> u64 {
        u64::from(self.sample_count) * 1000 / SIGNATURE_SAMPLE_RATE as u64
    }

    /// The binary container: a 48 byte header, a contents tag, then one
    /// tag/length/value entry per band that has peaks.
    pub fn encode(&self) -> Vec<u8> {
        let mut contents = Vec::new();
        for (band, peaks) in self.bands.iter().enumerate() {
            if peaks.is_empty() {
                continue;
            }
            let payload = encode_peaks(peaks);
            push_u32(&mut contents, BAND_TAG + band as u32);
            push_u32(&mut contents, payload.len() as u32);
            contents.extend_from_slice(&payload);
            contents.resize(contents.len().next_multiple_of(4), 0);
        }
        let size_minus_header = contents.len() as u32 + 8;
        let mut out = Vec::with_capacity(HEADER_LEN + size_minus_header as usize);
        push_u32(&mut out, MAGIC);
        push_u32(&mut out, 0);
        push_u32(&mut out, size_minus_header);
        push_u32(&mut out, MAGIC_2);
        out.extend_from_slice(&[0; 12]);
        push_u32(&mut out, SAMPLE_RATE_ID_16K);
        out.extend_from_slice(&[0; 8]);
        // The service expects a quarter second of lead in on top.
        push_u32(
            &mut out,
            self.sample_count + (SIGNATURE_SAMPLE_RATE as u32 * 24 / 100),
        );
        push_u32(&mut out, FIXED_HEADER_VALUE);
        push_u32(&mut out, CONTENTS_TAG);
        push_u32(&mut out, size_minus_header);
        out.extend_from_slice(&contents);
        let crc = crc32(&out[8..]);
        out[4..8].copy_from_slice(&crc.to_le_bytes());
        out
    }

    pub fn data_uri(&self) -> String {
        format!(
            "data:audio/vnd.shazam.sig;base64,{}",
            base64::engine::general_purpose::STANDARD.encode(self.encode())
        )
    }
}

/// Each peak is a pass delta byte, its magnitude and its corrected bin. A
/// delta of 255 or more is written as 0xFF and the absolute pass, after
/// which the peak's own delta is 0.
fn encode_peaks(peaks: &[Peak]) -> Vec<u8> {
    let mut out = Vec::with_capacity(peaks.len() * 5);
    let mut pass = 0;
    for peak in peaks {
        if peak.pass - pass >= 255 {
            out.push(0xFF);
            push_u32(&mut out, peak.pass);
            pass = peak.pass;
        }
        out.push((peak.pass - pass) as u8);
        out.extend_from_slice(&peak.magnitude.to_le_bytes());
        out.extend_from_slice(&peak.corrected_bin.to_le_bytes());
        pass = peak.pass;
    }
    out
}

fn push_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_le_bytes());
}

/// The zlib CRC32 (reflected, polynomial 0xEDB88320).
pub fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &byte in bytes {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xEDB8_8320 & (crc & 1).wrapping_neg());
        }
    }
    !crc
}

/// The RMS level of the samples in dBFS, or negative infinity for silence.
pub fn rms_dbfs(samples: &[i16]) -> f64 {
    if samples.is_empty() {
        return f64::NEG_INFINITY;
    }
    let power = samples
        .iter()
        .map(|&sample| f64::from(sample).powi(2))
        .sum::<f64>()
        / samples.len() as f64;
    10.0 * (power / 32768.0_f64.powi(2)).log10()
}

/// Fingerprints 16 kHz mono samples, at most [`MAX_SIGNATURE_SECONDS`] of
/// them; a trailing partial hop is ignored.
pub fn signature_from_pcm16(
    samples: &[i16],
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Signature, String> {
    let samples = &samples[..samples.len().min(MAX_SAMPLES)];
    let mut generator = Generator::new();
    for (index, hop) in samples.as_chunks::<HOP>().0.iter().enumerate() {
        if index % 64 == 0 {
            check()?;
        }
        generator.push_hop(hop);
    }
    Ok(generator.signature)
}

struct Generator {
    fft: Radix2Fft,
    window: Vec<f64>,
    samples: Vec<f64>,
    sample_cursor: usize,
    /// Power spectra of the latest frames, oldest overwritten first.
    spectra: Vec<Vec<f64>>,
    /// The same frames after spreading each peak over nearby bins and frames.
    spread: Vec<Vec<f64>>,
    cursor: usize,
    frames: usize,
    re: Vec<f64>,
    im: Vec<f64>,
    signature: Signature,
}

impl Generator {
    fn new() -> Self {
        let window = (0..WINDOW)
            .map(|i| {
                0.5 - 0.5 * (std::f64::consts::TAU * (i + 1) as f64 / (WINDOW + 1) as f64).cos()
            })
            .collect();
        Self {
            fft: Radix2Fft::new(WINDOW),
            window,
            samples: vec![0.0; WINDOW],
            sample_cursor: 0,
            spectra: vec![vec![0.0; BINS]; HISTORY],
            spread: vec![vec![0.0; BINS]; HISTORY],
            cursor: 0,
            frames: 0,
            re: vec![0.0; WINDOW],
            im: vec![0.0; WINDOW],
            signature: Signature::default(),
        }
    }

    fn frame(&self, back: isize) -> usize {
        (self.cursor as isize + back).rem_euclid(HISTORY as isize) as usize
    }

    fn push_hop(&mut self, hop: &[i16]) {
        for &sample in hop {
            self.samples[self.sample_cursor] = f64::from(sample);
            self.sample_cursor = (self.sample_cursor + 1) % WINDOW;
        }
        self.signature.sample_count += hop.len() as u32;
        self.transform();
        self.spread_latest();
        self.cursor = (self.cursor + 1) % HISTORY;
        self.frames += 1;
        if self.frames >= PEAK_DELAY {
            self.find_peaks();
        }
    }

    /// Windows the latest 2048 samples, oldest first, into a power spectrum.
    fn transform(&mut self) {
        for i in 0..WINDOW {
            self.re[i] = self.samples[(self.sample_cursor + i) % WINDOW] * self.window[i];
            self.im[i] = 0.0;
        }
        self.fft.transform(&mut self.re, &mut self.im);
        let spectrum = &mut self.spectra[self.cursor];
        for (bin, value) in spectrum.iter_mut().enumerate() {
            let power = (self.re[bin].powi(2) + self.im[bin].powi(2)) / f64::from(1 << 17);
            *value = power.max(1e-10);
        }
    }

    /// Spreads the new spectrum over the next two bins, then raises three
    /// earlier spread frames to it, so a peak must beat its surroundings.
    fn spread_latest(&mut self) {
        let mut spread = self.spectra[self.cursor].clone();
        for bin in 0..BINS - 2 {
            spread[bin] = spread[bin].max(spread[bin + 1]).max(spread[bin + 2]);
        }
        for back in SPREAD_BACK {
            let index = self.frame(-(back as isize));
            for (earlier, &value) in self.spread[index].iter_mut().zip(&spread) {
                *earlier = earlier.max(value);
            }
        }
        self.spread[self.cursor] = spread;
    }

    fn find_peaks(&mut self) {
        // The cursor already points past the newest frame.
        let spectrum = &self.spectra[self.frame(-(PEAK_DELAY as isize))];
        let spread = &self.spread[self.frame(-(SPREAD_DELAY as isize))];
        let pass = (self.frames - PEAK_DELAY) as u32;
        for bin in 10..=1014 {
            let energy = spectrum[bin];
            if energy < MIN_ENERGY || energy < spread[bin - 1] {
                continue;
            }
            let nearby = NEIGHBOR_BINS
                .iter()
                .map(|&offset| spread[(bin as isize + offset) as usize])
                .fold(0.0, f64::max);
            if energy <= nearby {
                continue;
            }
            let around = NEIGHBOR_FRAMES
                .iter()
                .map(|&offset| self.spread[self.frame(offset)][bin - 1])
                .fold(nearby, f64::max);
            if energy <= around {
                continue;
            }
            let magnitude = |value: f64| value.max(MIN_ENERGY).ln() * 1477.3 + 6144.0;
            let before = magnitude(spectrum[bin - 1]);
            let peak = magnitude(energy);
            let after = magnitude(spectrum[bin + 1]);
            let curvature = 2.0 * peak - before - after;
            if curvature <= 0.0 {
                continue;
            }
            let corrected = bin as f64 * 64.0 + (after - before) * 32.0 / curvature;
            let hz = corrected * HZ_PER_CORRECTED_BIN;
            let Some(band) = BANDS.iter().position(|&(low, high)| hz >= low && hz < high) else {
                continue;
            };
            self.signature.bands[band].push(Peak {
                pass,
                magnitude: peak as u16,
                corrected_bin: corrected as u16,
            });
        }
    }
}

#[cfg(test)]
mod tests;
