//! Sample-rate conversion for a song whose rate the DAC refuses: a Kaiser
//! windowed sinc filter applied as a polyphase rational resampler. Samples
//! are little-endian integers left-justified in their subslot, as on the
//! wire. The transport itself never changes a sample.

use std::collections::HashMap;
use std::f64::consts::{PI, TAU};
use std::sync::{Arc, Mutex, OnceLock};

/// Stopband attenuation of the filter, in dB.
const ATTENUATION_DB: f64 = 130.0;
/// The passband ends at this share of the lower of the two Nyquist
/// frequencies: 20 kHz for a 44.1 kHz stream.
const PASSBAND: f64 = 0.907;
/// Bounds the coefficient table for rate pairs with no small common ratio.
const MAX_PROTOTYPE: usize = 2_000_000;

pub struct Resampler {
    up: usize,
    down: usize,
    taps: usize,
    channels: usize,
    width: usize,
    /// One step of the output precision, in subslot units.
    step: f64,
    full_scale: f64,
    dither: bool,
    /// Dither whose noise sits in the high frequencies instead of all of them.
    high_pass: bool,
    /// The last uniform value of each channel, for the high-pass dither.
    previous: [f64; 2],
    random: u32,
    /// Per phase, `taps` coefficients in input order, oldest frame first.
    coefficients: Arc<Vec<f64>>,
    /// The input frames the filter still needs, one buffer per channel.
    history: Vec<Vec<f64>>,
    /// The next output frame, in `1 / up` input frames from the oldest one
    /// in `history`.
    position: usize,
}

impl Resampler {
    pub fn new(
        source_rate: u32,
        output_rate: u32,
        channels: u8,
        subslot: u8,
        bits: u8,
        high_pass_dither: bool,
    ) -> Result<Self, String> {
        if source_rate == 0 || output_rate == 0 || source_rate == output_rate {
            return Err("Resampling needs two different sample rates".into());
        }
        if !(1..=2).contains(&channels)
            || !(2..=4).contains(&subslot)
            || !(16..=subslot * 8).contains(&bits)
        {
            return Err("Unsupported PCM layout for resampling".into());
        }
        let divisor = gcd(source_rate, output_rate);
        let up = (output_rate / divisor) as usize;
        let down = (source_rate / divisor) as usize;
        let (taps, coefficients) = design(up, down)?;
        let mut resampler = Self {
            up,
            down,
            taps,
            channels: channels as usize,
            width: subslot as usize,
            step: f64::from(1u32 << (subslot * 8 - bits)),
            full_scale: (1u64 << (subslot * 8 - 1)) as f64,
            dither: bits <= 16,
            high_pass: high_pass_dither,
            previous: [0.0; 2],
            random: 0x9e37_79b9,
            coefficients,
            history: vec![Vec::new(); channels as usize],
            position: 0,
        };
        resampler.reset();
        Ok(resampler)
    }

    /// Forgets the audio heard so far, as after a seek.
    pub fn reset(&mut self) {
        for channel in &mut self.history {
            channel.clear();
            channel.resize(self.taps - 1, 0.0);
        }
        self.position = (self.taps - 1) * self.up;
    }

    /// Takes whole frames and returns the output frames they complete.
    pub fn process(&mut self, input: &[u8]) -> Result<Vec<u8>, String> {
        if !input.len().is_multiple_of(self.width * self.channels) {
            return Err("Resampler input is not frame aligned".into());
        }
        let unused = 64 - 8 * self.width as u32;
        for (index, sample) in input.chunks_exact(self.width).enumerate() {
            let mut bytes = [0u8; 8];
            bytes[..sample.len()].copy_from_slice(sample);
            let value = (i64::from_le_bytes(bytes) << unused) >> unused;
            self.history[index % self.channels].push(value as f64);
        }
        Ok(self.run())
    }

    /// The frames still inside the filter once the source has ended.
    pub fn finish(&mut self) -> Vec<u8> {
        let delay = self.taps.div_ceil(2);
        for channel in &mut self.history {
            channel.resize(channel.len() + delay, 0.0);
        }
        self.run()
    }

    fn run(&mut self) -> Vec<u8> {
        let frames = self.history[0].len();
        let ready = (frames * self.up).saturating_sub(self.position);
        let mut output = Vec::with_capacity(ready.div_ceil(self.down) * self.channels * self.width);
        while self.position / self.up < frames {
            let newest = self.position / self.up;
            let phase = self.position % self.up;
            let coefficients = &self.coefficients[phase * self.taps..(phase + 1) * self.taps];
            let mut sums = [0.0f64; 2];
            for (sum, channel) in sums.iter_mut().zip(&self.history) {
                *sum = dot(&channel[newest + 1 - self.taps..=newest], coefficients);
            }
            for (channel, sum) in sums.into_iter().take(self.channels).enumerate() {
                let sample = self.quantize(sum, channel);
                output.extend_from_slice(&sample.to_le_bytes()[..self.width]);
            }
            self.position += self.down;
        }
        // The next output frame reads back `taps - 1` frames from its newest.
        let done = (self.position / self.up)
            .saturating_sub(self.taps - 1)
            .min(frames);
        for channel in &mut self.history {
            channel.drain(..done);
        }
        self.position -= done * self.up;
        output
    }

    fn quantize(&mut self, value: f64, channel: usize) -> i64 {
        let mut steps = value / self.step;
        if self.dither {
            // Triangular dither of one step either way keeps the rounding
            // error of a 16-bit output free of the signal. The high-pass
            // kind takes the channel's last value from the new one, which
            // leaves the same noise power but none of it near 0 Hz.
            let fresh = self.uniform();
            steps += if self.high_pass {
                fresh - std::mem::replace(&mut self.previous[channel], fresh)
            } else {
                fresh + self.uniform()
            };
        }
        (steps.round() * self.step).clamp(-self.full_scale, self.full_scale - self.step) as i64
    }

    /// Uniform in [-0.5, 0.5).
    fn uniform(&mut self) -> f64 {
        self.random ^= self.random << 13;
        self.random ^= self.random >> 17;
        self.random ^= self.random << 5;
        f64::from(self.random) / 4_294_967_296.0 - 0.5
    }
}

/// A dot product kept in eight separate sums, which the compiler can hold
/// in vector registers; one running sum would force each addition to wait
/// for the one before it.
fn dot(samples: &[f64], coefficients: &[f64]) -> f64 {
    let mut sums = [0.0f64; 8];
    let (sample_chunks, sample_tail) = samples.as_chunks::<8>();
    let (coefficient_chunks, coefficient_tail) = coefficients.as_chunks::<8>();
    for (sample, coefficient) in sample_chunks.iter().zip(coefficient_chunks) {
        for index in 0..8 {
            sums[index] += sample[index] * coefficient[index];
        }
    }
    let tail: f64 = sample_tail
        .iter()
        .zip(coefficient_tail)
        .map(|(sample, coefficient)| sample * coefficient)
        .sum();
    sums.iter().sum::<f64>() + tail
}

fn gcd(a: u32, b: u32) -> u32 {
    if b == 0 { a } else { gcd(b, a % b) }
}

/// Taps per phase and the coefficient table, shared by every resampler of
/// one rate pair.
type Design = (usize, Arc<Vec<f64>>);

/// The taps per phase and the coefficient table of the low-pass filter that
/// both removes the images of raising the rate by `up` and guards against
/// the aliases of lowering it by `down`.
fn design(up: usize, down: usize) -> Result<Design, String> {
    static CACHE: OnceLock<Mutex<HashMap<(usize, usize), Design>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(hit) = cache.lock().unwrap().get(&(up, down)) {
        return Ok((hit.0, Arc::clone(&hit.1)));
    }
    // Frequencies in cycles per sample of the common rate `source * up`.
    let nyquist = 0.5 / up.max(down) as f64;
    let transition = nyquist * (1.0 - PASSBAND);
    let cutoff = nyquist - transition / 2.0;
    let length = ((ATTENUATION_DB - 7.95) / (2.285 * TAU * transition)).ceil() as usize;
    let taps = length.div_ceil(up).max(2);
    let length = taps * up;
    if length > MAX_PROTOTYPE {
        return Err("Sample rates have no practical conversion ratio".into());
    }
    let beta = 0.1102 * (ATTENUATION_DB - 8.7);
    let inv_i0_beta = 1.0 / bessel_i0(beta);
    let centre = (length - 1) as f64 / 2.0;
    let mut prototype = vec![0.0; length];
    let half = length.div_ceil(2);
    for index in 0..half {
        let offset = index as f64 - centre;
        let edge = offset / centre;
        let window = bessel_i0(beta * (1.0 - edge * edge).max(0.0).sqrt()) * inv_i0_beta;
        let value = sinc(2.0 * cutoff * offset) * window;
        prototype[index] = value;
        prototype[length - 1 - index] = value;
    }
    let gain = up as f64 / prototype.iter().sum::<f64>();
    let mut coefficients = vec![0.0; length];
    for phase in 0..up {
        for tap in 0..taps {
            coefficients[phase * taps + taps - 1 - tap] = prototype[phase + tap * up] * gain;
        }
    }
    let coefficients = Arc::new(coefficients);
    let mut guard = cache.lock().unwrap();
    if guard.len() >= 16 {
        guard.clear();
    }
    guard.insert((up, down), (taps, Arc::clone(&coefficients)));
    Ok((taps, coefficients))
}

fn sinc(x: f64) -> f64 {
    if x.abs() < 1e-12 {
        1.0
    } else {
        (PI * x).sin() / (PI * x)
    }
}

/// The zeroth-order modified Bessel function of the first kind.
fn bessel_i0(x: f64) -> f64 {
    let quarter = x * x / 4.0;
    let mut term = 1.0;
    let mut sum = 1.0;
    let mut k = 1.0;
    while term > sum * 1e-17 {
        term *= quarter / (k * k);
        sum += term;
        k += 1.0;
    }
    sum
}

#[cfg(test)]
mod tests {
    use super::*;

    const FULL: f64 = 2_147_483_648.0;

    /// A stereo 32-bit tone at 0.5 of full scale; the right channel is the
    /// left one inverted.
    fn tone(rate: u32, frequency: f64, frames: usize) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(frames * 8);
        for frame in 0..frames {
            let value = (0.5 * FULL * (TAU * frequency * frame as f64 / f64::from(rate)).sin())
                .round() as i32;
            bytes.extend_from_slice(&value.to_le_bytes());
            bytes.extend_from_slice(&(-value).to_le_bytes());
        }
        bytes
    }

    fn left(bytes: &[u8]) -> Vec<f64> {
        bytes
            .as_chunks::<8>()
            .0
            .iter()
            .map(|frame| f64::from(i32::from_le_bytes(frame[..4].try_into().unwrap())) / FULL)
            .collect()
    }

    fn convert(source: u32, output: u32, frequency: f64) -> Vec<f64> {
        let mut resampler = Resampler::new(source, output, 2, 4, 32, false).unwrap();
        let mut bytes = resampler
            .process(&tone(source, frequency, source as usize))
            .unwrap();
        bytes.extend(resampler.finish());
        left(&bytes)
    }

    /// The amplitude of `frequency` in `samples` by least squares, and the
    /// level of everything else relative to it, in dB.
    fn fit(samples: &[f64], rate: u32, frequency: f64) -> (f64, f64) {
        let (mut ss, mut cc, mut sc, mut ys, mut yc) = (0.0, 0.0, 0.0, 0.0, 0.0);
        let basis = |index: usize| {
            let angle = TAU * frequency * index as f64 / f64::from(rate);
            (angle.sin(), angle.cos())
        };
        for (index, sample) in samples.iter().enumerate() {
            let (s, c) = basis(index);
            ss += s * s;
            cc += c * c;
            sc += s * c;
            ys += sample * s;
            yc += sample * c;
        }
        let determinant = ss * cc - sc * sc;
        let a = (ys * cc - yc * sc) / determinant;
        let b = (yc * ss - ys * sc) / determinant;
        let residual: f64 = samples
            .iter()
            .enumerate()
            .map(|(index, sample)| {
                let (s, c) = basis(index);
                (sample - a * s - b * c).powi(2)
            })
            .sum();
        let amplitude = a.hypot(b);
        let signal = amplitude * amplitude / 2.0 * samples.len() as f64;
        (amplitude, 10.0 * (residual / signal).log10())
    }

    /// The part of a one-second conversion clear of the start and the end.
    fn steady(samples: &[f64]) -> &[f64] {
        &samples[samples.len() / 4..samples.len() * 3 / 4]
    }

    #[test]
    fn halving_the_rate_keeps_a_tone_clean() {
        let output = convert(96_000, 48_000, 1000.0);
        let (amplitude, residual) = fit(steady(&output), 48_000, 1000.0);
        assert!((amplitude - 0.5).abs() < 1e-5, "amplitude {amplitude}");
        assert!(residual < -120.0, "residual {residual} dB");
    }

    #[test]
    fn fractional_ratios_keep_the_passband_flat() {
        for (source, output) in [(44_100, 48_000), (48_000, 44_100), (96_000, 44_100)] {
            for frequency in [1000.0, 19_000.0] {
                let converted = convert(source, output, frequency);
                let (amplitude, residual) = fit(steady(&converted), output, frequency);
                assert!(
                    (amplitude - 0.5).abs() < 5e-4,
                    "{source} to {output} at {frequency}: amplitude {amplitude}"
                );
                assert!(
                    residual < -110.0,
                    "{source} to {output} at {frequency}: residual {residual} dB"
                );
            }
        }
    }

    #[test]
    fn a_tone_above_the_new_nyquist_does_not_alias() {
        // 30 kHz would fold to 18 kHz at 48 kHz.
        let output = convert(96_000, 48_000, 30_000.0);
        let steady = steady(&output);
        let power = steady.iter().map(|sample| sample * sample).sum::<f64>() / steady.len() as f64;
        let level = 10.0 * (power / 0.125).log10();
        assert!(level < -120.0, "alias at {level} dB");
    }

    #[test]
    fn chunked_input_matches_one_call() {
        let input = tone(44_100, 440.0, 20_000);
        let mut whole = Resampler::new(44_100, 48_000, 2, 4, 24, false).unwrap();
        let mut expected = whole.process(&input).unwrap();
        expected.extend(whole.finish());
        let mut chunked = Resampler::new(44_100, 48_000, 2, 4, 24, false).unwrap();
        let mut actual = Vec::new();
        for chunk in input.chunks(8 * 37) {
            actual.extend(chunked.process(chunk).unwrap());
        }
        actual.extend(chunked.finish());
        assert_eq!(actual, expected);
        // The length follows the ratio, plus the filter's own tail.
        let frames = actual.len() / 8;
        assert!((21_768..21_768 + 200).contains(&frames), "{frames} frames");
    }

    #[test]
    fn reset_starts_from_silence_again() {
        let input = tone(96_000, 1000.0, 5000);
        let mut resampler = Resampler::new(96_000, 48_000, 2, 4, 24, false).unwrap();
        let first = resampler.process(&input).unwrap();
        resampler.reset();
        assert_eq!(resampler.process(&input).unwrap(), first);
    }

    #[test]
    fn output_keeps_the_dac_precision_and_never_wraps() {
        // 24 valid bits in a 4-byte subslot: the low byte stays zero.
        let mut resampler = Resampler::new(96_000, 48_000, 2, 4, 24, false).unwrap();
        let output = resampler.process(&tone(96_000, 997.0, 9600)).unwrap();
        assert!(
            output
                .as_chunks::<4>()
                .0
                .iter()
                .all(|sample| sample[0] == 0)
        );

        // A full-scale square overshoots after filtering: it clips at the
        // rails instead of wrapping to the other one.
        let mut square = Vec::new();
        for frame in 0..9600 {
            let value: i16 = if (frame / 24) % 2 == 0 {
                i16::MAX
            } else {
                i16::MIN
            };
            square.extend_from_slice(&value.to_le_bytes());
        }
        let mut mono = Resampler::new(96_000, 48_000, 1, 2, 16, false).unwrap();
        let clipped = mono.process(&square).unwrap();
        let samples: Vec<i16> = clipped
            .as_chunks::<2>()
            .0
            .iter()
            .map(|sample| i16::from_le_bytes(*sample))
            .collect();
        assert!(samples.contains(&i16::MAX) && samples.contains(&i16::MIN));
        assert_eq!(mono.quantize(1e9, 0), i64::from(i16::MAX));
        assert_eq!(mono.quantize(-1e9, 0), i64::from(i16::MIN));
        assert_eq!(resampler.quantize(1e12, 0), i64::from(i32::MAX) - 255);
    }

    /// One second of 16-bit stereo silence converted, as steps of the
    /// output: all that is left is the dither.
    fn dither_of_silence(high_pass: bool) -> (Vec<f64>, Vec<f64>) {
        let mut resampler = Resampler::new(96_000, 48_000, 2, 2, 16, high_pass).unwrap();
        let output = resampler.process(&vec![0u8; 96_000 * 4]).unwrap();
        let samples: Vec<f64> = output
            .as_chunks::<2>()
            .0
            .iter()
            .map(|sample| f64::from(i16::from_le_bytes(*sample)))
            .collect();
        (
            samples.iter().step_by(2).copied().collect(),
            samples.iter().skip(1).step_by(2).copied().collect(),
        )
    }

    fn power(samples: &[f64]) -> f64 {
        samples.iter().map(|sample| sample * sample).sum::<f64>() / samples.len() as f64
    }

    /// The power of the upper half of the band over that of the lower half.
    fn tilt(samples: &[f64]) -> f64 {
        let (mut high, mut low) = (0.0, 0.0);
        for pair in samples.windows(2) {
            high += (pair[1] - pair[0]).powi(2);
            low += (pair[1] + pair[0]).powi(2);
        }
        high / low
    }

    #[test]
    fn high_pass_dither_moves_the_noise_up_without_adding_any() {
        let (plain, plain_right) = dither_of_silence(false);
        let (high, high_right) = dither_of_silence(true);
        for channel in [&plain, &plain_right, &high, &high_right] {
            // Never more than one step, and no offset.
            assert!(channel.iter().all(|sample| sample.abs() <= 1.0));
            let mean = channel.iter().sum::<f64>() / channel.len() as f64;
            assert!(mean.abs() < 0.01, "mean {mean}");
            // A quarter of a step squared, whichever kind.
            let power = power(channel);
            assert!((power - 0.25).abs() < 0.01, "power {power}");
        }
        // Plain dither is level; the high-pass kind has twice the power in
        // the upper half of the band.
        assert!((tilt(&plain) - 1.0).abs() < 0.05, "{}", tilt(&plain));
        assert!((tilt(&plain_right) - 1.0).abs() < 0.05);
        assert!((tilt(&high) - 2.0).abs() < 0.1, "{}", tilt(&high));
        assert!((tilt(&high_right) - 2.0).abs() < 0.1);
        // Each channel has its own noise.
        assert_ne!(high, high_right);
    }

    #[test]
    fn either_dither_keeps_a_quiet_tone_whole() {
        // A tone of 3 steps peak in 16 bits, which bare rounding would turn
        // into a staircase.
        let mut input = Vec::new();
        for frame in 0..96_000 {
            let value = 3.0 * 65_536.0 * (TAU * 1000.0 * f64::from(frame) / 96_000.0).sin();
            input.extend_from_slice(&(value.round() as i32).to_le_bytes());
        }
        for high_pass in [false, true] {
            let mut resampler = Resampler::new(96_000, 48_000, 1, 4, 16, high_pass).unwrap();
            let output = resampler.process(&input).unwrap();
            let steps: Vec<f64> = output
                .as_chunks::<4>()
                .0
                .iter()
                .map(|sample| f64::from(i32::from_le_bytes(*sample)) / 65_536.0)
                .collect();
            assert!(steps.iter().all(|step| step.fract() == 0.0));
            let (amplitude, residual) = fit(steady(&steps), 48_000, 1000.0);
            assert!(
                (amplitude - 3.0).abs() < 0.05,
                "high pass {high_pass}: amplitude {amplitude}"
            );
            // Beside the tone there is the dither's quarter of a step
            // squared and no more: 0.25 over 4.5 is -12.6 dB.
            assert!(
                (residual + 12.55).abs() < 0.5,
                "high pass {high_pass}: residual {residual} dB"
            );
        }
    }

    #[test]
    fn more_than_16_bits_get_no_dither_of_either_kind() {
        for high_pass in [false, true] {
            let mut resampler = Resampler::new(96_000, 48_000, 2, 4, 24, high_pass).unwrap();
            let output = resampler.process(&vec![0u8; 9600 * 8]).unwrap();
            assert!(output.iter().all(|byte| *byte == 0));
        }
    }

    #[test]
    fn three_byte_samples_keep_their_sign() {
        let mut input = Vec::new();
        for _ in 0..4000 {
            input.extend_from_slice(&(-4_000_000i32).to_le_bytes()[..3]);
        }
        let mut resampler = Resampler::new(88_200, 44_100, 1, 3, 24, false).unwrap();
        let output = resampler.process(&input).unwrap();
        let last = &output[output.len() - 3..];
        let value = i32::from_le_bytes([last[0], last[1], last[2], 0]) << 8 >> 8;
        assert!((value + 4_000_000).abs() <= 1, "{value}");
    }

    #[test]
    fn rejects_layouts_and_ratios_it_cannot_serve() {
        assert!(Resampler::new(48_000, 48_000, 2, 4, 24, false).is_err());
        assert!(Resampler::new(96_000, 48_000, 3, 4, 24, false).is_err());
        assert!(Resampler::new(96_000, 48_000, 2, 3, 32, false).is_err());
        assert!(Resampler::new(96_001, 48_000, 2, 4, 24, false).is_err());
        let mut resampler = Resampler::new(96_000, 48_000, 2, 4, 24, false).unwrap();
        assert!(resampler.process(&[0; 7]).is_err());
    }
}
