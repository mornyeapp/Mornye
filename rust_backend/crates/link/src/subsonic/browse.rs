//! Catalog endpoints: browsing (ID3 and folder style), album lists, genres,
//! random songs and search.

use super::objects::{self, put, put_some};
use super::{Failure, Payload, code, forward, number, page_offset, page_size, payload, required};
use crate::catalog::{Catalog, search_terms};
use crate::types::{Shared, SubsonicRequest};
use serde_json::{Map, Value, json};

/// Default page size of list endpoints without an explicit `size`.
const DEFAULT_LIST_SIZE: usize = 10;
/// Default per-kind result count of `search2`/`search3`.
const DEFAULT_SEARCH_SIZE: usize = 20;

pub(super) fn user(request: &SubsonicRequest) -> Payload {
    let username = request
        .param("username")
        .or_else(|| request.param("u"))
        .unwrap_or(request.device.name.as_str());
    payload(
        "user",
        json!({
            "username": username,
            "scrobblingEnabled": true,
            "adminRole": false,
            "settingsRole": false,
            "downloadRole": true,
            "uploadRole": false,
            "playlistRole": true,
            "coverArtRole": true,
            "commentRole": false,
            "podcastRole": false,
            "streamRole": true,
            "jukeboxRole": false,
            "shareRole": false,
            "videoConversionRole": false,
            "folder": [1],
        }),
    )
}

pub(super) fn indexes(catalog: &Catalog) -> Payload {
    payload(
        "indexes",
        json!({
            "lastModified": catalog.generated_ms(),
            "ignoredArticles": "",
            "index": artist_index(catalog),
        }),
    )
}

pub(super) fn artists(catalog: &Catalog) -> Payload {
    payload(
        "artists",
        json!({ "ignoredArticles": "", "index": artist_index(catalog) }),
    )
}

/// Album artists grouped by initial: `A` to `Z`, then `#` for the rest.
fn artist_index(catalog: &Catalog) -> Vec<Value> {
    let mut groups: Vec<(char, Vec<Value>)> = Vec::new();
    for &index in catalog.album_artists() {
        let initial = catalog
            .artist_sort_name(index)
            .chars()
            .next()
            .filter(char::is_ascii_alphabetic)
            .map_or('#', |c| c.to_ascii_uppercase());
        let artist = Value::Object(objects::artist(catalog, index));
        match groups.iter_mut().find(|(name, _)| *name == initial) {
            Some((_, members)) => members.push(artist),
            None => groups.push((initial, vec![artist])),
        }
    }
    groups.sort_by_key(|(name, _)| (*name == '#', *name));
    groups
        .into_iter()
        .map(|(name, artists)| json!({ "name": name.to_string(), "artist": artists }))
        .collect()
}

pub(super) fn artist(catalog: &Catalog, request: &SubsonicRequest) -> Result<Payload, Failure> {
    let id = required(request, "id")?;
    let index = catalog
        .artist_index(id)
        .ok_or_else(|| Failure::not_found("Artist"))?;
    let mut value = objects::artist(catalog, index);
    let albums = catalog.artists()[index]
        .browse_albums()
        .iter()
        .map(|album| Value::Object(objects::album_id3(catalog, *album)))
        .collect();
    put(&mut value, "album", Value::Array(albums));
    Ok(payload("artist", Value::Object(value)))
}

pub(super) fn album(catalog: &Catalog, request: &SubsonicRequest) -> Result<Payload, Failure> {
    let id = required(request, "id")?;
    let index = catalog
        .album_index(id)
        .ok_or_else(|| Failure::not_found("Album"))?;
    Ok(payload("album", objects::album_with_songs(catalog, index)))
}

pub(super) fn song(catalog: &Catalog, request: &SubsonicRequest) -> Result<Payload, Failure> {
    let id = required(request, "id")?;
    let index = catalog
        .song_index(id)
        .ok_or_else(|| Failure::not_found("Song"))?;
    Ok(payload("song", objects::song(catalog, index)))
}

/// Folder-style browsing: artist directories hold albums, album directories
/// hold songs.
pub(super) fn directory(catalog: &Catalog, request: &SubsonicRequest) -> Result<Payload, Failure> {
    let id = required(request, "id")?;
    let mut value = Map::new();
    if let Some(index) = catalog.artist_index(id) {
        let artist = &catalog.artists()[index];
        put(&mut value, "id", artist.id.as_str());
        put(&mut value, "name", artist.name.as_str());
        put(&mut value, "parent", "1");
        let children = artist
            .browse_albums()
            .iter()
            .map(|album| objects::album_dir(catalog, *album))
            .collect();
        put(&mut value, "child", Value::Array(children));
    } else if let Some(index) = catalog.album_index(id) {
        let album = &catalog.albums()[index];
        put(&mut value, "id", album.id.as_str());
        put(&mut value, "name", album.name.as_str());
        put(
            &mut value,
            "parent",
            catalog.artists()[album.artist].id.as_str(),
        );
        put_some(&mut value, "coverArt", catalog.album_cover_id(index));
        let children = album
            .songs
            .iter()
            .map(|song| objects::song(catalog, *song))
            .collect();
        put(&mut value, "child", Value::Array(children));
    } else {
        return Err(Failure::not_found("Directory"));
    }
    Ok(payload("directory", Value::Object(value)))
}

/// `getAlbumList` (legacy directories) and `getAlbumList2` (ID3).
pub(super) async fn album_list(
    shared: &Shared,
    catalog: &Catalog,
    request: &SubsonicRequest,
    id3: bool,
) -> Result<Payload, Failure> {
    let kind = required(request, "type")?;
    let size = page_size(request, "size", DEFAULT_LIST_SIZE);
    let offset = page_offset(request, "offset");
    let albums: Vec<usize> = match kind {
        "random" => sample(
            (0..catalog.albums().len()).collect(),
            size,
            &mut Random::new(),
        ),
        "newest" | "recent" | "frequent" | "highest" => page(catalog.albums_newest(), offset, size),
        "alphabeticalByName" => page(catalog.albums_by_name(), offset, size),
        "alphabeticalByArtist" => page(catalog.albums_by_artist(), offset, size),
        "byYear" => {
            let from =
                number::<i32>(request, "fromYear").ok_or_else(|| Failure::missing("fromYear"))?;
            let to = number::<i32>(request, "toYear").ok_or_else(|| Failure::missing("toYear"))?;
            page(&albums_by_year(catalog, from, to), offset, size)
        }
        "byGenre" => {
            let genre = required(request, "genre")?;
            let mut albums = catalog
                .genre(genre)
                .map(|genre| genre.albums.clone())
                .unwrap_or_default();
            albums.sort_by(|a, b| catalog.album_sort_name(*a).cmp(catalog.album_sort_name(*b)));
            page(&albums, offset, size)
        }
        "starred" => {
            let starred = forward::starred(shared, catalog, request).await?;
            page(&starred.albums, offset, size)
        }
        _ => {
            return Err(Failure::new(
                code::GENERIC,
                format!("Unsupported album list type: {kind}"),
            ));
        }
    };
    let items: Vec<Value> = albums
        .into_iter()
        .map(|album| {
            if id3 {
                Value::Object(objects::album_id3(catalog, album))
            } else {
                objects::album_dir(catalog, album)
            }
        })
        .collect();
    let key = if id3 { "albumList2" } else { "albumList" };
    Ok(payload(key, json!({ "album": items })))
}

/// Albums with a year in the range, ascending; a reversed range descends.
fn albums_by_year(catalog: &Catalog, from: i32, to: i32) -> Vec<usize> {
    let (low, high) = (from.min(to), from.max(to));
    let mut albums: Vec<usize> = catalog
        .albums_by_name()
        .iter()
        .copied()
        .filter(|album| {
            catalog.albums()[*album]
                .year
                .is_some_and(|year| (low..=high).contains(&year))
        })
        .collect();
    albums.sort_by_key(|album| catalog.albums()[*album].year);
    if from > to {
        albums.reverse();
    }
    albums
}

pub(super) fn random_songs(
    catalog: &Catalog,
    request: &SubsonicRequest,
) -> Result<Payload, Failure> {
    let size = page_size(request, "size", DEFAULT_LIST_SIZE);
    let from = number::<i32>(request, "fromYear");
    let to = number::<i32>(request, "toYear");
    let candidates: Vec<usize> = match request.param("genre").map(str::trim) {
        Some(name) if !name.is_empty() => catalog
            .genre(name)
            .map(|genre| genre.songs.clone())
            .unwrap_or_default(),
        _ => (0..catalog.songs().len()).collect(),
    };
    let candidates = if from.is_some() || to.is_some() {
        candidates
            .into_iter()
            .filter(|song| {
                catalog.songs()[*song].year.is_some_and(|year| {
                    from.is_none_or(|from| year >= from) && to.is_none_or(|to| year <= to)
                })
            })
            .collect()
    } else {
        candidates
    };
    let songs: Vec<Value> = sample(candidates, size, &mut Random::new())
        .into_iter()
        .map(|song| objects::song(catalog, song))
        .collect();
    Ok(payload("randomSongs", json!({ "song": songs })))
}

pub(super) fn genres(catalog: &Catalog) -> Payload {
    let mut genres: Vec<_> = catalog.genres().iter().collect();
    genres.sort_by_cached_key(|genre| crate::catalog::fold(&genre.name));
    let genres: Vec<Value> = genres
        .into_iter()
        .map(|genre| {
            json!({
                "value": genre.name,
                "songCount": genre.songs.len(),
                "albumCount": genre.albums.len(),
            })
        })
        .collect();
    payload("genres", json!({ "genre": genres }))
}

pub(super) fn songs_by_genre(
    catalog: &Catalog,
    request: &SubsonicRequest,
) -> Result<Payload, Failure> {
    let genre = required(request, "genre")?;
    let count = page_size(request, "count", DEFAULT_LIST_SIZE);
    let offset = page_offset(request, "offset");
    let songs: Vec<Value> = catalog
        .genre(genre)
        .map(|genre| page(&genre.songs, offset, count))
        .unwrap_or_default()
        .into_iter()
        .map(|song| objects::song(catalog, song))
        .collect();
    Ok(payload("songsByGenre", json!({ "song": songs })))
}

/// `search2` (legacy objects) and `search3` (ID3). An empty query, `""` or
/// `*` pages through everything.
pub(super) fn search(catalog: &Catalog, request: &SubsonicRequest, id3: bool) -> Payload {
    let terms = search_terms(request.param("query").unwrap_or(""));
    let artists: Vec<Value> = catalog
        .search_artists(&terms)
        .skip(page_offset(request, "artistOffset"))
        .take(page_size(request, "artistCount", DEFAULT_SEARCH_SIZE))
        .map(|artist| Value::Object(objects::artist(catalog, artist)))
        .collect();
    let albums: Vec<Value> = catalog
        .search_albums(&terms)
        .skip(page_offset(request, "albumOffset"))
        .take(page_size(request, "albumCount", DEFAULT_SEARCH_SIZE))
        .map(|album| {
            if id3 {
                Value::Object(objects::album_id3(catalog, album))
            } else {
                objects::album_dir(catalog, album)
            }
        })
        .collect();
    let songs: Vec<Value> = catalog
        .search_songs(&terms)
        .skip(page_offset(request, "songOffset"))
        .take(page_size(request, "songCount", DEFAULT_SEARCH_SIZE))
        .map(|song| objects::song(catalog, song))
        .collect();
    let key = if id3 {
        "searchResult3"
    } else {
        "searchResult2"
    };
    payload(
        key,
        json!({ "artist": artists, "album": albums, "song": songs }),
    )
}

/// `items[offset..offset + size]`, clamped.
pub(super) fn page(items: &[usize], offset: usize, size: usize) -> Vec<usize> {
    items.iter().skip(offset).take(size).copied().collect()
}

/// Up to `count` distinct items in random order (partial Fisher-Yates).
pub(super) fn sample(mut items: Vec<usize>, count: usize, random: &mut Random) -> Vec<usize> {
    let count = count.min(items.len());
    for slot in 0..count {
        let pick = slot + random.below(items.len() - slot);
        items.swap(slot, pick);
    }
    items.truncate(count);
    items
}

/// SplitMix64, seeded from the OS. Shuffling needs no cryptographic quality.
pub(super) struct Random(u64);

impl Random {
    pub(super) fn new() -> Self {
        let seed = getrandom::u64().unwrap_or_else(|_| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0x9e37_79b9_7f4a_7c15, |elapsed| elapsed.as_nanos() as u64)
        });
        Self(seed)
    }

    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    /// A value in `0..bound` (`bound` > 0).
    fn below(&mut self, bound: usize) -> usize {
        (self.next() % bound as u64) as usize
    }
}
