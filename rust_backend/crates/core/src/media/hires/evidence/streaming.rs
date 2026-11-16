//! Exact evidence with one circular STFT frame per channel. Only scalar
//! frame levels survive the FFT, for the existing floor/band percentiles.

use super::*;

pub(in crate::media::hires) struct StftPlan {
    n: usize,
    /// Samples from one frame to the next.
    hop: usize,
    window: Vec<f64>,
    window_power: f64,
    band_low: usize,
    band_high: usize,
    music_bands: Vec<(usize, usize)>,
    fft: Radix2Fft,
    re: Vec<f64>,
    im: Vec<f64>,
    band_power: Vec<f64>,
}

impl StftPlan {
    /// A plan whose frames lie at least `hop` samples apart, so a pass over
    /// a whole file reads a bounded number of them.
    pub(in crate::media::hires) fn spaced(n: usize, sample_rate: u32, hop: usize) -> Self {
        let mut plan = Self::new(n, sample_rate);
        plan.hop = plan.hop.max(hop);
        plan
    }

    pub(in crate::media::hires) fn size(&self) -> usize {
        self.n
    }

    pub(in crate::media::hires) fn new(n: usize, sample_rate: u32) -> Self {
        let window: Vec<f64> = (0..n)
            .map(|i| 0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / n as f64).cos())
            .collect();
        let window_power = window.iter().map(|w| w * w).sum();
        let bin_hz = f64::from(sample_rate) / n as f64;
        let band_low = (FLOOR_BAND_LOW_HZ / bin_hz).ceil() as usize;
        let band_high = ((FLOOR_BAND_HIGH_HZ / bin_hz) as usize).min(n / 2);
        let nyquist = f64::from(sample_rate) / 2.0;
        let mut music_bands = Vec::new();
        if nyquist > f64::from(SOURCE_RATES[1]) / 2.0 {
            let mut lo = MUSIC_BAND_START_HZ;
            while lo + MUSIC_BAND_WIDTH_HZ <= nyquist {
                let first = (lo / bin_hz).ceil() as usize;
                let last = (((lo + MUSIC_BAND_WIDTH_HZ) / bin_hz).ceil() as usize).min(n / 2 + 1);
                if last > first {
                    music_bands.push((first, last));
                }
                lo += MUSIC_BAND_WIDTH_HZ;
            }
        }
        Self {
            n,
            hop: n / 4,
            window,
            window_power,
            band_low,
            band_high,
            music_bands,
            fft: Radix2Fft::new(n),
            re: vec![0.0; n],
            im: vec![0.0; n],
            band_power: Vec::with_capacity(band_high.saturating_sub(band_low) + 1),
        }
    }
}

pub(in crate::media::hires) struct StftAccumulator {
    signal: Vec<f32>,
    cursor: usize,
    until_frame: usize,
    frame_count: usize,
    stats: StftStats,
    frames: Vec<(f64, f64)>,
    music_levels: Vec<Vec<f64>>,
}

impl StftAccumulator {
    pub(in crate::media::hires) fn new(plan: &StftPlan) -> Self {
        Self {
            signal: vec![0.0; plan.n],
            cursor: 0,
            until_frame: plan.n,
            frame_count: 0,
            stats: StftStats {
                avg_magnitude: vec![0.0; plan.n / 2 + 1],
                quiet_floor_var: f64::NAN,
                music_band_spreads: Vec::new(),
            },
            frames: Vec::new(),
            music_levels: vec![Vec::new(); plan.music_bands.len()],
        }
    }

    pub(in crate::media::hires) fn push(
        &mut self,
        value: f32,
        plan: &mut StftPlan,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<(), String> {
        self.signal[self.cursor] = value;
        self.cursor += 1;
        if self.cursor == plan.n {
            self.cursor = 0;
        }
        self.until_frame -= 1;
        if self.until_frame != 0 {
            return Ok(());
        }
        if self.frame_count.is_multiple_of(256) {
            check()?;
        }
        self.frame_count += 1;
        self.until_frame = plan.hop;
        if self.signal.iter().all(|sample| *sample == 0.0) {
            return Ok(());
        }
        let ordered = self.signal[self.cursor..]
            .iter()
            .chain(&self.signal[..self.cursor]);
        for ((r, w), sample) in plan.re.iter_mut().zip(&plan.window).zip(ordered) {
            *r = f64::from(*sample) * w;
        }
        plan.im.fill(0.0);
        plan.fft.transform(&mut plan.re, &mut plan.im);
        for (k, avg) in self.stats.avg_magnitude.iter_mut().enumerate() {
            *avg += plan.re[k].hypot(plan.im[k]);
        }
        if plan.band_high <= plan.band_low {
            return Ok(());
        }
        plan.band_power.clear();
        let mut sum = 0.0;
        for k in plan.band_low..=plan.band_high {
            let power = plan.re[k] * plan.re[k] + plan.im[k] * plan.im[k];
            plan.band_power.push(power);
            sum += power;
        }
        if sum == 0.0 {
            return Ok(());
        }
        self.frames.push((
            sum / plan.band_power.len() as f64,
            median_in_place(&mut plan.band_power),
        ));
        for (levels, &(first, last)) in self.music_levels.iter_mut().zip(&plan.music_bands) {
            let power = (first..last)
                .map(|k| plan.re[k] * plan.re[k] + plan.im[k] * plan.im[k])
                .sum::<f64>()
                / (last - first) as f64;
            levels.push(10.0 * power.max(1e-30).log10());
        }
        Ok(())
    }

    pub(in crate::media::hires) fn finish(mut self, plan: &StftPlan) -> StftStats {
        if self.frame_count == 0 {
            return self.stats;
        }
        for avg in &mut self.stats.avg_magnitude {
            *avg /= self.frame_count as f64;
        }
        if !self.frames.is_empty() {
            self.frames.sort_by(|a, b| a.0.total_cmp(&b.0));
            let count = ((self.frames.len() as f64 * QUIET_FRAME_FRACTION) as usize).max(1);
            let mut estimates: Vec<f64> = self.frames[..count]
                .iter()
                .map(|&(_, median)| median / std::f64::consts::LN_2 / plan.window_power)
                .collect();
            self.stats.quiet_floor_var = median_in_place(&mut estimates);
        }
        for mut levels in self.music_levels {
            if levels.len() < 2 {
                break;
            }
            levels.sort_by(f64::total_cmp);
            self.stats
                .music_band_spreads
                .push(percentile_sorted(&levels, 0.95) - percentile_sorted(&levels, 0.05));
        }
        self.stats
    }
}

struct Position {
    count: usize,
    moving: usize,
    // Bucket floor(log2(abs(d2) - 1)). Then abs(d2) > 2 << unused
    // exactly when its bucket is at least unused + 1. Samples are all
    // divisible by 1 << unused, once the final OR establishes that shift.
    second_derivatives: [usize; 33],
}

impl Default for Position {
    fn default() -> Self {
        Self {
            count: 0,
            moving: 0,
            second_derivatives: [0; 33],
        }
    }
}

pub(in crate::media::hires) struct IntegerEvidence {
    pub(in crate::media::hires) or_bits: u32,
    count: usize,
    previous: [i32; 2],
    ratios: Vec<Vec<Position>>,
}

impl IntegerEvidence {
    pub(in crate::media::hires) fn new(sample_rate: u32) -> Self {
        let ratios = SOURCE_RATES
            .into_iter()
            .filter_map(|rate| {
                let ratio = (sample_rate / rate) as usize;
                (sample_rate.is_multiple_of(rate) && (2..=8).contains(&ratio))
                    .then(|| (0..ratio).map(|_| Position::default()).collect())
            })
            .collect();
        Self {
            or_bits: 0,
            count: 0,
            previous: [0; 2],
            ratios,
        }
    }

    pub(in crate::media::hires) fn push(&mut self, value: i32) {
        self.or_bits |= value as u32;
        if self.count >= 2 {
            let d1 = i64::from(self.previous[1]) - i64::from(self.previous[0]);
            let d2 = (i64::from(self.previous[0]) - 2 * i64::from(self.previous[1])
                + i64::from(value))
            .unsigned_abs();
            let bucket = d2.saturating_sub(1).checked_ilog2();
            for positions in &mut self.ratios {
                let position = (self.count - 1) % positions.len();
                let state = &mut positions[position];
                state.count += 1;
                state.moving += usize::from(d1 != 0);
                if let Some(bucket) = bucket {
                    state.second_derivatives[bucket as usize] += 1;
                }
            }
        }
        self.previous = [self.previous[1], value];
        self.count += 1;
    }

    pub(in crate::media::hires) fn artifact(&self) -> &'static str {
        if self.or_bits == 0 || self.count < 4 {
            return "";
        }
        let first_bucket = self.or_bits.trailing_zeros() as usize + 1;
        for positions in &self.ratios {
            let inner_total: usize = positions.iter().map(|state| state.count).sum();
            let hold_total: usize = positions.iter().map(|state| state.moving).sum();
            let lines: Vec<usize> = positions
                .iter()
                .map(|state| state.second_derivatives[first_bucket..].iter().sum())
                .collect();
            let line_total: usize = lines.iter().sum();
            for (phase, anchor) in positions.iter().enumerate() {
                let maximum = (inner_total - anchor.count) as f64 * ARTIFACT_MAX_VIOLATION_RATE;
                if anchor.moving >= ARTIFACT_MIN_MOVING_ANCHORS
                    && (hold_total - anchor.moving) as f64 <= maximum
                {
                    return ARTIFACT_SAMPLE_HOLD;
                }
                if lines[phase] >= ARTIFACT_MIN_MOVING_ANCHORS
                    && (line_total - lines[phase]) as f64 <= maximum
                {
                    return ARTIFACT_INTERPOLATION;
                }
            }
        }
        ""
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(in crate::media::hires) fn assert_stats_equal(actual: &StftStats, expected: &StftStats) {
        assert_eq!(actual.avg_magnitude, expected.avg_magnitude);
        assert_eq!(
            actual.quiet_floor_var.to_bits(),
            expected.quiet_floor_var.to_bits()
        );
        assert_eq!(actual.music_band_spreads, expected.music_band_spreads);
    }

    #[test]
    fn circular_stft_matches_buffered_reference_exactly() {
        for rate in [44_100, 96_000, 192_000] {
            for n in [256, 1024] {
                let mut plan = StftPlan::new(n, rate);
                for length in [n - 1, n, n + n / 4 - 1, 7 * n + 13] {
                    let signals: Vec<Vec<f32>> = (0..3)
                        .map(|channel| {
                            (0..length)
                                .map(|i| match channel {
                                    0 => 0.0,
                                    1 if i < 2 * n => 0.0,
                                    1 => ((i * 7919 % 65537) as f32 - 32768.0) / 65536.0,
                                    _ => -((i * 7919 % 65537) as f32 - 32768.0) / 65536.0,
                                })
                                .collect()
                        })
                        .collect();
                    let mut channels: Vec<_> = signals
                        .iter()
                        .map(|_| StftAccumulator::new(&plan))
                        .collect();
                    for i in 0..length {
                        for (channel, signal) in channels.iter_mut().zip(&signals) {
                            channel.push(signal[i], &mut plan, &|| Ok(())).unwrap();
                        }
                    }
                    for (channel, signal) in channels.into_iter().zip(signals) {
                        assert_stats_equal(
                            &channel.finish(&plan),
                            &analyze_stft(&signal, n, rate, &|| Ok(())).unwrap(),
                        );
                    }
                }
            }
        }
    }

    fn assert_integer_equal(samples: &[i32], rate: u32) {
        let mut evidence = IntegerEvidence::new(rate);
        for &sample in samples {
            evidence.push(sample);
        }
        let orbit = samples.iter().fold(0, |bits, sample| bits | *sample as u32);
        assert_eq!(evidence.or_bits, orbit);
        assert_eq!(
            evidence.artifact(),
            detect_integer_upsampling(samples, orbit, rate)
        );
    }

    #[test]
    fn integer_histograms_match_every_ratio_phase_padding_and_violation_boundary() {
        for base_rate in SOURCE_RATES {
            for ratio in 2..=8 {
                for phase in 0..ratio {
                    for shift in [0, 8, 16] {
                        let anchors: Vec<i32> =
                            (0..1300).map(|i| (i * 137 % 1021 - 510) * 16).collect();
                        let hold: Vec<i32> = anchors
                            .iter()
                            .flat_map(|value| std::iter::repeat_n(*value << shift, ratio))
                            .skip(phase)
                            .collect();
                        let line: Vec<i32> = anchors
                            .windows(2)
                            .flat_map(|pair| {
                                (0..ratio).map(move |i| {
                                    (pair[0] + (pair[1] - pair[0]) * i as i32 / ratio as i32)
                                        << shift
                                })
                            })
                            .skip(phase)
                            .collect();
                        let rate = base_rate * ratio as u32;
                        for signal in [hold, line] {
                            assert_integer_equal(&signal, rate);
                            for violations in [1, ratio, ratio * 2] {
                                let mut altered = signal.clone();
                                for i in 0..violations {
                                    altered[10 + i * 17] += 37 << shift;
                                }
                                assert_integer_equal(&altered, rate);
                            }
                            // The final value changes the unused-bit shift for all earlier derivatives.
                            let mut altered = signal;
                            altered.push(1);
                            assert_integer_equal(&altered, rate);
                        }
                    }
                }
            }
        }
        for samples in [
            vec![],
            vec![0; 10],
            vec![i32::MIN, i32::MAX, i32::MIN, 1],
            vec![i32::MIN; 5000],
        ] {
            assert_integer_equal(&samples, 96_000);
        }
    }
}
