//! Finds the granule grid of MPEG layer 3 in decoded audio.
//!
//! A layer 3 decoder's output, analysed again with the encoder's own
//! filterbank at the encoder's own alignment, gives back the spectrum the
//! file stored: every line is zero or `n^(4/3) * 2^(q/4)` for whole `n` and
//! `q`. One sample off, neither holds. Two readings of the same coefficients
//! tell that alignment from the other 575:
//!
//! - The lattice. `12 * log2|c|` is a whole number for `n` = 1, 2, 4, 8 and
//!   16, whatever `q` is, so the phases `exp(2 pi i * 12 log2|c|)` of the
//!   loud coefficients point one way and their mean is long. A gain turns
//!   them all alike and leaves the length alone.
//! - The zeros. Lines that are loud at every other alignment and silent at
//!   this one.
//!
//! The filterbank is the standard's: a 512-tap window folded into 32
//! subbands, every other sample of the odd subbands negated, a 36-point
//! sine-windowed transform per subband, and the butterflies that cancel the
//! aliasing between neighbouring subbands. A plain lapped transform over the
//! same 1152 samples is too far from it to bring the zeros back at high
//! bitrates.

use std::f64::consts::PI;

/// Samples from one granule to the next, and so the alignments to tell
/// apart.
pub(super) const GRANULE: usize = 576;
const BANDS: usize = 32;
const BAND_LINES: usize = 18;
const TAPS: usize = 512;
/// Subband samples one transform spans.
const BLOCK: usize = 36;
/// Granules read at every alignment of one excerpt.
const GRANULES: usize = 3;
/// Subband outputs an excerpt yields: one block start per alignment and
/// granule, and the rest of the last block.
const POSITIONS: usize = GRANULE * GRANULES + (BLOCK - 1) * BANDS;
/// Samples of an excerpt. Excerpts must start a whole number of granules
/// apart, so an alignment means the same in all of them.
pub(super) const EXCERPT: usize = TAPS - 1 + POSITIONS;
/// Excerpts transformed, out of the candidates on offer.
const EXCERPTS: usize = 3;
/// Granule-long stretches an excerpt's level and steadiness are judged by.
const LEVEL_BLOCKS: usize = 5;
/// A sample within this of the loudest in the file counts as clipped: two
/// 16-bit steps. A decoder overshoots full scale on a loud master, and one
/// clipped sample spoils every coefficient of the granules around it.
const CLIP_MARGIN: f64 = 1.0 / 16_384.0;

/// The lattice is read from the lines above this, where small `n` prevail,
/// in coefficients this many noise units strong.
const LATTICE_LOW_HZ: f64 = 2_000.0;
const LATTICE_LEVEL: f64 = 20.0;
/// Zeros are counted above this, in lines whose level over all alignments
/// is this many noise units, as coefficients below `ZERO_LEVEL` units.
const ZERO_LOW_HZ: f64 = 5_000.0;
const ZERO_GATE: f64 = 300.0;
const ZERO_LEVEL: f64 = 2.0;
const _: () = assert!(ZERO_LOW_HZ >= LATTICE_LOW_HZ);
/// Loud coefficients a signal must bring to a typical alignment before its
/// phases mean anything.
const MIN_LATTICE_COUNT: f64 = 500.0;
/// Entries of the phase table, indexed by the top bits of the mantissa.
const PHASE_BITS: u32 = 12;

/// The grid counts as found from this lattice peak (in robust deviations),
/// this far above every other alignment, with the zeros peaking at the same
/// alignment. Audio that never was layer 3 stays below 6 and 1.5, which is
/// what chance gives 576 alignments.
pub(super) const FOUND_SCORE: f64 = 15.0;
pub(super) const FOUND_RATIO: f64 = 3.0;
const HINT_SCORE: f64 = 10.0;
const HINT_RATIO: f64 = 2.0;
const ZERO_HINT_SCORE: f64 = 10.0;
const ZERO_HINT_RATIO: f64 = 2.0;

/// The first half of the analysis window of ISO/IEC 11172-3 (table C.1),
/// entries 0 to 256. The second half mirrors it; see [`window`].
#[rustfmt::skip]
const WINDOW_HALF: [f64; TAPS / 2 + 1] = [
    0.000000000, -0.000000477, -0.000000477, -0.000000477, -0.000000477, -0.000000477,
    -0.000000477, -0.000000954, -0.000000954, -0.000000954, -0.000000954, -0.000001431,
    -0.000001431, -0.000001907, -0.000001907, -0.000002384, -0.000002384, -0.000002861,
    -0.000003338, -0.000003338, -0.000003815, -0.000004292, -0.000004768, -0.000005245,
    -0.000006199, -0.000006676, -0.000007629, -0.000008106, -0.000009060, -0.000010014,
    -0.000011444, -0.000012398, -0.000013828, -0.000014782, -0.000016689, -0.000018120,
    -0.000019550, -0.000021458, -0.000023365, -0.000025272, -0.000027657, -0.000030041,
    -0.000032425, -0.000034809, -0.000037670, -0.000040531, -0.000043392, -0.000046253,
    -0.000049591, -0.000052929, -0.000055790, -0.000059605, -0.000062943, -0.000066280,
    -0.000070095, -0.000073433, -0.000076771, -0.000080585, -0.000083923, -0.000087261,
    -0.000090599, -0.000093460, -0.000096321, -0.000099182, 0.000101566, 0.000103951,
    0.000105858, 0.000107288, 0.000108242, 0.000108719, 0.000108719, 0.000108242,
    0.000106812, 0.000105381, 0.000102520, 0.000099182, 0.000095367, 0.000090122,
    0.000084400, 0.000077724, 0.000069618, 0.000060558, 0.000050545, 0.000039577,
    0.000027180, 0.000013828, -0.000000954, -0.000017166, -0.000034332, -0.000052929,
    -0.000072956, -0.000093937, -0.000116348, -0.000140190, -0.000165462, -0.000191212,
    -0.000218868, -0.000247478, -0.000277042, -0.000307560, -0.000339031, -0.000371456,
    -0.000404358, -0.000438213, -0.000472546, -0.000507355, -0.000542164, -0.000576973,
    -0.000611782, -0.000646591, -0.000680923, -0.000714302, -0.000747204, -0.000779152,
    -0.000809669, -0.000838757, -0.000866413, -0.000891685, -0.000915051, -0.000935555,
    -0.000954151, -0.000968933, -0.000980854, -0.000989437, -0.000994205, -0.000995159,
    -0.000991821, -0.000983715, 0.000971317, 0.000953674, 0.000930786, 0.000902653,
    0.000868797, 0.000829220, 0.000783920, 0.000731945, 0.000674248, 0.000610352,
    0.000539303, 0.000462532, 0.000378609, 0.000288486, 0.000191689, 0.000088215,
    -0.000021458, -0.000137329, -0.000259876, -0.000388145, -0.000522137, -0.000661850,
    -0.000806808, -0.000956535, -0.001111031, -0.001269817, -0.001432419, -0.001597881,
    -0.001766682, -0.001937389, -0.002110004, -0.002283096, -0.002457142, -0.002630711,
    -0.002803326, -0.002974033, -0.003141880, -0.003306866, -0.003467083, -0.003622532,
    -0.003771782, -0.003914356, -0.004048824, -0.004174709, -0.004290581, -0.004395962,
    -0.004489899, -0.004570484, -0.004638195, -0.004691124, -0.004728317, -0.004748821,
    -0.004752159, -0.004737377, -0.004703045, -0.004649162, -0.004573822, -0.004477024,
    -0.004357815, -0.004215240, -0.004049301, -0.003858566, -0.003643036, -0.003401756,
    0.003134727, 0.002841473, 0.002521515, 0.002174854, 0.001800537, 0.001399517,
    0.000971317, 0.000515938, 0.000033379, -0.000475883, -0.001011848, -0.001573563,
    -0.002161503, -0.002774239, -0.003411293, -0.004072189, -0.004756451, -0.005462170,
    -0.006189346, -0.006937027, -0.007703304, -0.008487225, -0.009287834, -0.010103703,
    -0.010933399, -0.011775017, -0.012627602, -0.013489246, -0.014358521, -0.015233517,
    -0.016112804, -0.016994476, -0.017876148, -0.018756866, -0.019634247, -0.020506859,
    -0.021372318, -0.022228718, -0.023074150, -0.023907185, -0.024725437, -0.025527000,
    -0.026310921, -0.027073860, -0.027815342, -0.028532982, -0.029224873, -0.029890060,
    -0.030526638, -0.031132698, -0.031706810, -0.032248020, -0.032754898, -0.033225536,
    -0.033659935, -0.034055710, -0.034412861, -0.034730434, -0.035007000, -0.035242081,
    -0.035435200, -0.035586357, -0.035694122, -0.035758972, 0.035780907,
];

/// The 512 taps of the analysis window. Tap `512 - i` repeats tap `i`,
/// negated except at the multiples of 64.
fn window() -> [f64; TAPS] {
    let mut window = [0.0; TAPS];
    window[..=TAPS / 2].copy_from_slice(&WINDOW_HALF);
    for i in 1..TAPS / 2 {
        window[TAPS - i] = if i % 64 == 0 {
            WINDOW_HALF[i]
        } else {
            -WINDOW_HALF[i]
        };
    }
    window
}

/// `(cs, ca)` of the eight alias butterflies.
fn butterflies() -> [(f64, f64); 8] {
    [
        -0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037,
    ]
    .map(|c: f64| {
        let norm = (1.0 + c * c).sqrt();
        (1.0 / norm, c / norm)
    })
}

/// The cosine of the 36-point transform for subband sample `m` and line `i`.
fn kernel(m: usize, i: usize) -> f64 {
    (PI / 72.0 * ((2 * m + 19) * (2 * i + 1)) as f64).cos()
}

fn block_window(m: usize) -> f64 {
    (PI / 36.0 * (m as f64 + 0.5)).sin()
}

/// The analysis side of the layer 3 hybrid filterbank.
struct Filterbank {
    /// The window, oldest sample first.
    window: [f64; TAPS],
    /// Per subband, what the 64 folded sums are mixed with, oldest first.
    matrix: Vec<[f64; 64]>,
    /// Window, sign and cosine of the 36-point transform in one, for even
    /// and for odd subbands: `[parity][subband sample][line]`.
    transform: [[[f64; BAND_LINES]; BLOCK]; 2],
    butterflies: [(f64, f64); 8],
}

impl Filterbank {
    fn new() -> Self {
        let mut reversed = window();
        reversed.reverse();
        let matrix = (0..BANDS)
            .map(|k| {
                let mut row = [0.0; 64];
                for (u, value) in row.iter_mut().enumerate() {
                    // Folded sum `63 - u` of the standard's order.
                    let i = 63 - u as i32;
                    *value = (f64::from((2 * k as i32 + 1) * (i - 16)) * PI / 64.0).cos();
                }
                row
            })
            .collect();
        let mut transform = [[[0.0; BAND_LINES]; BLOCK]; 2];
        for (parity, table) in transform.iter_mut().enumerate() {
            for (m, row) in table.iter_mut().enumerate() {
                // Every other sample of an odd subband is negated.
                let sign = if parity == 1 && m % 2 == 1 { -1.0 } else { 1.0 };
                for (i, value) in row.iter_mut().enumerate() {
                    *value = sign * block_window(m) * kernel(m, i) / 9.0;
                }
            }
        }
        Self {
            window: reversed,
            matrix,
            transform,
            butterflies: butterflies(),
        }
    }

    /// The subbands from `first_band` up at every position of an excerpt:
    /// `out[b * POSITIONS + p]` is the output of subband `first_band + b` when
    /// sample `TAPS - 1 + p` is the newest one in.
    fn subbands(
        &self,
        excerpt: &[f32],
        first_band: usize,
        out: &mut [f64],
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<(), String> {
        let band_count = BANDS - first_band;
        debug_assert_eq!(out.len(), band_count * POSITIONS);
        let mut folded = [0.0f64; 64];
        let (taps, _) = self.window.as_chunks::<64>();
        let matrix = &self.matrix[first_band..];
        for p in 0..POSITIONS {
            if p % 256 == 0 {
                check()?;
            }
            folded.fill(0.0);
            let (samples, _) = excerpt[p..p + TAPS].as_chunks::<64>();
            for (taps, samples) in taps.iter().zip(samples) {
                for ((sum, tap), sample) in folded.iter_mut().zip(taps).zip(samples) {
                    *sum += tap * f64::from(*sample);
                }
            }
            for (b, row) in matrix.iter().enumerate() {
                out[b * POSITIONS + p] = row.iter().zip(&folded).map(|(m, y)| m * y).sum();
            }
        }
        Ok(())
    }

    /// The coefficients of the block that starts at position `q`, into
    /// `lines`: 18 per subband. The lowest subband given lacks the
    /// butterfly with the one below it.
    fn block(&self, subbands: &[f64], first_band: usize, q: usize, lines: &mut [f64]) {
        let band_count = BANDS - first_band;
        for b in 0..band_count {
            let band = &subbands[b * POSITIONS..(b + 1) * POSITIONS];
            let out = &mut lines[b * BAND_LINES..(b + 1) * BAND_LINES];
            out.fill(0.0);
            for (m, weights) in self.transform[(first_band + b) % 2].iter().enumerate() {
                let sample = band[q + BANDS * m];
                for (line, weight) in out.iter_mut().zip(weights) {
                    *line += sample * weight;
                }
            }
        }
        for b in 1..band_count {
            for (i, (cs, ca)) in self.butterflies.iter().enumerate() {
                let (below, above) = (b * BAND_LINES - 1 - i, b * BAND_LINES + i);
                let (low, high) = (lines[below], lines[above]);
                lines[below] = low * cs + high * ca;
                lines[above] = high * cs - low * ca;
            }
        }
    }
}

/// What the alignments add up to over excerpts, granules and signals.
struct Tally {
    /// Coefficient size from which the lattice is read, and below which a
    /// coefficient is a zero.
    lattice_level: f64,
    zero_level: f64,
    /// Summed power over all alignments from which a line is loud.
    gate: f64,
    /// `(cos, sin)` of the lattice phase by the top bits of the mantissa.
    phases: Vec<(f64, f64)>,
    count: Vec<f64>,
    cos: Vec<f64>,
    sin: Vec<f64>,
    zeros: Vec<f64>,
    /// Loud lines the zeros were counted in.
    gated: f64,
    power: Vec<f64>,
    loud: Vec<usize>,
}

impl Tally {
    fn new() -> Self {
        // What 16-bit rounding leaves in one coefficient: the window passes
        // 1/32 of white noise into a subband, the transform 1/9 of that.
        let noise = 2f64.powi(-15) / 12f64.sqrt() / 288f64.sqrt();
        let entries = 1usize << PHASE_BITS;
        Self {
            lattice_level: LATTICE_LEVEL * noise,
            zero_level: ZERO_LEVEL * noise,
            gate: GRANULE as f64 * (ZERO_GATE * noise).powi(2),
            // Twelve times the exponent is whole, so the mantissa decides.
            phases: (0..entries)
                .map(|index| {
                    let mantissa = 1.0 + (index as f64 + 0.5) / entries as f64;
                    let (sin, cos) = (2.0 * PI * 12.0 * mantissa.log2()).sin_cos();
                    (cos, sin)
                })
                .collect(),
            count: vec![0.0; GRANULE],
            cos: vec![0.0; GRANULE],
            sin: vec![0.0; GRANULE],
            zeros: vec![0.0; GRANULE],
            gated: 0.0,
            power: Vec::new(),
            loud: Vec::new(),
        }
    }

    /// Adds one granule of one signal: `rows` holds its coefficients, one
    /// row of `width` lines per alignment. The lattice reads the lines from
    /// `lattice_from` on, the zeros those from `zeros_from` on.
    fn add(&mut self, rows: &[f64], width: usize, lattice_from: usize, zeros_from: usize) {
        self.power.clear();
        self.power.resize(width, 0.0);
        let mask = (1u64 << PHASE_BITS) - 1;
        for (alignment, row) in rows.chunks_exact(width).enumerate() {
            let (mut count, mut cos, mut sin) = (0u32, 0.0, 0.0);
            for (value, power) in row.iter().zip(&mut self.power).skip(lattice_from) {
                let size = value.abs();
                *power += size * size;
                if size >= self.lattice_level {
                    let index = (size.to_bits() >> (52 - PHASE_BITS)) & mask;
                    let phase = self.phases[index as usize];
                    count += 1;
                    cos += phase.0;
                    sin += phase.1;
                }
            }
            self.count[alignment] += f64::from(count);
            self.cos[alignment] += cos;
            self.sin[alignment] += sin;
        }
        self.loud.clear();
        for line in zeros_from.max(lattice_from)..width {
            if self.power[line] >= self.gate {
                self.loud.push(line);
            }
        }
        self.gated += self.loud.len() as f64;
        for (alignment, row) in rows.chunks_exact(width).enumerate() {
            let zeros = self
                .loud
                .iter()
                .filter(|&&line| row[line].abs() < self.zero_level)
                .count();
            self.zeros[alignment] += zeros as f64;
        }
    }
}

/// Where a curve over the alignments peaks and how far the peak stands out:
/// above the median in robust deviations, and against the highest value more
/// than two alignments away.
struct Peak {
    at: usize,
    score: f64,
    ratio: f64,
}

fn peak_of(curve: &[f64], eps: f64, floor: f64) -> Peak {
    let at = (0..curve.len()).fold(0, |best, a| if curve[a] > curve[best] { a } else { best });
    let median = median_of(curve.to_vec());
    let deviation = median_of(curve.iter().map(|v| (v - median).abs()).collect());
    let second = (0..curve.len())
        .filter(|&a| {
            let distance = a.abs_diff(at);
            distance.min(curve.len() - distance) > 2
        })
        .map(|a| curve[a])
        .fold(0.0, f64::max);
    Peak {
        at,
        score: (curve[at] - median) / (1.4826 * deviation + floor),
        ratio: (curve[at] + eps) / (second + eps).max(1e-30),
    }
}

fn median_of(mut values: Vec<f64>) -> f64 {
    super::super::evidence::median_in_place(&mut values)
}

/// The first line whose centre lies at or above `hz`.
fn first_line(hz: f64, sample_rate: u32) -> usize {
    let line = (hz * 2.0 * GRANULE as f64 / f64::from(sample_rate) - 0.5).ceil();
    (line.max(0.0) as usize).min(GRANULE)
}

/// The excerpts to transform: free of clipping where the file allows it,
/// from the louder half of those, spread over the file, the steadiest of
/// each stretch. `peak` is the loudest sample of the whole file.
fn choose(left: &[&[f32]], right: Option<&[&[f32]]>, peak: f32) -> Vec<usize> {
    let clip_level = f64::from(peak) - CLIP_MARGIN;
    let clipped = |index: usize| -> usize {
        let hit = |sample: &f32| f64::from(sample.abs()) >= clip_level;
        match right {
            Some(right) => left[index]
                .iter()
                .zip(right[index])
                .filter(|(l, r)| hit(l) || hit(r))
                .count(),
            None => left[index].iter().filter(|l| hit(l)).count(),
        }
    };
    let clips: Vec<usize> = (0..left.len()).map(clipped).collect();
    let mut sorted = clips.clone();
    sorted.sort_unstable();
    let Some(&limit) = sorted.get((2 * EXCERPTS).min(sorted.len()).wrapping_sub(1)) else {
        return Vec::new();
    };

    // How much each stretch moves, by its second difference: loud bass alone
    // brings no coefficient above the lines read.
    let stretches = |index: usize| -> [f64; LEVEL_BLOCKS] {
        let mid = |t: usize| -> f64 {
            let l = f64::from(left[index][t]);
            right.map_or(l, |right| (l + f64::from(right[index][t])) / 2.0)
        };
        let mut blocks = [0.0; LEVEL_BLOCKS];
        for (b, block) in blocks.iter_mut().enumerate() {
            for t in b * GRANULE..(b + 1) * GRANULE {
                let bend = mid(t + 2) - 2.0 * mid(t + 1) + mid(t);
                *block += bend * bend;
            }
        }
        blocks
    };
    // Per pooled excerpt: its index, its energy, and how far its loudest
    // stretch stands above its median one.
    let pool: Vec<(usize, f64, f64)> = (0..left.len())
        .filter(|&index| clips[index] <= limit)
        .map(|index| {
            let blocks = stretches(index);
            let loudest = blocks.iter().copied().fold(0.0, f64::max);
            let steady = loudest / median_of(blocks.to_vec()).max(1e-30);
            (index, blocks.iter().sum(), steady)
        })
        .collect();
    let median = median_of(pool.iter().map(|(_, energy, _)| *energy).collect());
    let kept: Vec<(usize, f64)> = pool
        .iter()
        .filter(|(_, energy, _)| *energy >= median)
        .map(|&(index, _, steady)| (index, steady))
        .collect();
    if kept.len() <= EXCERPTS {
        return kept.iter().map(|(index, _)| *index).collect();
    }
    let (share, extra) = (kept.len() / EXCERPTS, kept.len() % EXCERPTS);
    let mut chosen = Vec::with_capacity(EXCERPTS);
    let mut from = 0;
    for group in 0..EXCERPTS {
        let to = from + share + usize::from(group < extra);
        let best =
            kept[from..to].iter().fold(
                kept[from],
                |best, &next| if next.1 < best.1 { next } else { best },
            );
        chosen.push(best.0);
        from = to;
    }
    chosen
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Verdict {
    Found,
    Suspected,
    None,
}

/// What the scan made of the lattice peak.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct Granules {
    pub verdict: Verdict,
    /// The lattice peak above the median over all alignments, in robust
    /// deviations.
    pub score: f64,
    /// The lattice peak against the longest mean at any alignment away from
    /// it.
    pub ratio: f64,
    /// Samples from the start of an excerpt to the alignment of the peak.
    pub offset: usize,
}

/// Looks for the granule grid in excerpts of [`EXCERPT`] samples that start
/// a whole number of granules apart; `right` holds the same excerpts of the
/// second channel. `loudest` is the loudest sample of the whole file. `None`
/// when the audio brings too few loud coefficients to say anything.
pub(super) fn scan(
    left: &[&[f32]],
    right: Option<&[&[f32]]>,
    loudest: f32,
    sample_rate: u32,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<Granules>, String> {
    let lattice_line = first_line(LATTICE_LOW_HZ, sample_rate);
    if lattice_line + BAND_LINES > GRANULE {
        return Ok(None);
    }
    // One subband more than the lines need, as the butterfly partner of the
    // lowest one read.
    let first_band = (lattice_line / BAND_LINES).saturating_sub(1);
    let width = (BANDS - first_band) * BAND_LINES;
    let lattice_from = lattice_line - first_band * BAND_LINES;
    let zeros_from = first_line(ZERO_LOW_HZ, sample_rate) - first_band * BAND_LINES;

    let right = right.filter(|right| right.len() == left.len());
    let chosen = choose(left, right, loudest);
    if chosen.is_empty() {
        return Ok(None);
    }
    let bank = Filterbank::new();
    let mut tally = Tally::new();
    let channels = if right.is_some() { 2 } else { 1 };
    let mut subbands = vec![vec![0.0f64; (BANDS - first_band) * POSITIONS]; channels];
    let mut rows = vec![vec![0.0f64; GRANULE * width]; channels];
    let mut mixed = vec![0.0f64; if right.is_some() { GRANULE * width } else { 0 }];
    for &index in &chosen {
        check()?;
        bank.subbands(left[index], first_band, &mut subbands[0], check)?;
        if let Some(right) = right {
            bank.subbands(right[index], first_band, &mut subbands[1], check)?;
        }
        for granule in 0..GRANULES {
            check()?;
            for (channel, bands) in rows.iter_mut().zip(&subbands) {
                for step in 0..GRANULE {
                    let q = granule * GRANULE + step;
                    // The oldest of the 32 samples that entered for the
                    // block's first subband sample, within the granule grid.
                    let alignment = (q + TAPS - BANDS) % GRANULE;
                    let lines = &mut channel[alignment * width..(alignment + 1) * width];
                    bank.block(bands, first_band, q, lines);
                }
                tally.add(channel, width, lattice_from, zeros_from);
            }
            // Joint stereo codes some granules as mid and side: those are on
            // the lattice only in the sum and the difference.
            if let [l, r] = rows.as_slice() {
                for sign in [1.0, -1.0] {
                    for ((mix, l), r) in mixed.iter_mut().zip(l).zip(r) {
                        *mix = (l + sign * r) / 2.0;
                    }
                    tally.add(&mixed, width, lattice_from, zeros_from);
                }
            }
        }
    }

    let signals = if right.is_some() { 4.0 } else { 1.0 };
    // At the grid itself many coefficients are zero; the typical alignment
    // says how much audio there was.
    if median_of(tally.count.clone()) < MIN_LATTICE_COUNT * signals {
        return Ok(None);
    }
    let lengths: Vec<f64> = (0..GRANULE)
        .map(|a| tally.cos[a].hypot(tally.sin[a]) / tally.count[a].max(1.0))
        .collect();
    let gated = tally.gated.max(1.0);
    let shares: Vec<f64> = tally.zeros.iter().map(|zeros| zeros / gated).collect();
    let lattice = peak_of(&lengths, 0.0, 1e-9);
    let zeros = peak_of(&shares, 1e-3, 1.0 / gated);
    let agree = zeros.at == lattice.at;
    let verdict = if agree && lattice.ratio >= FOUND_RATIO && lattice.score >= FOUND_SCORE {
        Verdict::Found
    } else if (lattice.ratio >= HINT_RATIO && lattice.score >= HINT_SCORE)
        || (agree && zeros.ratio >= ZERO_HINT_RATIO && zeros.score >= ZERO_HINT_SCORE)
    {
        Verdict::Suspected
    } else {
        Verdict::None
    };
    Ok(Some(Granules {
        verdict,
        score: lattice.score,
        ratio: lattice.ratio,
        offset: lattice.at,
    }))
}

#[cfg(test)]
pub(in crate::media::hires) mod testing {
    use super::*;

    /// The samples a linear congruential generator gives from `seed`, as
    /// 16-bit values.
    pub(in crate::media::hires) fn lcg(count: usize, seed: u32) -> Vec<i32> {
        let mut state = seed;
        (0..count)
            .map(|_| {
                state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (state >> 16) as i32 - 32_768
            })
            .collect()
    }

    /// What a layer 3 decoder makes of `spectra`, one granule of 576 lines
    /// each: 576 samples per granule, the first granules still fading in.
    fn decode(spectra: &[Vec<f64>]) -> Vec<f64> {
        let window = window();
        let butterflies = butterflies();
        let mut overlap = vec![[0.0f64; BAND_LINES]; BANDS];
        let mut history = vec![0.0f64; 1_024];
        let mut out = Vec::with_capacity(spectra.len() * GRANULE);
        for spectrum in spectra {
            let mut lines = spectrum.clone();
            for b in 1..BANDS {
                for (i, (cs, ca)) in butterflies.iter().enumerate() {
                    let (below, above) = (b * BAND_LINES - 1 - i, b * BAND_LINES + i);
                    let (low, high) = (lines[below], lines[above]);
                    lines[below] = low * cs - high * ca;
                    lines[above] = high * cs + low * ca;
                }
            }
            let mut samples = [[0.0f64; BAND_LINES]; BANDS];
            for (k, (band, overlap)) in samples.iter_mut().zip(&mut overlap).enumerate() {
                let mut block = [0.0f64; BLOCK];
                for (m, value) in block.iter_mut().enumerate() {
                    let sum: f64 = (0..BAND_LINES)
                        .map(|i| lines[k * BAND_LINES + i] * kernel(m, i))
                        .sum();
                    *value = sum * block_window(m);
                }
                for t in 0..BAND_LINES {
                    let sign = if k % 2 == 1 && t % 2 == 1 { -1.0 } else { 1.0 };
                    band[t] = sign * (block[t] + overlap[t]);
                    overlap[t] = block[t + BAND_LINES];
                }
            }
            for t in 0..BAND_LINES {
                history.copy_within(..960, 64);
                for (i, newest) in history.iter_mut().enumerate().take(64) {
                    *newest = samples
                        .iter()
                        .enumerate()
                        .map(|(k, band)| {
                            band[t] * (((16 + i) * (2 * k + 1)) as f64 * PI / 64.0).cos()
                        })
                        .sum();
                }
                for j in 0..32 {
                    let mut sum = 0.0;
                    for i in 0..8 {
                        sum += history[i * 128 + j] * 32.0 * window[i * 64 + j];
                        sum += history[i * 128 + 96 + j] * 32.0 * window[i * 64 + 32 + j];
                    }
                    out.push(sum);
                }
            }
        }
        out
    }

    /// One channel of audio that was layer 3 once: random spectra quantized
    /// the way the format stores them, band by band, decoded and rounded to
    /// 16 bits. `dropped` samples are cut from the start, which leaves the
    /// grid at alignment `(481 - dropped) mod 576`.
    pub(in crate::media::hires) fn once_layer3(
        granules: usize,
        seed: u32,
        dropped: usize,
    ) -> Vec<i32> {
        const BAND_EDGES: [usize; 23] = [
            0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 52, 62, 74, 90, 110, 134, 162, 196, 238, 288, 342,
            418, 576,
        ];
        const LOWPASS_LINE: usize = 440;
        let level = |line: usize| 0.02 * 10f64.powf(-3.0 * line as f64 / GRANULE as f64);
        let random = lcg(granules * GRANULE, seed);
        let spectra: Vec<Vec<f64>> = random
            .as_chunks::<GRANULE>()
            .0
            .iter()
            .map(|random| {
                let mut lines = vec![0.0; GRANULE];
                for edges in BAND_EDGES.windows(2) {
                    let (low, high) = (edges[0], edges[1]);
                    if low >= LOWPASS_LINE {
                        continue;
                    }
                    let step = 2f64.powf((4.0 * (level(low) * 0.5).log2()).floor() / 4.0);
                    for line in low..high.min(LOWPASS_LINE) {
                        let value = level(line) * (f64::from(random[line]) + 0.5) / 32_768.0;
                        let n = ((value.abs() / step).powf(0.75) + 0.4054).floor();
                        lines[line] = value.signum() * n.powf(4.0 / 3.0) * step;
                    }
                }
                lines
            })
            .collect();
        decode(&spectra)[dropped..]
            .iter()
            .map(|v| (v * 32_768.0).round().clamp(-32_768.0, 32_767.0) as i32)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::testing::{lcg, once_layer3};
    use super::*;

    fn as_audio(samples: &[i32]) -> Vec<f32> {
        samples.iter().map(|&v| v as f32 / 32_768.0).collect()
    }

    /// Every excerpt of `audio` that starts sixteen granules after the last.
    fn excerpts(audio: &[f32]) -> Vec<&[f32]> {
        (0..)
            .map(|index| index * 16 * GRANULE)
            .take_while(|start| start + EXCERPT <= audio.len())
            .map(|start| &audio[start..start + EXCERPT])
            .collect()
    }

    fn loudest(audio: &[f32]) -> f32 {
        audio.iter().fold(0.0, |peak, v| peak.max(v.abs()))
    }

    #[test]
    fn the_window_is_the_standards() {
        let window = window();
        assert_eq!(window[256], 0.035780907);
        assert_eq!(window[257], 0.035758972);
        assert_eq!(window[448], window[64]);
        assert_eq!(window[511], 0.000000477);
        // Half the window, as a filter, passes one subband in 32.
        let power: f64 = window.iter().map(|tap| tap * tap).sum();
        assert!((power / 4.0 - 1.0 / 64.0 - 7.2e-9).abs() < 1e-9, "{power}");
    }

    #[test]
    fn the_filterbank_gives_the_reference_coefficients() {
        // Values of a reference implementation written from the standard,
        // for 4096 samples of the generator with seed 1.
        let audio = as_audio(&lcg(4_096, 1));
        let bank = Filterbank::new();
        let mut subbands = vec![0.0; BANDS * POSITIONS];
        bank.subbands(&audio[..EXCERPT], 0, &mut subbands, &|| Ok(()))
            .unwrap();
        let first = [
            4.841525678929e-02,
            1.117178065265e-01,
            -1.409790790997e-02,
            -1.305090955327e-01,
            -1.568985876230e-01,
            1.069451677927e-01,
            -5.621398023854e-02,
            -9.455216055181e-02,
            3.428669602314e-03,
            7.264824179766e-03,
            -3.971514067411e-02,
            -1.899135070999e-02,
            4.489274361628e-02,
            -4.497505667762e-02,
            6.257680201913e-02,
            5.012138516356e-02,
            -4.043569114594e-02,
            2.803792149094e-02,
            -1.348287040156e-01,
            5.289848110752e-02,
            -1.762312038521e-02,
            9.051104269731e-02,
            -3.504922248479e-02,
            1.633422424885e-02,
            1.146423984554e-02,
            6.162175267925e-02,
            -1.668719096152e-01,
            9.428321098036e-03,
            1.187392613649e-01,
            -2.340713210390e-02,
            7.635066870005e-02,
            6.623927084890e-02,
        ];
        for (k, expected) in first.into_iter().enumerate() {
            let value = subbands[k * POSITIONS];
            assert!((value - expected).abs() < 1e-11, "{value} {expected}");
        }
        for (k, expected) in [
            7.882292299976e-03,
            8.090809223372e-02,
            1.353429338258e-01,
            -3.518398439428e-02,
        ]
        .into_iter()
        .enumerate()
        {
            let value = subbands[k * POSITIONS + (1_000 - (TAPS - 1))];
            assert!((value - expected).abs() < 1e-11, "{value} {expected}");
        }

        // The block whose first subband sample is at sample 607, then 1238.
        let mut lines = vec![0.0; GRANULE];
        bank.block(&subbands, 0, 607 - (TAPS - 1), &mut lines);
        for (line, expected) in [
            (0, 3.590535060027e-03),
            (17, -3.094816519592e-02),
            (18, 3.294123546688e-02),
            (25, 1.783134814285e-02),
            (35, 6.698274955765e-02),
            (36, -1.065009346630e-02),
            (52, 1.849847363610e-02),
            (53, -1.654286780937e-02),
            (100, 7.986051789406e-02),
            (287, 4.511210272639e-02),
            (300, 8.156838523122e-03),
            (440, -1.905438228410e-02),
            (574, 4.283420876138e-02),
            (575, -2.314163312757e-02),
        ] {
            assert!((lines[line] - expected).abs() < 1e-11, "line {line}");
        }
        bank.block(&subbands, 0, 1_238 - (TAPS - 1), &mut lines);
        for (line, expected) in [
            (0, 3.938204686349e-02),
            (17, 1.615602846800e-02),
            (18, -2.978683406180e-03),
            (25, 9.209302808458e-03),
            (35, -4.806991140570e-02),
            (36, -3.618639609932e-02),
            (52, -1.800951721731e-02),
            (53, -2.907664541350e-03),
            (100, 3.319602395926e-02),
            (287, 1.714709565070e-02),
            (300, 3.273505624501e-02),
            (440, -1.349206920175e-02),
            (574, -1.014707249640e-02),
            (575, 3.904302058096e-02),
        ] {
            assert!((lines[line] - expected).abs() < 1e-11, "line {line}");
        }
    }

    #[test]
    fn audio_that_was_layer_3_shows_its_granule_grid() {
        let left = as_audio(&once_layer3(70, 12_345, 100));
        let right = as_audio(&once_layer3(70, 54_321, 100));
        let peak = loudest(&left).max(loudest(&right));
        let found = scan(
            &excerpts(&left),
            Some(&excerpts(&right)),
            peak,
            44_100,
            &|| Ok(()),
        )
        .expect("scan")
        .expect("enough audio");
        assert_eq!(found.verdict, Verdict::Found, "{found:?}");
        assert_eq!(found.offset, 381);
        assert!(found.ratio > 10.0 && found.score > 60.0, "{found:?}");

        // One channel alone shows it as well.
        let mono = scan(&excerpts(&left), None, peak, 44_100, &|| Ok(()))
            .expect("scan")
            .expect("enough audio");
        assert_eq!(mono.verdict, Verdict::Found, "{mono:?}");
        assert_eq!(mono.offset, 381);
    }

    #[test]
    fn audio_that_never_was_layer_3_shows_no_grid() {
        let quarter =
            |seed| -> Vec<i32> { lcg(40_000, seed).iter().map(|v| v.div_euclid(4)).collect() };
        let (left, right) = (as_audio(&quarter(7)), as_audio(&quarter(8)));
        let peak = loudest(&left).max(loudest(&right));
        let none = scan(
            &excerpts(&left),
            Some(&excerpts(&right)),
            peak,
            44_100,
            &|| Ok(()),
        )
        .expect("scan")
        .expect("enough audio");
        assert_eq!(none.verdict, Verdict::None, "{none:?}");
        assert!(none.ratio < 1.5 && none.score < 7.0, "{none:?}");
    }

    #[test]
    fn too_little_audio_says_nothing() {
        let silence = vec![0.0f32; 40_000];
        let result = scan(&excerpts(&silence), None, 0.0, 44_100, &|| Ok(()));
        assert_eq!(result, Ok(None));
    }
}
