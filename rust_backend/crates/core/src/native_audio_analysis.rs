//! UI-independent ports of the bounded Flutter AutoMix and spectral estimators.
//! Decoding, playback scheduling and spectrogram painting remain with their owners.

use serde::Serialize;
use std::fs::File;
use std::io::Read;

const MAX_PCM_BYTES: usize = 11_025 * 2 * 25;
const MAX_SPECTRAL_BYTES: usize = 4 << 20;

pub(crate) fn read_bounded(
    path: &str,
    maximum: usize,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Vec<u8>, String> {
    check()?;
    let file = File::open(path).map_err(|error| error.to_string())?;
    if !file
        .metadata()
        .map_err(|error| error.to_string())?
        .is_file()
    {
        return Err("analysis input is not a regular file".into());
    }
    if file.metadata().map_err(|error| error.to_string())?.len() > maximum as u64 {
        return Err("analysis input exceeds the size limit".into());
    }
    let mut bytes = Vec::new();
    file.take(maximum as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    check()?;
    if bytes.len() > maximum {
        return Err("analysis input exceeds the size limit".into());
    }
    Ok(bytes)
}

#[derive(Debug, Default, PartialEq, Serialize)]
pub struct AutoMixBeatGrid {
    pub bpm: f64,
    pub phase: f64,
    pub confidence: f64,
    #[serde(rename = "first_sound")]
    pub first_sound: f64,
}

pub fn analyze_automix_pcm_file(
    path: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<AutoMixBeatGrid, String> {
    analyze_automix_pcm(&read_bounded(path, MAX_PCM_BYTES, check)?, check)
}

/// Arithmetic order, thresholds and tie handling match analyzeAutoMixPcm.
pub fn analyze_automix_pcm(
    pcm: &[u8],
    check: &dyn Fn() -> Result<(), String>,
) -> Result<AutoMixBeatGrid, String> {
    check()?;
    if pcm.len() > MAX_PCM_BYTES {
        return Err("AutoMix PCM exceeds the size limit".into());
    }
    const HOP: usize = 128;
    const FPS: f64 = 11_025.0 / HOP as f64;
    let frames = pcm.len() / (2 * HOP);
    if (frames as f64) < FPS * 6.0 {
        return Ok(AutoMixBeatGrid::default());
    }
    let mut onset = vec![0.0_f64; frames];
    let mut energy = vec![0.0_f64; frames];
    let (mut low, mut mid, mut previous_low, mut previous_mid, mut previous_high) =
        (0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64);
    for frame in 0..frames {
        check()?;
        let (mut lo_energy, mut mid_energy, mut hi_energy) = (0.0_f64, 0.0_f64, 0.0_f64);
        for index in 0..HOP {
            let byte = (frame * HOP + index) * 2;
            let value = i16::from_le_bytes([pcm[byte], pcm[byte + 1]]) as f64 / 32768.0;
            low += 0.075 * (value - low);
            mid += 0.45 * (value - mid);
            lo_energy += low * low;
            mid_energy += (mid - low) * (mid - low);
            hi_energy += (value - mid) * (value - mid);
            energy[frame] += value * value / HOP as f64;
        }
        let lo = (1.0 + lo_energy * 100.0 / HOP as f64).ln();
        let mi = (1.0 + mid_energy * 100.0 / HOP as f64).ln();
        let hi = (1.0 + hi_energy * 100.0 / HOP as f64).ln();
        onset[frame] = (lo - previous_low).max(0.0)
            + (mi - previous_mid).max(0.0)
            + 0.5 * (hi - previous_high).max(0.0);
        previous_low = lo;
        previous_mid = mi;
        previous_high = hi;
    }
    let peak_energy = energy.iter().copied().fold(0.0_f64, f64::max);
    if peak_energy < 0.00001 {
        return Ok(AutoMixBeatGrid::default());
    }
    let first_audible = energy
        .iter()
        .position(|value| *value > 0.00001_f64.max(peak_energy * 0.0001))
        .unwrap_or(0);
    let first_sound = first_audible as f64 / FPS;
    let mut prefix = vec![0.0; frames + 1];
    for index in 0..frames {
        prefix[index + 1] = prefix[index] + onset[index];
    }
    let mut total = 0.0;
    for (index, value) in onset.iter_mut().enumerate() {
        let begin = index.saturating_sub(8);
        let end = frames.min(index + 9);
        *value = (*value - (prefix[end] - prefix[begin]) / (end - begin) as f64).max(0.0);
        total += *value * *value;
    }
    if total < 0.000001 {
        return Ok(AutoMixBeatGrid {
            first_sound,
            ..AutoMixBeatGrid::default()
        });
    }
    // Match the bounded local onset normalization in analyzeAutoMixPcm.
    let mut power = vec![0.0; frames + 1];
    for index in 0..frames {
        power[index + 1] = power[index] + onset[index] * onset[index];
    }
    let floor = total / frames as f64 * 0.01;
    for (index, value) in onset.iter_mut().enumerate() {
        check()?;
        let begin = index.saturating_sub(43);
        let end = frames.min(index + 44);
        let local = (power[end] - power[begin]) / (end - begin) as f64;
        *value = (*value / floor.max(local).sqrt()).min(6.0);
    }
    let correlation = |lag: f64| {
        let (mut dot, mut left, mut right) = (0.0_f64, 0.0_f64, 0.0_f64);
        for index in lag.ceil() as usize..frames {
            let source = index as f64 - lag;
            let previous = source.floor() as usize;
            let fraction = source - previous as f64;
            let delayed = onset[previous] * (1.0 - fraction)
                + onset[(previous + 1).min(frames - 1)] * fraction;
            dot += onset[index] * delayed;
            left += onset[index] * onset[index];
            right += delayed * delayed;
        }
        dot / (left * right).max(0.000000001).sqrt()
    };
    let (mut best_bpm, mut best_score) = (0.0, 0.0);
    for quarter_bpm in 240..=720 {
        check()?;
        let bpm = quarter_bpm as f64 / 4.0;
        let score = correlation(FPS * 60.0 / bpm);
        let weighted = score * (0.96 + 0.04 * (-((bpm - 120.0) / 45.0).powf(2.0)).exp());
        if weighted > best_score {
            best_score = weighted;
            best_bpm = bpm;
        }
    }
    if best_bpm == 0.0 {
        return Ok(AutoMixBeatGrid::default());
    }
    let coarse_bpm = best_bpm;
    for step in -25..=25 {
        check()?;
        let bpm = coarse_bpm + f64::from(step) * 0.01;
        if !(60.0..=180.0).contains(&bpm) {
            continue;
        }
        let score = correlation(FPS * 60.0 / bpm);
        let weighted = score * (0.96 + 0.04 * (-((bpm - 120.0) / 45.0).powf(2.0)).exp());
        if weighted > best_score {
            best_score = weighted;
            best_bpm = bpm;
        }
    }
    let period = FPS * 60.0 / best_bpm;
    let (mut best_phase, mut phase_score) = (0.0, 0.0);
    let mut phase = 0.0;
    while phase < period {
        check()?;
        let (mut score, mut count) = (0.0_f64, 0_usize);
        let mut beat = phase;
        while beat < (frames - 1) as f64 {
            score += onset[beat.round() as usize];
            count += 1;
            beat += period;
        }
        score /= count.max(1) as f64;
        if score > phase_score {
            phase_score = score;
            best_phase = phase;
        }
        phase += 0.5;
    }
    let (mut hits, mut beats) = (0_usize, 0_usize);
    let mut beat = best_phase;
    while beat < (frames - 2) as f64 {
        let index = beat.round() as usize;
        let peak = onset[index].max(onset[index.saturating_sub(1)].max(onset[index + 1]));
        if peak >= phase_score * 0.3 {
            hits += 1;
        }
        beats += 1;
        beat += period;
    }
    Ok(AutoMixBeatGrid {
        bpm: best_bpm,
        phase: best_phase / FPS,
        confidence: best_score.min(hits as f64 / beats.max(1) as f64),
        first_sound,
    })
}

pub fn estimate_spectral_cutoff_file(
    path: &str,
    width: usize,
    height: usize,
    max_frequency: f64,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<f64>, String> {
    let expected = width
        .checked_mul(height)
        .filter(|size| *size <= MAX_SPECTRAL_BYTES)
        .ok_or("spectral plane exceeds the size limit")?;
    let bytes = read_bounded(path, expected, check)?;
    estimate_spectral_cutoff(&bytes, width, height, max_frequency, check)
}

fn sorted_window(values: &[f64], start: isize, end: isize) -> Vec<f64> {
    let begin = start.clamp(0, values.len() as isize) as usize;
    let end = end.clamp(begin as isize, values.len() as isize) as usize;
    let mut result = values[begin..end].to_vec();
    result.sort_by(f64::total_cmp);
    result
}

fn percentile(sorted: &[f64], fraction: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    sorted[((sorted.len() - 1) as f64 * fraction).round() as usize]
}

fn median(values: &[f64], start: isize, end: isize) -> f64 {
    percentile(&sorted_window(values, start, end), 0.5)
}

pub fn estimate_spectral_cutoff(
    intensity: &[u8],
    width: usize,
    height: usize,
    max_frequency: f64,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<f64>, String> {
    check()?;
    let pixels = width
        .checked_mul(height)
        .ok_or("invalid spectral dimensions")?;
    if pixels > MAX_SPECTRAL_BYTES {
        return Err("spectral plane exceeds the size limit".into());
    }
    if width == 0
        || height == 0
        || !max_frequency.is_finite()
        || max_frequency <= 0.0
        || intensity.len() < pixels
    {
        return Ok(None);
    }
    let mut profile = vec![0.0; height];
    let target = (width as f64 * 0.90).floor() as usize;
    for y in 0..height {
        check()?;
        let mut histogram = [0_usize; 256];
        for x in 0..width {
            histogram[intensity[y * width + x] as usize] += 1;
        }
        let mut cumulative = 0;
        for (value, count) in histogram.iter().enumerate() {
            cumulative += count;
            if cumulative > target {
                profile[height - y - 1] = value as f64;
                break;
            }
        }
    }
    let hz_per_row = max_frequency / height as f64;
    // A radius larger than the image samples the entire same bounded window;
    // cap it before integer conversion, including tiny malformed frequencies.
    let line_radius = (250.0 / hz_per_row).ceil().max(1.0).min(height as f64) as isize;
    let mut broadband = vec![0.0; height];
    for (index, value) in broadband.iter_mut().enumerate() {
        check()?;
        *value = median(
            &profile,
            index as isize - line_radius,
            index as isize + line_radius + 1,
        );
    }
    let smoothing_radius = (50.0 / hz_per_row).ceil().max(1.0).min(height as f64) as usize;
    let mut smoothed = vec![0.0; height];
    let (mut running, mut begin, mut end) = (0.0, 0_usize, 0_usize);
    for (index, value) in smoothed.iter_mut().enumerate() {
        let desired_begin = index.saturating_sub(smoothing_radius);
        let desired_end = (index.saturating_add(smoothing_radius)).min(height - 1);
        while end <= desired_end {
            running += broadband[end];
            end += 1;
        }
        while begin < desired_begin {
            running -= broadband[begin];
            begin += 1;
        }
        *value = running / (end - begin) as f64;
    }
    let central = sorted_window(
        &smoothed,
        (height as f64 * 0.05).floor() as isize,
        (height as f64 * 0.95).ceil() as isize,
    );
    let low_level = percentile(&central, 0.10);
    let high_level = percentile(&central, 0.95);
    let dynamic_span = high_level - low_level;
    if high_level < 24.0 {
        return Ok(None);
    }
    if dynamic_span < 1.0 {
        return Ok(Some(max_frequency));
    }
    let edge_rows = (200.0 / hz_per_row).ceil().max(2.0) as usize;
    let guard_rows = edge_rows.max((500.0 / hz_per_row).ceil() as usize);
    let min_hz = 1000.0_f64.max(4000.0_f64.min(max_frequency * 0.20));
    let search_start = edge_rows.max((min_hz / hz_per_row).floor() as usize);
    let search_end = height.saturating_sub(edge_rows).saturating_sub(guard_rows);
    let mut candidates: Vec<usize> = (search_start..search_end)
        .filter(|index| smoothed[*index] - smoothed[*index + edge_rows] > 0.0)
        .collect();
    candidates.sort_by(|a, b| {
        (smoothed[*b] - smoothed[*b + edge_rows])
            .total_cmp(&(smoothed[*a] - smoothed[*a + edge_rows]))
    });
    let minimum_drop = 6.0_f64.max(dynamic_span * 0.18);
    let gap_rows = (100.0 / hz_per_row).ceil().max(1.0) as isize;
    let support_rows = (1200.0 / hz_per_row).ceil().max(3.0) as isize;
    let tail_spread_limit = 4.0_f64.max(dynamic_span * 0.06);
    for start in candidates {
        check()?;
        if smoothed[start] - smoothed[start + edge_rows] < minimum_drop * 0.60 {
            break;
        }
        let edge = (start as f64 + edge_rows as f64 / 2.0).round() as isize;
        let below_end = edge - gap_rows;
        let below_start = (below_end - support_rows).max(0);
        let above_start = edge + gap_rows;
        let above_end = (above_start + support_rows).min(height as isize);
        if below_end > below_start && above_end > above_start {
            let below = median(&smoothed, below_start, below_end);
            let above = median(&smoothed, above_start, above_end);
            if below - above < minimum_drop {
                continue;
            }
            let tail = sorted_window(&smoothed, above_start, height as isize);
            let tail_level = percentile(&tail, 0.50);
            if below - tail_level < minimum_drop {
                continue;
            }
            if percentile(&tail, 0.80) - percentile(&tail, 0.20) > tail_spread_limit {
                continue;
            }
            let base_start = (edge - (3000.0 / hz_per_row).ceil() as isize).max(0);
            if median(&smoothed, base_start, below_end) - tail_level >= minimum_drop {
                return Ok(Some(
                    ((edge as f64 + 0.5) * hz_per_row).clamp(0.0, max_frequency),
                ));
            }
        }
    }
    let tail_reference = median(
        &smoothed,
        (height as f64 * 0.90).floor() as isize,
        ((height as f64 * 0.98).floor() as isize).max(1),
    );
    let margin = 12.0_f64.max(dynamic_span * 0.25);
    for edge in (search_start..search_end).rev() {
        check()?;
        let below_end = edge as isize - gap_rows;
        let below_start = (below_end - support_rows).max(0);
        let above_start = edge as isize + gap_rows;
        if below_end <= below_start || above_start >= height as isize {
            continue;
        }
        let below = median(&smoothed, below_start, below_end);
        if below < tail_reference + margin {
            continue;
        }
        let tail = sorted_window(&smoothed, above_start, height as isize);
        if below - percentile(&tail, 0.50) < margin {
            continue;
        }
        if percentile(&tail, 0.80) - percentile(&tail, 0.20) <= tail_spread_limit {
            let cutoff_index = edge as f64 - support_rows as f64 / 2.0;
            return Ok(Some(
                ((cutoff_index + 0.5) * hz_per_row).clamp(0.0, max_frequency),
            ));
        }
    }
    let base = median(
        &smoothed,
        (height as f64 * 0.05).floor() as isize,
        ((height as f64 * 0.50).floor() as isize).max(1),
    );
    let top = median(
        &smoothed,
        (height as f64 * 0.90).floor() as isize,
        ((height as f64 * 0.98).floor() as isize).max(1),
    );
    let lower_top = median(
        &smoothed,
        (height as f64 * 0.80).floor() as isize,
        ((height as f64 * 0.90).floor() as isize).max(1),
    );
    Ok((base >= 24.0
        && top >= 24.0
        && (top >= high_level - minimum_drop
            || lower_top - top >= 1.0_f64.max(dynamic_span * 0.05)))
    .then_some(max_frequency))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn automix_matches_shared_dart_drum_vectors() {
        let expected = [
            (90.0, 90.0, 0.16834467120181407, 0.8021635512174413),
            (120.0, 119.99, 0.16834467120181407, 0.9844533705342401),
            (124.0, 123.88, 0.156734693877551, 0.8467090068250587),
            (160.0, 160.15, 0.1799546485260771, 0.8319336271448226),
        ];
        for (input_bpm, bpm, phase, confidence) in expected {
            let mut pcm = Vec::new();
            for i in 0..11_025 * 24 {
                let time = i as f64 / 11_025.0;
                let since = (time - 0.17) % (60.0 / input_bpm);
                let transient = if time < 0.17 {
                    0.0
                } else {
                    (-since * 50.0).exp()
                };
                let value = 0.75 * transient * (time * 2.0 * std::f64::consts::PI * 100.0).sin();
                pcm.extend_from_slice(&((value * 32767.0).round() as i16).to_le_bytes());
            }
            let grid = analyze_automix_pcm(&pcm, &|| Ok(())).unwrap();
            assert_eq!(grid.bpm, bpm);
            assert_eq!(grid.phase, phase);
            assert!((grid.confidence - confidence).abs() < 1e-12);
            assert_eq!(grid.first_sound, 0.16253968253968254);
        }
    }

    #[test]
    fn automix_keeps_quiet_beats_in_changing_dynamics() {
        for bpm in [90.0, 120.0, 124.0, 160.0] {
            let mut pcm = Vec::new();
            for i in 0..11_025 * 24 {
                let time = i as f64 / 11_025.0;
                let since = (time - 0.17) % (60.0 / bpm);
                let transient = if time < 0.17 {
                    0.0
                } else {
                    (-since * 50.0).exp()
                };
                let gain = 0.03 + 0.97 * (time / 24.0).powi(3);
                let value =
                    0.75 * gain * transient * (time * 2.0 * std::f64::consts::PI * 100.0).sin();
                pcm.extend_from_slice(&((value * 32767.0).round() as i16).to_le_bytes());
            }
            let grid = analyze_automix_pcm(&pcm, &|| Ok(())).unwrap();
            assert!(grid.confidence >= 0.55, "{bpm}: {}", grid.confidence);
            assert!((grid.bpm - bpm).abs() < 0.4);
            assert!(grid.first_sound < 0.3);
        }
    }

    #[test]
    fn automix_noise_does_not_invent_a_reliable_beat() {
        let mut seed = 11_u32;
        let mut pcm = Vec::new();
        for _ in 0..11_025 * 24 {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            pcm.extend_from_slice(&(seed as i16).to_le_bytes());
        }
        let grid = analyze_automix_pcm(&pcm, &|| Ok(())).unwrap();
        assert!(grid.confidence < 0.55);
    }

    #[test]
    fn automix_silence_short_and_partial_frames_remain_unknown() {
        for size in [0, 11_025 * 5 * 2, 11_025 * 24 * 2 + 1] {
            assert_eq!(
                analyze_automix_pcm(&vec![0; size], &|| Ok(())).unwrap(),
                AutoMixBeatGrid::default()
            );
        }
        assert!(analyze_automix_pcm(&vec![0; MAX_PCM_BYTES + 1], &|| Ok(())).is_err());
    }

    #[test]
    fn worker_cancels_inside_analysis_without_deleting_owned_input() {
        let calls = Cell::new(0);
        let result = analyze_automix_pcm(&vec![0; 11_025 * 24 * 2], &|| {
            calls.set(calls.get() + 1);
            if calls.get() >= 5 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        });
        assert_eq!(result.unwrap_err(), "cancelled");
    }

    #[test]
    fn spectral_silence_full_band_and_invalid_inputs() {
        assert_eq!(
            estimate_spectral_cutoff(&vec![0; 320_000], 400, 800, 24_000.0, &|| Ok(())).unwrap(),
            None
        );
        assert_eq!(
            estimate_spectral_cutoff(&vec![80; 320_000], 400, 800, 24_000.0, &|| Ok(())).unwrap(),
            Some(24_000.0)
        );
        assert_eq!(
            estimate_spectral_cutoff(&[], 400, 800, f64::NAN, &|| Ok(())).unwrap(),
            None
        );
        assert!(estimate_spectral_cutoff(&[], usize::MAX, 2, 24_000.0, &|| Ok(())).is_err());
    }
}
