import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/utils/path_match_keys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native backup fixture matches actual complete HistoryDatabase codecs',
    () async {
      SharedPreferences.setMockInitialValues({});
      final factory = databaseFactoryOrNull;
      databaseFactory = databaseFactorySqflitePlugin;
      addTearDown(() => databaseFactory = factory);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const sqlite = MethodChannel('com.tekartik.sqflite');
      messenger.setMockMethodCallHandler(paths, (_) async => '/test/documents');
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
      addTearDown(() => messenger.setMockMethodCallHandler(sqlite, null));
      Map<String, dynamic>? encoded;
      messenger.setMockMethodCallHandler(sqlite, (call) async {
        final args = (call.arguments as Map?) ?? {};
        if (call.method == 'openDatabase') return {'id': 1};
        final sql = args['sql'] as String? ?? '';
        if (call.method == 'execute' && sql.contains('CREATE VIRTUAL TABLE')) {
          throw PlatformException(code: 'sqlite_error', message: 'no fts5');
        }
        if (call.method == 'batch') {
          for (final operation in args['operations'] as List) {
            final op = operation as Map;
            final statement = op['sql'] as String? ?? '';
            if (statement.startsWith('INSERT OR REPLACE INTO history (')) {
              final columnText = statement.substring(
                statement.indexOf('(') + 1,
                statement.indexOf(')'),
              );
              final columns = columnText
                  .split(',')
                  .map((value) => value.trim())
                  .toList();
              final values = op['arguments'] as List;
              final placeholders = statement
                  .substring(
                    statement.lastIndexOf('(') + 1,
                    statement.lastIndexOf(')'),
                  )
                  .split(',')
                  .map((value) => value.trim())
                  .toList();
              var argument = 0;
              encoded = {
                for (var i = 0; i < columns.length; i++)
                  columns[i]: placeholders[i] == '?'
                      ? values[argument++]
                      : null,
              };
            }
          }
          return null;
        }
        if (call.method != 'query') return null;
        if (sql.toLowerCase().contains('pragma user_version')) {
          return {
            'columns': ['user_version'],
            'rows': [
              [HistoryDatabase.schemaVersion],
            ],
          };
        }
        if (sql.startsWith('SELECT * FROM history ') && encoded != null) {
          return {
            'columns': encoded!.keys.toList(),
            'rows': [encoded!.values.toList()],
          };
        }
        return {'columns': <String>[], 'rows': <List<Object?>>[]};
      });

      final complete = DownloadHistoryItem(
        id: 'complete',
        trackName: '  CAFÉ İ ΑΣ ß  ',
        artistName: ' Artist ',
        albumName: ' Album ',
        albumArtist: ' Album Artist ',
        coverUrl: 'https://example.test/cover.jpg',
        originFilePath: 'network://nas/Artist/Album/Track.flac',
        filePath: 'content://nas.provider/tree/root/document/Ab%252FC.flac',
        storageMode: 'saf',
        downloadTreeUri: 'content://nas.provider/tree/root',
        safRelativeDir: 'Album',
        safFileName: 'Track.flac',
        safRepaired: true,
        service: 'provider',
        downloadedAt: DateTime.utc(2026, 10, 6, 12, 0, 0, 123, 456),
        isrc: ' us-aa-a26 00001 ',
        spotifyId: ' Spotify:Track:ABC ',
        trackNumber: 3,
        totalTracks: 10,
        discNumber: 2,
        totalDiscs: 3,
        duration: 240,
        releaseDate: ' 2026-10-01 ',
        quality: 'lossless',
        bitDepth: 24,
        sampleRate: 96000,
        bitrate: 3456,
        format: 'flac',
        genre: ' Rock ',
        composer: 'Composer',
        label: 'Label',
        copyright: 'Copyright',
        explicit: true,
        hasLyrics: true,
        lyricsMetadataScanVersion: 2,
        hasReplayGain: true,
        replayGainMetadataScanVersion: 1,
      ).toJson();
      final inputs = <Map<String, dynamic>>[
        complete,
        {
          ...complete,
          'id': 'empty-artist',
          'albumArtist': '',
          'isrc': 'ß-ﬃ\u00a0\ufeff',
          'spotifyId': null,
        },
        {
          ...complete,
          'id': 'numeric-flags',
          'explicit': 1,
          'safRepaired': 1,
          'hasLyrics': 1,
          'hasReplayGain': false,
          'replaygain_track_gain': ' -2.5 dB ',
          'lyricsMetadataScanVersion': 1.9,
        },
        {
          ...complete,
          'id': 'legacy',
          'hasLyrics': null,
          'lyricsMetadataScanVersion': null,
          'replayGainMetadataScanVersion': null,
          'downloadedAt': '20261006T120000.123456789z',
        },
        {
          ...complete,
          'id': 'overflow-date',
          'downloadedAt': '2026-10-32T25:61:00Z',
        },
        {
          ...complete,
          'id': 'short-time',
          'downloadedAt': '2026-10-06T00Z',
          'albumArtist': null,
        },
        {
          ...complete,
          'id': 'invalid-date',
          'downloadedAt': 'invalid',
          'hasReplayGain': false,
          'replaygain_album_gain': 'NaN',
          'filePath': '/Music/a%zz.flac',
        },
      ];
      final actual = <Map<String, dynamic>>[];
      for (final input in inputs) {
        encoded = null;
        await HistoryDatabase.instance.upsertBatch([input]);
        expect(encoded, isNotNull);
        final decoded = (await HistoryDatabase.instance.getAll()).single;
        actual.add({
          'input': input,
          'encoded': encoded,
          'decoded': decoded,
          'path_keys': buildPathMatchKeys(input['filePath'] as String).toList()
            ..sort(),
        });
      }
      final file = File('test/fixtures/native_backup_contract.json');
      if (const bool.fromEnvironment('NATIVE_BACKUP_CAPTURE')) {
        file.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(actual)}\n',
        );
      }
      expect(actual, jsonDecode(file.readAsStringSync()));
    },
  );
}
