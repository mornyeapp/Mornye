//! Evidence that separates a fake Hi-Res file from a genuine master that was
//! merely low-pass filtered. Above ~22 kHz the two are the same signal, so no
//! spectral rule can tell them apart everywhere; these tests answer instead
//! how the sampled segment may have been made. They cannot prove that a
//! separate LOSSLESS copy preserves the whole file.
//!
//! - Integer-ratio upsampling artifacts (sample-and-hold, linear
//!   interpolation) give strong evidence. Spectral imaging is a heuristic.
//! - A brickwall right at a CD/DAT Nyquist (22.05 / 24 kHz) means a
//!   44.1/48 kHz chain. With an in-band noise floor no lower than 16-bit
//!   quantization noise, a CD-derived source is "likely". This remains a
//!   heuristic and does not authorize automatic replacement.
//! - A limited bandwidth alone does not establish a file's provenance.

use super::fft::Radix2Fft;

mod streaming;
pub(super) use streaming::{IntegerEvidence, StftAccumulator, StftPlan};

pub const CONFIDENCE_CERTAIN: &str = "certain";
pub const CONFIDENCE_LIKELY: &str = "likely";

pub const ARTIFACT_SAMPLE_HOLD: &str = "sample_hold";
pub const ARTIFACT_INTERPOLATION: &str = "linear_interpolation";
pub const ARTIFACT_IMAGING: &str = "imaging";

pub const FLOOR_BELOW_16BIT: &str = "below_16bit";
pub const FLOOR_AT_16BIT: &str = "at_16bit";
pub const FLOOR_MASKED: &str = "masked";

/// Standard-definition rates a fake is made from; their Nyquist is where a
/// resampler's anti-imaging filter leaves its cliff.
const SOURCE_RATES: [u32; 2] = [44_100, 48_000];

/// Band the in-band noise floor is measured over. Noise-shaped dither lowers
/// the floor in the mid-band only by raising it above ~15 kHz, so averaging
/// over the whole band keeps a shaped 16-bit floor at or above the flat one.
const FLOOR_BAND_LOW_HZ: f64 = 500.0;
const FLOOR_BAND_HIGH_HZ: f64 = 20_000.0;
/// Fraction of fully-inside STFT frames, quietest first, the floor is read in.
const QUIET_FRAME_FRACTION: f64 = 0.1;
/// Floor against flat 16-bit quantization noise: below this there is
/// resolution a 16-bit copy would lose; above FLOOR_MASKED_DB the quietest
/// frames still carry music and the floor cannot be read.
const FLOOR_BELOW_16BIT_DB: f64 = -6.0;
const FLOOR_MASKED_DB: f64 = 20.0;
/// Brickwall: flat passband before the source Nyquist, a cliff after it.
const BRICKWALL_MAX_PASSBAND_DROP_DB: f64 = 20.0;
const BRICKWALL_MIN_CLIFF_DB: f64 = 40.0;
/// Within this, the passband counts as still flat at the edge.
const BRICKWALL_FLAT_PASSBAND_DB: f64 = 6.0;
/// Imaging: the band above the source Nyquist mirrors the one below.
const IMAGING_MIN_CORRELATION: f64 = 0.9;
/// Integer-upsampling artifacts: the signal must move at enough original
/// samples, and (almost) never between them.
const ARTIFACT_MIN_MOVING_ANCHORS: usize = 1000;
const ARTIFACT_MAX_VIOLATION_RATE: f64 = 0.001;
/// Music bandwidth: 1 kHz bands from MUSIC_BAND_START_HZ up are music while
/// their level swings with it across frames (p95-p5 at least
/// MUSIC_MIN_SPREAD_DB). Steady noise, such as the ultrasonic hump a DSD or
/// tape transfer carries up to Nyquist, averages out to a few dB.
const MUSIC_BAND_START_HZ: f64 = 16_000.0;
const MUSIC_BAND_WIDTH_HZ: f64 = 1_000.0;
const MUSIC_MIN_SPREAD_DB: f64 = 10.0;
/// Active content this far past the music bandwidth is reported as steady
/// noise rather than content.
pub const ULTRASONIC_NOISE_MARGIN_HZ: f64 = 8_000.0;
/// Standard rate families; a file's useful rate is looked up in its own.
const RATE_FAMILIES: [[u32; 4]; 2] = [
    [44_100, 88_200, 176_400, 352_800],
    [48_000, 96_000, 192_000, 384_000],
];

/// The averaged spectrum plus what the quiet frames and the ultrasonic bands
/// say, gathered in the same STFT pass.
pub struct StftStats {
    pub avg_magnitude: Vec<f64>,
    /// Variance-equivalent (white noise) floor of the quietest frames in
    /// full-scale units, or NaN when no frame qualified.
    pub quiet_floor_var: f64,
    /// p95-p5 spread across frames of each 1 kHz band's level, from 16 kHz
    /// up, in order; see [`music_cutoff`].
    pub music_band_spreads: Vec<f64>,
}

/// Averaged channel spectrum with a periodic Hann window and hop n_fft/4.
/// Only complete frames are used: padding a cropped segment with zeros
/// introduces an artificial discontinuity and broadband spectral leakage.
#[cfg(test)]
pub fn analyze_stft(
    y: &[f32],
    n_fft: usize,
    sample_rate: u32,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<StftStats, String> {
    let hop = n_fft / 4;
    let half = n_fft / 2;
    let bins = half + 1;
    let mut stats = StftStats {
        avg_magnitude: vec![0.0; bins],
        quiet_floor_var: f64::NAN,
        music_band_spreads: Vec::new(),
    };
    if y.len() < n_fft {
        return Ok(stats);
    }
    let frame_count = 1 + (y.len() - n_fft) / hop;

    let window: Vec<f64> = (0..n_fft)
        .map(|i| 0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / n_fft as f64).cos())
        .collect();
    let window_power: f64 = window.iter().map(|w| w * w).sum();
    let bin_hz = f64::from(sample_rate) / n_fft as f64;
    let band_low = (FLOOR_BAND_LOW_HZ / bin_hz).ceil() as usize;
    let band_high = ((FLOOR_BAND_HIGH_HZ / bin_hz) as usize).min(half);

    // Per-frame level of each 1 kHz band above 16 kHz, for the music
    // bandwidth. Only above a CD's Nyquist does the question arise.
    let mut music_bands: Vec<(usize, usize)> = Vec::new();
    let nyquist = f64::from(sample_rate) / 2.0;
    if nyquist > f64::from(SOURCE_RATES[1]) / 2.0 {
        let mut lo = MUSIC_BAND_START_HZ;
        while lo + MUSIC_BAND_WIDTH_HZ <= nyquist {
            let first = (lo / bin_hz).ceil() as usize;
            let last = (((lo + MUSIC_BAND_WIDTH_HZ) / bin_hz).ceil() as usize).min(half + 1);
            if last > first {
                music_bands.push((first, last));
            }
            lo += MUSIC_BAND_WIDTH_HZ;
        }
    }
    let mut music_levels: Vec<Vec<f64>> = vec![Vec::new(); music_bands.len()];

    let fft = Radix2Fft::new(n_fft);
    let mut re = vec![0.0; n_fft];
    let mut im = vec![0.0; n_fft];
    let mut band_power: Vec<f64> = Vec::with_capacity(band_high.saturating_sub(band_low) + 1);
    // (mean, median) band power of each fully-inside, non-silent frame.
    let mut frames: Vec<(f64, f64)> = Vec::new();

    for f in 0..frame_count {
        if f.is_multiple_of(256) {
            check()?;
        }
        let start = f * hop;
        for (i, (r, w)) in re.iter_mut().zip(&window).enumerate() {
            *r = f64::from(y[start + i]) * w;
        }
        im.fill(0.0);
        fft.transform(&mut re, &mut im);
        for (k, avg) in stats.avg_magnitude.iter_mut().enumerate() {
            *avg += re[k].hypot(im[k]);
        }

        if band_high <= band_low {
            continue;
        }
        band_power.clear();
        let mut sum = 0.0;
        for k in band_low..=band_high {
            let p = re[k] * re[k] + im[k] * im[k];
            band_power.push(p);
            sum += p;
        }
        if sum == 0.0 {
            continue; // digital silence carries no floor to measure
        }
        let mean = sum / band_power.len() as f64;
        frames.push((mean, median_in_place(&mut band_power)));
        for (levels, &(first, last)) in music_levels.iter_mut().zip(&music_bands) {
            let power: f64 = (first..last)
                .map(|k| re[k] * re[k] + im[k] * im[k])
                .sum::<f64>()
                / (last - first) as f64;
            levels.push(10.0 * power.max(1e-30).log10());
        }
    }
    for avg in &mut stats.avg_magnitude {
        *avg /= frame_count as f64;
    }

    if !frames.is_empty() {
        frames.sort_by(|a, b| a.0.total_cmp(&b.0));
        let count = ((frames.len() as f64 * QUIET_FRAME_FRACTION) as usize).max(1);
        // |X|^2 of white noise is exponential with mean sigma^2 * sum(w^2), so
        // its median is ln 2 times that. The median ignores tonal peaks.
        let mut estimates: Vec<f64> = frames[..count]
            .iter()
            .map(|&(_, median)| median / std::f64::consts::LN_2 / window_power)
            .collect();
        stats.quiet_floor_var = median_in_place(&mut estimates);
    }
    for mut levels in music_levels {
        if levels.len() < 2 {
            break;
        }
        levels.sort_by(f64::total_cmp);
        stats
            .music_band_spreads
            .push(percentile_sorted(&levels, 0.95) - percentile_sorted(&levels, 0.05));
    }
    Ok(stats)
}

/// Compares the measured floor with flat 16-bit quantization noise: LSB^2/12
/// per channel, divided by the channel count for the mono downmix of
/// independent channels, which is the lowest it can be.
pub fn classify_noise_floor(floor_var: f64, channels: u32) -> (&'static str, f64) {
    if floor_var.is_nan() || floor_var <= 0.0 {
        return ("", 0.0);
    }
    let lsb = 2f64.powi(-15);
    let reference = lsb * lsb / 12.0 / f64::from(channels.max(1));
    let vs_16bit_db = 10.0 * (floor_var / reference).log10();
    let class = if vs_16bit_db < FLOOR_BELOW_16BIT_DB {
        FLOOR_BELOW_16BIT
    } else if vs_16bit_db > FLOOR_MASKED_DB {
        FLOOR_MASKED
    } else {
        FLOOR_AT_16BIT
    };
    (class, vs_16bit_db)
}

/// Converts the averaged magnitude spectrum to dB below its peak.
pub fn spectrum_db(avg: &[f64]) -> Vec<f64> {
    let peak = avg.iter().copied().fold(0.0, f64::max).max(1e-30);
    avg.iter()
        .map(|&v| 20.0 * (v.max(1e-30) / peak).log10())
        .collect()
}

/// The bins between `low_hz` and `high_hz` inclusive.
fn spectrum_band(
    spec_db: &[f64],
    sample_rate: u32,
    n_fft: usize,
    low_hz: f64,
    high_hz: f64,
) -> Vec<f64> {
    let bin_hz = f64::from(sample_rate) / n_fft as f64;
    let lo = (low_hz / bin_hz).ceil().max(0.0) as usize;
    let hi = ((high_hz / bin_hz) as usize).min(spec_db.len().saturating_sub(1));
    if hi < lo {
        return Vec::new();
    }
    spec_db[lo..=hi].to_vec()
}

/// The source Nyquist (22050 or 24000 Hz) at which the spectrum stays flat
/// right up to the edge and then falls off a cliff: the shape a resampler's
/// anti-imaging filter leaves. A mastering low-pass rolls off gradually and is
/// already well down before the edge. 0 if neither.
///
/// A 48 kHz source passes the test at 22.05 kHz too (its cliff lies beyond
/// that edge as well), so the highest edge the passband still reaches flat
/// wins; a 44.1 kHz source is already sloping into its transition band there.
pub fn detect_brickwall(
    spec_db: &[f64],
    sample_rate: u32,
    n_fft: usize,
    noise_floor_db: f64,
) -> f64 {
    let mut best = 0.0;
    let mut best_drop = f64::INFINITY;
    for rate in SOURCE_RATES {
        let edge = f64::from(rate) / 2.0;
        if edge + 5000.0 > f64::from(sample_rate) / 2.0 {
            continue;
        }
        let mut passband = spectrum_band(spec_db, sample_rate, n_fft, edge - 8000.0, edge - 5000.0);
        let mut below = spectrum_band(spec_db, sample_rate, n_fft, edge - 2500.0, edge - 500.0);
        let mut above = spectrum_band(spec_db, sample_rate, n_fft, edge + 2500.0, edge + 5000.0);
        if passband.is_empty() || below.is_empty() || above.is_empty() {
            continue;
        }
        let below_level = median_in_place(&mut below);
        let drop = median_in_place(&mut passband) - below_level;
        let cliff = below_level - median_in_place(&mut above);
        if below_level <= noise_floor_db
            || drop > BRICKWALL_MAX_PASSBAND_DROP_DB
            || cliff < BRICKWALL_MIN_CLIFF_DB
        {
            continue;
        }
        let flat = drop <= BRICKWALL_FLAT_PASSBAND_DB;
        let best_flat = best_drop <= BRICKWALL_FLAT_PASSBAND_DB;
        if best == 0.0
            || (flat && (!best_flat || edge > best))
            || (!flat && !best_flat && drop < best_drop)
        {
            best = edge;
            best_drop = drop;
        }
    }
    best
}

/// Whether the band above a source Nyquist mirrors the band below it, which
/// is what upsampling without (or with a poor) anti-imaging filter leaves.
/// Genuine content keeps falling with frequency, so its mirror correlation is
/// near zero or negative.
pub fn detect_imaging(
    spec_db: &[f64],
    sample_rate: u32,
    n_fft: usize,
    noise_floor_db: f64,
) -> bool {
    let bin_hz = f64::from(sample_rate) / n_fft as f64;
    for rate in SOURCE_RATES {
        let rate = f64::from(rate);
        let low_hz = rate / 2.0 + 500.0;
        let high_hz = (rate - 500.0).min(f64::from(sample_rate) / 2.0 - 500.0);
        if high_hz - low_hz < 2000.0 {
            continue;
        }
        let mut image = Vec::new();
        let mut mirror = Vec::new();
        let mut k = (low_hz / bin_hz).ceil() as usize;
        while k as f64 * bin_hz <= high_hz {
            // Rounded half away from zero, as Go's math.Round does.
            let m = ((rate - k as f64 * bin_hz) / bin_hz).round();
            if k < spec_db.len() && m >= 0.0 && (m as usize) < spec_db.len() {
                image.push(spec_db[k]);
                mirror.push(spec_db[m as usize]);
            }
            k += 1;
        }
        if image.len() < 16 || image.iter().sum::<f64>() / image.len() as f64 <= noise_floor_db {
            continue; // no content above the edge: nothing was mirrored
        }
        if pearson(&image, &mirror) >= IMAGING_MIN_CORRELATION {
            return true;
        }
    }
    false
}

/// The exact fingerprints of upsampling by an integer ratio from 44.1/48 kHz:
/// every sample repeated (sample-and-hold) or the in-between samples on a
/// straight line (linear interpolation). `samples` is one channel,
/// right-justified; `or_bits` is the OR over the whole window.
#[cfg(test)]
pub fn detect_integer_upsampling(samples: &[i32], or_bits: u32, sample_rate: u32) -> &'static str {
    if or_bits == 0 || samples.len() < 4 {
        return "";
    }
    // Measure in units of the bits actually used, so a padded source's
    // rounding stays within a couple of its own LSBs.
    let unused = or_bits.trailing_zeros();
    for rate in SOURCE_RATES {
        if !sample_rate.is_multiple_of(rate) {
            continue;
        }
        let ratio = (sample_rate / rate) as usize;
        if !(2..=8).contains(&ratio) {
            continue;
        }
        for phase in 0..ratio {
            let artifact = integer_upsampling_at_phase(samples, unused, ratio, phase);
            if !artifact.is_empty() {
                return artifact;
            }
        }
    }
    ""
}

#[cfg(test)]
fn integer_upsampling_at_phase(
    samples: &[i32],
    unused: u32,
    ratio: usize,
    phase: usize,
) -> &'static str {
    let at = |i: usize| i64::from(samples[i] >> unused);
    let (mut inner, mut hold_violations, mut hold_moving) = (0usize, 0usize, 0usize);
    let (mut line_violations, mut line_moving) = (0usize, 0usize);
    for i in 1..samples.len() - 1 {
        let d1 = at(i) - at(i - 1);
        let d2 = (at(i - 1) - 2 * at(i) + at(i + 1)).abs();
        if !(i + ratio - phase).is_multiple_of(ratio) {
            // Between two original samples.
            inner += 1;
            hold_violations += usize::from(d1 != 0);
            line_violations += usize::from(d2 > 2);
        } else {
            // An original sample.
            hold_moving += usize::from(d1 != 0);
            line_moving += usize::from(d2 > 2);
        }
    }
    let max_violations = inner as f64 * ARTIFACT_MAX_VIOLATION_RATE;
    if hold_moving >= ARTIFACT_MIN_MOVING_ANCHORS && hold_violations as f64 <= max_violations {
        return ARTIFACT_SAMPLE_HOLD;
    }
    if line_moving >= ARTIFACT_MIN_MOVING_ANCHORS && line_violations as f64 <= max_violations {
        return ARTIFACT_INTERPOLATION;
    }
    ""
}

/// Upper edge of the last contiguous 1 kHz band, from 16 kHz up, that both
/// carries active content (its level in the averaged spectrum above
/// `noise_floor_db`) and moves with the music. The level test keeps a
/// resampler's leakage, which swings with the music too but sits far below
/// it, from counting. 0 when even the first band fails.
pub fn music_cutoff(
    spreads: &[f64],
    spec_db: &[f64],
    sample_rate: u32,
    n_fft: usize,
    noise_floor_db: f64,
) -> f64 {
    let mut cutoff = 0.0;
    for (index, &spread) in spreads.iter().enumerate() {
        let lo = MUSIC_BAND_START_HZ + index as f64 * MUSIC_BAND_WIDTH_HZ;
        let band = spectrum_band(spec_db, sample_rate, n_fft, lo, lo + MUSIC_BAND_WIDTH_HZ);
        if band.is_empty() || spread < MUSIC_MIN_SPREAD_DB {
            break;
        }
        if band.iter().sum::<f64>() / band.len() as f64 <= noise_floor_db {
            break;
        }
        cutoff = lo + MUSIC_BAND_WIDTH_HZ;
    }
    cutoff
}

/// The lowest standard rate in the declared rate's family whose Nyquist
/// still holds `music_cutoff_hz`; the declared rate itself when none below it
/// does, or when the rate is not a standard one.
pub fn useful_sample_rate(declared: u32, music_cutoff_hz: f64) -> u32 {
    for family in RATE_FAMILIES {
        if !declared.is_multiple_of(family[0]) {
            continue;
        }
        for rate in family {
            if rate >= declared {
                break;
            }
            if f64::from(rate) / 2.0 >= music_cutoff_hz {
                return rate;
            }
        }
    }
    declared
}

fn pearson(a: &[f64], b: &[f64]) -> f64 {
    let n = a.len() as f64;
    let mean_a = a.iter().sum::<f64>() / n;
    let mean_b = b.iter().sum::<f64>() / n;
    let (mut cov, mut var_a, mut var_b) = (0.0, 0.0, 0.0);
    for (&x, &y) in a.iter().zip(b) {
        let (da, db) = (x - mean_a, y - mean_b);
        cov += da * db;
        var_a += da * da;
        var_b += db * db;
    }
    if var_a == 0.0 || var_b == 0.0 {
        return 0.0;
    }
    cov / (var_a * var_b).sqrt()
}

/// Partitions `values` in linear time and returns their median.
pub(super) fn median_in_place(values: &mut [f64]) -> f64 {
    let len = values.len();
    if len == 0 {
        return f64::NAN;
    }
    let mid = len / 2;
    let (lower, upper_mid, _) = values.select_nth_unstable_by(mid, f64::total_cmp);
    if len % 2 == 1 {
        *upper_mid
    } else {
        let lower_max = lower
            .iter()
            .copied()
            .max_by(f64::total_cmp)
            .expect("non-empty lower half");
        (lower_max + *upper_mid) / 2.0
    }
}

/// numpy's default (linear) percentile of sorted values.
fn percentile_sorted(sorted: &[f64], q: f64) -> f64 {
    let pos = q * (sorted.len() - 1) as f64;
    let lo = pos.floor() as usize;
    let hi = (lo + 1).min(sorted.len() - 1);
    sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo as f64)
}
