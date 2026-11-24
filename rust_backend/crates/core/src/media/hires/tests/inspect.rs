//! A full inspection, on synthesised files. Files above 48 kHz skip the scan
//! for a codec's frame grid, which keeps the tests that are not about it
//! quick.

use super::*;
use crate::media::hires::inspect::{
    GRADE_CLEAN, GRADE_CORRUPT, GRADE_LOSSY, GRADE_SUSPECT, GRADE_UPSCALED, once_layer3,
    through_lapped_transform,
};
use md5::{Digest, Md5};

const RATE: u32 = 96_000;

fn inspect(path: &Path) -> Inspection {
    let file = File::open(path).expect("open fixture");
    inspect_file(
        file,
        &path.to_string_lossy(),
        &HiResCheckOptions::default(),
        &|| Ok(()),
    )
    .expect("inspect")
}

/// Noise some 40 dB down, so that many samples are quiet ones.
fn quiet_noise(n: usize, seed: u64) -> Vec<f64> {
    full_band_noise(n, seed).iter().map(|v| v / 20.0).collect()
}

/// Writes the checksum of `samples`, the same on every channel, into the
/// stream header of the FLAC at `path`.
fn store_checksum(path: &Path, samples: &[i32], bits: u32, channels: u32) {
    let mut digest = Md5::new();
    for sample in samples {
        for _ in 0..channels {
            digest.update(&sample.to_le_bytes()[..(bits / 8) as usize]);
        }
    }
    let mut bytes = std::fs::read(path).expect("flac");
    bytes[26..42].copy_from_slice(&digest.finalize());
    std::fs::write(path, bytes).expect("flac with checksum");
}

#[test]
fn the_audio_is_checked_against_the_checksum_its_stream_carries() {
    let dir = TempDir::new("inspect-checksum");
    let path = dir.file("audio.flac");
    let samples = quantize(&full_band_noise(40_000, 3), 24);
    write_flac(&path, &samples, RATE, 24, 2);
    let report = inspect(&path).report;
    assert_eq!(report.integrity.status, "unverified");
    assert_eq!(report.integrity.stored_md5, "");
    assert_eq!(report.grade, GRADE_CLEAN);

    store_checksum(&path, &samples, 24, 2);
    let report = inspect(&path).report;
    assert_eq!(report.integrity.status, "verified");
    assert_eq!(report.integrity.stored_md5, report.integrity.computed_md5);
    assert_eq!(report.integrity.decoded_frames, 40_000);
    assert_eq!(report.grade, GRADE_CLEAN);

    let mut bytes = std::fs::read(&path).expect("flac");
    bytes[30] ^= 1;
    std::fs::write(&path, bytes).expect("flac with a wrong checksum");
    let report = inspect(&path).report;
    assert_eq!(report.integrity.status, "checksum_mismatch");
    assert_eq!(report.grade, GRADE_CORRUPT);
}

#[test]
fn a_stream_that_ends_early_is_corrupt() {
    let dir = TempDir::new("inspect-cut");
    let path = dir.file("audio.flac");
    let samples = quantize(&full_band_noise(40_000, 5), 16);
    write_flac(&path, &samples, RATE, 16, 1);
    store_checksum(&path, &samples, 16, 1);
    let mut bytes = std::fs::read(&path).expect("flac");
    bytes.truncate(bytes.len() - 5_000);
    std::fs::write(&path, bytes).expect("cut flac");
    let report = inspect(&path).report;
    assert_eq!(report.integrity.status, "decode_error");
    assert!(report.integrity.decoded_frames < report.integrity.declared_frames);
    assert_eq!(report.grade, GRADE_CORRUPT);
}

#[test]
fn the_spacing_of_quiet_samples_shows_the_real_resolution() {
    let dir = TempDir::new("inspect-depth");
    let noise = quiet_noise(200_000, 7);
    let sixteen = quantize(&noise, 16);

    let path = flac(&dir, "full.flac", &quantize(&noise, 24), RATE, 24);
    let report = inspect(&path).report;
    assert_eq!(report.bit_depth.status, "full");
    assert_eq!(report.bit_depth.resolution_bits, 24.0);
    assert_eq!(report.grade, GRADE_CLEAN);

    // A 16-bit master turned down and stored as 24-bit: every bit is in
    // use, but the values lie some 150 steps apart.
    let scaled: Vec<i32> = sixteen
        .iter()
        .map(|&v| (f64::from(v) * 256.0 * 0.6).round() as i32)
        .collect();
    let report = inspect(&flac(&dir, "scaled.flac", &scaled, RATE, 24)).report;
    assert_eq!(report.bit_depth.status, "coarse");
    assert_eq!(report.bit_depth.used, 24);
    assert!(
        (16.5..17.0).contains(&report.bit_depth.resolution_bits),
        "{:?}",
        report.bit_depth
    );
    assert_eq!(report.grade, GRADE_SUSPECT);

    // The same master with low-level noise added at 24 bits.
    let mut rng = Rng(11);
    let dithered: Vec<i32> = sixteen
        .iter()
        .map(|&v| v * 256 + (rng.next_u64() % 11) as i32 - 5)
        .collect();
    let report = inspect(&flac(&dir, "dithered.flac", &dithered, RATE, 24)).report;
    assert_eq!(report.bit_depth.status, "near_16bit");
    assert_eq!(report.grade, GRADE_SUSPECT);

    let padded: Vec<i32> = sixteen.iter().map(|&v| v * 256).collect();
    let report = inspect(&flac(&dir, "padded.flac", &padded, RATE, 24)).report;
    assert_eq!(report.bit_depth.status, "padded");
    assert_eq!(report.bit_depth.used, 16);
    assert_eq!(report.grade, GRADE_UPSCALED);
}

#[test]
fn audio_that_was_lossy_once_shows_the_codec_frame_grid() {
    const FRAME: usize = 2_048;
    let dir = TempDir::new("inspect-lossy");
    let noise = full_band_noise(FRAME * 4, 9);

    let path = dir.file("never.wav");
    write_wav(&path, &quantize(&noise[FRAME..FRAME * 3], 16), CD_SR, 16);
    let report = inspect(&path).report;
    assert_eq!(report.lossy.status, "not_found");
    assert_eq!(report.integrity.status, "unverified");
    assert_eq!(report.grade, GRADE_CLEAN);

    // Frames 1024 samples apart, the first one 300 samples in; the file is
    // the part every frame rebuilt in full.
    let coded = through_lapped_transform(&noise, FRAME, "sine", 300, 5.4);
    let path = flac(
        &dir,
        "once.flac",
        &quantize(&coded[FRAME..FRAME * 3], 16),
        CD_SR,
        16,
    );
    let report = inspect(&path).report;
    assert_eq!(report.lossy.status, "found", "{:?}", report.lossy);
    assert_eq!(report.lossy.family, "aac");
    assert_eq!(report.lossy.frame_samples, 1_024);
    assert_eq!(report.grade, GRADE_LOSSY);
}

#[test]
fn audio_that_was_layer_3_once_shows_the_granule_grid() {
    let dir = TempDir::new("inspect-layer3");
    let samples = once_layer3(70, 12_345, 100);
    let report = inspect(&flac(&dir, "once.flac", &samples, CD_SR, 16)).report;
    assert_eq!(report.lossy.status, "found", "{:?}", report.lossy);
    assert_eq!(report.lossy.family, "mp3");
    assert_eq!(report.lossy.frame_samples, 576);
    assert_eq!(report.lossy.found_score, 15.0);
    assert_eq!(report.grade, GRADE_LOSSY);
}
