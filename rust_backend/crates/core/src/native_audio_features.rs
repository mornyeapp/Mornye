//! A compact description of how a song sounds, so Autoplay can pick songs
//! that sound like the listening session and flow into each other. Flutter
//! decodes one or two short mono windows; whole files never come here, and
//! no model or network is involved.

use crate::media::hires::fft::Radix2Fft;
use crate::native_audio_analysis::{analyze_automix_pcm, read_bounded};
use serde::Serialize;

/// Changes whenever the vector's layout or meaning does, so stored vectors
/// of another version are analyzed again.
pub const AUDIO_FEATURES_VERSION: u32 = 1;
/// The rate of the mono s16le windows Flutter decodes.
pub const AUDIO_FEATURES_SAMPLE_RATE: usize = 22_050;
pub const MAX_AUDIO_FEATURE_WINDOWS: usize = 2;
pub const MFCC_COEFFICIENTS: usize = 13;
const MAX_WINDOW_BYTES: usize = AUDIO_FEATURES_SAMPLE_RATE * 2 * 25;
const FRAME: usize = 2048;
const HOP: usize = 512;
const BINS: usize = FRAME / 2 + 1;
const BIN_HZ: f64 = AUDIO_FEATURES_SAMPLE_RATE as f64 / FRAME as f64;
const MEL_BANDS: usize = 40;
/// Frames quieter than this stay out of the spectral statistics.
const SILENT_DB: f64 = -60.0;
/// Less audible audio than this describes nothing reliably.
const MIN_AUDIBLE_SECONDS: f64 = 3.0;

// Krumhansl-Kessler key profiles, tonic first.
const MAJOR_PROFILE: [f64; 12] = [
    6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
];
const MINOR_PROFILE: [f64; 12] = [
    6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
];

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct AudioFeatures {
    /// Beats per minute, 60 to 180, or 0 when no beat was found.
    pub tempo: f64,
    pub tempo_confidence: f64,
    /// Mean and standard deviation of the audible frames' RMS, in dBFS.
    pub loudness: f64,
    pub loudness_spread: f64,
    /// Spectral centroid mean and standard deviation, in Hz (brightness).
    pub centroid: f64,
    pub centroid_spread: f64,
    /// The frequency below which 85% of the spectral magnitude lies, in Hz.
    pub rolloff: f64,
    /// Spectral flatness, near 0 for tones and about 0.56 for white noise.
    pub flatness: f64,
    /// Onsets per second and mean spectral flux (rhythmic density).
    pub onset_rate: f64,
    pub flux: f64,
    /// Energy shares below 250 Hz, up to 4 kHz and above.
    pub bands: [f64; 3],
    /// The key's tonic as a pitch class (C = 0), its mode, and how well the
    /// chroma correlates with that key's profile (-1 to 1).
    pub key: usize,
    pub major: bool,
    pub key_strength: f64,
    /// Means and standard deviations of MFCC 1 to 13 (timbre).
    pub mfcc: [f64; MFCC_COEFFICIENTS],
    pub mfcc_spread: [f64; MFCC_COEFFICIENTS],
}

impl AudioFeatures {
    /// The length of [`AudioFeatures::to_vector`].
    pub const LEN: usize = 16 + 2 * MFCC_COEFFICIENTS;

    /// The stored layout: tempo, tempo confidence, loudness, loudness
    /// spread, centroid, centroid spread, rolloff, flatness, onset rate,
    /// flux, the three band shares, key, mode (1 major), key strength, the
    /// MFCC means, then their spreads.
    pub fn to_vector(&self) -> Vec<f64> {
        let mut vector = vec![
            self.tempo,
            self.tempo_confidence,
            self.loudness,
            self.loudness_spread,
            self.centroid,
            self.centroid_spread,
            self.rolloff,
            self.flatness,
            self.onset_rate,
            self.flux,
        ];
        vector.extend(self.bands);
        vector.extend([
            self.key as f64,
            if self.major { 1.0 } else { 0.0 },
            self.key_strength,
        ]);
        vector.extend(self.mfcc);
        vector.extend(self.mfcc_spread);
        vector
    }
}

/// Reads one or two decoded windows, each at most 25 seconds.
pub fn analyze_audio_features_files(
    paths: &[&str],
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<AudioFeatures>, String> {
    if paths.is_empty() || paths.len() > MAX_AUDIO_FEATURE_WINDOWS {
        return Err("audio features take one or two windows".into());
    }
    let windows = paths
        .iter()
        .map(|path| read_bounded(path, MAX_WINDOW_BYTES, check))
        .collect::<Result<Vec<_>, _>>()?;
    let windows: Vec<&[u8]> = windows.iter().map(Vec::as_slice).collect();
    analyze_audio_features(&windows, check)
}

/// Describes mono s16le windows at [`AUDIO_FEATURES_SAMPLE_RATE`]. None
/// means too little audible audio to describe.
pub fn analyze_audio_features(
    windows: &[&[u8]],
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<AudioFeatures>, String> {
    check()?;
    if windows.is_empty() || windows.len() > MAX_AUDIO_FEATURE_WINDOWS {
        return Err("audio features take one or two windows".into());
    }
    if windows.iter().any(|window| window.len() > MAX_WINDOW_BYTES) {
        return Err("audio feature window exceeds the size limit".into());
    }
    let mut spectra = Spectra::new();
    let mut tempos = Vec::new();
    for window in windows {
        let samples: Vec<f64> = window
            .as_chunks::<2>()
            .0
            .iter()
            .map(|bytes| f64::from(i16::from_le_bytes(*bytes)) / 32768.0)
            .collect();
        spectra.add_window(&samples, check)?;
        // The AutoMix beat grid runs at half this rate.
        let grid = analyze_automix_pcm(&decimate(&samples), check)?;
        if grid.bpm > 0.0 {
            tempos.push((grid.bpm, grid.confidence));
        }
    }
    Ok(spectra.finish(&tempos, windows.len()))
}

/// Averages sample pairs, a gentle low-pass before halving the rate.
fn decimate(samples: &[f64]) -> Vec<u8> {
    samples
        .as_chunks::<2>()
        .0
        .iter()
        .flat_map(|[first, second]| {
            let value = ((first + second) * 0.5 * 32768.0)
                .round()
                .clamp(-32768.0, 32767.0) as i16;
            value.to_le_bytes()
        })
        .collect()
}

fn mel(hz: f64) -> f64 {
    2595.0 * (1.0 + hz / 700.0).log10()
}

fn hz(mel: f64) -> f64 {
    700.0 * (10f64.powf(mel / 2595.0) - 1.0)
}

/// Triangular mel filters from 20 Hz to Nyquist, each as its first bin and
/// the weights from there.
fn mel_filters() -> Vec<(usize, Vec<f64>)> {
    let low = mel(20.0);
    let high = mel(AUDIO_FEATURES_SAMPLE_RATE as f64 / 2.0);
    let points: Vec<f64> = (0..MEL_BANDS + 2)
        .map(|index| hz(low + (high - low) * index as f64 / (MEL_BANDS + 1) as f64))
        .collect();
    points
        .windows(3)
        .map(|edges| {
            let (left, center, right) = (edges[0], edges[1], edges[2]);
            let first = ((left / BIN_HZ).ceil() as usize).max(1);
            let last = ((right / BIN_HZ).floor() as usize).min(BINS - 1);
            let weights: Vec<f64> = (first..=last.max(first))
                .map(|bin| {
                    let frequency = bin as f64 * BIN_HZ;
                    if frequency <= center {
                        (frequency - left) / (center - left)
                    } else {
                        (right - frequency) / (right - center)
                    }
                    .max(0.0)
                })
                .collect();
            // A filter narrower than a bin still takes its nearest bin.
            if weights.iter().all(|weight| *weight == 0.0) {
                ((center / BIN_HZ).round() as usize, vec![1.0])
            } else {
                (first, weights)
            }
        })
        .collect()
}

/// Statistics accumulated over the audible frames of every window.
struct Spectra {
    fft: Radix2Fft,
    hann: Vec<f64>,
    mel: Vec<(usize, Vec<f64>)>,
    dct: Vec<[f64; MEL_BANDS]>,
    seconds: f64,
    onsets: usize,
    loudness: Vec<f64>,
    centroid: Vec<f64>,
    rolloff: f64,
    flatness: f64,
    flux: f64,
    bands: [f64; 3],
    mfcc: [f64; MFCC_COEFFICIENTS],
    mfcc_squares: [f64; MFCC_COEFFICIENTS],
    chroma: [f64; 12],
}

impl Spectra {
    fn new() -> Self {
        let hann = (0..FRAME)
            .map(|index| {
                0.5 - 0.5 * (2.0 * std::f64::consts::PI * index as f64 / FRAME as f64).cos()
            })
            .collect();
        // Orthonormal DCT-II rows 1 to 13; row 0 is overall level.
        let dct = (1..=MFCC_COEFFICIENTS)
            .map(|row| {
                let mut coefficients = [0.0; MEL_BANDS];
                for (band, value) in coefficients.iter_mut().enumerate() {
                    *value = (2.0 / MEL_BANDS as f64).sqrt()
                        * (std::f64::consts::PI * row as f64 * (band as f64 + 0.5)
                            / MEL_BANDS as f64)
                            .cos();
                }
                coefficients
            })
            .collect();
        Self {
            fft: Radix2Fft::new(FRAME),
            hann,
            mel: mel_filters(),
            dct,
            seconds: 0.0,
            onsets: 0,
            loudness: Vec::new(),
            centroid: Vec::new(),
            rolloff: 0.0,
            flatness: 0.0,
            flux: 0.0,
            bands: [0.0; 3],
            mfcc: [0.0; MFCC_COEFFICIENTS],
            mfcc_squares: [0.0; MFCC_COEFFICIENTS],
            chroma: [0.0; 12],
        }
    }

    fn add_window(
        &mut self,
        samples: &[f64],
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<(), String> {
        self.seconds += samples.len() as f64 / AUDIO_FEATURES_SAMPLE_RATE as f64;
        if samples.len() < FRAME {
            return Ok(());
        }
        let (mut re, mut im) = (vec![0.0; FRAME], vec![0.0; FRAME]);
        let mut power = vec![0.0; BINS];
        // Log-compressed magnitudes of this frame and the one before.
        let (mut current, mut previous) = (vec![0.0; BINS], vec![0.0; BINS]);
        let mut flux = Vec::new();
        for (index, start) in (0..=samples.len() - FRAME).step_by(HOP).enumerate() {
            if index % 32 == 0 {
                check()?;
            }
            let frame = &samples[start..start + FRAME];
            let rms = (frame.iter().map(|value| value * value).sum::<f64>() / FRAME as f64).sqrt();
            let db = 20.0 * rms.max(1e-9).log10();
            for ((real, imaginary), (value, weight)) in re
                .iter_mut()
                .zip(im.iter_mut())
                .zip(frame.iter().zip(&self.hann))
            {
                *real = value * weight;
                *imaginary = 0.0;
            }
            self.fft.transform(&mut re, &mut im);
            for (((bin, magnitude), real), imaginary) in
                power.iter_mut().zip(current.iter_mut()).zip(&re).zip(&im)
            {
                *bin = real * real + imaginary * imaginary;
                // About the amplitude of a sine at this bin, compressed.
                *magnitude = (1.0 + 100.0 * bin.sqrt() * 4.0 / FRAME as f64).ln();
            }
            let rise = current
                .iter()
                .zip(&previous)
                .map(|(now, before)| (now - before).max(0.0))
                .sum::<f64>()
                / BINS as f64;
            std::mem::swap(&mut current, &mut previous);
            // The first frame rises from nothing.
            flux.push(if index == 0 { 0.0 } else { rise });
            if db < SILENT_DB {
                continue;
            }
            self.loudness.push(db);
            self.flux += rise;
            self.describe(&power);
        }
        self.onsets += count_onsets(&flux);
        Ok(())
    }

    fn describe(&mut self, power: &[f64]) {
        let total: f64 = power[1..].iter().sum();
        if total <= 1e-12 {
            return;
        }
        // Brightness weighs magnitudes, as power would let the bass decide.
        let magnitudes: f64 = power[1..].iter().map(|value| value.sqrt()).sum();
        let mut weighted = 0.0;
        let mut cumulative = 0.0;
        let mut rolloff = None;
        for (bin, value) in power.iter().enumerate().skip(1) {
            let frequency = bin as f64 * BIN_HZ;
            let magnitude = value.sqrt();
            weighted += frequency * magnitude;
            cumulative += magnitude;
            if rolloff.is_none() && cumulative >= 0.85 * magnitudes {
                rolloff = Some(frequency);
            }
            let band = if frequency < 250.0 {
                0
            } else if frequency < 4000.0 {
                1
            } else {
                2
            };
            self.bands[band] += value;
        }
        self.centroid.push(weighted / magnitudes);
        self.rolloff += rolloff.unwrap_or(0.0);
        let mean = total / (BINS - 1) as f64;
        let floor = mean * 1e-10;
        let log_mean = power[1..]
            .iter()
            .map(|value| (value + floor).ln())
            .sum::<f64>()
            / (BINS - 1) as f64;
        self.flatness += (log_mean.exp() / mean).min(1.0);

        let mut log_mel = [0.0; MEL_BANDS];
        for (value, (first, weights)) in log_mel.iter_mut().zip(&self.mel) {
            let energy: f64 = weights
                .iter()
                .zip(&power[*first..])
                .map(|(weight, bin)| weight * bin)
                .sum();
            *value = (energy + 1e-10).ln();
        }
        for ((sum, squares), row) in self
            .mfcc
            .iter_mut()
            .zip(self.mfcc_squares.iter_mut())
            .zip(&self.dct)
        {
            let coefficient: f64 = row.iter().zip(&log_mel).map(|(a, b)| a * b).sum();
            *sum += coefficient;
            *squares += coefficient * coefficient;
        }

        // Pitch classes of the spectral peaks, their frequencies refined by
        // parabolic interpolation, between 80 Hz and 5 kHz.
        let peak = power.iter().copied().fold(0.0, f64::max);
        let mut chroma = [0.0; 12];
        for bin in ((80.0 / BIN_HZ) as usize).max(1)..((5000.0 / BIN_HZ) as usize).min(BINS - 1) {
            let value = power[bin];
            if value < peak * 1e-4 || value < power[bin - 1] || value <= power[bin + 1] {
                continue;
            }
            let (left, center, right) = (
                (power[bin - 1] + 1e-20).ln(),
                (value + 1e-20).ln(),
                (power[bin + 1] + 1e-20).ln(),
            );
            let curvature = left - 2.0 * center + right;
            let offset = if curvature < 0.0 {
                (0.5 * (left - right) / curvature).clamp(-0.5, 0.5)
            } else {
                0.0
            };
            let frequency = (bin as f64 + offset) * BIN_HZ;
            let note = 69.0 + 12.0 * (frequency / 440.0).log2();
            chroma[(note.round() as i64).rem_euclid(12) as usize] += value.sqrt();
        }
        let strongest = chroma.iter().copied().fold(0.0, f64::max);
        if strongest > 0.0 {
            for (sum, value) in self.chroma.iter_mut().zip(chroma) {
                *sum += value / strongest;
            }
        }
    }

    fn finish(self, tempos: &[(f64, f64)], windows: usize) -> Option<AudioFeatures> {
        let frames = self.loudness.len();
        if (frames as f64) * (HOP as f64) / (AUDIO_FEATURES_SAMPLE_RATE as f64)
            < MIN_AUDIBLE_SECONDS
            || self.centroid.is_empty()
        {
            return None;
        }
        let count = self.centroid.len() as f64;
        let (loudness, loudness_spread) = mean_spread(&self.loudness);
        let (centroid, centroid_spread) = mean_spread(&self.centroid);
        let band_total = self.bands.iter().sum::<f64>().max(1e-12);
        let mut mfcc = [0.0; MFCC_COEFFICIENTS];
        let mut mfcc_spread = [0.0; MFCC_COEFFICIENTS];
        for (index, (mean, spread)) in mfcc.iter_mut().zip(mfcc_spread.iter_mut()).enumerate() {
            *mean = self.mfcc[index] / count;
            *spread = (self.mfcc_squares[index] / count - *mean * *mean)
                .max(0.0)
                .sqrt();
        }
        let (key, major, key_strength) = estimate_key(&self.chroma);
        let (tempo, tempo_confidence) = combine_tempos(tempos, windows);
        Some(AudioFeatures {
            tempo,
            tempo_confidence,
            loudness,
            loudness_spread,
            centroid,
            centroid_spread,
            rolloff: self.rolloff / count,
            flatness: self.flatness / count,
            onset_rate: self.onsets as f64 / self.seconds.max(1.0),
            flux: self.flux / frames as f64,
            bands: self.bands.map(|band| band / band_total),
            key,
            major,
            key_strength,
            mfcc,
            mfcc_spread,
        })
    }
}

fn mean_spread(values: &[f64]) -> (f64, f64) {
    let count = values.len().max(1) as f64;
    let mean = values.iter().sum::<f64>() / count;
    let variance = values
        .iter()
        .map(|value| (value - mean) * (value - mean))
        .sum::<f64>()
        / count;
    (mean, variance.sqrt())
}

/// Local spectral flux peaks that stand out from their surroundings, at
/// least four frames (93 ms) apart.
fn count_onsets(flux: &[f64]) -> usize {
    const RADIUS: usize = 3;
    const CONTEXT: usize = 16;
    const FLOOR: f64 = 0.002;
    let mut onsets = 0;
    let mut last: Option<usize> = None;
    for (index, value) in flux.iter().enumerate() {
        if *value < FLOOR {
            continue;
        }
        let begin = index.saturating_sub(RADIUS);
        let end = (index + RADIUS + 1).min(flux.len());
        if flux[begin..end].iter().any(|other| other > value) {
            continue;
        }
        let begin = index.saturating_sub(CONTEXT);
        let end = (index + CONTEXT + 1).min(flux.len());
        let local = flux[begin..end].iter().sum::<f64>() / (end - begin) as f64;
        if *value < 1.5 * local || last.is_some_and(|before| index - before <= RADIUS) {
            continue;
        }
        onsets += 1;
        last = Some(index);
    }
    onsets
}

/// The key whose Krumhansl-Kessler profile correlates best with [chroma].
fn estimate_key(chroma: &[f64; 12]) -> (usize, bool, f64) {
    let correlate = |profile: &[f64; 12], tonic: usize| {
        let mean_chroma = chroma.iter().sum::<f64>() / 12.0;
        let mean_profile = profile.iter().sum::<f64>() / 12.0;
        let (mut dot, mut left, mut right) = (0.0, 0.0, 0.0);
        for (pitch, value) in chroma.iter().enumerate() {
            let a = value - mean_chroma;
            let b = profile[(pitch + 12 - tonic) % 12] - mean_profile;
            dot += a * b;
            left += a * a;
            right += b * b;
        }
        dot / (left * right).sqrt().max(1e-12)
    };
    let mut best = (0, true, f64::MIN);
    for tonic in 0..12 {
        for (major, profile) in [(true, &MAJOR_PROFILE), (false, &MINOR_PROFILE)] {
            let strength = correlate(profile, tonic);
            if strength > best.2 {
                best = (tonic, major, strength);
            }
        }
    }
    best
}

/// One tempo for the song: windows that agree reinforce each other; a
/// disagreement keeps the surer one at reduced confidence.
fn combine_tempos(tempos: &[(f64, f64)], windows: usize) -> (f64, f64) {
    match tempos {
        [] => (0.0, 0.0),
        [(bpm, confidence)] if windows > 1 => (*bpm, confidence * 0.8),
        [(bpm, confidence)] => (*bpm, *confidence),
        [first, second, ..] => {
            let (best, other) = if first.1 >= second.1 {
                (first, second)
            } else {
                (second, first)
            };
            if (other.0 / best.0 - 1.0).abs() < 0.03 {
                let weight = (best.1 + other.1).max(1e-9);
                ((best.0 * best.1 + other.0 * other.1) / weight, best.1)
            } else {
                (best.0, best.1 * 0.8)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::f64::consts::PI;

    const SECONDS: usize = 24;

    fn pcm(samples: impl Iterator<Item = f64>) -> Vec<u8> {
        samples
            .flat_map(|value| (((value * 32767.0).round()) as i16).to_le_bytes())
            .collect()
    }

    fn signal(mut value: impl FnMut(f64) -> f64) -> Vec<u8> {
        pcm((0..AUDIO_FEATURES_SAMPLE_RATE * SECONDS)
            .map(|index| value(index as f64 / AUDIO_FEATURES_SAMPLE_RATE as f64)))
    }

    fn noise(seed: u32) -> impl FnMut() -> f64 {
        let mut state = seed;
        move || {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            f64::from(state) / f64::from(u32::MAX) * 2.0 - 1.0
        }
    }

    fn describe(window: &[u8]) -> AudioFeatures {
        analyze_audio_features(&[window, window], &|| Ok(()))
            .unwrap()
            .unwrap()
    }

    fn sine(frequency: f64, amplitude: f64) -> Vec<u8> {
        signal(|time| amplitude * (2.0 * PI * frequency * time).sin())
    }

    #[test]
    fn click_track_gives_its_tempo_and_onsets() {
        let mut next = noise(7);
        let bursts: Vec<f64> = (0..AUDIO_FEATURES_SAMPLE_RATE * SECONDS)
            .map(|_| next())
            .collect();
        let clicks = pcm(bursts.iter().enumerate().map(|(index, value)| {
            let time = index as f64 / AUDIO_FEATURES_SAMPLE_RATE as f64;
            let since = (time - 0.1).rem_euclid(0.5);
            if time < 0.1 {
                0.0
            } else {
                0.8 * (-since * 60.0).exp() * value
            }
        }));
        let features = describe(&clicks);
        assert!((features.tempo - 120.0).abs() < 1.5, "{}", features.tempo);
        assert!(
            features.tempo_confidence > 0.5,
            "{}",
            features.tempo_confidence
        );
        assert!(
            (features.onset_rate - 2.0).abs() < 0.4,
            "{}",
            features.onset_rate
        );
    }

    #[test]
    fn a_tone_and_noise_differ_in_brightness_and_flatness() {
        let tone = describe(&sine(1000.0, 0.5));
        let mut next = noise(3);
        let hiss = describe(&signal(|_| 0.5 * next()));
        assert!((tone.centroid - 1000.0).abs() < 100.0, "{}", tone.centroid);
        assert!(hiss.centroid > 4000.0, "{}", hiss.centroid);
        assert!(hiss.rolloff > tone.rolloff + 4000.0);
        assert!(tone.flatness < 0.05, "{}", tone.flatness);
        assert!(hiss.flatness > 0.3, "{}", hiss.flatness);
        assert!(tone.bands[1] > 0.95);
        assert!(hiss.bands[2] > 0.5);
        assert!(tone.onset_rate < 0.2);
    }

    #[test]
    fn quiet_and_loud_differ_in_loudness() {
        let tone = describe(&sine(440.0, 0.5));
        assert!((tone.loudness + 9.03).abs() < 0.5, "{}", tone.loudness);
        assert!(tone.loudness_spread < 0.5);
        let mut next = noise(5);
        let hiss: Vec<f64> = (0..AUDIO_FEATURES_SAMPLE_RATE * SECONDS)
            .map(|_| next())
            .collect();
        let quiet = describe(&pcm(hiss.iter().map(|value| 0.05 * value)));
        let loud = describe(&pcm(hiss.iter().map(|value| 0.5 * value)));
        assert!((loud.loudness - quiet.loudness - 20.0).abs() < 0.5);
        // Timbre does not depend on level.
        for (a, b) in quiet.mfcc.iter().zip(&loud.mfcc) {
            assert!((a - b).abs() < 0.1, "{a} {b}");
        }
    }

    #[test]
    fn triads_give_their_keys() {
        let triad = |notes: [f64; 3]| {
            describe(&signal(|time| {
                notes
                    .iter()
                    .map(|note| {
                        let frequency = 440.0 * 2f64.powf((note - 69.0) / 12.0);
                        0.2 * (2.0 * PI * frequency * time).sin()
                    })
                    .sum()
            }))
        };
        let c_major = triad([60.0, 64.0, 67.0]);
        assert_eq!((c_major.key, c_major.major), (0, true));
        assert!(c_major.key_strength > 0.5);
        let a_minor = triad([57.0, 60.0, 64.0]);
        assert_eq!((a_minor.key, a_minor.major), (9, false));
    }

    #[test]
    fn silence_and_short_windows_describe_nothing() {
        let silence = vec![0; AUDIO_FEATURES_SAMPLE_RATE * 2 * SECONDS];
        assert_eq!(
            analyze_audio_features(&[&silence], &|| Ok(())).unwrap(),
            None
        );
        let short = &sine(440.0, 0.5)[..AUDIO_FEATURES_SAMPLE_RATE * 2];
        assert_eq!(analyze_audio_features(&[short], &|| Ok(())).unwrap(), None);
    }

    #[test]
    fn the_job_is_bounded_and_cancelable() {
        let tone = sine(440.0, 0.5);
        let features = analyze_audio_features(&[&tone], &|| Ok(()))
            .unwrap()
            .unwrap();
        let vector = features.to_vector();
        assert_eq!(vector.len(), AudioFeatures::LEN);
        assert!(vector.iter().all(|value| value.is_finite()));

        assert!(analyze_audio_features(&[], &|| Ok(())).is_err());
        assert!(analyze_audio_features(&[&tone, &tone, &tone], &|| Ok(())).is_err());
        let oversized = vec![0; MAX_WINDOW_BYTES + 2];
        assert!(analyze_audio_features(&[&oversized], &|| Ok(())).is_err());
        assert!(analyze_audio_features_files(&[], &|| Ok(())).is_err());

        let calls = Cell::new(0);
        let result = analyze_audio_features(&[&tone, &tone], &|| {
            calls.set(calls.get() + 1);
            if calls.get() >= 20 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        });
        assert_eq!(result.unwrap_err(), "cancelled");
    }

    #[test]
    fn windows_that_disagree_on_tempo_lower_its_confidence() {
        assert_eq!(combine_tempos(&[], 2), (0.0, 0.0));
        assert_eq!(combine_tempos(&[(120.0, 0.8)], 1), (120.0, 0.8));
        let (tempo, confidence) = combine_tempos(&[(120.0, 0.8), (121.0, 0.4)], 2);
        assert!((tempo - 120.0 - 1.0 / 3.0).abs() < 1e-9);
        assert_eq!(confidence, 0.8);
        let (tempo, confidence) = combine_tempos(&[(90.0, 0.4), (128.0, 0.6)], 2);
        assert_eq!(tempo, 128.0);
        assert!((confidence - 0.48).abs() < 1e-9);
    }
}
