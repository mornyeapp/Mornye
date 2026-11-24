//! A full inspection: every sample of the file read once, for the evidence a
//! sampled check cannot have.
//!
//! - Integrity: the decoded audio against the checksum and the length the
//!   stream declares.
//! - Bit depth: how finely the quiet samples are really spaced, which shows
//!   a lower-resolution source that was scaled into a wider word.
//! - Lossy history: the frame grid a lapped-transform codec leaves behind,
//!   and where the spectrum is cut off.
//!
//! Each finding says how far it reaches. Finding nothing is reported as
//! that: a lossy file at a high bitrate can leave no trace this can see.

mod grid;
mod layer3;
#[cfg(test)]
pub(super) use grid::testing::through_lapped_transform;
#[cfg(test)]
pub(super) use layer3::testing::once_layer3;

use super::*;
use md5::{Digest, Md5};

pub const GRADE_CORRUPT: &str = "corrupt";
pub const GRADE_LOSSY: &str = "lossy";
pub const GRADE_UPSCALED: &str = "upscaled";
pub const GRADE_SUSPECT: &str = "suspect";
pub const GRADE_LIMITED: &str = "limited";
pub const GRADE_CLEAN: &str = "clean";
pub const GRADE_INCONCLUSIVE: &str = "inconclusive";

/// STFT frames a full pass reads at most, however long the file is.
const MAX_STFT_FRAMES: u64 = 6_000;
/// Points of the spectrum curve handed to the report.
const CURVE_POINTS: usize = 160;

/// Quiet samples, as 24-bit values, whose spacing the bit-depth audit maps.
const LOW_LEVEL: i32 = 1 << 15;
/// Values per cell of that map; the density of samples is taken as even
/// within one cell.
const CELL: usize = 256;
/// Distinct values a full-resolution file would be expected to show before
/// the audit trusts its count.
const MIN_EXPECTED_VALUES: f64 = 8_192.0;
/// Spacing, in 24-bit steps, from which the resolution counts as reduced.
const COARSE_STEP: f64 = 4.0;
/// Samples the low-byte histogram needs, and the share of them that must sit
/// on the 16-bit grid for the file to count as 16-bit plus low-level noise.
const MIN_LOW_BYTE_SAMPLES: u64 = 100_000;
/// By chance 17 of the 256 low-byte values lie this near the grid.
const NEAR_16BIT_SHARE: f64 = 0.9;
const NEAR_16BIT_DISTANCE: usize = 8;

/// Samples kept of each excerpt: what the layer 3 scan reads, which is more
/// than the long transform and half of it again, so every frame alignment
/// of either fits.
const EXCERPT: usize = layer3::EXCERPT;
const _: () = assert!(EXCERPT >= LONG_TRANSFORM.size * 3 / 2);
/// Excerpts start a whole number of frames apart for every transform looked
/// for (1024 and 576 samples), so a grid falls on the same alignment in all
/// of them and their evidence adds up.
const EXCERPT_ALIGN: u64 = 9_216;
const _: () = assert!(EXCERPT_ALIGN.is_multiple_of(layer3::GRANULE as u64));
/// Excerpts kept while reading, and how many of the louder ones the long
/// transform is scanned in. The layer 3 scan picks its own.
const EXCERPT_CANDIDATES: u64 = 40;
const EXCERPTS_SCANNED: usize = 10;
/// The frame grid is looked for where codecs spend the fewest bits.
const GRID_LOW_HZ: f64 = 8_000.0;
const GRID_HIGH_HZ: f64 = 20_000.0;
/// Codecs of these families work at the rate of the file they produce; a
/// higher rate means the grid, if any, no longer falls on whole samples.
const GRID_MAX_SAMPLE_RATE: u32 = 48_000;
/// The grid of the long transform counts as found from this peak (in robust
/// deviations) that also stands this far above every other alignment; real
/// music that was never lossy stays below 6 and 1.1. Layer 3 has its own
/// scan and its own limits, see [`layer3`].
const GRID_SCORE: f64 = 12.0;
const GRID_RATIO: f64 = 1.25;

const LONG_TRANSFORM: grid::Transform = grid::Transform {
    size: 2_048,
    windows: &[grid::Window::Sine, grid::Window::Kbd, grid::Window::Vorbis],
    zero_db: -50.0,
};

/// A step in the spectrum counts as a low-pass from this drop, and as
/// grounds for suspicion from the second.
const LOWPASS_DROP_DB: f64 = 18.0;
const LOWPASS_SUSPECT_DROP_DB: f64 = 25.0;
/// Where lossy encoders put their low-pass, by how hard they squeeze.
const LOWPASS_LOW_HZ: f64 = 17_000.0;
const LOWPASS_MEDIUM_HZ: f64 = 19_300.0;
const LOWPASS_HIGH_HZ: f64 = 20_250.0;

/// A check with the report of a full inspection.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Inspection {
    #[serde(flatten)]
    pub check: HiResCheckResult,
    pub report: Report,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Report {
    /// The one-word outcome; the sections say why.
    pub grade: String,
    pub integrity: Integrity,
    pub bit_depth: BitDepth,
    pub bandwidth: Bandwidth,
    pub lossy: Lossy,
    pub spectrum: Spectrum,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Integrity {
    /// "verified" (audio matches its checksum), "unverified" (no checksum to
    /// compare, the audio decoded in full), "checksum_mismatch",
    /// "length_mismatch" or "decode_error".
    pub status: String,
    /// MD5 of the audio the stream carries, in hex; empty when it has none.
    pub stored_md5: String,
    pub computed_md5: String,
    pub declared_frames: u64,
    pub decoded_frames: u64,
    pub decode_error: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct BitDepth {
    /// "full", "padded" (low bits never used), "coarse" (quiet samples lie
    /// further apart than the word allows), "near_16bit" (a 16-bit grid under
    /// low-level noise), "float" or "unmeasured".
    pub status: String,
    pub declared: u32,
    /// Bits that ever change; 0 when not measured.
    pub used: u32,
    /// Resolution the spacing of the quiet samples shows; 0 when not measured.
    pub resolution_bits: f64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Bandwidth {
    pub nyquist_hz: f64,
    /// Highest frequency with content above the noise threshold.
    pub content_hz: f64,
    /// Where the spectrum steps down and stays down; 0 when it does not.
    pub lowpass_hz: f64,
    pub lowpass_drop_db: f64,
    /// "none", "format" (the file's own anti-alias filter), "source_rate"
    /// (the filter of a lower sample rate), or how a lossy encoder would
    /// place it: "high", "medium", "low".
    pub lowpass_class: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Lossy {
    /// "found" (a codec's frame grid is in the audio), "suspected",
    /// "not_found" or "not_checked".
    pub status: String,
    /// "aac", "vorbis" or "mp3"; empty unless a grid showed.
    pub family: String,
    /// Samples from one codec frame to the next.
    pub frame_samples: u32,
    /// How far the best alignment stands out; see [`grid::GridPeak`].
    pub score: f64,
    pub ratio: f64,
    /// The score from which a grid of the kind `score` was measured for
    /// counts as found; 0 when nothing was measured.
    pub found_score: f64,
}

/// The average spectrum, for drawing: `db[i]` is the loudest level, below
/// the peak, between `i * step_hz` and the next point.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Spectrum {
    pub step_hz: f64,
    pub db: Vec<f64>,
}

/// What one channel gathers over the whole file.
pub(super) struct ChannelDetail {
    /// Right shift that brings a sample to 24 bits; `None` for words too
    /// narrow to audit.
    shift: Option<u32>,
    /// One bit per quiet value seen.
    seen: Vec<u64>,
    /// Quiet samples per cell.
    cell_samples: Vec<u32>,
    low_bytes: [u64; 256],
    /// The loudest sample of the channel.
    loudest: f32,
    capture: Option<Capture>,
}

/// Evenly spaced excerpts, kept as read.
struct Capture {
    starts: Vec<u64>,
    next: usize,
    position: u64,
    samples: Vec<f32>,
}

impl ChannelDetail {
    /// `capture` keeps excerpts of a channel of `frames` samples.
    pub(super) fn new(declared_bits: u32, frames: u64, capture: bool) -> Self {
        let span = frames.saturating_sub(EXCERPT as u64);
        let count = if frames < EXCERPT as u64 {
            0
        } else {
            (span / EXCERPT_ALIGN + 1).min(EXCERPT_CANDIDATES)
        };
        let stride = span / (count.max(2) - 1) / EXCERPT_ALIGN * EXCERPT_ALIGN;
        Self {
            shift: (declared_bits >= 24).then(|| declared_bits - 24),
            seen: vec![0; 2 * LOW_LEVEL as usize / 64],
            cell_samples: vec![0; 2 * LOW_LEVEL as usize / CELL],
            low_bytes: [0; 256],
            loudest: 0.0,
            capture: (capture && count > 0).then(|| Capture {
                starts: (0..count).map(|i| i * stride).collect(),
                next: 0,
                position: 0,
                samples: Vec::with_capacity(count as usize * EXCERPT),
            }),
        }
    }

    pub(super) fn push(&mut self, sample: f32, integer: Option<i32>) {
        if let (Some(shift), Some(value)) = (self.shift, integer) {
            let view = value >> shift;
            if view != 0 && (-LOW_LEVEL..LOW_LEVEL).contains(&view) {
                let slot = (view + LOW_LEVEL) as usize;
                self.seen[slot / 64] |= 1 << (slot % 64);
                let cell = &mut self.cell_samples[slot / CELL];
                *cell = cell.saturating_add(1);
            }
            // Near silence every value is near the 16-bit grid.
            if view.unsigned_abs() >= 128 {
                self.low_bytes[(view & 0xFF) as usize] += 1;
            }
        }
        self.loudest = self.loudest.max(sample.abs());
        if let Some(capture) = &mut self.capture {
            if let Some(&start) = capture.starts.get(capture.next)
                && capture.position >= start
            {
                capture.samples.push(sample);
                if capture.position + 1 == start + EXCERPT as u64 {
                    capture.next += 1;
                }
            }
            capture.position += 1;
        }
    }

    /// Spacing of the quiet values in 24-bit steps: the spacing at which as
    /// many samples as each cell received would leave as many distinct
    /// values as were seen. `None` when too few quiet samples were seen for
    /// a full-resolution file to show itself.
    fn step(&self) -> Option<f64> {
        let distinct: u32 = self.seen.iter().map(|word| word.count_ones()).sum();
        // Values a cell shows when they lie `step` apart and each sample
        // picks one at random.
        let expected = |step: f64| -> f64 {
            self.cell_samples
                .iter()
                .map(|&samples| {
                    let values = CELL as f64 / step;
                    values * (1.0 - (-f64::from(samples) / values).exp())
                })
                .sum()
        };
        if expected(1.0) < MIN_EXPECTED_VALUES {
            return None;
        }
        let (mut fine, mut coarse) = (1.0, 2.0 * f64::from(LOW_LEVEL));
        for _ in 0..40 {
            let middle = (fine * coarse).sqrt();
            if expected(middle) > f64::from(distinct) {
                fine = middle;
            } else {
                coarse = middle;
            }
        }
        Some(fine)
    }

    /// Whether the samples sit on the 16-bit grid, give or take low-level
    /// noise. `None` when too few samples were loud enough to say.
    fn near_16bit(&self) -> Option<bool> {
        let total: u64 = self.low_bytes.iter().sum();
        if total < MIN_LOW_BYTE_SAMPLES {
            return None;
        }
        let near: u64 = self
            .low_bytes
            .iter()
            .enumerate()
            .filter(|(byte, _)| (*byte).min(256 - *byte) <= NEAR_16BIT_DISTANCE)
            .map(|(_, count)| count)
            .sum();
        Some(near as f64 >= total as f64 * NEAR_16BIT_SHARE)
    }

    /// The complete excerpts.
    fn excerpts(&self) -> Vec<&[f32]> {
        self.capture
            .as_ref()
            .map(|capture| {
                let (excerpts, _) = capture.samples.as_chunks::<EXCERPT>();
                excerpts.iter().map(<[f32; EXCERPT]>::as_slice).collect()
            })
            .unwrap_or_default()
    }
}

/// What the stream as a whole gathers.
pub(super) struct StreamDetail {
    /// The running checksum of the decoded audio, for a stream that stores
    /// one to compare.
    digest: Option<Md5>,
    stored: [u8; 16],
    bytes_per_sample: usize,
    frames: u64,
    buffer: Vec<u8>,
}

impl StreamDetail {
    pub(super) fn new(source: &Source) -> Self {
        let (stored, bits) = match source {
            Source::Flac(reader) => {
                let info = reader.streaminfo();
                (Some(info.md5sum), info.bits_per_sample)
            }
            Source::Wav(_) => (None, 0),
        };
        Self {
            digest: stored.map(|_| Md5::new()),
            stored: stored.unwrap_or_default(),
            bytes_per_sample: bits.div_ceil(8) as usize,
            frames: 0,
            buffer: Vec::new(),
        }
    }

    /// The checksum covers the samples interleaved, each sign-extended to
    /// whole bytes, little-endian.
    pub(super) fn block(&mut self, block: &claxon::Block) {
        self.frames += u64::from(block.duration());
        let Some(digest) = &mut self.digest else {
            return;
        };
        let channels: Vec<&[i32]> = (0..block.channels()).map(|ch| block.channel(ch)).collect();
        self.buffer.clear();
        for frame in 0..block.duration() as usize {
            for channel in &channels {
                self.buffer
                    .extend_from_slice(&channel[frame].to_le_bytes()[..self.bytes_per_sample]);
            }
        }
        digest.update(&self.buffer);
    }
}

/// Reads the whole file and reports on its integrity, its real bit depth and
/// any trace of a lossy source, along with the Hi-Res check over all of it.
pub fn inspect_file(
    mut file: File,
    file_path: &str,
    options: &HiResCheckOptions,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Inspection, HiResCheckError> {
    validate(&file, file_path, options)?;
    check()?;
    let mut source = Source::open(&mut file)?;
    let (mut result, window) = prepare(&source, file_path, options, true)?;
    let sample_rate = result.declared_sample_rate;
    let declared_frames = source.total_frames();
    let mut plan = StftPlan::spaced(
        window.n_fft,
        sample_rate,
        (window.frames / MAX_STFT_FRAMES) as usize,
    );
    let mut analysis = source
        .analyze(window.start_frame, window.frames, &mut plan, check, true)
        .map_err(|e| HiResCheckError::Failed(format!("could not decode audio: {e}")))?;
    let details: Vec<Box<ChannelDetail>> = analysis
        .channels
        .iter_mut()
        .filter_map(|channel| channel.detail.take())
        .collect();
    let pushed_frames = analysis.channels.first().map_or(0, |c| c.count as u64);
    let integrity = integrity(
        analysis.stream.take(),
        analysis.decode_error.take(),
        declared_frames,
        pushed_frames,
        result.declared_bit_depth,
    );
    let stats = conclude(&mut result, analysis.channels, &plan, options, check)?;

    let mut report = Report {
        integrity,
        bit_depth: bit_depth(&result, &details),
        bandwidth: Bandwidth {
            nyquist_hz: f64::from(sample_rate) / 2.0,
            content_hz: result.cutoff_frequency_hz,
            lowpass_class: "none".into(),
            ..Bandwidth::default()
        },
        lossy: Lossy {
            status: "not_checked".into(),
            ..Lossy::default()
        },
        ..Report::default()
    };
    if let Some(stats) = stats {
        let spec_db = spectrum_db(&stats.avg_magnitude);
        let (edge, drop) = lowpass_edge(&spec_db, sample_rate, plan.size());
        if drop >= LOWPASS_DROP_DB {
            report.bandwidth.lowpass_hz = edge;
            report.bandwidth.lowpass_drop_db = (drop * 10.0).round() / 10.0;
            report.bandwidth.lowpass_class = lowpass_class(edge, sample_rate).into();
        }
        report.spectrum = curve(&spec_db, sample_rate);
        report.lossy = lossy(&result, &details, &report.bandwidth, check)?;
    }
    report.grade = grade(&result, &report).into();
    Ok(Inspection {
        check: result,
        report,
    })
}

fn integrity(
    stream: Option<StreamDetail>,
    decode_error: Option<String>,
    declared_frames: u64,
    pushed_frames: u64,
    declared_bits: u32,
) -> Integrity {
    let mut integrity = Integrity {
        declared_frames,
        decoded_frames: pushed_frames,
        ..Integrity::default()
    };
    let mut matches = None;
    if let Some(stream) = stream
        && let Some(digest) = stream.digest
    {
        integrity.decoded_frames = stream.frames;
        let computed = digest.finalize();
        integrity.computed_md5 = hex(&computed);
        if stream.stored != [0; 16] {
            integrity.stored_md5 = hex(&stream.stored);
            matches = Some(computed[..] == stream.stored);
        }
    }
    integrity.status = if let Some(error) = decode_error {
        integrity.decode_error = error;
        "decode_error"
    } else if integrity.decoded_frames != declared_frames {
        "length_mismatch"
    } else {
        match matches {
            Some(true) => "verified",
            // Words wider than 24 bits are beyond what the decoder is proven
            // on; a mismatch there may be the decoder's.
            Some(false) if declared_bits <= 24 => "checksum_mismatch",
            _ => "unverified",
        }
    }
    .into();
    integrity
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn bit_depth(result: &HiResCheckResult, details: &[Box<ChannelDetail>]) -> BitDepth {
    let declared = result.declared_bit_depth;
    let used = result.effective_bit_depth;
    let mut depth = BitDepth {
        declared,
        used,
        ..BitDepth::default()
    };
    // The finest channel speaks for the file: a silent or duplicated channel
    // must not hide real resolution in another.
    let step = details
        .iter()
        .filter_map(|detail| detail.step())
        .min_by(f64::total_cmp);
    let near_16bit: Vec<bool> = details
        .iter()
        .filter_map(|detail| detail.near_16bit())
        .collect();
    depth.status = if declared == 0 {
        "float"
    } else if used > 0 && used < declared {
        depth.resolution_bits = f64::from(used);
        "padded"
    } else if declared < 24 {
        if used == 0 {
            "unmeasured"
        } else {
            depth.resolution_bits = f64::from(used);
            "full"
        }
    } else if !near_16bit.is_empty() && near_16bit.iter().all(|near| *near) {
        depth.resolution_bits = 16.0;
        "near_16bit"
    } else if let Some(step) = step {
        let bits = (24.0 - step.max(1.0).log2()).clamp(1.0, 24.0);
        depth.resolution_bits = (bits * 10.0).round() / 10.0;
        if step >= COARSE_STEP {
            "coarse"
        } else {
            depth.resolution_bits = f64::from(declared.min(24));
            "full"
        }
    } else {
        "unmeasured"
    }
    .into();
    depth
}

/// The largest step down in the spectrum, from 9 kHz up, after which the
/// level stays down: `(frequency, drop in dB)`, zeros when there is none.
fn lowpass_edge(spec_db: &[f64], sample_rate: u32, n_fft: usize) -> (f64, f64) {
    let bin_hz = f64::from(sample_rate) / n_fft as f64;
    let nyquist = f64::from(sample_rate) / 2.0;
    let level = |low: f64, high: f64| -> f64 {
        let first = (low / bin_hz) as usize;
        let last = ((high / bin_hz) as usize + 1).min(spec_db.len());
        if last <= first {
            return f64::NAN;
        }
        median_in_place(&mut spec_db[first..last].to_vec())
    };
    let mut best = (0.0, 0.0);
    let mut edge = 9_000.0;
    while edge + 1_200.0 < nyquist {
        let before = level(edge - 1_000.0, edge - 200.0);
        let after = level(edge + 400.0, edge + 1_200.0);
        let drop = before - after;
        // Nothing above may come back to within 12 dB of the level before.
        let rest = if edge + 1_500.0 < nyquist - 100.0 {
            level(edge + 1_200.0, (nyquist - 100.0).min(edge + 4_000.0))
        } else {
            after
        };
        if drop > best.1 && (rest.is_nan() || rest <= before - 12.0) {
            best = (edge, drop);
        }
        edge += 100.0;
    }
    best
}

fn lowpass_class(edge: f64, sample_rate: u32) -> &'static str {
    let nyquist = f64::from(sample_rate) / 2.0;
    if edge <= LOWPASS_LOW_HZ {
        "low"
    } else if edge <= LOWPASS_MEDIUM_HZ {
        "medium"
    } else if edge <= LOWPASS_HIGH_HZ || (sample_rate >= 48_000 && edge <= 20_600.0) {
        "high"
    } else if sample_rate > 48_000 && edge < 25_000.0 {
        "source_rate"
    } else if edge >= nyquist * 0.9 {
        "format"
    } else {
        "none"
    }
}

fn curve(spec_db: &[f64], sample_rate: u32) -> Spectrum {
    let points = CURVE_POINTS.min(spec_db.len());
    if points == 0 {
        return Spectrum::default();
    }
    Spectrum {
        step_hz: f64::from(sample_rate) / 2.0 / points as f64,
        db: (0..points)
            .map(|point| {
                let first = point * spec_db.len() / points;
                let last = ((point + 1) * spec_db.len() / points).max(first + 1);
                let loudest = spec_db[first..last]
                    .iter()
                    .copied()
                    .fold(f64::NEG_INFINITY, f64::max);
                (loudest.max(-140.0) * 10.0).round() / 10.0
            })
            .collect(),
    }
}

/// How far a peak stands out against what a grid must show: 1 is enough.
fn strength((score, ratio): (f64, f64), (needed_score, needed_ratio): (f64, f64)) -> f64 {
    (score / needed_score).min((ratio - 1.0) / (needed_ratio - 1.0))
}

/// A peak of one of the two scans, in the terms the report shows.
struct Grid {
    family: &'static str,
    frame_samples: usize,
    score: f64,
    ratio: f64,
    found_score: f64,
    /// How far it stands out against what its scan asks for.
    strength: f64,
}

/// The layer 3 scan, over every excerpt kept of the first two channels.
fn granules(
    details: &[Box<ChannelDetail>],
    sample_rate: u32,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<layer3::Granules>, String> {
    let Some(first) = details.first() else {
        return Ok(None);
    };
    let left = first.excerpts();
    let right = details.get(1).map(|second| second.excerpts());
    let loudest = details
        .iter()
        .take(2)
        .map(|detail| detail.loudest)
        .fold(0.0, f32::max);
    layer3::scan(&left, right.as_deref(), loudest, sample_rate, check)
}

fn lossy(
    result: &HiResCheckResult,
    details: &[Box<ChannelDetail>],
    bandwidth: &Bandwidth,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Lossy, HiResCheckError> {
    let sample_rate = result.declared_sample_rate;
    let suspect_lowpass = bandwidth.lowpass_drop_db >= LOWPASS_SUSPECT_DROP_DB
        && matches!(bandwidth.lowpass_class.as_str(), "low" | "medium");
    let mut lossy = Lossy {
        status: if suspect_lowpass {
            "suspected"
        } else {
            "not_checked"
        }
        .into(),
        ..Lossy::default()
    };
    if sample_rate > GRID_MAX_SAMPLE_RATE {
        return Ok(lossy);
    }
    let signals = signals(details);
    if signals.is_empty() {
        return Ok(lossy);
    }

    // Above a low-pass there is nothing but zeros, at every alignment alike.
    let mut high = GRID_HIGH_HZ.min(f64::from(sample_rate) / 2.0 - 500.0);
    if bandwidth.lowpass_drop_db >= LOWPASS_SUSPECT_DROP_DB {
        high = high.min(bandwidth.lowpass_hz - 500.0);
    }
    let low = if high < GRID_LOW_HZ + 2_000.0 {
        high / 2.0
    } else {
        GRID_LOW_HZ
    };
    let bits = match (result.effective_bit_depth, result.declared_bit_depth) {
        (0, 0) => 24,
        (0, declared) => declared,
        (used, _) => used,
    };
    let lsb = 2f64.powi(1 - bits.min(32) as i32);

    // The clearest peak of the long transform, over the signals.
    let needed = (GRID_SCORE, GRID_RATIO);
    // What rounding noise alone puts into one coefficient, four times over.
    let noise = 4.0 * lsb / 12f64.sqrt() * (LONG_TRANSFORM.size as f64 / 4.0).sqrt();
    let mut long: Option<grid::GridPeak> = None;
    for signal in &signals {
        let excerpts: Vec<&[f64]> = signal.iter().map(Vec::as_slice).collect();
        let band = (low, high);
        let peak = grid::scan(&LONG_TRANSFORM, &excerpts, sample_rate, band, noise, check)?;
        if let Some(peak) = peak
            && long.as_ref().is_none_or(|other| {
                strength((peak.score, peak.ratio), needed)
                    > strength((other.score, other.ratio), needed)
            })
        {
            long = Some(peak);
        }
    }
    let long = long.map(|peak| Grid {
        family: if peak.window == grid::Window::Vorbis {
            "vorbis"
        } else {
            "aac"
        },
        frame_samples: LONG_TRANSFORM.size / 2,
        score: peak.score,
        ratio: peak.ratio,
        found_score: GRID_SCORE,
        strength: strength((peak.score, peak.ratio), needed),
    });
    let granules = granules(details, sample_rate, check)?;
    let layer3_grid = granules.map(|peak| Grid {
        family: "mp3",
        frame_samples: layer3::GRANULE,
        score: peak.score,
        ratio: peak.ratio,
        found_score: layer3::FOUND_SCORE,
        strength: strength(
            (peak.score, peak.ratio),
            (layer3::FOUND_SCORE, layer3::FOUND_RATIO),
        ),
    });
    if (long.is_some() || layer3_grid.is_some()) && !suspect_lowpass {
        lossy.status = "not_found".into();
    }

    let clearer = |a: &&Grid, b: &&Grid| a.strength.total_cmp(&b.strength);
    let grids = [&long, &layer3_grid];
    let found = grids
        .into_iter()
        .flatten()
        .filter(|grid| match grid.family {
            "mp3" => granules.is_some_and(|peak| peak.verdict == layer3::Verdict::Found),
            _ => grid.strength >= 1.0,
        })
        .max_by(clearer);
    let suspected = layer3_grid
        .as_ref()
        .filter(|_| granules.is_some_and(|peak| peak.verdict == layer3::Verdict::Suspected));
    let shown = if let Some(grid) = found.or(suspected) {
        lossy.status = if found.is_some() {
            "found"
        } else {
            "suspected"
        }
        .into();
        lossy.family = grid.family.into();
        lossy.frame_samples = grid.frame_samples as u32;
        Some(grid)
    } else {
        // Nothing found: show how close the nearest miss came.
        grids.into_iter().flatten().max_by(clearer)
    };
    if let Some(grid) = shown {
        lossy.score = (grid.score * 10.0).round() / 10.0;
        lossy.ratio = (grid.ratio * 1_000.0).round() / 1_000.0;
        lossy.found_score = grid.found_score;
    }
    Ok(lossy)
}

/// The signals a codec's grid shows in, as excerpts: the first channel and,
/// for stereo, half the difference of the first two, which joint stereo
/// codes on its own. Only excerpts from the louder half of the file are kept.
fn signals(details: &[Box<ChannelDetail>]) -> Vec<Vec<Vec<f64>>> {
    let Some(first) = details.first() else {
        return Vec::new();
    };
    let left = first.excerpts();
    if left.is_empty() {
        return Vec::new();
    }
    let mut energy: Vec<(f64, usize)> = left
        .iter()
        .enumerate()
        .map(|(index, excerpt)| {
            let moved: f64 = excerpt
                .windows(2)
                .map(|pair| f64::from(pair[1] - pair[0]).powi(2))
                .sum();
            (moved, index)
        })
        .collect();
    energy.sort_by(|a, b| b.0.total_cmp(&a.0));
    let mut louder: Vec<usize> = energy[..energy.len().div_ceil(2)]
        .iter()
        .map(|(_, index)| *index)
        .collect();
    louder.sort_unstable();
    let count = EXCERPTS_SCANNED.min(louder.len());
    let chosen: Vec<usize> = (0..count)
        .map(|i| louder[i * (louder.len() - 1) / (count - 1).max(1)])
        .collect();

    let widen = |excerpt: &[f32]| excerpt.iter().map(|&v| f64::from(v)).collect::<Vec<f64>>();
    let mut signals = vec![chosen.iter().map(|&index| widen(left[index])).collect()];
    if let Some(second) = details.get(1) {
        let right = second.excerpts();
        if right.len() == left.len() {
            signals.push(
                chosen
                    .iter()
                    .map(|&index| {
                        left[index]
                            .iter()
                            .zip(right[index])
                            .map(|(l, r)| (f64::from(*l) - f64::from(*r)) / 2.0)
                            .collect()
                    })
                    .collect(),
            );
        }
    }
    signals
}

fn grade(result: &HiResCheckResult, report: &Report) -> &'static str {
    let broken = matches!(
        report.integrity.status.as_str(),
        "checksum_mismatch" | "length_mismatch" | "decode_error"
    );
    let reduced_depth = match report.bit_depth.status.as_str() {
        "near_16bit" => true,
        "coarse" => report.bit_depth.resolution_bits <= 17.0,
        _ => false,
    };
    if broken {
        GRADE_CORRUPT
    } else if report.lossy.status == "found" {
        GRADE_LOSSY
    } else if result.verdict == VERDICT_FAKE {
        GRADE_UPSCALED
    } else if report.lossy.status == "suspected" || reduced_depth {
        GRADE_SUSPECT
    } else if result.verdict == VERDICT_INCONCLUSIVE {
        GRADE_INCONCLUSIVE
    } else if result.verdict == VERDICT_BAND_LIMITED {
        GRADE_LIMITED
    } else {
        GRADE_CLEAN
    }
}
