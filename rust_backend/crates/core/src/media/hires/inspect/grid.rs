//! Finds the frame grid of a lapped transform in decoded audio.
//!
//! A lossy decoder's output, transformed again with the encoder's own window
//! at the encoder's own frame alignment, gives back the quantized
//! coefficients, many of them zero. One sample off, the zeros smear away. So
//! the share of near-zero coefficients, measured at every alignment, has one
//! lone peak for audio that was lossy once and none for audio that never was.
//!
//! No alignment needs a transform of its own. A window is a short series of
//! odd sines, which makes every windowed coefficient a fixed mix of a few
//! plain DFT bins of the frame, and the DFT of a frame moved by one sample
//! costs one multiplication per bin.

use std::f64::consts::PI;

/// The window shapes lapped-transform codecs use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Window {
    Sine,
    /// Kaiser-Bessel derived, alpha 4.
    Kbd,
    /// The power-complementary window of the Vorbis family.
    Vorbis,
}

impl Window {
    /// Odd sine terms that describe the window to about -60 dB.
    fn terms(self) -> usize {
        match self {
            Window::Sine => 1,
            Window::Kbd => 6,
            Window::Vorbis => 10,
        }
    }

    fn samples(self, size: usize) -> Vec<f64> {
        let at = |t: usize| PI * (t as f64 + 0.5) / size as f64;
        match self {
            Window::Sine => (0..size).map(|t| at(t).sin()).collect(),
            Window::Vorbis => (0..size)
                .map(|t| (PI / 2.0 * at(t).sin().powi(2)).sin())
                .collect(),
            Window::Kbd => {
                let half = size / 2;
                let kaiser: Vec<f64> = (0..=half)
                    .map(|j| {
                        let x = 2.0 * j as f64 / half as f64 - 1.0;
                        bessel_i0(PI * 4.0 * (1.0 - x * x).max(0.0).sqrt())
                    })
                    .collect();
                let total: f64 = kaiser.iter().sum();
                let mut sum = 0.0;
                let rising: Vec<f64> = kaiser[..half]
                    .iter()
                    .map(|value| {
                        sum += value;
                        (sum / total).sqrt()
                    })
                    .collect();
                rising.iter().chain(rising.iter().rev()).copied().collect()
            }
        }
    }

    /// The window as `sum(c[m] * sin(pi * (2m + 1) * (t + 1/2) / size))`.
    fn series(self, size: usize) -> Vec<f64> {
        let samples = self.samples(size);
        (0..self.terms())
            .map(|m| {
                let step = PI * (2 * m + 1) as f64 / size as f64;
                2.0 / size as f64
                    * samples
                        .iter()
                        .enumerate()
                        .map(|(t, w)| w * (step * (t as f64 + 0.5)).sin())
                        .sum::<f64>()
            })
            .collect()
    }
}

/// Modified Bessel function of the first kind, order zero.
fn bessel_i0(x: f64) -> f64 {
    let quarter = x * x / 4.0;
    let (mut term, mut sum) = (1.0, 1.0);
    for k in 1..64 {
        term *= quarter / (k * k) as f64;
        sum += term;
        if term < sum * 1e-17 {
            break;
        }
    }
    sum
}

/// One lapped transform to look for.
pub(super) struct Transform {
    /// Samples a frame spans; frames lie half of it apart.
    pub size: usize,
    pub windows: &'static [Window],
    /// A coefficient this far below its frame's RMS counts as zero.
    pub zero_db: f64,
}

/// The alignment at which the most coefficients vanish, and how far it
/// stands out from every other alignment.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct GridPeak {
    /// The peak above the median over all alignments, in robust deviations.
    pub score: f64,
    /// The peak against the highest share at any alignment away from it.
    pub ratio: f64,
    /// Share of coefficients that vanish at the peak.
    pub share: f64,
    pub window: Window,
    /// Samples from the start of an excerpt to the first frame.
    pub offset: usize,
}

/// What mixes the DFT bins around a coefficient into that coefficient, for
/// one window. Per sine term and coefficient: the factor of the bin above
/// (`up`) and of the bin below (`down`).
struct Mixer {
    window: Window,
    up: Vec<Vec<(f64, f64)>>,
    down: Vec<Vec<(f64, f64)>>,
}

/// Scans `excerpts` of one signal, each at least `transform.size * 3 / 2`
/// samples long, for the transform's frame grid in the coefficients between
/// `low_hz` and `high_hz`. `noise` is the level a coefficient of pure
/// rounding noise reaches; frames that do not rise well above it are left
/// out. `None` when too little audio qualified.
pub(super) fn scan(
    transform: &Transform,
    excerpts: &[&[f64]],
    sample_rate: u32,
    (low_hz, high_hz): (f64, f64),
    noise: f64,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<GridPeak>, String> {
    let size = transform.size;
    let hop = size / 2;
    let terms = transform
        .windows
        .iter()
        .map(|window| window.terms())
        .max()
        .unwrap_or(1);
    let hz = f64::from(sample_rate) / size as f64;
    let first = ((low_hz / hz - 0.5).ceil().max(0.0) as usize).max(terms);
    let last = ((high_hz / hz - 0.5).floor() as usize).min(hop - 1 - terms.min(hop - 1));
    if last < first + 16 {
        return Ok(None);
    }
    let count = last - first + 1;
    let bin0 = first - terms;
    let bins = count + 2 * terms + 1;

    let mixers: Vec<Mixer> = transform
        .windows
        .iter()
        .map(|&window| {
            let series = window.series(size);
            let shift = 0.5 + size as f64 / 4.0;
            let factors = |sign: f64| -> Vec<Vec<(f64, f64)>> {
                series
                    .iter()
                    .enumerate()
                    .map(|(m, c)| {
                        let phi = PI * (2 * m + 1) as f64 / size as f64;
                        (0..count)
                            .map(|i| {
                                let theta = 2.0 * PI * ((first + i) as f64 + 0.5) / size as f64;
                                let angle = theta * shift + sign * phi / 2.0;
                                (0.5 * c * angle.cos(), 0.5 * c * angle.sin())
                            })
                            .collect()
                    })
                    .collect()
            };
            Mixer {
                window,
                up: factors(1.0),
                down: factors(-1.0),
            }
        })
        .collect();

    let turn: Vec<(f64, f64)> = (0..size)
        .map(|t| {
            let angle = 2.0 * PI * t as f64 / size as f64;
            (angle.cos(), angle.sin())
        })
        .collect();
    let relative = 10f64.powf(transform.zero_db / 20.0);
    let mut share = vec![vec![0.0f64; hop]; mixers.len()];
    let mut frames = vec![vec![0u32; hop]; mixers.len()];
    let (mut re, mut im) = (vec![0.0f64; bins], vec![0.0f64; bins]);
    let mut coefficients = vec![0.0f64; count];

    for excerpt in excerpts {
        check()?;
        if excerpt.len() < size + hop {
            continue;
        }
        // The plain DFT of the first frame, over the bins the band needs.
        for (index, (r, i)) in re.iter_mut().zip(im.iter_mut()).enumerate() {
            let bin = bin0 + index;
            let (mut sum_re, mut sum_im) = (0.0, 0.0);
            for (t, sample) in excerpt[..size].iter().enumerate() {
                let (cos, sin) = turn[bin * t % size];
                sum_re += sample * cos;
                sum_im -= sample * sin;
            }
            (*r, *i) = (sum_re, sum_im);
        }
        for offset in 0..hop {
            for (which, mixer) in mixers.iter().enumerate() {
                coefficients.fill(0.0);
                for (m, (up, down)) in mixer.up.iter().zip(&mixer.down).enumerate() {
                    // Coefficient k mixes bins k + m + 1 and k - m.
                    let above = &re[terms + m + 1..terms + m + 1 + count];
                    let above_im = &im[terms + m + 1..terms + m + 1 + count];
                    let below = &re[terms - m..terms - m + count];
                    let below_im = &im[terms - m..terms - m + count];
                    for i in 0..count {
                        coefficients[i] += up[i].1 * above[i]
                            - up[i].0 * above_im[i]
                            - (down[i].1 * below[i] - down[i].0 * below_im[i]);
                    }
                }
                let rms = (coefficients.iter().map(|c| c * c).sum::<f64>() / count as f64).sqrt();
                if rms <= 20.0 * noise {
                    continue;
                }
                let limit = noise.max(rms * relative);
                let zeros = coefficients.iter().filter(|c| c.abs() < limit).count();
                share[which][offset] += zeros as f64 / count as f64;
                frames[which][offset] += 1;
            }
            // Move the frame one sample on.
            let change = excerpt[offset + size] - excerpt[offset];
            for (index, (r, i)) in re.iter_mut().zip(im.iter_mut()).enumerate() {
                let (cos, sin) = turn[(bin0 + index) % size];
                let moved = *r + change;
                (*r, *i) = (moved * cos - *i * sin, moved * sin + *i * cos);
            }
        }
    }

    let mut best: Option<(f64, GridPeak)> = None;
    for (which, mixer) in mixers.iter().enumerate() {
        if frames[which].iter().filter(|&&n| n > 0).count() < hop {
            continue;
        }
        let z: Vec<f64> = share[which]
            .iter()
            .zip(&frames[which])
            .map(|(sum, &n)| sum / f64::from(n))
            .collect();
        let peak = (0..hop).max_by(|&a, &b| z[a].total_cmp(&z[b])).unwrap_or(0);
        let median = median_of(z.clone());
        let deviation = median_of(z.iter().map(|v| (v - median).abs()).collect());
        let second = (0..hop)
            .filter(|&o| {
                let distance = o.abs_diff(peak);
                distance.min(hop - distance) > 2
            })
            .map(|o| z[o])
            .fold(0.0, f64::max);
        let rise = z[peak] - median;
        if best.as_ref().is_none_or(|(other, _)| rise > *other) {
            best = Some((
                rise,
                GridPeak {
                    score: rise / (1.4826 * deviation + 1e-4),
                    ratio: (z[peak] + 1e-3) / (second + 1e-3),
                    share: z[peak],
                    window: mixer.window,
                    offset: peak,
                },
            ));
        }
    }
    Ok(best.map(|(_, peak)| peak))
}

fn median_of(mut values: Vec<f64>) -> f64 {
    super::super::evidence::median_in_place(&mut values)
}

#[cfg(test)]
pub(in crate::media::hires) mod testing {
    use super::*;

    /// What a codec built on a lapped transform does to `signal`: frames of
    /// `size` samples from `offset` on are transformed with the `kind` of
    /// window ("sine", "kbd" or "vorbis"), their coefficients rounded to
    /// multiples of `step`, transformed back and overlapped. The first and
    /// the last frame are only half rebuilt.
    pub(in crate::media::hires) fn through_lapped_transform(
        signal: &[f64],
        size: usize,
        kind: &str,
        offset: usize,
        step: f64,
    ) -> Vec<f64> {
        let window = match kind {
            "kbd" => Window::Kbd,
            "vorbis" => Window::Vorbis,
            _ => Window::Sine,
        }
        .samples(size);
        let half = size / 2;
        let cos: Vec<f64> = (0..8 * size)
            .map(|i| (2.0 * PI * i as f64 / (8 * size) as f64).cos())
            .collect();
        let at = |t: usize, k: usize| cos[(4 * t + 2 + size) * (2 * k + 1) % (8 * size)];
        let mut out = vec![0.0; signal.len()];
        let mut start = offset;
        while start + size <= signal.len() {
            let coefficients: Vec<f64> = (0..half)
                .map(|k| {
                    let value: f64 = (0..size)
                        .map(|t| window[t] * signal[start + t] * at(t, k))
                        .sum();
                    (value / step).round() * step
                })
                .collect();
            for t in 0..size {
                let value: f64 = (0..half).map(|k| coefficients[k] * at(t, k)).sum();
                out[start + t] += window[t] * value * 2.0 / half as f64;
            }
            start += half;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::testing::through_lapped_transform;
    use super::*;

    const SIZE: usize = 256;
    const TRANSFORM: Transform = Transform {
        size: SIZE,
        windows: &[Window::Sine, Window::Kbd, Window::Vorbis],
        zero_db: -50.0,
    };

    fn noise(len: usize) -> Vec<f64> {
        let mut state = 0x2545_F491_4F6C_DD1D_u64;
        (0..len)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                (state >> 11) as f64 / (1u64 << 53) as f64 - 0.5
            })
            .collect()
    }

    fn peak_of(signal: &[f64]) -> GridPeak {
        // Whole frames apart, away from the half-rebuilt ends.
        let excerpts: Vec<&[f64]> = (2..10)
            .map(|i| &signal[i * 4 * SIZE..i * 4 * SIZE + SIZE * 3 / 2])
            .collect();
        scan(
            &TRANSFORM,
            &excerpts,
            44_100,
            (2_000.0, 20_000.0),
            1e-9,
            &|| Ok(()),
        )
        .expect("scan")
        .expect("enough audio")
    }

    #[test]
    fn a_window_is_rebuilt_from_its_sine_series() {
        for window in TRANSFORM.windows {
            let samples = window.samples(2_048);
            let series = window.series(2_048);
            for (t, sample) in samples.iter().enumerate() {
                let rebuilt: f64 = series
                    .iter()
                    .enumerate()
                    .map(|(m, c)| c * (PI * (2 * m + 1) as f64 * (t as f64 + 0.5) / 2_048.0).sin())
                    .sum();
                assert!((rebuilt - sample).abs() < 3e-3, "{window:?} at {t}");
            }
        }
    }

    #[test]
    fn the_frame_grid_and_window_of_a_lapped_transform_are_found() {
        let original = noise(SIZE * 48);
        for (kind, window) in [
            ("sine", Window::Sine),
            ("kbd", Window::Kbd),
            ("vorbis", Window::Vorbis),
        ] {
            let coded = through_lapped_transform(&original, SIZE, kind, 37, 2.5);
            let peak = peak_of(&coded);
            assert_eq!((peak.window, peak.offset), (window, 37), "{kind}: {peak:?}");
            assert!(peak.score > 12.0 && peak.ratio > 1.25, "{kind}: {peak:?}");
        }
    }

    #[test]
    fn audio_that_was_never_transformed_shows_no_grid() {
        let peak = peak_of(&noise(SIZE * 48));
        assert!(peak.score < 12.0 || peak.ratio < 1.25, "{peak:?}");
    }
}
