//! Sampled Hi-Res analysis. A spectral roll-off is an observation, not proof
//! that a master was upsampled or that a replacement preserves its audio.
//!
//! A file can claim Hi-Res along two independent axes, and each is checked on
//! its own terms:
//!
//! - Sample rate: spectral roll-off, noise floor and interpolation patterns
//!   can suggest a lower-rate source. A cutoff alone is not a fingerprint.
//! - Bit depth: it declares 24-bit but only 16 of those bits ever carry data,
//!   the low 8 being zero in every sample: a CD master padded out. Unlike the
//!   spectral test this one is exact, and it is the only test that can judge
//!   a 24-bit/44.1 kHz file.
//!
//! The cutoff alone cannot tell an upsampled CD from a genuine master that
//! was low-pass filtered in mastering; that finding is `band_limited`.
//! `fake_hires` requires additional evidence ("certain" or "likely"). These
//! confidence levels describe the sampled evidence, not permission to discard
//! audio. Replacement additionally requires a full, exact PCM comparison.
//!
//! Only FLAC and PCM WAV are decoded. Anything else is
//! [`HiResCheckError::Unsupported`], which callers treat as "check skipped".

mod evidence;
pub(crate) mod fft;
mod replacement;
pub use replacement::replacement_preserves_audio;
#[cfg(test)]
mod reference;
#[cfg(test)]
mod tests;

use evidence::*;
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};

pub const VERDICT_FAKE: &str = "fake_hires";
pub const VERDICT_STANDARD: &str = "standard_definition";
pub const VERDICT_GENUINE: &str = "genuine_hires";
pub const VERDICT_BAND_LIMITED: &str = "band_limited";
pub const VERDICT_INCONCLUSIVE: &str = "inconclusive";

#[derive(Debug, PartialEq, Eq)]
pub enum HiResCheckError {
    /// A container this checker cannot decode; never a reason to treat the
    /// file itself as broken.
    Unsupported,
    Failed(String),
}

impl std::fmt::Display for HiResCheckError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsupported => f.write_str("hi-res check: unsupported audio format"),
            Self::Failed(message) => write!(f, "hi-res check: {message}"),
        }
    }
}

impl From<String> for HiResCheckError {
    fn from(message: String) -> Self {
        Self::Failed(message)
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct HiResCheckOptions {
    /// Length of the segment analysed from the middle of the track.
    pub sample_seconds: i64,
    /// dB relative to the segment's spectral peak above which a bin is
    /// considered active content rather than noise.
    pub noise_floor_db: f64,
    /// Sample rate above which a file claims Hi-Res.
    pub hires_sample_rate_threshold: i64,
    /// Threshold for reporting limited bandwidth, including transition-band
    /// tails above CD bandwidth. This is never a requirement for authenticity.
    pub hires_cutoff_threshold_hz: f64,
    /// STFT window size; must be a power of two. Shrunk for short segments.
    pub n_fft: i64,
}

impl Default for HiResCheckOptions {
    fn default() -> Self {
        Self {
            sample_seconds: 30,
            noise_floor_db: -80.0,
            hires_sample_rate_threshold: 48_000,
            hires_cutoff_threshold_hz: 28_000.0,
            n_fft: 4096,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct HiResCheckResult {
    pub file_path: String,
    pub declared_sample_rate: u32,
    pub total_duration_s: f64,
    pub analyzed_duration_s: f64,
    pub cutoff_frequency_hz: f64,
    pub noise_floor_db: f64,
    pub verdict: String,
    /// Bits per sample the container declares; 0 when the format has no
    /// fixed-point depth to declare (float PCM).
    pub declared_bit_depth: u32,
    /// Bits per sample that actually carry data; 0 when not measured.
    pub effective_bit_depth: u32,
    /// Why the file was flagged, in one clause; empty when it was not.
    pub reason: String,
    /// Strength of the sampled evidence: "certain" (padding or integer
    /// pattern), "likely" (spectral evidence). Empty for other verdicts.
    pub confidence: String,
    /// Exact upsampling fingerprint found, if any: "sample_hold",
    /// "linear_interpolation" or "imaging".
    pub upsampling_artifact: String,
    /// Source Nyquist (22050 / 24000) with a resampler-style cliff; 0 if none.
    pub brickwall_hz: f64,
    /// In-band floor of the quietest frames against flat 16-bit quantization
    /// noise: "below_16bit", "at_16bit", "masked" (music never quiet enough),
    /// or empty when not measured.
    pub noise_floor_class: String,
    pub noise_floor_vs_16bit_db: f64,
    /// Highest frequency whose level still moves with the music, for a file
    /// claiming Hi-Res by rate; 0 when not measured. Informational: the
    /// verdict rests on the tests above.
    pub music_cutoff_hz: f64,
    /// True when the active content past `music_cutoff_hz` is steady noise,
    /// like the ultrasonic hump of a DSD or analog tape transfer, so
    /// `cutoff_frequency_hz` marks where that noise ends rather than the music.
    pub ultrasonic_noise_only: bool,
    /// With `ultrasonic_noise_only`: the lowest standard rate of the same
    /// family that holds all the music (e.g. 88200 for a 176.4 kHz file whose
    /// music stops at 34 kHz). Otherwise the declared rate.
    pub useful_sample_rate: u32,
}

impl HiResCheckResult {
    /// True for any "fake hi-res" verdict, whatever its confidence.
    pub fn is_suspicious(&self) -> bool {
        self.verdict == VERDICT_FAKE
    }

    /// A conservative candidate filter, not proof that a replacement is safe.
    /// Both depth and rate must fit CD quality; spectral heuristics cannot
    /// establish that. The caller must still compare every decoded sample.
    pub fn redownload_safe(&self) -> bool {
        self.is_suspicious()
            && self.confidence == CONFIDENCE_CERTAIN
            && self.declared_bit_depth > 0
            && self.effective_bit_depth > 0
            && self.effective_bit_depth <= 16
            && (self.declared_sample_rate <= 44_100
                || (self.upsampling_artifact == ARTIFACT_SAMPLE_HOLD
                    && self.declared_sample_rate.is_multiple_of(44_100)))
    }

    /// True when the declared depth is bits the file never uses.
    pub fn padded_bit_depth(&self) -> bool {
        self.declared_bit_depth > 16
            && self.effective_bit_depth > 0
            && self.effective_bit_depth <= 16
    }
}

struct ChannelAnalysis {
    stft: StftAccumulator,
    integers: IntegerEvidence,
    count: usize,
    non_silent: bool,
}

impl ChannelAnalysis {
    fn push(
        &mut self,
        sample: f32,
        integer: Option<i32>,
        plan: &mut StftPlan,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<(), String> {
        self.count += 1;
        self.non_silent |= f64::from(sample.abs()) > 1e-9;
        if let Some(integer) = integer {
            self.integers.push(integer);
        }
        self.stft.push(sample, plan, check)
    }
}

struct WindowAnalysis {
    channels: Vec<ChannelAnalysis>,
    #[cfg(test)]
    decoded_blocks: usize,
}

/// Analyses one file and returns a populated result. Only a short segment from
/// the middle of the track is decoded, never the whole file.
pub fn check_file(
    mut file: File,
    file_path: &str,
    options: &HiResCheckOptions,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<HiResCheckResult, HiResCheckError> {
    if options.sample_seconds <= 0 {
        return Err("sample_seconds must be positive".to_string().into());
    }
    if options.n_fft < 4 || (options.n_fft & (options.n_fft - 1)) != 0 {
        return Err("n_fft must be a power of two of at least 4"
            .to_string()
            .into());
    }
    let size = file.metadata().map_err(|e| e.to_string())?.len();
    if size == 0 {
        return Err(format!("file is empty: {file_path}").into());
    }
    check()?;

    let mut source = Source::open(&mut file)?;
    let sr = source.sample_rate();
    if sr == 0 {
        return Err("invalid declared sample rate 0".to_string().into());
    }
    let total_duration = source.total_frames() as f64 / f64::from(sr);
    if total_duration <= 0.0 {
        return Err("file reports no duration, likely corrupt"
            .to_string()
            .into());
    }

    let analyzed_duration = (options.sample_seconds as f64).min(total_duration);
    let offset = ((total_duration - analyzed_duration) / 2.0).max(0.0);
    let start_frame = (offset * f64::from(sr)) as u64;
    let window_frames = (analyzed_duration * f64::from(sr)) as u64;

    let declared_bits = source.declared_bits();

    let mut result = HiResCheckResult {
        file_path: file_path.to_string(),
        declared_sample_rate: sr,
        total_duration_s: total_duration,
        analyzed_duration_s: analyzed_duration,
        noise_floor_db: options.noise_floor_db,
        declared_bit_depth: declared_bits,
        useful_sample_rate: sr,
        verdict: VERDICT_INCONCLUSIVE.into(),
        ..HiResCheckResult::default()
    };

    // Use complete windows only. Zero-padding a segment boundary introduces
    // an artificial broadband transient and can hide a real spectral cutoff.
    let mut n_fft = options.n_fft as usize;
    while n_fft > 256 && n_fft as u64 > window_frames {
        n_fft /= 2;
    }
    let claims_by_rate = i64::from(sr) > options.hires_sample_rate_threshold;
    let mut combined: Option<StftStats> = None;
    let mut or_bits = 0;
    let mut common_artifact: Option<&str> = None;
    let mut all_floors_at_16bit = true;
    let mut plan = StftPlan::new(n_fft, sr);
    let analysis = source
        .analyze_window(start_frame, window_frames, &mut plan, check)
        .map_err(|e| HiResCheckError::Failed(format!("could not decode audio: {e}")))?;
    for channel in analysis.channels {
        check()?;
        if channel.count == 0 {
            return Err("decoded audio segment is empty".to_string().into());
        }
        or_bits |= channel.integers.or_bits;
        result.analyzed_duration_s = result
            .analyzed_duration_s
            .min(channel.count as f64 / f64::from(sr));
        if !channel.non_silent {
            continue;
        }
        let stats = channel.stft.finish(&plan);
        all_floors_at_16bit &= classify_noise_floor(stats.quiet_floor_var, 1).0 == FLOOR_AT_16BIT;
        if claims_by_rate {
            let artifact = channel.integers.artifact();
            // A pattern in one channel must not implicate independent,
            // full-resolution content in another channel.
            common_artifact = Some(match common_artifact {
                None => artifact,
                Some(previous) if previous == artifact => artifact,
                Some(_) => "",
            });
        }
        if let Some(combined) = &mut combined {
            for (all, channel) in combined.avg_magnitude.iter_mut().zip(&stats.avg_magnitude) {
                *all = all.max(*channel);
            }
            for (all, channel) in combined
                .music_band_spreads
                .iter_mut()
                .zip(&stats.music_band_spreads)
            {
                *all = all.max(*channel);
            }
            combined.quiet_floor_var = combined.quiet_floor_var.max(stats.quiet_floor_var);
        } else {
            combined = Some(stats);
        }
    }
    let Some(stats) = combined else {
        return Ok(result);
    };
    if !stats.avg_magnitude.iter().any(|&v| v > 0.0) {
        return Ok(result);
    }

    // Deliberately unclamped: flooring at the noise floor itself would make
    // every floored bin count as active at any lower threshold.
    let spec_db = spectrum_db(&stats.avg_magnitude);
    let cutoff = spec_db
        .iter()
        .rposition(|&db| db > options.noise_floor_db)
        .map_or(0.0, |k| k as f64 * f64::from(sr) / n_fft as f64);
    result.cutoff_frequency_hz = cutoff;

    let mut effective_bits = 0;
    if declared_bits > 0 && or_bits != 0 {
        // Digital silence carries no bits at all; leaving it at 0 keeps it
        // out of the padded-depth test.
        effective_bits = declared_bits.saturating_sub(or_bits.trailing_zeros());
    }
    result.declared_bit_depth = declared_bits;
    result.effective_bit_depth = effective_bits;

    // A file can claim Hi-Res by rate, by depth, or both, and each claim is
    // answered by the test that can actually judge it.
    let claims_by_depth = declared_bits > 16;
    result.useful_sample_rate = sr;
    if claims_by_rate {
        result.music_cutoff_hz = music_cutoff(
            &stats.music_band_spreads,
            &spec_db,
            sr,
            n_fft,
            options.noise_floor_db,
        );
        if result.music_cutoff_hz > 0.0
            && cutoff - result.music_cutoff_hz >= ULTRASONIC_NOISE_MARGIN_HZ
        {
            result.ultrasonic_noise_only = true;
            result.useful_sample_rate = useful_sample_rate(sr, result.music_cutoff_hz);
        }
        // A resampler's cliff at 22.05/24 kHz betrays a 44.1/48 kHz chain
        // even when a weak stopband leaves a flat plateau above it that reads
        // as "content" to the cutoff test (ffmpeg's default resampler does).
        result.brickwall_hz = detect_brickwall(&spec_db, sr, n_fft, options.noise_floor_db);
    }
    let cutoff_is_low = claims_by_rate && cutoff < options.hires_cutoff_threshold_hz;
    let limited_bandwidth = cutoff_is_low || result.brickwall_hz > 0.0;
    let depth_is_fake = claims_by_depth && effective_bits > 0 && effective_bits <= 16;

    // Integer fingerprints of a conversion. Imaging puts content back above
    // 22 kHz, so such a file can pass the cutoff test and still be a fake.
    let mut artifact = common_artifact.unwrap_or("");
    if claims_by_rate
        && artifact.is_empty()
        && detect_imaging(&spec_db, sr, n_fft, options.noise_floor_db)
    {
        artifact = ARTIFACT_IMAGING;
    }
    result.upsampling_artifact = artifact.into();
    if limited_bandwidth {
        let (class, vs_16bit_db) = classify_noise_floor(stats.quiet_floor_var, 1);
        result.noise_floor_class = class.into();
        result.noise_floor_vs_16bit_db = vs_16bit_db;
    }
    // A noisier channel must not obscure a quieter channel's extra precision.
    let likely_upsampled = result.brickwall_hz > 0.0 && all_floors_at_16bit;

    result.verdict = if !claims_by_rate && !claims_by_depth {
        VERDICT_STANDARD
    } else if likely_upsampled || depth_is_fake || !artifact.is_empty() {
        VERDICT_FAKE
    } else if limited_bandwidth {
        VERDICT_BAND_LIMITED
    } else {
        VERDICT_GENUINE
    }
    .into();

    if result.verdict == VERDICT_FAKE {
        result.confidence = if depth_is_fake
            || artifact == ARTIFACT_SAMPLE_HOLD
            || artifact == ARTIFACT_INTERPOLATION
        {
            CONFIDENCE_CERTAIN
        } else {
            CONFIDENCE_LIKELY
        }
        .into();
    }

    let mut findings: Vec<String> = Vec::new();
    match artifact {
        ARTIFACT_SAMPLE_HOLD => {
            findings.push("every sample is repeated (sample-and-hold upsampling)".into());
        }
        ARTIFACT_INTERPOLATION => {
            findings.push("in-between samples are linearly interpolated".into());
        }
        ARTIFACT_IMAGING => {
            findings.push("content above the source Nyquist mirrors the audible band".into());
        }
        _ => {}
    }
    if cutoff_is_low {
        findings.push(format!(
            "declares {sr} Hz but content stops at ~{cutoff:.0} Hz"
        ));
    } else if limited_bandwidth {
        findings.push(format!(
            "declares {sr} Hz but the spectrum falls off a cliff at {:.0} Hz",
            result.brickwall_hz
        ));
    }
    if depth_is_fake {
        findings.push(format!(
            "declares {declared_bits}-bit but only {effective_bits} bits carry data"
        ));
    }
    if result.verdict == VERDICT_BAND_LIMITED {
        findings.push("bandwidth alone does not establish upsampling or master provenance".into());
    }
    result.reason = findings.join("; ");
    Ok(result)
}

/// The containers the checker decodes, sniffed from their magic bytes rather
/// than the extension so Android descriptor paths without a suffix work too.
enum Source<'a> {
    Flac(Box<claxon::FlacReader<BufReader<&'a mut File>>>),
    Wav(WavSource<'a>),
}

impl<'a> Source<'a> {
    fn open(file: &'a mut File) -> Result<Self, HiResCheckError> {
        let mut head = [0u8; 12];
        let mut read = 0;
        while read < head.len() {
            match file.read(&mut head[read..]) {
                Ok(0) => break,
                Ok(n) => read += n,
                Err(e) => return Err(e.to_string().into()),
            }
        }
        file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        if read >= 4 && &head[..4] == b"fLaC" {
            return claxon::FlacReader::new(BufReader::new(file))
                .map(|reader| Source::Flac(Box::new(reader)))
                .map_err(|e| HiResCheckError::Failed(format!("could not read audio header: {e}")));
        }
        if read >= 12 && &head[..4] == b"RIFF" && &head[8..12] == b"WAVE" {
            return WavSource::open(file).map(Source::Wav);
        }
        Err(HiResCheckError::Unsupported)
    }

    fn sample_rate(&self) -> u32 {
        match self {
            Source::Flac(reader) => reader.streaminfo().sample_rate,
            Source::Wav(wav) => wav.sample_rate,
        }
    }

    fn total_frames(&self) -> u64 {
        match self {
            Source::Flac(reader) => reader.streaminfo().samples.unwrap_or(0),
            Source::Wav(wav) => wav.data_size / wav.frame_bytes(),
        }
    }

    /// 0 for formats without a fixed-point depth.
    fn declared_bits(&self) -> u32 {
        match self {
            Source::Flac(reader) => reader.streaminfo().bits_per_sample,
            Source::Wav(wav) if wav.is_float => 0,
            Source::Wav(wav) => wav.container_bits,
        }
    }

    fn channel_count(&self) -> u32 {
        match self {
            Source::Flac(reader) => reader.streaminfo().channels,
            Source::Wav(wav) => wav.channels,
        }
    }

    fn analyze_window(
        &mut self,
        start_frame: u64,
        frames: u64,
        plan: &mut StftPlan,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<WindowAnalysis, String> {
        let sample_rate = self.sample_rate();
        let mut analysis = WindowAnalysis {
            channels: (0..self.channel_count())
                .map(|_| ChannelAnalysis {
                    stft: StftAccumulator::new(plan),
                    integers: IntegerEvidence::new(sample_rate),
                    count: 0,
                    non_silent: false,
                })
                .collect(),
            #[cfg(test)]
            decoded_blocks: 0,
        };
        match self {
            Source::Flac(reader) => {
                let scale = 1.0 / 2f64.powi(reader.streaminfo().bits_per_sample as i32 - 1);
                let end = start_frame + frames;
                let mut blocks = reader.blocks();
                let mut buffer = Vec::new();
                let mut decoded = 0_u64;
                while analysis
                    .channels
                    .first()
                    .is_some_and(|channel| (channel.count as u64) < frames)
                {
                    if decoded.is_multiple_of(64) {
                        check()?;
                    }
                    decoded += 1;
                    let block = match blocks.read_next_or_eof(buffer) {
                        Ok(Some(block)) => block,
                        Ok(None) => break,
                        Err(_) if analysis.channels[0].count > 0 => break,
                        Err(error) => return Err(error.to_string()),
                    };
                    #[cfg(test)]
                    {
                        analysis.decoded_blocks += 1;
                    }
                    let first = block.time();
                    let n = u64::from(block.duration());
                    if first + n > start_frame {
                        let from = start_frame.saturating_sub(first) as usize;
                        let to = n.min(end.saturating_sub(first)) as usize;
                        for (index, channel) in analysis.channels.iter_mut().enumerate() {
                            for &value in &block.channel(index as u32)[from..to] {
                                channel.push(
                                    (f64::from(value) * scale) as f32,
                                    Some(value),
                                    plan,
                                    check,
                                )?;
                            }
                        }
                    }
                    buffer = block.into_buffer();
                }
            }
            Source::Wav(wav) => {
                wav.analyze_window(start_frame, frames, &mut analysis, plan, check)?
            }
        }
        Ok(analysis)
    }
}

const WAV_FORMAT_PCM: u16 = 1;
const WAV_FORMAT_FLOAT: u16 = 3;
const WAV_FORMAT_EXTENSIBLE: u16 = 0xFFFE;

struct WavSource<'a> {
    file: &'a mut File,
    sample_rate: u32,
    channels: u32,
    /// Bits per sample as stored.
    container_bits: u32,
    is_float: bool,
    data_offset: u64,
    data_size: u64,
}

impl<'a> WavSource<'a> {
    fn open(file: &'a mut File) -> Result<Self, HiResCheckError> {
        let file_size = file.metadata().map_err(|e| e.to_string())?.len();
        file.seek(SeekFrom::Start(12)).map_err(|e| e.to_string())?;
        let (mut sample_rate, mut channels, mut container_bits) = (0u32, 0u32, 0u32);
        let mut format = 0u16;
        let (mut data_offset, mut data_size) = (0u64, 0u64);
        let mut header = [0u8; 8];
        while data_offset == 0 {
            if file.read_exact(&mut header).is_err() {
                break;
            }
            let size = u64::from(u32::from_le_bytes([
                header[4], header[5], header[6], header[7],
            ]));
            let pad = size & 1;
            let chunk_start = file.stream_position().map_err(|e| e.to_string())?;
            let chunk_end = chunk_start + size;
            // Only the data chunk may use a streaming-size placeholder.
            if &header[..4] != b"data" && chunk_end + pad > file_size {
                return Err("truncated WAV chunk".to_string().into());
            }
            match &header[..4] {
                b"fmt " => {
                    // The format prefix is at most 40 bytes. Never allocate
                    // from an untrusted 32-bit chunk length.
                    let mut chunk = [0u8; 40];
                    let prefix_len = size.min(chunk.len() as u64) as usize;
                    if prefix_len < 16 || file.read_exact(&mut chunk[..prefix_len]).is_err() {
                        return Err("truncated WAV fmt chunk".to_string().into());
                    }
                    format = u16::from_le_bytes([chunk[0], chunk[1]]);
                    channels = u32::from(u16::from_le_bytes([chunk[2], chunk[3]]));
                    sample_rate = u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]);
                    container_bits = u32::from(u16::from_le_bytes([chunk[14], chunk[15]]));
                    if format == WAV_FORMAT_EXTENSIBLE {
                        if prefix_len < 40 || u16::from_le_bytes([chunk[16], chunk[17]]) < 22 {
                            return Err("truncated extensible WAV fmt chunk".to_string().into());
                        }
                        // SubFormat GUID's leading format tag.
                        format = u16::from_le_bytes([chunk[24], chunk[25]]);
                    }
                    file.seek(SeekFrom::Start(chunk_end + pad))
                        .map_err(|e| e.to_string())?;
                }
                b"data" => {
                    data_offset = file.stream_position().map_err(|e| e.to_string())?;
                    // Streamed WAVs often carry a placeholder data size.
                    if size != u64::from(u32::MAX) && chunk_end > file_size {
                        return Err("truncated WAV data chunk".to_string().into());
                    }
                    data_size = size.min(file_size.saturating_sub(data_offset));
                }
                _ => {
                    file.seek(SeekFrom::Start(chunk_end + pad))
                        .map_err(|e| e.to_string())?;
                }
            }
        }

        if data_offset == 0 || channels == 0 || sample_rate == 0 {
            return Err("WAV has no usable fmt/data chunk".to_string().into());
        }
        let is_float = match (format, container_bits) {
            (WAV_FORMAT_PCM, 8 | 16 | 24 | 32) => false,
            (WAV_FORMAT_FLOAT, 32 | 64) => true,
            _ => return Err(HiResCheckError::Unsupported),
        };
        Ok(Self {
            file,
            sample_rate,
            channels,
            container_bits,
            is_float,
            data_offset,
            data_size,
        })
    }

    fn frame_bytes(&self) -> u64 {
        u64::from(self.channels * self.container_bits / 8)
    }

    fn analyze_window(
        &mut self,
        start_frame: u64,
        frames: u64,
        analysis: &mut WindowAnalysis,
        plan: &mut StftPlan,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<(), String> {
        let total = self.data_size / self.frame_bytes();
        let frames = frames.min(total.saturating_sub(start_frame));
        let frame_bytes = self.frame_bytes() as usize;
        self.file
            .seek(SeekFrom::Start(
                self.data_offset + start_frame * frame_bytes as u64,
            ))
            .map_err(|e| e.to_string())?;
        let bytes_per_sample = (self.container_bits / 8) as usize;
        let scale = 1.0 / 2f64.powi(self.container_bits as i32 - 1);
        let mut reader = BufReader::with_capacity(1 << 16, &mut *self.file);
        let mut frame = vec![0; frame_bytes];
        for index in 0..frames {
            if index.is_multiple_of(65_536) {
                check()?;
            }
            if reader.read_exact(&mut frame).is_err() {
                break;
            }
            for (channel, bytes) in analysis
                .channels
                .iter_mut()
                .zip(frame.chunks_exact(bytes_per_sample))
            {
                if self.is_float {
                    let value = if self.container_bits == 32 {
                        f64::from(f32::from_le_bytes(bytes.try_into().expect("32-bit float")))
                    } else {
                        f64::from_le_bytes(bytes.try_into().expect("64-bit float"))
                    };
                    channel.push(value as f32, None, plan, check)?;
                } else {
                    let value = match self.container_bits {
                        8 => i32::from(bytes[0]) - 128,
                        16 => i32::from(i16::from_le_bytes(bytes.try_into().expect("16-bit PCM"))),
                        24 => i32::from_le_bytes([0, bytes[0], bytes[1], bytes[2]]) >> 8,
                        _ => i32::from_le_bytes(bytes.try_into().expect("32-bit PCM")),
                    };
                    channel.push((f64::from(value) * scale) as f32, Some(value), plan, check)?;
                }
            }
        }
        Ok(())
    }
}
