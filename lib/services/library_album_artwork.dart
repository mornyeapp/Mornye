import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/album_artwork_match.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('AlbumArtwork');

/// What was found for one Library album, kept so a later run neither looks
/// it up again nor puts back artwork the user removed.
class AlbumArtworkRecord {
  const AlbumArtworkRecord({
    required this.albumKey,
    required this.matched,
    required this.checkedAt,
    this.providerId,
    this.albumId,
    this.coverUrl,
    this.motionUrl,
    this.coverFile,
    this.coverRemoved = false,
    this.motionSaved = false,
    this.motionRemoved = false,
  });

  final String albumKey;

  /// Whether a provider album matched. A record without a match stops the
  /// album from being looked up again for [AlbumArtworkJob.recheckAfter].
  final bool matched;
  final DateTime checkedAt;
  final String? providerId;
  final String? albumId;
  final String? coverUrl;
  final String? motionUrl;

  /// The cover saved for the album's songs that have none. Clearing the
  /// cover cache deletes it; [coverUrl] fetches it again without a search.
  final String? coverFile;

  /// The user removed the cover as wrong; runs leave the album alone.
  final bool coverRemoved;
  final bool motionSaved;
  final bool motionRemoved;

  AlbumArtworkRecord copyWith({
    String? coverFile,
    bool clearCoverFile = false,
    bool? coverRemoved,
    bool? motionSaved,
    bool? motionRemoved,
  }) => AlbumArtworkRecord(
    albumKey: albumKey,
    matched: matched,
    checkedAt: checkedAt,
    providerId: providerId,
    albumId: albumId,
    coverUrl: coverUrl,
    motionUrl: motionUrl,
    coverFile: clearCoverFile ? null : coverFile ?? this.coverFile,
    coverRemoved: coverRemoved ?? this.coverRemoved,
    motionSaved: motionSaved ?? this.motionSaved,
    motionRemoved: motionRemoved ?? this.motionRemoved,
  );

  Map<String, Object?> toRow() => {
    'album_key': albumKey,
    'matched': matched ? 1 : 0,
    'provider_id': providerId,
    'album_id': albumId,
    'cover_url': coverUrl,
    'motion_url': motionUrl,
    'cover_file': coverFile,
    'cover_removed': coverRemoved ? 1 : 0,
    'motion_saved': motionSaved ? 1 : 0,
    'motion_removed': motionRemoved ? 1 : 0,
    'checked_at': checkedAt.millisecondsSinceEpoch,
  };

  static AlbumArtworkRecord fromRow(Map<String, Object?> row) =>
      AlbumArtworkRecord(
        albumKey: row['album_key'] as String,
        matched: row['matched'] == 1,
        checkedAt: DateTime.fromMillisecondsSinceEpoch(
          (row['checked_at'] as num?)?.toInt() ?? 0,
        ),
        providerId: row['provider_id'] as String?,
        albumId: row['album_id'] as String?,
        coverUrl: row['cover_url'] as String?,
        motionUrl: row['motion_url'] as String?,
        coverFile: row['cover_file'] as String?,
        coverRemoved: row['cover_removed'] == 1,
        motionSaved: row['motion_saved'] == 1,
        motionRemoved: row['motion_removed'] == 1,
      );
}

class LibraryArtworkAlbum {
  const LibraryArtworkAlbum({
    required this.album,
    required this.hasCover,
    required this.artists,
  });

  final ArtworkAlbum album;

  /// Whether any of its songs has a cover, its own or a found one.
  final bool hasCover;

  /// Each song artist on the album. Players find an animated cover by the
  /// album and the playing song's artist.
  final List<String> artists;
}

/// Artwork found online for Library albums, kept in the app and never
/// written to the music files.
///
/// Covers are saved beside the scan's covers and set on the album's songs
/// that have no cover, so every screen, the player and Link show them as
/// they show embedded art. A scan clears a song's cover when the file has
/// none, so [apply] runs after each scan to set them again.
class LibraryAlbumArtworkStore {
  LibraryAlbumArtworkStore({
    required Future<Database> Function() database,
    required Future<Directory> Function() coverDirectory,
  }) : _database = database,
       _coverDirectory = coverDirectory;

  static const table = 'library_album_artwork';

  final Future<Database> Function() _database;
  final Future<Directory> Function() _coverDirectory;
  Future<void>? _ready;

  Future<Database> _open() async {
    final db = await _database();
    await (_ready ??= db
        .execute('''
          CREATE TABLE IF NOT EXISTS $table (
            album_key TEXT PRIMARY KEY,
            matched INTEGER NOT NULL DEFAULT 0,
            provider_id TEXT,
            album_id TEXT,
            cover_url TEXT,
            motion_url TEXT,
            cover_file TEXT,
            cover_removed INTEGER NOT NULL DEFAULT 0,
            motion_saved INTEGER NOT NULL DEFAULT 0,
            motion_removed INTEGER NOT NULL DEFAULT 0,
            checked_at INTEGER NOT NULL DEFAULT 0
          )''')
        .catchError((Object error) {
          _ready = null;
          throw error;
        }));
    return db;
  }

  /// The visible local albums, or only the one with [albumKey]. Network
  /// songs keep the covers their server gives them.
  Future<List<LibraryArtworkAlbum>> albums({String? albumKey}) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT album_key, MAX(album_name) AS album_name, '
      "MAX(COALESCE(NULLIF(TRIM(album_artist), ''), artist_name)) AS artist, "
      'COUNT(*) AS tracks, '
      "MIN(NULLIF(release_date, '')) AS release_date, "
      "MAX(CASE WHEN cover_path IS NOT NULL AND cover_path != '' "
      'THEN 1 ELSE 0 END) AS has_cover '
      'FROM ${LibrarySchema.visibleView} '
      "WHERE file_path NOT LIKE 'network://%' AND album_key IS NOT NULL "
      "AND TRIM(COALESCE(album_name, '')) != '' "
      '${albumKey == null ? '' : 'AND album_key = ? '}'
      'GROUP BY album_key',
      [?albumKey],
    );
    final artists = <String, List<String>>{};
    for (final row in await db.rawQuery(
      'SELECT DISTINCT album_key, artist_name '
      'FROM ${LibrarySchema.visibleView} '
      "WHERE file_path NOT LIKE 'network://%' AND album_key IS NOT NULL "
      '${albumKey == null ? '' : 'AND album_key = ? '}',
      [?albumKey],
    )) {
      final artist = (row['artist_name'] as String? ?? '').trim();
      if (artist.isEmpty) continue;
      artists.putIfAbsent(row['album_key'] as String, () => []).add(artist);
    }
    final albums = <LibraryArtworkAlbum>[];
    for (final row in rows) {
      final name = (row['album_name'] as String? ?? '').trim();
      final artist = (row['artist'] as String? ?? '').trim();
      if (_unknown.contains(artworkMatchText(name)) ||
          _unknown.contains(artworkMatchText(artist))) {
        continue;
      }
      albums.add(
        LibraryArtworkAlbum(
          album: ArtworkAlbum(
            key: row['album_key'] as String,
            album: name,
            artist: artist,
            trackCount: (row['tracks'] as num?)?.toInt() ?? 0,
            year: artworkYear(row['release_date'] as String?),
          ),
          hasCover: row['has_cover'] == 1,
          artists: artists[row['album_key']] ?? const [],
        ),
      );
    }
    return albums;
  }

  // Tags read from file names fall back to these; nothing can match them.
  static const _unknown = {'', 'unknown', 'unknown album', 'unknown artist'};

  Future<String?> albumKeyOf(String filePath) async {
    final db = await _open();
    final rows = await db.query(
      'library',
      columns: ['album_key'],
      where: 'file_path = ?',
      whereArgs: [filePath],
      limit: 1,
    );
    return rows.firstOrNull?['album_key'] as String?;
  }

  Future<Map<String, AlbumArtworkRecord>> records({String? albumKey}) async {
    final db = await _open();
    final rows = await db.query(
      table,
      where: albumKey == null ? null : 'album_key = ?',
      whereArgs: [?albumKey],
    );
    return {
      for (final row in rows)
        row['album_key'] as String: AlbumArtworkRecord.fromRow(row),
    };
  }

  Future<void> save(AlbumArtworkRecord record) async {
    final db = await _open();
    await db.insert(
      table,
      record.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Where a new cover for [albumKey] is saved. Each cover gets its own
  /// name, so image caches keyed by path never show the one it replaced.
  Future<String> newCoverPath(String albumKey, DateTime now) async {
    final directory = await _coverDirectory();
    await directory.create(recursive: true);
    final hash = sha1
        .convert(utf8.encode(albumKey))
        .toString()
        .substring(0, 16);
    return '${directory.path}/album_${hash}_'
        '${now.microsecondsSinceEpoch.toRadixString(36)}.jpg';
  }

  /// Sets each found cover on its album's songs that have none. A cover
  /// whose file is gone is dropped from its record and from those songs,
  /// so [AlbumArtworkJob.restore] can fetch it again. Returns the number of
  /// songs that changed.
  Future<int> apply() async {
    final db = await _open();
    final rows = await db.query(
      table,
      columns: ['album_key', 'cover_file'],
      where: 'cover_file IS NOT NULL AND cover_removed = 0',
    );
    final gone = <String, String>{};
    for (final row in rows) {
      final path = row['cover_file'] as String;
      if (!await File(path).exists()) gone[row['album_key'] as String] = path;
    }
    return sqlite.transactionWithBusyRetry(db, (txn) async {
      var changed = 0;
      for (final MapEntry(key: albumKey, value: path) in gone.entries) {
        await txn.update(
          table,
          {'cover_file': null},
          where: 'album_key = ?',
          whereArgs: [albumKey],
        );
        changed += await txn.update(
          'library',
          {'cover_path': null},
          where: 'cover_path = ?',
          whereArgs: [path],
        );
      }
      changed += await txn.rawUpdate(
        'UPDATE library SET cover_path = ('
        'SELECT a.cover_file FROM $table a '
        'WHERE a.album_key = library.album_key) '
        "WHERE (cover_path IS NULL OR cover_path = '') "
        "AND file_path NOT LIKE 'network://%' "
        'AND album_key IN (SELECT album_key FROM $table '
        'WHERE cover_file IS NOT NULL AND cover_removed = 0)',
      );
      return changed;
    });
  }

  /// Takes the found cover off [albumKey]'s songs and keeps runs from
  /// putting it back. Returns the record as it was.
  Future<AlbumArtworkRecord?> removeCover(String albumKey) async {
    final db = await _open();
    final record = (await records(albumKey: albumKey))[albumKey];
    if (record == null) return null;
    final file = record.coverFile;
    await sqlite.transactionWithBusyRetry(db, (txn) async {
      if (file != null) {
        await txn.update(
          'library',
          {'cover_path': null},
          where: 'cover_path = ?',
          whereArgs: [file],
        );
      }
      await txn.insert(
        table,
        record
            .copyWith(
              clearCoverFile: true,
              coverRemoved: true,
              motionSaved: false,
              motionRemoved: record.motionSaved || record.motionRemoved,
            )
            .toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    if (file != null) await deleteFileQuietly(File(file));
    return record;
  }
}

sealed class ArtworkLookup {
  const ArtworkLookup();
}

class ArtworkFound extends ArtworkLookup {
  const ArtworkFound(this.candidate, {this.coverUrl, this.motionUrl});

  final ArtworkCandidate candidate;
  final String? coverUrl;
  final String? motionUrl;
}

/// Every provider answered and none had the album.
class ArtworkNotFound extends ArtworkLookup {
  const ArtworkNotFound();
}

/// No provider answered, so nothing is known yet.
class ArtworkLookupFailed extends ArtworkLookup {
  const ArtworkLookupFailed();
}

/// Searches providers in order for an album, then reads the matched one's
/// details for its full-size cover and animated cover.
class AlbumArtworkLookup {
  const AlbumArtworkLookup({
    required this.providers,
    required this.search,
    required this.details,
  });

  /// Metadata provider IDs in the user's priority order.
  final List<String> providers;

  final Future<List<Map<String, dynamic>>> Function(
    String providerId,
    String query,
  )
  search;

  /// One provider album, as `getProviderMetadata` returns it.
  final Future<Map<String, dynamic>> Function(String providerId, String id)
  details;

  Future<ArtworkLookup> find(ArtworkAlbum album) async {
    var answered = false;
    for (final provider in providers) {
      final List<Map<String, dynamic>> results;
      try {
        results = await search(provider, '${album.artist} ${album.album}');
        answered = true;
      } catch (error) {
        _log.d('Album search failed on $provider: $error');
        continue;
      }
      final match = pickArtworkCandidate(album, [
        for (final result in results)
          ?ArtworkCandidate.fromSearchResult(provider, result),
      ]);
      if (match == null) continue;
      String? coverUrl;
      String? motionUrl;
      try {
        final result = await details(provider, match.albumId);
        final info = result['album_info'] is Map
            ? Map<String, dynamic>.from(result['album_info'] as Map)
            : result;
        String? url(Object? value) => normalizeArtworkUrl(value?.toString());
        coverUrl =
            url(info['cover_url'] ?? info['images']) ??
            url(result['cover_url']);
        motionUrl = url(info['header_video'] ?? result['header_video']);
      } catch (error) {
        _log.d('Album details failed on $provider: $error');
      }
      return ArtworkFound(
        match,
        coverUrl: coverUrl ?? match.coverUrl,
        motionUrl: motionUrl,
      );
    }
    return answered ? const ArtworkNotFound() : const ArtworkLookupFailed();
  }
}

class AlbumArtworkSummary {
  const AlbumArtworkSummary({
    this.albums = 0,
    this.covers = 0,
    this.motion = 0,
    this.failed = 0,
    this.songs = 0,
    this.cancelled = false,
  });

  /// Albums that needed something.
  final int albums;
  final int covers;
  final int motion;

  /// Albums no provider could be asked about.
  final int failed;

  final int songs;
  final bool cancelled;
}

/// Finds covers for Library albums without one, and animated covers, one
/// lookup per album instead of one per song, and keeps them in the app.
class AlbumArtworkJob {
  AlbumArtworkJob({
    required this.store,
    required this.lookup,
    required this.downloadCover,
    required this.hasMotion,
    required this.saveMotion,
    DateTime Function()? now,
    this.concurrency = 2,
  }) : _now = now ?? DateTime.now;

  /// How long an album without a match waits before it is looked up again,
  /// as providers add albums.
  static const recheckAfter = Duration(days: 30);

  final LibraryAlbumArtworkStore store;
  final AlbumArtworkLookup lookup;

  /// Saves the cover at a URL to a path, at most library cover size.
  final Future<bool> Function(String url, String path) downloadCover;

  final Future<bool> Function(LibraryArtworkAlbum album) hasMotion;

  final Future<bool> Function(LibraryArtworkAlbum album, String url) saveMotion;
  final DateTime Function() _now;
  final int concurrency;

  /// Looks up the albums that need a cover ([covers]) or an animated cover
  /// ([motion]). [albumKey] limits it to one album; [force] looks that one
  /// up again and lets back artwork the user removed.
  Future<AlbumArtworkSummary> run({
    required bool covers,
    required bool motion,
    String? albumKey,
    bool force = false,
    bool Function()? cancelled,
    void Function(int done, int total)? progress,
  }) async {
    final isCancelled = cancelled ?? () => false;
    final albums = await store.albums(albumKey: albumKey);
    final records = await store.records(albumKey: albumKey);
    final work = <({LibraryArtworkAlbum album, bool cover, bool motion})>[];
    for (final album in albums) {
      final record = records[album.album.key];
      final wantCover =
          covers && !album.hasCover && (force || record?.coverRemoved != true);
      final wantMotion =
          motion &&
          (force || record?.motionRemoved != true) &&
          !await hasMotion(album);
      if (wantCover || wantMotion) {
        work.add((album: album, cover: wantCover, motion: wantMotion));
      }
    }
    var done = 0;
    var foundCovers = 0;
    var foundMotion = 0;
    var failed = 0;
    progress?.call(0, work.length);
    var next = 0;
    Future<void> worker() async {
      while (next < work.length && !isCancelled()) {
        final item = work[next++];
        final outcome = await _process(
          item.album,
          records[item.album.album.key],
          cover: item.cover,
          motion: item.motion,
          force: force,
          cancelled: isCancelled,
        );
        if (outcome.failed) failed++;
        if (outcome.cover) foundCovers++;
        if (outcome.motion) foundMotion++;
        progress?.call(++done, work.length);
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
    final songs = await store.apply();
    return AlbumArtworkSummary(
      albums: work.length,
      covers: foundCovers,
      motion: foundMotion,
      failed: failed,
      songs: songs,
      cancelled: isCancelled(),
    );
  }

  Future<({bool cover, bool motion, bool failed})> _process(
    LibraryArtworkAlbum album,
    AlbumArtworkRecord? record, {
    required bool cover,
    required bool motion,
    required bool force,
    required bool Function() cancelled,
  }) async {
    final now = _now();
    final AlbumArtworkRecord? latest;
    if (record != null && !force && !_wantsLookup(record, now, cover, motion)) {
      latest = record;
    } else {
      latest = await _lookUp(album, record, now, force);
    }
    if (latest == null) return (cover: false, motion: false, failed: true);
    var current = latest;
    if (cancelled()) return (cover: false, motion: false, failed: false);
    var gotCover = false;
    var gotMotion = false;
    final coverUrl = current.coverUrl;
    if (cover && current.matched && coverUrl != null) {
      final path = await store.newCoverPath(album.album.key, now);
      try {
        if (await downloadCover(coverUrl, path) && await File(path).exists()) {
          final previous = current.coverFile;
          current = current.copyWith(coverFile: path, coverRemoved: false);
          await store.save(current);
          if (previous != null && previous != path) {
            await deleteFileQuietly(File(previous));
          }
          gotCover = true;
        }
      } catch (error) {
        _log.w('Could not save the cover for an album: $error');
      }
      if (!gotCover) await deleteFileQuietly(File(path));
    }
    final motionUrl = current.motionUrl;
    if (motion && current.matched && motionUrl != null && !cancelled()) {
      try {
        if (await saveMotion(album, motionUrl)) {
          await store.save(
            current.copyWith(motionSaved: true, motionRemoved: false),
          );
          gotMotion = true;
        }
      } catch (error) {
        _log.w('Could not save the animated cover for an album: $error');
      }
    }
    return (cover: gotCover, motion: gotMotion, failed: false);
  }

  /// A known album is looked up again only once its result is old and
  /// lacks what is wanted now: a match, a cover or an animated cover.
  bool _wantsLookup(
    AlbumArtworkRecord record,
    DateTime now,
    bool cover,
    bool motion,
  ) {
    if (now.difference(record.checkedAt) < recheckAfter) return false;
    return !record.matched ||
        (cover && record.coverUrl == null) ||
        (motion && record.motionUrl == null);
  }

  /// Looks [album] up and saves what was found, keeping what [record] had.
  /// Null when no provider could be asked.
  Future<AlbumArtworkRecord?> _lookUp(
    LibraryArtworkAlbum album,
    AlbumArtworkRecord? record,
    DateTime now,
    bool force,
  ) async {
    final result = await lookup.find(album.album);
    if (result is ArtworkLookupFailed) return null;
    final found = result is ArtworkFound ? result : null;
    final latest = AlbumArtworkRecord(
      albumKey: album.album.key,
      matched: found != null,
      checkedAt: now,
      providerId: found?.candidate.providerId,
      albumId: found?.candidate.albumId,
      coverUrl: found?.coverUrl,
      motionUrl: found?.motionUrl,
      coverFile: record?.coverFile,
      coverRemoved: !force && (record?.coverRemoved ?? false),
      motionSaved: record?.motionSaved ?? false,
      motionRemoved: !force && (record?.motionRemoved ?? false),
    );
    await store.save(latest);
    return latest;
  }

  /// Fetches again the found covers whose files are gone, as after clearing
  /// the cover cache, from their saved URLs and without a search. Returns
  /// the number of songs that changed.
  Future<int> restore({bool Function()? cancelled}) async {
    // [apply] first drops the covers whose file is gone, so their songs count
    // as without a cover below.
    var changed = await store.apply();
    final lacking = {
      for (final album in await store.albums())
        if (!album.hasCover) album.album.key,
    };
    var restored = false;
    for (final record in (await store.records()).values) {
      if (cancelled?.call() == true) break;
      final url = record.coverUrl;
      if (!record.matched ||
          record.coverRemoved ||
          record.coverFile != null ||
          url == null ||
          !lacking.contains(record.albumKey)) {
        continue;
      }
      final path = await store.newCoverPath(record.albumKey, _now());
      try {
        if (await downloadCover(url, path) && await File(path).exists()) {
          await store.save(record.copyWith(coverFile: path));
          restored = true;
          continue;
        }
      } catch (error) {
        _log.w('Could not restore the cover for an album: $error');
      }
      await deleteFileQuietly(File(path));
    }
    if (restored) changed += await store.apply();
    return changed;
  }
}

/// [value] when it is an http(s) URL.
String? normalizeArtworkUrl(String? value) {
  final url = value?.trim() ?? '';
  return url.startsWith('https://') || url.startsWith('http://') ? url : null;
}
