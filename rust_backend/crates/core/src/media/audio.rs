//! Quality probes used by the file metadata export. Callers supply a checked
//! reader; large audio payloads are skipped instead of buffered.

use super::AudioQuality;
use crate::tags::{ogg_packets, ogg_stream_is_opus};
use std::io::{BufReader, Read, Seek, SeekFrom};

pub(crate) fn mp3_quality(
    file: &mut (impl Read + Seek),
    size: i64,
) -> Result<AudioQuality, String> {
    let mut quality = AudioQuality::default();
    let header = read::<10>(file)?;
    let start = if &header[..3] == b"ID3" {
        10 + ((i64::from(header[6]) << 21)
            | (i64::from(header[7]) << 14)
            | (i64::from(header[8]) << 7)
            | i64::from(header[9]))
    } else {
        0
    };
    seek(file, SeekFrom::Start(start as u64))?;
    let Ok(header) = read::<4>(file) else {
        return Ok(quality);
    };
    let frame = if header[0] == 0xff && header[1] & 0xe0 == 0xe0 {
        Some((header, seek(file, SeekFrom::Current(0))? - 4))
    } else {
        // Allocate only for resynchronization; normal MP3s need no read-ahead.
        let mut buffered = BufReader::new(&mut *file);
        let mut frame = None;
        for _ in 1..10000 {
            buffered
                .seek_relative(-3)
                .map_err(|error| error.to_string())?;
            let Ok(header) = read::<4>(&mut buffered) else {
                break;
            };
            if header[0] == 0xff && header[1] & 0xe0 == 0xe0 {
                frame = Some((header, seek(&mut buffered, SeekFrom::Current(0))? - 4));
                break;
            }
        }
        frame
    };
    let Some((header, frame_start)) = frame else {
        return Ok(quality);
    };
    let version = (header[1] >> 3) & 3;
    let layer = (header[1] >> 1) & 3;
    let bitrate_index = (header[2] >> 4) as usize;
    let rate_index = ((header[2] >> 2) & 3) as usize;
    let mono = (header[3] >> 6) == 3;
    let rates = [
        [11025, 12000, 8000],
        [0, 0, 0],
        [22050, 24000, 16000],
        [44100, 48000, 32000],
    ];
    if rate_index < 3 {
        quality.sample_rate = rates[version as usize][rate_index];
    }
    if layer == 1 {
        let rates = if version == 3 {
            [
                0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
            ]
        } else if version == 0 || version == 2 {
            [
                0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
            ]
        } else {
            [0; 16]
        };
        quality.bitrate = rates[bitrate_index] * 1000;
    }
    let samples_per_frame = if version == 0 || version == 2 {
        576
    } else {
        1152
    };
    let xing_offset = match (version == 3, mono) {
        (true, false) => 32,
        (false, true) => 9,
        _ => 17,
    };
    seek(file, SeekFrom::Start(frame_start + 4))?;
    let mut xing = [0; 200];
    let mut length = 0;
    while length < xing.len() {
        match file.read(&mut xing[length..]) {
            Ok(0) | Err(_) => break,
            Ok(n) => length += n,
        }
    }
    let mut frames = 0;
    let mut bytes = 0;
    if xing_offset + 8 <= length && matches!(&xing[xing_offset..xing_offset + 4], b"Xing" | b"Info")
    {
        let flags = be32(&xing[xing_offset + 4..xing_offset + 8]);
        let mut offset = xing_offset + 8;
        if flags & 1 != 0 && offset + 4 <= length {
            frames = be32(&xing[offset..offset + 4]);
            offset += 4;
        }
        if flags & 2 != 0 && offset + 4 <= length {
            bytes = be32(&xing[offset..offset + 4]);
        }
    }
    if frames == 0 && length >= 62 && &xing[32..36] == b"VBRI" {
        bytes = be32(&xing[42..46]);
        frames = be32(&xing[46..50]);
    }
    if frames > 0 && quality.sample_rate > 0 {
        quality.duration = frames * samples_per_frame / quality.sample_rate;
        if quality.duration > 0 {
            quality.bitrate = if bytes > 0 { bytes } else { size - start } * 8 / quality.duration;
        }
    } else if quality.bitrate > 0 && size - start - 128 > 0 {
        quality.duration = (size - start - 128) * 8 / quality.bitrate;
    }
    Ok(quality)
}

const ADTS_RATES: [i64; 13] = [
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
];

/// The 12-bit ADTS sync word followed by layer 0.
pub(crate) fn is_adts_frame(header: &[u8]) -> bool {
    header.len() >= 2 && header[0] == 0xff && header[1] & 0xf6 == 0xf0
}

/// Raw AAC in ADTS frames, often behind an ID3v2 tag. The first frames give
/// the sample rate and an average frame size for the duration and bitrate.
pub(crate) fn adts_quality(
    file: &mut (impl Read + Seek),
    size: i64,
) -> Result<AudioQuality, String> {
    let header = read::<10>(file)?;
    let start = crate::tags::v2_tag_length(&header).unwrap_or(0);
    seek(file, SeekFrom::Start(start))?;
    let mut reader = BufReader::new(&mut *file);
    let (mut frames, mut bytes, mut samples, mut sample_rate) = (0, 0_i64, 0_i64, 0);
    while frames < 256 {
        let Ok(frame) = read::<7>(&mut reader) else {
            break;
        };
        let rate = ADTS_RATES
            .get(usize::from((frame[2] >> 2) & 0x0f))
            .copied()
            .unwrap_or(0);
        let length = (i64::from(frame[3] & 0x03) << 11)
            | (i64::from(frame[4]) << 3)
            | i64::from(frame[5] >> 5);
        if !is_adts_frame(&frame)
            || rate == 0
            || length < 7
            || (sample_rate != 0 && rate != sample_rate)
        {
            break;
        }
        sample_rate = rate;
        samples += 1024 * (i64::from(frame[6] & 0x03) + 1);
        bytes += length;
        frames += 1;
        reader
            .seek_relative(length - 7)
            .map_err(|error| error.to_string())?;
    }
    if frames == 0 {
        return Err("no ADTS frames found".into());
    }
    let seconds = samples as f64 / sample_rate as f64;
    let bitrate = (bytes as f64 * 8.0 / seconds) as i64;
    Ok(AudioQuality {
        sample_rate,
        duration: ((size - start as i64) as f64 * 8.0 / bitrate as f64).round() as i64,
        bitrate,
        codec: "aac".into(),
        ..AudioQuality::default()
    })
}

pub(crate) fn ogg_quality(
    file: &mut (impl Read + Seek),
    size: i64,
    path: &str,
) -> Result<AudioQuality, String> {
    let packets = {
        let mut buffered = std::io::BufReader::new(&mut *file);
        ogg_packets(&mut buffered, 5, 10)?
    };
    let opus =
        ogg_stream_is_opus(&packets).unwrap_or_else(|| path.to_lowercase().ends_with(".opus"));
    let mut quality = AudioQuality::default();
    let mut pre_skip = 0;
    for packet in packets {
        if opus && packet.len() >= 19 && packet.starts_with(b"OpusHead") {
            quality.sample_rate = le32(&packet[12..16]);
            if quality.sample_rate == 0 {
                quality.sample_rate = 48000;
            }
            pre_skip = i64::from(u16::from_le_bytes(packet[10..12].try_into().unwrap()));
            break;
        }
        if !opus && packet.len() > 29 && packet.starts_with(b"\x01vorbis") {
            quality.sample_rate = le32(&packet[12..16]);
            break;
        }
    }
    let length = size.clamp(0, 65536) as usize;
    seek(file, SeekFrom::Start((size - length as i64) as u64))?;
    let mut tail = vec![0; length];
    file.read_exact(&mut tail).map_err(|e| e.to_string())?;
    let granule = (0..length.saturating_sub(3))
        .rev()
        .find_map(|offset| {
            let data = &tail[offset..];
            if data.len() < 27 || &data[..4] != b"OggS" || data[4] != 0 || data[5] > 7 {
                return None;
            }
            let header_length = 27 + data[26] as usize;
            if data.len() < header_length {
                return None;
            }
            let payload: usize = data[27..header_length].iter().map(|v| *v as usize).sum();
            (data.len() >= header_length + payload)
                .then(|| u64::from_le_bytes(data[6..14].try_into().unwrap()) as i64)
        })
        .unwrap_or(0);
    let seconds = if granule <= 0 {
        0.0
    } else if opus {
        (granule - pre_skip) as f64 / 48000.0
    } else if quality.sample_rate > 0 {
        granule as f64 / quality.sample_rate as f64
    } else {
        0.0
    };
    if seconds > 0.0 {
        quality.duration = seconds.round() as i64;
        quality.bitrate = (size as f64 * 8.0 / seconds) as i64;
    }
    if quality.bitrate <= 0 && quality.duration > 0 {
        quality.bitrate = size * 8 / quality.duration;
    }
    if quality.duration > 86400 {
        quality.duration = 0;
        quality.bitrate = 0;
    }
    if quality.bitrate > 0 && quality.bitrate < 8000 {
        quality.bitrate = 0;
    }
    Ok(quality)
}

pub(crate) fn riff_quality(
    file: &mut (impl Read + Seek),
    size: i64,
    aiff: bool,
) -> Result<AudioQuality, String> {
    let header = read::<12>(file)?;
    if if aiff {
        &header[..4] != b"FORM" || !matches!(&header[8..], b"AIFF" | b"AIFC")
    } else {
        &header[..4] != b"RIFF" || &header[8..] != b"WAVE"
    } {
        return Err("invalid audio container".into());
    }
    let mut quality = AudioQuality::default();
    let (mut channels, mut byte_rate, mut data_size, mut frames) = (0, 0, 0, 0);
    while let Ok(header) = read::<8>(file) {
        let length = if aiff {
            be32(&header[4..])
        } else {
            le32(&header[4..])
        };
        let start = seek(file, SeekFrom::Current(0))?;
        if (!aiff && &header[..4] == b"fmt ") || (aiff && &header[..4] == b"COMM") {
            // Go returns the previous probe on a truncated format chunk.
            if start + length as u64 > size as u64 {
                break;
            }
            let mut data = [0; 26];
            let count = length.min(data.len() as i64) as usize;
            if file.read_exact(&mut data[..count]).is_err() {
                break;
            }
            if aiff && length >= 18 {
                channels = i64::from(u16::from_be_bytes(data[..2].try_into().unwrap()));
                frames = be32(&data[2..6]);
                quality.bit_depth = i64::from(u16::from_be_bytes(data[6..8].try_into().unwrap()));
                let exponent = (i32::from(data[8] & 0x7f) << 8) | i32::from(data[9]);
                let mantissa = u64::from_be_bytes(data[10..18].try_into().unwrap());
                let sign = if data[8] & 0x80 == 0 { 1.0 } else { -1.0 };
                quality.sample_rate =
                    (sign * mantissa as f64 * 2.0_f64.powi(exponent - 16446) + 0.5) as i64;
            } else if !aiff && length >= 16 {
                channels = i64::from(u16::from_le_bytes(data[2..4].try_into().unwrap()));
                quality.sample_rate = le32(&data[4..8]);
                byte_rate = le32(&data[8..12]);
                quality.bit_depth = i64::from(u16::from_le_bytes(data[14..16].try_into().unwrap()));
                if data[..2] == [0xfe, 0xff] && length >= 26 {
                    let valid_bits =
                        i64::from(u16::from_le_bytes(data[18..20].try_into().unwrap()));
                    if valid_bits > 0 {
                        quality.bit_depth = valid_bits;
                    }
                }
            }
        } else if !aiff && &header[..4] == b"data" {
            data_size = length;
        }
        seek(
            file,
            SeekFrom::Start(start + length as u64 + (length & 1) as u64),
        )?;
    }
    if aiff {
        if quality.sample_rate > 0 && frames > 0 {
            quality.duration = frames / quality.sample_rate;
        }
    } else if byte_rate > 0 && data_size > 0 {
        quality.duration = data_size / byte_rate;
    } else if quality.sample_rate > 0 && channels > 0 && quality.bit_depth > 0 && data_size > 0 {
        let bytes_per_second = quality
            .sample_rate
            .wrapping_mul(channels)
            .wrapping_mul(quality.bit_depth)
            / 8;
        if bytes_per_second > 0 {
            quality.duration = data_size / bytes_per_second;
        }
    }
    Ok(quality)
}

fn read<const N: usize>(file: &mut impl Read) -> Result<[u8; N], String> {
    let mut data = [0; N];
    file.read_exact(&mut data).map_err(|e| e.to_string())?;
    Ok(data)
}

fn seek(file: &mut impl Seek, position: SeekFrom) -> Result<u64, String> {
    file.seek(position).map_err(|e| e.to_string())
}

fn be32(data: &[u8]) -> i64 {
    i64::from(u32::from_be_bytes(data.try_into().unwrap()))
}

fn le32(data: &[u8]) -> i64 {
    i64::from(u32::from_le_bytes(data.try_into().unwrap()))
}
