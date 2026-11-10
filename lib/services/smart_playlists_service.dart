import 'dart:async';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/song_analysis_store.dart';
import 'package:mornye/services/song_features.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('SmartPlaylists');

enum SmartPlaylistType {
  recentlyAdded(
    id: 'smart_recently_added',
    title: 'Aggiunti di recente',
    subtitle: 'Gli ultimi brani aggiunti alla tua libreria',
  ),
  mostPlayed(
    id: 'smart_most_played',
    title: 'I più ascoltati',
    subtitle: 'I tuoi brani preferiti in base agli ascolti',
  ),
  bpmMix(
    id: 'smart_bpm_mix',
    title: 'BPM Mix Energetico',
    subtitle: 'Brani ritmati con tempo ideale (120 - 135 BPM)',
  );

  const SmartPlaylistType({
    required this.id,
    required this.title,
    required this.subtitle,
  });

  final String id;
  final String title;
  final String subtitle;

  static SmartPlaylistType? fromId(String id) {
    for (final type in SmartPlaylistType.values) {
      if (type.id == id) return type;
    }
    return null;
  }
}

class SmartPlaylistsService {
  SmartPlaylistsService({
    LibraryDatabase? libraryDb,
    HistoryDatabase? historyDb,
    ListeningStatisticsStore? statsStore,
    SongAnalysisStore? analysisStore,
  }) : _libraryDb = libraryDb ?? LibraryDatabase.instance,
       _historyDb = historyDb ?? HistoryDatabase.instance,
       _statsStore = statsStore ?? ListeningStatisticsStore.instance,
       _analysisStore = analysisStore ?? SongAnalysisStore();

  static final instance = SmartPlaylistsService();

  final LibraryDatabase _libraryDb;
  final HistoryDatabase _historyDb;
  final ListeningStatisticsStore _statsStore;
  final SongAnalysisStore _analysisStore;

  /// Retrieves the tracks for the requested smart playlist.
  Future<List<Map<String, dynamic>>> loadTracks(
    SmartPlaylistType type, {
    int limit = 50,
  }) async {
    switch (type) {
      case SmartPlaylistType.recentlyAdded:
        return _getRecentlyAdded(limit: limit);
      case SmartPlaylistType.mostPlayed:
        return _getMostPlayed(limit: limit);
      case SmartPlaylistType.bpmMix:
        return _getBpmMix(limit: limit);
    }
  }

  /// Maps loaded rows into full [Track] objects for display in playlist screens.
  Future<List<Track>> getPlaylistTracks(
    SmartPlaylistType type, {
    int limit = 50,
  }) async {
    final rows = await loadTracks(type, limit: limit);
    return rows
        .map(
          (r) => Track(
            id: r['id']?.toString() ?? r['track_key']?.toString() ?? '',
            name:
                r['name']?.toString() ??
                r['trackName']?.toString() ??
                r['title']?.toString() ??
                '',
            artistName:
                r['artistName']?.toString() ??
                r['artist_name']?.toString() ??
                r['artist']?.toString() ??
                '',
            albumName:
                r['albumName']?.toString() ??
                r['album_name']?.toString() ??
                r['album']?.toString() ??
                '',
            albumArtist:
                r['albumArtist']?.toString() ?? r['album_artist']?.toString(),
            duration: (r['duration'] as num?)?.toInt() ?? 0,
            coverUrl:
                r['coverPath']?.toString() ??
                r['coverUrl']?.toString() ??
                r['cover_url']?.toString() ??
                r['artwork']?.toString(),
            source:
                r['source']?.toString() ?? r['sourceId']?.toString() ?? 'local',
            isrc: r['isrc']?.toString(),
          ),
        )
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _getRecentlyAdded({int limit = 50}) async {
    final results = <Map<String, dynamic>>[];
    final seenKeys = <String>{};

    try {
      final db = await _libraryDb.database;
      final rows = await db.query(
        LibraryDatabase.visibleLibraryView,
        orderBy: 'sort_added DESC, scanned_at DESC',
        limit: limit,
      );
      for (final r in rows.map(LibraryRowMapper.decode)) {
        final key = r['filePath']?.toString() ?? r['id']?.toString() ?? '';
        if (key.isNotEmpty && seenKeys.add(key)) {
          results.add({...r, 'source': 'local'});
        }
      }
    } catch (e) {
      _log.w('Library recently added query skipped/failed: $e');
    }

    try {
      final historyRows = await _historyDb.getAll(limit: limit);
      for (final r in historyRows) {
        final key = r['filePath']?.toString() ?? r['id']?.toString() ?? '';
        if (key.isNotEmpty && seenKeys.add(key)) {
          results.add({...r, 'source': r['source'] ?? 'downloaded'});
        }
      }
    } catch (e) {
      _log.w('History recently added query skipped/failed: $e');
    }

    results.sort((a, b) {
      final aAdded =
          (a['sort_added'] as num?)?.toInt() ??
          (a['scanned_at'] != null
              ? DateTime.tryParse(
                  a['scanned_at'].toString(),
                )?.millisecondsSinceEpoch
              : 0) ??
          0;
      final bAdded =
          (b['sort_added'] as num?)?.toInt() ??
          (b['scanned_at'] != null
              ? DateTime.tryParse(
                  b['scanned_at'].toString(),
                )?.millisecondsSinceEpoch
              : 0) ??
          0;
      return bAdded.compareTo(aAdded);
    });

    return results.take(limit).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _getMostPlayed({int limit = 50}) async {
    try {
      final statsDb = await _statsStore.database;
      final topKeys = await statsDb.rawQuery(
        '''
        SELECT track_key, title, artist, album, artwork, SUM(plays) as total_plays
        FROM listening
        GROUP BY track_key
        HAVING total_plays > 0
        ORDER BY total_plays DESC
        LIMIT ?
      ''',
        [limit],
      );

      if (topKeys.isEmpty) {
        return await _getRecentlyAdded(limit: limit);
      }

      final results = <Map<String, dynamic>>[];
      final seen = <String>{};

      for (final row in topKeys) {
        final trackKey = row['track_key']?.toString() ?? '';
        final title = row['title']?.toString() ?? '';
        final artist = row['artist']?.toString() ?? '';

        Map<String, dynamic>? matchedTrack;

        if (trackKey.isNotEmpty) {
          try {
            final libDb = await _libraryDb.database;
            final libRows = await libDb.query(
              LibraryDatabase.visibleLibraryView,
              where: 'file_path = ? OR id = ?',
              whereArgs: [trackKey, trackKey],
              limit: 1,
            );
            if (libRows.isNotEmpty) {
              matchedTrack = {
                ...LibraryRowMapper.decode(libRows.first),
                'source': 'local',
              };
            }
          } catch (_) {}
        }

        if (matchedTrack == null && trackKey.isNotEmpty) {
          try {
            matchedTrack = await _historyDb.findByFilePath(trackKey);
            if (matchedTrack != null) {
              matchedTrack['source'] = matchedTrack['source'] ?? 'downloaded';
            }
          } catch (_) {}
        }

        if (matchedTrack == null && title.isNotEmpty && artist.isNotEmpty) {
          try {
            matchedTrack = await _historyDb.findByTrackAndArtist(title, artist);
            if (matchedTrack != null) {
              matchedTrack['source'] = matchedTrack['source'] ?? 'downloaded';
            }
          } catch (_) {}
        }

        matchedTrack ??= {
          'id': trackKey,
          'trackName': title,
          'artistName': artist,
          'albumName': row['album']?.toString() ?? '',
          'coverPath': row['artwork']?.toString(),
          'source': 'local',
        };

        final dedup =
            '${matchedTrack['trackName']}|${matchedTrack['artistName']}';
        if (seen.add(dedup)) {
          results.add(matchedTrack);
        }
      }

      if (results.isEmpty) {
        return await _getRecentlyAdded(limit: limit);
      }
      return results.take(limit).toList(growable: false);
    } catch (e) {
      _log.w('Failed to query most played tracks: $e');
      return await _getRecentlyAdded(limit: limit);
    }
  }

  Future<List<Map<String, dynamic>>> _getBpmMix({
    int limit = 50,
    double minBpm = 120.0,
    double maxBpm = 135.0,
  }) async {
    try {
      final analysisDb = await _analysisStore.database;
      final rows = await analysisDb.query(
        'song_features',
        columns: ['path', 'features'],
        where: 'features IS NOT NULL',
        limit: 500,
      );

      final matchingPaths = <String>[];
      for (final row in rows) {
        final blob = row['features'];
        final features = SongFeatures.decode(blob);
        if (features != null) {
          final bpm = features[SongFeatures.tempo];
          if (bpm >= minBpm && bpm <= maxBpm) {
            final path = row['path']?.toString();
            if (path != null && path.isNotEmpty) {
              matchingPaths.add(path);
              if (matchingPaths.length >= limit) break;
            }
          }
        }
      }

      if (matchingPaths.isEmpty) {
        return await _getRecentlyAdded(limit: limit);
      }

      final results = <Map<String, dynamic>>[];
      for (final path in matchingPaths) {
        Map<String, dynamic>? track;
        try {
          final libDb = await _libraryDb.database;
          final libRows = await libDb.query(
            LibraryDatabase.visibleLibraryView,
            where: 'file_path = ?',
            whereArgs: [path],
            limit: 1,
          );
          if (libRows.isNotEmpty) {
            track = {
              ...LibraryRowMapper.decode(libRows.first),
              'source': 'local',
            };
          }
        } catch (_) {}

        if (track == null) {
          try {
            track = await _historyDb.findByFilePath(path);
            if (track != null) {
              track['source'] = track['source'] ?? 'downloaded';
            }
          } catch (_) {}
        }

        if (track != null) {
          results.add(track);
        }
      }

      if (results.isEmpty) {
        return await _getRecentlyAdded(limit: limit);
      }
      return results.take(limit).toList(growable: false);
    } catch (e) {
      _log.w('Failed to query BPM mix tracks: $e');
      return await _getRecentlyAdded(limit: limit);
    }
  }
}
