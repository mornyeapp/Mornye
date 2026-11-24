use super::{AudioMetadata, CoverArt, bytes, seek, truthy, utf8};
use crate::matching::uppercase;
use std::io::{Read, Seek, SeekFrom};

#[derive(Clone, Copy)]
struct Atom {
    payload: u64,
    end: u64,
    kind: [u8; 4],
}

struct Reader<'a, R> {
    file: &'a mut R,
    size: u64,
}

pub(super) fn read(file: &mut (impl Read + Seek)) -> Result<AudioMetadata, String> {
    read_inner(file, None)
}

pub(super) fn read_with_cover(
    file: &mut (impl Read + Seek),
    cover: &mut Option<CoverArt>,
) -> Result<AudioMetadata, String> {
    read_inner(file, Some(cover))
}

fn read_inner(
    file: &mut (impl Read + Seek),
    mut cover: Option<&mut Option<CoverArt>>,
) -> Result<AudioMetadata, String> {
    let size = seek(file, SeekFrom::End(0))?;
    let mut reader = Reader { file, size };
    let ilst = reader.ilst()?;
    let mut metadata = AudioMetadata::default();
    let mut position = ilst.payload;
    while position.saturating_add(8) <= ilst.end {
        let atom = reader.atom(position, ilst.end)?;
        match &atom.kind {
            b"\xa9nam" => metadata.title = reader.text(atom),
            b"\xa9ART" => metadata.artist = reader.text(atom),
            b"\xa9alb" => metadata.album = reader.text(atom),
            b"aART" => metadata.album_artist = reader.text(atom),
            b"\xa9day" => {
                metadata.date = reader.text(atom);
                metadata.year = metadata.date.clone();
            }
            b"\xa9gen" => metadata.genre = reader.text(atom),
            b"\xa9wrt" => metadata.composer = reader.text(atom),
            b"\xa9cmt" => metadata.comment = reader.text(atom),
            b"cprt" => metadata.copyright = reader.text(atom),
            b"\xa9lyr" => metadata.lyrics = reader.text(atom),
            b"trkn" => (metadata.track_number, metadata.total_tracks) = reader.pair(atom),
            b"disk" => (metadata.disc_number, metadata.total_discs) = reader.pair(atom),
            b"rtng" => {
                if let Ok(data) = reader.data(atom)
                    && let Some(value) = data.last()
                {
                    metadata.explicit = *value == 1;
                }
            }
            b"cpil" => {
                if let Ok(data) = reader.data(atom)
                    && data.last().is_some_and(|value| *value != 0)
                    && metadata.album_type.is_empty()
                {
                    metadata.album_type = "compilation".into();
                }
            }
            b"----" => {
                if let Ok((name, value)) = reader.freeform(atom) {
                    apply(&mut metadata, &name, value);
                }
            }
            b"covr" => {
                if let Some(slot) = cover.as_deref_mut()
                    && slot.is_none()
                    && let Ok(art) = reader.cover_from_atom(atom)
                {
                    *slot = Some(art);
                }
            }
            _ => {}
        }
        position = atom.end;
    }
    if metadata == AudioMetadata::default() {
        Err("no M4A tags found".into())
    } else {
        Ok(metadata)
    }
}

pub(super) fn cover(file: &mut (impl Read + Seek)) -> Result<CoverArt, String> {
    let size = seek(file, SeekFrom::End(0))?;
    let mut reader = Reader { file, size };
    let ilst = reader.ilst()?;
    let cover = reader
        .find(ilst.payload, ilst.end, b"covr")
        .ok()
        .flatten()
        .ok_or("cover atom not found")?;
    reader.cover_from_atom(cover)
}

impl<R: Read + Seek> Reader<'_, R> {
    fn cover_from_atom(&mut self, cover: Atom) -> Result<CoverArt, String> {
        let data = self
            .find(cover.payload, cover.end, b"data")
            .ok()
            .flatten()
            .ok_or("data atom not found in cover")?;
        if data.end <= data.payload + 8 {
            return Err("empty cover data".into());
        }
        let data = self.payload(data, 8)?;
        let mime = if data.len() >= 8 && data.starts_with(b"\x89PNG") {
            "image/png"
        } else {
            "image/jpeg"
        };
        Ok(CoverArt {
            data,
            mime: mime.into(),
        })
    }

    fn ilst(&mut self) -> Result<Atom, String> {
        let moov = self
            .find(0, self.size, b"moov")
            .ok()
            .flatten()
            .ok_or("moov not found")?;
        let mut ilst = None;
        if let Ok(Some(udta)) = self.find(moov.payload, moov.end, b"udta") {
            ilst = self.metadata(udta);
        }
        ilst.or_else(|| self.metadata(moov))
            .ok_or_else(|| "ilst not found (tried moov>udta>meta>ilst and moov>meta>ilst)".into())
    }
    fn atom(&mut self, offset: u64, end: u64) -> Result<Atom, String> {
        if offset.saturating_add(8) > self.size {
            return Err("unexpected EOF".into());
        }
        seek(self.file, SeekFrom::Start(offset))?;
        let header = bytes(self.file, 8)?;
        let kind: [u8; 4] = header[4..].try_into().unwrap();
        let mut length = u64::from(u32::from_be_bytes(header[..4].try_into().unwrap()));
        let mut header_size = 8;
        if length == 1 {
            length = u64::from_be_bytes(bytes(self.file, 8)?.try_into().unwrap());
            header_size = 16;
        } else if length == 0 {
            length = end.saturating_sub(offset);
        }
        if length < header_size || length > i64::MAX as u64 || offset.checked_add(length).is_none()
        {
            return Err(format!("invalid atom size for {}", utf8(&kind)));
        }
        Ok(Atom {
            payload: offset + header_size,
            end: offset + length,
            kind,
        })
    }

    fn find(&mut self, mut offset: u64, end: u64, kind: &[u8; 4]) -> Result<Option<Atom>, String> {
        while offset.saturating_add(8) <= end {
            let atom = self.atom(offset, end)?;
            if &atom.kind == kind {
                return Ok(Some(atom));
            }
            offset = atom.end;
        }
        Ok(None)
    }

    fn metadata(&mut self, parent: Atom) -> Option<Atom> {
        let meta = self.find(parent.payload, parent.end, b"meta").ok()??;
        self.find(meta.payload + 4, meta.end, b"ilst")
            .ok()
            .flatten()
            .or_else(|| self.find(meta.payload, meta.end, b"ilst").ok().flatten())
    }

    fn payload(&mut self, atom: Atom, prefix: u64) -> Result<Vec<u8>, String> {
        let start = atom.payload + prefix;
        let length = atom.end.checked_sub(start).ok_or("invalid atom payload")?;
        // Bound selected metadata and artwork, including malformed 64-bit
        // declarations on 32-bit Android. Unknown atoms are skipped.
        if length == 0 || length > 32 * 1024 * 1024 || atom.end > self.size {
            return Err("invalid atom payload".into());
        }
        seek(self.file, SeekFrom::Start(start))?;
        bytes(self.file, length as usize)
    }

    fn data(&mut self, parent: Atom) -> Result<Vec<u8>, String> {
        let atom = self
            .find(parent.payload, parent.end, b"data")?
            .ok_or("data atom not found")?;
        self.payload(atom, 8)
    }

    fn text(&mut self, atom: Atom) -> String {
        self.data(atom).map(|data| text(&data)).unwrap_or_default()
    }

    fn pair(&mut self, atom: Atom) -> (i64, i64) {
        if let Ok(data) = self.data(atom)
            && data.len() >= 6
        {
            (
                i64::from(u16::from_be_bytes(data[2..4].try_into().unwrap())),
                i64::from(u16::from_be_bytes(data[4..6].try_into().unwrap())),
            )
        } else {
            (0, 0)
        }
    }

    fn freeform(&mut self, parent: Atom) -> Result<(String, String), String> {
        let mut offset = parent.payload;
        let mut name = String::new();
        let mut value = String::new();
        while offset.saturating_add(8) <= parent.end {
            let atom = self.atom(offset, parent.end)?;
            if atom.kind == *b"name"
                && let Ok(data) = self.payload(atom, 4)
            {
                name = text(&data);
            }
            if atom.kind == *b"data"
                && let Ok(data) = self.payload(atom, 8)
            {
                value = text(&data);
            }
            offset = atom.end;
        }
        if name.is_empty() || value.is_empty() {
            Err("freeform M4A tag incomplete".into())
        } else {
            Ok((name, value))
        }
    }
}

fn text(data: &[u8]) -> String {
    utf8(data).trim_end_matches('\0').trim().into()
}

fn apply(metadata: &mut AudioMetadata, name: &str, value: String) {
    match uppercase(name.trim()).as_str() {
        "ISRC" => metadata.isrc = value,
        "LABEL" | "ORGANIZATION" => metadata.label = value,
        "COMMENT" if metadata.comment.is_empty() => metadata.comment = value,
        "COMPOSER" if metadata.composer.is_empty() => metadata.composer = value,
        "COPYRIGHT" if metadata.copyright.is_empty() => metadata.copyright = value,
        "LYRICS" | "UNSYNCEDLYRICS" | "SYNCEDLYRICS" if metadata.lyrics.is_empty() => {
            metadata.lyrics = value
        }
        "REPLAYGAIN_TRACK_GAIN" => metadata.replay_gain_track_gain = value,
        "REPLAYGAIN_TRACK_PEAK" => metadata.replay_gain_track_peak = value,
        "REPLAYGAIN_ALBUM_GAIN" => metadata.replay_gain_album_gain = value,
        "REPLAYGAIN_ALBUM_PEAK" => metadata.replay_gain_album_peak = value,
        "ITUNESADVISORY" => metadata.explicit = truthy(&value),
        "RELEASETYPE" => metadata.album_type = value,
        "BARCODE" | "UPC" => metadata.upc = value,
        _ => {}
    }
}
