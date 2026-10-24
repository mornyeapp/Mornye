//! The song catalog the desktop app exports (contract section 5), indexed
//! into artists, albums and search. Owned by unit L1b.
//!
//! Ids follow contract section 4: songs keep the exported `id`, albums are
//! `al-` + 16 hex of SHA-256(albumKey) and artists `ar-` + 16 hex of
//! SHA-256([`normalize`]d name). A missing `albumKey` falls back to
//! `normalize(albumArtist or artist) + "|" + normalize(album)`.

mod parse;
#[cfg(test)]
mod tests;
mod text;

pub(crate) use text::{fold, hex, matches, normalize, search_terms, short_id};

use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

/// Album name shown when songs carry no album tag.
pub(crate) const UNKNOWN_ALBUM: &str = "Unknown Album";
/// Artist name shown when songs carry an empty artist.
pub(crate) const UNKNOWN_ARTIST: &str = "Unknown Artist";
/// Album artist for an album whose songs disagree and name no album artist.
pub(crate) const VARIOUS_ARTISTS: &str = "Various Artists";

/// The phone rejects longer song ids.
const MAX_ID_LEN: usize = 4096;
/// Upper bound for preallocation from the header's `count`.
const MAX_PREALLOCATE: usize = 1_000_000;

/// An indexed catalog snapshot. Immutable once loaded.
#[derive(Debug, Default)]
pub struct Catalog {
    generated_ms: i64,
    skipped: usize,
    songs: Vec<Song>,
    song_ids: HashMap<String, usize>,
    albums: Vec<Album>,
    album_ids: HashMap<String, usize>,
    artists: Vec<Artist>,
    artist_ids: HashMap<String, usize>,
    genres: Vec<Genre>,
    genre_keys: HashMap<String, usize>,
    /// Albums by folded name.
    albums_by_name: Vec<usize>,
    /// Albums by folded artist, then name.
    albums_by_artist: Vec<usize>,
    /// Albums by newest song first.
    albums_newest: Vec<usize>,
    /// Artists owning at least one album, by folded name.
    album_artists: Vec<usize>,
}

/// One exported song.
#[derive(Debug, Clone)]
pub(crate) struct Song {
    pub(crate) id: String,
    pub(crate) title: String,
    pub(crate) artist: String,
    pub(crate) album_artist: Option<String>,
    pub(crate) album_name: Option<String>,
    pub(crate) track: Option<u32>,
    pub(crate) disc: Option<u32>,
    pub(crate) year: Option<i32>,
    pub(crate) genre: Option<String>,
    pub(crate) duration_ms: Option<u64>,
    pub(crate) path: PathBuf,
    pub(crate) size: Option<u64>,
    /// Lowercase file extension, for example `flac`.
    pub(crate) suffix: String,
    /// Kilobits per second.
    pub(crate) bit_rate: Option<u32>,
    pub(crate) sample_rate: Option<u32>,
    pub(crate) bit_depth: Option<u32>,
    pub(crate) channels: Option<u32>,
    pub(crate) isrc: Option<String>,
    pub(crate) match_key: Option<String>,
    pub(crate) cover_path: Option<PathBuf>,
    pub(crate) added_ms: Option<i64>,
    pub(crate) track_gain: Option<f64>,
    pub(crate) album_gain: Option<f64>,
    pub(crate) track_peak: Option<f64>,
    pub(crate) album_peak: Option<f64>,
    pub(crate) explicit: bool,
    /// Index into the catalog's albums.
    pub(crate) album: usize,
    /// Index of the song artist into the catalog's artists.
    pub(crate) artist_ref: usize,
    /// Folded title, artist and album, separated by NUL.
    search: Box<str>,
    sort_title: Box<str>,
}

impl Song {
    /// Duration in whole seconds, rounded.
    pub(crate) fn duration_secs(&self) -> Option<u64> {
        self.duration_ms.map(|ms| (ms + 500) / 1000)
    }

    /// Bit rate in kbps: the exported value, else estimated from size and
    /// duration.
    pub(crate) fn source_kbps(&self) -> Option<u32> {
        self.bit_rate.or_else(|| {
            let size = self.size?;
            let ms = self.duration_ms.filter(|ms| *ms > 0)?;
            u32::try_from(size.saturating_mul(8) / ms).ok()
        })
    }
}

/// Songs grouped by album key.
#[derive(Debug, Clone)]
pub(crate) struct Album {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) artist_name: String,
    /// Index of the owning (album) artist.
    pub(crate) artist: usize,
    /// Song indexes by disc, track, then title.
    pub(crate) songs: Vec<usize>,
    /// The first song (in album order) with a cover.
    pub(crate) cover: Option<usize>,
    pub(crate) year: Option<i32>,
    pub(crate) genre: Option<String>,
    pub(crate) duration_secs: u64,
    /// Newest `addedMs` of its songs.
    pub(crate) added_ms: Option<i64>,
    search: Box<str>,
    sort_name: Box<str>,
}

/// An artist by normalized name.
#[derive(Debug, Clone)]
pub(crate) struct Artist {
    pub(crate) id: String,
    pub(crate) name: String,
    /// Albums this artist owns as album artist, by year then name.
    pub(crate) albums: Vec<usize>,
    /// Albums with at least one song by this artist.
    pub(crate) appears_on: Vec<usize>,
    /// The first owned (else appeared-on) album with a cover.
    pub(crate) cover_album: Option<usize>,
    /// Folded name, for sorting and search.
    sort_name: Box<str>,
}

impl Artist {
    /// Owned albums, or the albums it appears on when it owns none.
    pub(crate) fn browse_albums(&self) -> &[usize] {
        if self.albums.is_empty() {
            &self.appears_on
        } else {
            &self.albums
        }
    }
}

/// Songs sharing a genre (case-insensitive), in album order.
#[derive(Debug, Clone)]
pub(crate) struct Genre {
    pub(crate) name: String,
    pub(crate) songs: Vec<usize>,
    pub(crate) albums: Vec<usize>,
}

impl Catalog {
    /// A catalog with no songs, used before the first export.
    pub fn empty() -> Self {
        Self::default()
    }

    /// Reads and indexes the NDJSON export at `path`. Fails when the file or
    /// its header is unreadable; invalid song lines are skipped.
    pub fn load(path: &Path) -> Result<Self, String> {
        let file = File::open(path).map_err(|error| format!("catalog unreadable: {error}"))?;
        Self::read(BufReader::with_capacity(1 << 20, file))
    }

    /// Indexes an export from `reader`.
    pub(crate) fn read(mut reader: impl BufRead) -> Result<Self, String> {
        let mut line = Vec::with_capacity(1024);
        let read = reader
            .read_until(b'\n', &mut line)
            .map_err(|error| format!("catalog unreadable: {error}"))?;
        let first = trim_line(&line);
        let first = first.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(first);
        if read == 0 || first.is_empty() {
            return Err("catalog header is missing".to_owned());
        }
        let header = parse::header(first)?;
        let mut builder = Builder::new(header);
        loop {
            line.clear();
            let read = reader
                .read_until(b'\n', &mut line)
                .map_err(|error| format!("catalog unreadable: {error}"))?;
            if read == 0 {
                break;
            }
            let content = trim_line(&line);
            if content.is_empty() {
                continue;
            }
            match parse::row(content) {
                Some(row) => builder.add(row),
                None => builder.skipped += 1,
            }
        }
        Ok(builder.finish())
    }

    pub fn song_count(&self) -> usize {
        self.songs.len()
    }

    /// `generatedMs` from the export header.
    pub fn generated_ms(&self) -> i64 {
        self.generated_ms
    }

    /// Song lines skipped as invalid or duplicate.
    pub fn skipped_rows(&self) -> usize {
        self.skipped
    }

    pub(crate) fn songs(&self) -> &[Song] {
        &self.songs
    }

    pub(crate) fn albums(&self) -> &[Album] {
        &self.albums
    }

    pub(crate) fn artists(&self) -> &[Artist] {
        &self.artists
    }

    pub(crate) fn genres(&self) -> &[Genre] {
        &self.genres
    }

    pub(crate) fn song_index(&self, id: &str) -> Option<usize> {
        self.song_ids.get(id).copied()
    }

    pub(crate) fn album_index(&self, id: &str) -> Option<usize> {
        self.album_ids.get(id).copied()
    }

    pub(crate) fn artist_index(&self, id: &str) -> Option<usize> {
        self.artist_ids.get(id).copied()
    }

    /// The artist the app knows by `name`, so the app never derives ids.
    pub(crate) fn artist_index_by_name(&self, name: &str) -> Option<usize> {
        self.artist_index(&short_id("ar-", &normalize(name)))
    }

    pub(crate) fn song(&self, id: &str) -> Option<&Song> {
        self.song_index(id).map(|index| &self.songs[index])
    }

    pub(crate) fn genre(&self, name: &str) -> Option<&Genre> {
        self.genre_keys
            .get(&normalize(name))
            .map(|index| &self.genres[*index])
    }

    pub(crate) fn albums_by_name(&self) -> &[usize] {
        &self.albums_by_name
    }

    pub(crate) fn albums_by_artist(&self) -> &[usize] {
        &self.albums_by_artist
    }

    pub(crate) fn albums_newest(&self) -> &[usize] {
        &self.albums_newest
    }

    /// Artists owning at least one album, alphabetical.
    pub(crate) fn album_artists(&self) -> &[usize] {
        &self.album_artists
    }

    /// The `coverArt` id for a song: its album id when the album has a
    /// cover, else its own id when it has one.
    pub(crate) fn song_cover_id(&self, index: usize) -> Option<&str> {
        let song = &self.songs[index];
        let album = &self.albums[song.album];
        if album.cover.is_some() {
            Some(&album.id)
        } else if song.cover_path.is_some() {
            Some(&song.id)
        } else {
            None
        }
    }

    /// The `coverArt` id for an album.
    pub(crate) fn album_cover_id(&self, index: usize) -> Option<&str> {
        let album = &self.albums[index];
        album.cover.map(|_| album.id.as_str())
    }

    /// The `coverArt` id for an artist.
    pub(crate) fn artist_cover_id(&self, index: usize) -> Option<&str> {
        let artist = &self.artists[index];
        artist.cover_album.map(|_| artist.id.as_str())
    }

    /// The image file behind a `coverArt` id (album, artist or song id).
    pub(crate) fn cover_path(&self, id: &str) -> Option<&Path> {
        let album = if let Some(index) = self.album_index(id) {
            Some(index)
        } else if let Some(index) = self.artist_index(id) {
            self.artists[index].cover_album
        } else if let Some(song) = self.song(id) {
            if let Some(path) = &song.cover_path {
                return Some(path);
            }
            Some(song.album)
        } else {
            None
        };
        let song = self.albums[album?].cover?;
        self.songs[song].cover_path.as_deref()
    }

    /// Songs matching every term (title, artist or album), export order.
    pub(crate) fn search_songs<'a>(
        &'a self,
        terms: &'a [String],
    ) -> impl Iterator<Item = usize> + 'a {
        self.songs
            .iter()
            .enumerate()
            .filter(move |(_, song)| matches(&song.search, terms))
            .map(|(index, _)| index)
    }

    /// Albums matching every term (name or artist), alphabetical.
    pub(crate) fn search_albums<'a>(
        &'a self,
        terms: &'a [String],
    ) -> impl Iterator<Item = usize> + 'a {
        self.albums_by_name
            .iter()
            .copied()
            .filter(move |index| matches(&self.albums[*index].search, terms))
    }

    /// Album artists whose name matches every term, alphabetical.
    pub(crate) fn search_artists<'a>(
        &'a self,
        terms: &'a [String],
    ) -> impl Iterator<Item = usize> + 'a {
        self.album_artists
            .iter()
            .copied()
            .filter(move |index| matches(&self.artists[*index].sort_name, terms))
    }

    /// Artist sort key (folded name).
    pub(crate) fn artist_sort_name(&self, index: usize) -> &str {
        &self.artists[index].sort_name
    }

    /// Album sort key (folded name).
    pub(crate) fn album_sort_name(&self, index: usize) -> &str {
        &self.albums[index].sort_name
    }
}

fn trim_line(line: &[u8]) -> &[u8] {
    line.trim_ascii()
}

/// Builds the indexes from validated rows.
struct Builder {
    generated_ms: i64,
    skipped: usize,
    songs: Vec<Song>,
    song_ids: HashMap<String, usize>,
    /// Album key per song, parallel to `songs`.
    album_keys: Vec<String>,
}

impl Builder {
    fn new(header: parse::Header) -> Self {
        let capacity = header.count.min(MAX_PREALLOCATE);
        Self {
            generated_ms: header.generated_ms,
            skipped: 0,
            songs: Vec::with_capacity(capacity),
            song_ids: HashMap::with_capacity(capacity),
            album_keys: Vec::with_capacity(capacity),
        }
    }

    fn add(&mut self, row: parse::Row) {
        let (Some(id), Some(title), Some(artist), Some(path)) =
            (row.id, row.title, row.artist, row.path)
        else {
            self.skipped += 1;
            return;
        };
        let id = id.trim().to_owned();
        let path = path.trim().to_owned();
        if id.is_empty() || id.len() > MAX_ID_LEN || path.is_empty() {
            self.skipped += 1;
            return;
        }
        if self.song_ids.contains_key(&id) {
            self.skipped += 1;
            return;
        }
        self.song_ids.insert(id.clone(), self.songs.len());
        let path = PathBuf::from(path);
        let title = match title.trim() {
            "" => path
                .file_stem()
                .map(|stem| stem.to_string_lossy().into_owned())
                .unwrap_or_default(),
            title => title.to_owned(),
        };
        let artist = match artist.trim() {
            "" => UNKNOWN_ARTIST.to_owned(),
            artist => artist.to_owned(),
        };
        let album_artist = non_empty(row.album_artist);
        let album_name = non_empty(row.album);
        let album_key = non_empty(row.album_key).unwrap_or_else(|| {
            format!(
                "{}|{}",
                normalize(album_artist.as_deref().unwrap_or(&artist)),
                normalize(album_name.as_deref().unwrap_or(""))
            )
        });
        let suffix = non_empty(row.suffix)
            .or_else(|| {
                path.extension()
                    .map(|extension| extension.to_string_lossy().into_owned())
            })
            .unwrap_or_default()
            .trim_start_matches('.')
            .to_ascii_lowercase();
        let search = format!(
            "{}\0{}\0{}",
            fold(&title),
            fold(&artist),
            fold(album_name.as_deref().unwrap_or(""))
        );
        let sort_title = fold(&title);
        self.songs.push(Song {
            id,
            title,
            artist,
            album_artist,
            album_name,
            track: positive(row.track),
            disc: positive(row.disc),
            year: row
                .year
                .filter(|year| (1..=9999).contains(year))
                .and_then(|year| i32::try_from(year).ok()),
            genre: non_empty(row.genre),
            duration_ms: row.duration_ms.and_then(|ms| u64::try_from(ms).ok()),
            path,
            size: row.size.and_then(|size| u64::try_from(size).ok()),
            suffix,
            bit_rate: positive(row.bit_rate).map(kbps),
            sample_rate: positive(row.sample_rate),
            bit_depth: positive(row.bit_depth),
            channels: positive(row.channels),
            isrc: non_empty(row.isrc),
            match_key: non_empty(row.match_key),
            cover_path: non_empty(row.cover_path).map(PathBuf::from),
            added_ms: row.added_ms,
            track_gain: row.track_gain,
            album_gain: row.album_gain,
            track_peak: row.track_peak,
            album_peak: row.album_peak,
            explicit: row.explicit.unwrap_or(false),
            album: 0,
            artist_ref: 0,
            search: search.into_boxed_str(),
            sort_title: sort_title.into_boxed_str(),
        });
        self.album_keys.push(album_key);
    }

    fn finish(self) -> Catalog {
        let Builder {
            generated_ms,
            skipped,
            mut songs,
            song_ids,
            album_keys,
        } = self;

        // Albums in first-seen order.
        let mut albums: Vec<Album> = Vec::new();
        let mut album_ids: HashMap<String, usize> = HashMap::new();
        let mut album_of_key: HashMap<String, usize> = HashMap::new();
        for (index, key) in album_keys.into_iter().enumerate() {
            let album = match album_of_key.entry(key) {
                Entry::Occupied(entry) => *entry.get(),
                Entry::Vacant(entry) => {
                    let id = short_id("al-", entry.key());
                    let album = albums.len();
                    let song = &songs[index];
                    let name = song.album_name.as_deref().unwrap_or(UNKNOWN_ALBUM);
                    albums.push(Album {
                        id: id.clone(),
                        name: name.to_owned(),
                        artist_name: String::new(),
                        artist: 0,
                        songs: Vec::new(),
                        cover: None,
                        year: None,
                        genre: None,
                        duration_secs: 0,
                        added_ms: None,
                        search: Box::default(),
                        sort_name: fold(name).into_boxed_str(),
                    });
                    album_ids.entry(id).or_insert(album);
                    entry.insert(album);
                    album
                }
            };
            songs[index].album = album;
            albums[album].songs.push(index);
        }

        let mut artists: Vec<Artist> = Vec::new();
        let mut artist_ids: HashMap<String, usize> = HashMap::new();
        let mut artist_keys: HashMap<String, usize> = HashMap::new();
        let mut intern = |name: &str, artists: &mut Vec<Artist>| -> usize {
            let key = normalize(name);
            match artist_keys.entry(key) {
                Entry::Occupied(entry) => *entry.get(),
                Entry::Vacant(entry) => {
                    let id = short_id("ar-", entry.key());
                    let index = artists.len();
                    artists.push(Artist {
                        id: id.clone(),
                        name: name.to_owned(),
                        albums: Vec::new(),
                        appears_on: Vec::new(),
                        cover_album: None,
                        sort_name: fold(name).into_boxed_str(),
                    });
                    artist_ids.entry(id).or_insert(index);
                    entry.insert(index);
                    index
                }
            }
        };

        for (album_index, album) in albums.iter_mut().enumerate() {
            // Spellings come from export order, before the disc/track sort.
            let artist_name = album
                .songs
                .iter()
                .find_map(|index| songs[*index].album_artist.clone())
                .unwrap_or_else(|| {
                    let first = &songs[album.songs[0]].artist;
                    let first_key = normalize(first);
                    if album
                        .songs
                        .iter()
                        .all(|index| normalize(&songs[*index].artist) == first_key)
                    {
                        first.clone()
                    } else {
                        VARIOUS_ARTISTS.to_owned()
                    }
                });
            album.songs.sort_by(|a, b| {
                let (a_song, b_song) = (&songs[*a], &songs[*b]);
                (a_song.disc.unwrap_or(0), a_song.track.unwrap_or(u32::MAX))
                    .cmp(&(b_song.disc.unwrap_or(0), b_song.track.unwrap_or(u32::MAX)))
                    .then_with(|| a_song.sort_title.cmp(&b_song.sort_title))
                    .then_with(|| a.cmp(b))
            });
            let members = album.songs.iter().map(|index| &songs[*index]);
            album.cover = album
                .songs
                .iter()
                .copied()
                .find(|index| songs[*index].cover_path.is_some());
            album.year = members.clone().find_map(|song| song.year);
            album.genre = members.clone().find_map(|song| song.genre.clone());
            album.duration_secs = members.clone().filter_map(Song::duration_secs).sum();
            album.added_ms = members.clone().filter_map(|song| song.added_ms).max();
            album.search = format!("{}\0{}", album.sort_name, fold(&artist_name)).into_boxed_str();
            album.artist = intern(&artist_name, &mut artists);
            artists[album.artist].albums.push(album_index);
            album.artist_name = artist_name;
            for &song_index in &album.songs {
                let artist = intern(&songs[song_index].artist, &mut artists);
                songs[song_index].artist_ref = artist;
                let entry = &mut artists[artist];
                if entry.appears_on.last() != Some(&album_index) {
                    entry.appears_on.push(album_index);
                }
            }
        }

        for artist in &mut artists {
            artist.albums.sort_by(|a, b| {
                (
                    albums[*a].year.unwrap_or(0),
                    &albums[*a].sort_name,
                    &albums[*a].id,
                )
                    .cmp(&(
                        albums[*b].year.unwrap_or(0),
                        &albums[*b].sort_name,
                        &albums[*b].id,
                    ))
            });
            artist.cover_album = artist
                .browse_albums()
                .iter()
                .copied()
                .find(|album| albums[*album].cover.is_some());
        }

        let mut genres: Vec<Genre> = Vec::new();
        let mut genre_keys: HashMap<String, usize> = HashMap::new();
        for (album_index, album) in albums.iter().enumerate() {
            for &song_index in &album.songs {
                let Some(name) = songs[song_index].genre.as_deref() else {
                    continue;
                };
                let genre = *genre_keys.entry(normalize(name)).or_insert_with(|| {
                    genres.push(Genre {
                        name: name.to_owned(),
                        songs: Vec::new(),
                        albums: Vec::new(),
                    });
                    genres.len() - 1
                });
                let entry = &mut genres[genre];
                entry.songs.push(song_index);
                if entry.albums.last() != Some(&album_index) {
                    entry.albums.push(album_index);
                }
            }
        }

        let mut albums_by_name: Vec<usize> = (0..albums.len()).collect();
        albums_by_name.sort_by(|a, b| {
            (&albums[*a].sort_name, &albums[*a].id).cmp(&(&albums[*b].sort_name, &albums[*b].id))
        });
        let mut albums_by_artist = albums_by_name.clone();
        albums_by_artist.sort_by(|a, b| {
            artists[albums[*a].artist]
                .sort_name
                .cmp(&artists[albums[*b].artist].sort_name)
                .then_with(|| albums[*a].sort_name.cmp(&albums[*b].sort_name))
                .then_with(|| albums[*a].id.cmp(&albums[*b].id))
        });
        let mut albums_newest = albums_by_name.clone();
        albums_newest.sort_by(|a, b| albums[*b].added_ms.cmp(&albums[*a].added_ms));
        let mut album_artists: Vec<usize> = (0..artists.len())
            .filter(|index| !artists[*index].albums.is_empty())
            .collect();
        album_artists.sort_by(|a, b| {
            (&artists[*a].sort_name, &artists[*a].id)
                .cmp(&(&artists[*b].sort_name, &artists[*b].id))
        });

        Catalog {
            generated_ms,
            skipped,
            songs,
            song_ids,
            albums,
            album_ids,
            artists,
            artist_ids,
            genres,
            genre_keys,
            albums_by_name,
            albums_by_artist,
            albums_newest,
            album_artists,
        }
    }
}

fn non_empty(text: Option<String>) -> Option<String> {
    text.map(|text| text.trim().to_owned())
        .filter(|text| !text.is_empty())
}

fn positive(value: Option<i64>) -> Option<u32> {
    value
        .filter(|value| *value > 0)
        .and_then(|value| u32::try_from(value).ok())
}

/// The export should carry kbps; values beyond any real audio stream are
/// read as bits per second.
fn kbps(value: u32) -> u32 {
    if value > 40_000 { value / 1000 } else { value }
}
