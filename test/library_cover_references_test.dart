import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/listening_statistics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'covers named by playlists, sessions, statistics and history survive the prune',
    () async {
      final root = await Directory.systemTemp.createTemp('cover-references-');
      addTearDown(() => root.delete(recursive: true));
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      final previousFactory = databaseFactoryOrNull;
      databaseFactory = databaseFactoryFfi;
      addTearDown(() => databaseFactory = previousFactory);
      messenger.setMockMethodCallHandler(paths, (_) async => root.path);
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));

      final covers = await Directory('${root.path}/library_covers').create();
      Future<File> cover(String name) async {
        final file = await File('${covers.path}/$name').writeAsBytes([1]);
        await file.setLastModified(DateTime(2024));
        return file;
      }

      final subsonic = 'subsonic_${'a' * 64}';
      final retained = [
        await cover('cover_playlist.jpg'),
        await cover('cover_loved.jpg'),
        await cover('cover_session.jpg'),
        await cover('${subsonic}_${'b' * 48}.image'),
        await cover('$subsonic.image.current'),
        await cover('network_cover_history.image'),
        await cover('${subsonic}_${'b' * 48}.image.etag'),
      ];
      final orphans = [
        await cover('cover_orphan.jpg'),
        await cover('$subsonic.image'),
        await cover('$subsonic.image.etag'),
        await cover('cover_playlist.jpg.etag'),
      ];

      final collections = await LibraryCollectionsDatabase.instance.database;
      await collections.insert('playlists', {
        'id': 'mix',
        'name': 'Mix',
        'created_at': '2026-10-30',
        'updated_at': '2026-10-30',
      });
      await collections.insert('playlist_tracks', {
        'playlist_id': 'mix',
        'track_key': 'one',
        'track_json': jsonEncode({'coverUrl': retained[0].path}),
        'added_at': '2026-10-30',
      });
      // An older iOS container and a file URI still name today's file.
      await collections.insert('loved_tracks', {
        'track_key': 'two',
        'track_json': jsonEncode({
          'coverUrl':
              'file:///var/mobile/Containers/Data/Application/OLD/Library/'
              'Application%20Support/library_covers/cover_loved.jpg',
        }),
        'added_at': '2026-10-30',
      });
      final appState = await AppStateDatabase.instance.database;
      await appState.insert('playback_session', {
        'id': 1,
        'media_json': jsonEncode([
          {'artUri': Uri.file(retained[2].path).toString()},
        ]),
        'updated_at': '2026-10-30',
      });
      final statistics = await ListeningStatisticsStore.instance.database;
      await statistics.insert('listening', {
        'day': '2026-10-30',
        'track_key': 'three',
        'title': 'Three',
        'artist': 'Artist',
        'album': 'Album',
        'artwork': Uri.file(retained[3].path).toString(),
      });
      final history = await HistoryDatabase.instance.database;
      await history.insert('history', {
        'id': 'saved',
        'track_name': 'Saved',
        'artist_name': 'Artist',
        'album_name': 'Album',
        'cover_url': retained[5].path,
        'file_path': '/music/saved.flac',
        'service': 'link',
        'downloaded_at': '2026-10-30',
      });

      final deleted = await pruneUnreferencedLibraryCovers(
        covers,
        const {},
        referenceColumns: await appLibraryCoverReferenceColumns(),
      );

      expect(deleted, orphans.length);
      for (final file in retained) {
        expect(await file.exists(), isTrue, reason: file.path);
      }
      for (final file in orphans) {
        expect(await file.exists(), isFalse, reason: file.path);
      }
    },
  );
}
