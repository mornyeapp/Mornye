use super::{AudioQuality, flac_quality, read_at};
use std::io::{Read, Seek, SeekFrom};

pub(crate) struct Reader<'a, R> {
    pub(crate) file: &'a mut R,
    pub(crate) size: u64,
    pub(crate) check: &'a dyn Fn() -> Result<(), String>,
}

#[derive(Clone, Copy)]
pub(crate) struct Atom {
    pub(crate) start: u64,
    pub(crate) end: u64,
    pub(crate) payload: u64,
    pub(crate) kind: [u8; 4],
}

pub(super) fn probe(
    file: &mut (impl Read + Seek),
    check: &dyn Fn() -> Result<(), String>,
) -> Result<AudioQuality, String> {
    let size = file.seek(SeekFrom::End(0)).map_err(|e| e.to_string())?;
    let mut reader = Reader { file, size, check };
    let moov = reader
        .find(0, size, b"moov")
        .map_err(|e| format!("failed to find moov atom: {e}"))?
        .ok_or("moov atom not found")?;
    let mut duration = reader
        .find(moov.payload, moov.end, b"mvhd")
        .ok()
        .flatten()
        .map_or(0, |atom| reader.duration(atom).unwrap_or(0));
    if duration <= 0 {
        let _ = reader.track_duration(moov.payload, moov.end, 0, &mut duration);
    }
    let (offset, kind) = reader.sample_entry(moov)?;
    let bytes = read_at::<32>(reader.file, offset)
        .map_err(|e| format!("failed to read audio sample entry: {e}"))?;
    let mut rate = u16::from_be_bytes(bytes[28..30].try_into().unwrap()) as i64;
    let mut depth = 0;
    if &kind == b"alac" || &kind == b"fLaC" {
        depth = u16::from_be_bytes(bytes[22..24].try_into().unwrap()) as i64;
        if let Some((bits, hz, samples)) = reader.specific_config(offset, &kind) {
            if bits > 0 {
                depth = bits;
            }
            if hz > 0 {
                rate = hz;
            }
            if samples > 0 && rate > 0 && duration <= 0 {
                duration = samples / rate;
            }
        }
    }
    (reader.check)()?;
    let bitrate = if duration > 0 {
        (size as f64 * 8.0 / duration as f64 / 1000.0).round() as i64
    } else {
        0
    };
    Ok(AudioQuality {
        bit_depth: depth,
        sample_rate: rate,
        duration,
        bitrate: if bitrate < 16 { 0 } else { bitrate },
        codec: match &kind {
            b"mp4a" => "aac",
            b"alac" => "alac",
            b"fLaC" => "flac",
            b"ec-3" => "eac3",
            b"ac-3" => "ac3",
            b"ac-4" => "ac4",
            b"Opus" => "opus",
            _ => unreachable!("recognized sample entry"),
        }
        .into(),
        // Go leaves total_samples zero for MP4, even when dfLa contains it.
        total_samples: 0,
    })
}

impl<R: Read + Seek> Reader<'_, R> {
    pub(crate) fn atom(&mut self, offset: u64, end: u64) -> Result<Atom, String> {
        (self.check)()?;
        if offset.checked_add(8).is_none_or(|value| value > self.size) {
            return Err("unexpected EOF".into());
        }
        let bytes = read_at::<8>(self.file, offset)?;
        let kind: [u8; 4] = bytes[4..8].try_into().unwrap();
        let mut size = u32::from_be_bytes(bytes[..4].try_into().unwrap()) as u64;
        let mut header = 8;
        if size == 1 {
            if offset.checked_add(16).is_none_or(|value| value > self.size) {
                return Err("unexpected EOF".into());
            }
            size = u64::from_be_bytes(read_at::<8>(self.file, offset + 8)?);
            header = 16;
        } else if size == 0 {
            size = end.saturating_sub(offset);
        }
        if size < header || offset.checked_add(size).is_none() || size > i64::MAX as u64 {
            return Err(format!(
                "invalid atom size for {}",
                String::from_utf8_lossy(&kind)
            ));
        }
        Ok(Atom {
            start: offset,
            end: offset + size,
            payload: offset + header,
            kind,
        })
    }

    fn find(&mut self, mut start: u64, end: u64, kind: &[u8; 4]) -> Result<Option<Atom>, String> {
        while start.checked_add(8).is_some_and(|value| value <= end) {
            let atom = self.atom(start, end)?;
            if &atom.kind == kind {
                return Ok(Some(atom));
            }
            start = atom.end;
        }
        Ok(None)
    }

    fn duration(&mut self, atom: Atom) -> Result<i64, String> {
        let version = read_at::<1>(self.file, atom.payload)?[0];
        let (scale, duration) = if version == 1 {
            let bytes = read_at::<32>(self.file, atom.payload)?;
            (
                u32::from_be_bytes(bytes[20..24].try_into().unwrap()),
                u64::from_be_bytes(bytes[24..32].try_into().unwrap()),
            )
        } else {
            let bytes = read_at::<20>(self.file, atom.payload)?;
            (
                u32::from_be_bytes(bytes[12..16].try_into().unwrap()),
                u32::from_be_bytes(bytes[16..20].try_into().unwrap()) as u64,
            )
        };
        Ok(if scale > 0 {
            (duration as f64 / scale as f64).round() as i64
        } else {
            0
        })
    }

    fn track_duration(
        &mut self,
        mut start: u64,
        end: u64,
        depth: usize,
        best: &mut i64,
    ) -> Result<(), String> {
        if depth >= 32 {
            return Err("MP4 nesting exceeds 32 levels".into());
        }
        while start.checked_add(8).is_some_and(|value| value <= end) {
            let atom = self.atom(start, end)?;
            match &atom.kind {
                b"mdhd" => *best = (*best).max(self.duration(atom).unwrap_or(0)),
                b"trak" | b"mdia" => {
                    self.track_duration(atom.payload, atom.end, depth + 1, best)?
                }
                _ => {}
            }
            start = atom.end;
        }
        Ok(())
    }

    // Walks the box tree so large udta/covr/stsz boxes are skipped by seeking;
    // the byte scan remains for files that nest entries unexpectedly.
    fn sample_entry(&mut self, atom: Atom) -> Result<(u64, [u8; 4]), String> {
        if let Ok(Some(found)) = self.find_sample_entry(atom.payload, atom.end, 0) {
            return Ok(found);
        }
        self.sample_entry_scan(atom)
    }

    fn find_sample_entry(
        &mut self,
        mut start: u64,
        end: u64,
        depth: usize,
    ) -> Result<Option<(u64, [u8; 4])>, String> {
        if depth >= 32 {
            return Ok(None);
        }
        while start.checked_add(8).is_some_and(|value| value <= end) {
            let atom = self.atom(start, end)?;
            match &atom.kind {
                b"mp4a" | b"alac" | b"fLaC" | b"ec-3" | b"ac-3" | b"ac-4" | b"Opus" => {
                    let absolute = atom.start + 4;
                    if absolute
                        .checked_add(32)
                        .is_none_or(|value| value > self.size)
                    {
                        return Err("audio info not found in M4A file".into());
                    }
                    return Ok(Some((absolute, atom.kind)));
                }
                b"trak" | b"mdia" | b"minf" | b"stbl" | b"dinf" => {
                    if let Some(found) =
                        self.find_sample_entry(atom.payload, atom.end, depth + 1)?
                    {
                        return Ok(Some(found));
                    }
                }
                b"stsd" => {
                    if let Some(children) = atom.payload.checked_add(8)
                        && children < atom.end
                        && let Some(found) =
                            self.find_sample_entry(children, atom.end, depth + 1)?
                    {
                        return Ok(Some(found));
                    }
                }
                _ => {}
            }
            start = atom.end;
        }
        Ok(None)
    }

    // Match Go's earliest recognized byte pattern, including chunk boundaries.
    // Do not load moov/mdat in full: some files put large covers in moov.
    fn sample_entry_scan(&mut self, atom: Atom) -> Result<(u64, [u8; 4]), String> {
        let mut offset = atom.start;
        let mut data = vec![0; 65536 + 3];
        let mut tail = 0;
        while offset < atom.end {
            (self.check)()?;
            let length = (atom.end - offset).min(65536) as usize;
            self.file
                .seek(SeekFrom::Start(offset))
                .map_err(|e| e.to_string())?;
            let n = self
                .file
                .read(&mut data[tail..tail + length])
                .map_err(|e| format!("failed to read M4A atom data: {e}"))?;
            if n == 0 {
                break;
            }
            for (index, bytes) in data[..tail + n].windows(4).enumerate() {
                if matches!(
                    bytes,
                    b"mp4a" | b"alac" | b"fLaC" | b"ec-3" | b"ac-3" | b"ac-4" | b"Opus"
                ) {
                    let absolute = offset - tail as u64 + index as u64;
                    if absolute
                        .checked_add(32)
                        .is_none_or(|value| value > self.size)
                    {
                        return Err("audio info not found in M4A file".into());
                    }
                    return Ok((absolute, bytes.try_into().unwrap()));
                }
            }
            let end = tail + n;
            tail = end.min(3);
            data.copy_within(end - tail..end, 0);
            offset += n as u64;
        }
        Err("audio info not found in M4A file".into())
    }

    fn specific_config(&mut self, offset: u64, kind: &[u8; 4]) -> Option<(i64, i64, i64)> {
        let entry = self.atom(offset.checked_sub(4)?, self.size).ok()?;
        let config = self
            .find(
                offset + 32,
                entry.end,
                if kind == b"alac" { b"alac" } else { b"dfLa" },
            )
            .ok()??;
        let size = config.end.saturating_sub(config.payload);
        // Go reads the entire config. Only these fixed fields are needed, and
        // malformed size declarations must not cause file-sized allocations.
        if config.end > self.size {
            return None;
        }
        if kind == b"alac" {
            if size < 24 {
                return None;
            }
            let bytes = read_at::<24>(self.file, config.payload).ok()?;
            let bits = bytes[5] as i64;
            let rate = u32::from_be_bytes(bytes[20..24].try_into().unwrap()) as i64;
            if bits > 0 && rate > 0 {
                return Some((bits, rate, 0));
            }
            if size < 28 {
                return None;
            }
            let bytes = read_at::<24>(self.file, config.payload + 4).ok()?;
            let bits = bytes[5] as i64;
            let rate = u32::from_be_bytes(bytes[20..24].try_into().unwrap()) as i64;
            return (bits > 0 && rate > 0).then_some((bits, rate, 0));
        }
        let mut position = config.payload + 4;
        while position
            .checked_add(4)
            .is_some_and(|value| value <= config.end)
        {
            (self.check)().ok()?;
            let bytes = read_at::<4>(self.file, position).ok()?;
            let length = u32::from_be_bytes([0, bytes[1], bytes[2], bytes[3]]) as u64;
            let next = position.checked_add(4 + length)?;
            if next > config.end {
                return None;
            }
            if bytes[0] & 0x7f == 0 && length >= 34 {
                let quality = flac_quality(&read_at::<34>(self.file, position + 4).ok()?);
                return Some((
                    quality.bit_depth,
                    quality.sample_rate,
                    quality.total_samples,
                ));
            }
            position = next;
        }
        None
    }
}
