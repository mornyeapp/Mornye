import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_reorganizer.dart';

import 'support/fixed_settings.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
  @override
  Future<void> ensureInitialized() async {}
}

/// Minimal stand-in for the native filename formatter.
String _format(String template, Map<String, dynamic> metadata) {
  return template.replaceAllMapped(RegExp(r'\{([a-z_]+)(?::(\d+))?\}'), (m) {
    final value = metadata[m[1]];
    if (value == null) return '';
    final width = int.tryParse(m[2] ?? '');
    return width == null ? '$value' : '$value'.padLeft(width, '0');
  });
}

Map<String, Object?> _historyRow(
  String id,
  String filePath, {
  required String title,
  String artist = 'Artist',
  String album = 'Album',
  int? trackNumber,
  int? totalTracks,
}) => {
  'id': id,
  'track_name': title,
  'artist_name': artist,
  'album_name': album,
  'file_path': filePath,
  'service': 'example',
  'downloaded_at': '2026-01-01T00:00:00.000Z',
  'track_number': trackNumber,
  'total_tracks': totalTracks,
};

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;

  late Directory root;
  late List<Map<String, Object?>> historyRows;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-reorganize-plan-');
    historyRows = [];
    addTearDown(() => root.delete(recursive: true));
  });

  // The queue and history databases are process-wide singletons, so the
  // platform fakes stay installed for the whole file.
  setUpAll(() async {
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactorySqflitePlugin;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    SharedPreferences.setMockInitialValues({
      'app_state_migrated_queue_to_sqlite_v1': true,
    });
    const backend = MethodChannel('com.zarz.mornye/backend');
    const sqlite = MethodChannel('com.tekartik.sqflite');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const notifications = MethodChannel(
      'dexterous.com/flutter/local_notifications',
    );
    const connectivity = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    const progress = MethodChannel('com.zarz.mornye/download_progress_stream');
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    messenger.setMockMethodCallHandler(connectivity, (_) async => null);
    messenger.setMockMethodCallHandler(progress, (_) async => null);
    messenger.setMockMethodCallHandler(
      notifications,
      (call) async => call.method == 'initialize' ? true : null,
    );
    final versions = <int, int>{};
    messenger.setMockMethodCallHandler(sqlite, (call) async {
      final args = (call.arguments as Map?) ?? {};
      if (call.method == 'openDatabase') {
        final id = versions.length + 1;
        versions[id] = (args['path'] as String).endsWith('history.db')
            ? HistoryDatabase.schemaVersion
            : 4;
        return {'id': id};
      }
      if (call.method == 'execute') {
        final sql = args['sql'] as String? ?? '';
        if (sql.contains('CREATE VIRTUAL TABLE')) {
          throw PlatformException(code: 'sqlite_error', message: 'no fts5');
        }
        return null;
      }
      if (call.method != 'query') return null;
      final sql = (args['sql'] as String? ?? '').toLowerCase();
      List<Map<String, Object?>> rows = const [];
      if (sql.contains('pragma user_version')) {
        rows = [
          {'user_version': versions[args['id']]},
        ];
      } else if (sql.startsWith('select * from history')) {
        final offset =
            int.tryParse(RegExp(r'offset (\d+)').firstMatch(sql)?[1] ?? '') ??
            0;
        rows = historyRows.skip(offset).toList();
      }
      final columns = <String>{for (final row in rows) ...row.keys}.toList();
      return {
        'columns': columns,
        'rows': [
          for (final row in rows) [for (final column in columns) row[column]],
        ],
      };
    });
    messenger.setMockMethodCallHandler(backend, (call) async {
      final args = call.arguments is Map
          ? call.arguments as Map
          : const <Object?, Object?>{};
      switch (call.method) {
        case 'buildFilename':
          return _format(
            args['template'] as String,
            (jsonDecode(args['metadata'] as String) as Map)
                .cast<String, dynamic>(),
          );
        case 'sanitizeFilename':
          return (args['filename'] as String).replaceAll(
            RegExp(r'[<>:"/\\|?*]'),
            ' ',
          );
      }
      return null;
    });
    addTearDown(() async {
      await (await AppStateDatabase.instance.database).close();
      for (final channel in [
        backend,
        sqlite,
        paths,
        notifications,
        connectivity,
        progress,
      ]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
      databaseFactory = previousFactory;
    });
  });

  Future<File> write(String relative) async {
    final file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    return file.writeAsString('audio');
  }

  Future<DownloadQueueNotifier> queueWith(AppSettings settings) async {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => FixedSettingsNotifier(settings)),
        extensionProvider.overrideWith(_Extensions.new),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    addTearDown(queue.flushQueuePersistence);
    return queue;
  }

  test(
    'files saved flat under an old rule are planned into the new layout',
    () async {
      final flat = await write('Song A - Artist.flac');
      final organized = await write('Artist/Album/Artist - Song B.flac');
      final outsideDir = await Directory.systemTemp.createTemp('outside-');
      addTearDown(() => outsideDir.delete(recursive: true));
      final outside = File(p.join(outsideDir.path, 'Song C - Artist.flac'));
      await outside.writeAsString('audio');
      historyRows = [
        _historyRow('a', flat.path, title: 'Song A', totalTracks: 10),
        _historyRow('a-copy', flat.path, title: 'Song A', totalTracks: 10),
        _historyRow('b', organized.path, title: 'Song B', totalTracks: 10),
        _historyRow('c', outside.path, title: 'Song C', totalTracks: 10),
        _historyRow(
          'gone',
          p.join(root.path, 'Gone - Artist.flac'),
          title: 'Gone',
          totalTracks: 10,
        ),
      ];

      final queue = await queueWith(
        AppSettings(
          downloadDirectory: root.path,
          folderOrganization: 'artist_album',
          filenameFormat: '{artist} - {title}',
        ),
      );
      final plan = await queue.planLibraryReorganization();

      expect(plan.safMode, isFalse);
      expect(plan.alreadyOrganized, 1);
      expect(plan.outsideDownloadFolder, 1);
      expect(plan.missing, 1);
      expect(plan.moves, hasLength(1));
      final move = plan.moves.single;
      expect(move.historyIds, ['a', 'a-copy']);
      expect(move.sourceDisplayPath, 'Song A - Artist.flac');
      expect(move.targetDisplayPath, 'Artist/Album/Artist - Song A.flac');

      final updated = <String, String>{};
      final result = await queue.applyLibraryReorganization(
        plan,
        reorganizer: LibraryReorganizer(
          updateHistoryPath:
              (
                id,
                newFilePath, {
                newSafFileName,
                newSafRelativeDir,
                required expectedFilePath,
              }) async {
                updated[id] = newFilePath;
                return true;
              },
          forgetLibraryPath: (_) async {},
        ),
      );
      final target = p.join(
        root.path,
        'Artist',
        'Album',
        'Artist - Song A.flac',
      );
      expect(result.moved, 1);
      expect(await File(target).exists(), isTrue);
      expect(await flat.exists(), isFalse);
      expect(updated, {'a': target, 'a-copy': target});
    },
  );

  test('the single filename rule applies to one-track releases', () async {
    final single = await write('Hit.flac');
    historyRows = [
      _historyRow('s', single.path, title: 'Hit', album: 'Hit', totalTracks: 1),
    ];
    final queue = await queueWith(
      AppSettings(
        downloadDirectory: root.path,
        filenameFormat: '{artist} - {album} - {title}',
        singleFilenameFormat: '{artist} - {title}',
      ),
    );
    final plan = await queue.planLibraryReorganization();
    expect(plan.moves.single.targetDisplayPath, 'Artist - Hit.flac');
  });

  test('separate-singles placement is kept for tracks whose release type is '
      'unknown', () async {
    // A 3-track EP that a provider reported as a single at download time.
    final ep = await write('Singles/EP Song - Artist.flac');
    historyRows = [
      _historyRow('ep', ep.path, title: 'EP Song', totalTracks: 3),
    ];
    final queue = await queueWith(
      AppSettings(
        downloadDirectory: root.path,
        separateSingles: true,
        filenameFormat: '{artist} - {title}',
        singleFilenameFormat: '{title} ({artist})',
      ),
    );
    final plan = await queue.planLibraryReorganization();
    expect(
      plan.moves.single.targetDisplayPath,
      'Singles/EP Song (Artist).flac',
    );
  });

  test('playlist-based folder rules only rename in place', () async {
    final track = await write('Road Trip/Song - Artist.flac');
    historyRows = [
      _historyRow('t', track.path, title: 'Song', totalTracks: 10),
    ];
    final queue = await queueWith(
      AppSettings(
        downloadDirectory: root.path,
        folderOrganization: 'playlist',
        filenameFormat: '{artist} - {title}',
      ),
    );
    final plan = await queue.planLibraryReorganization();
    expect(plan.keepsPlaylistFolders, isTrue);
    expect(plan.moves.single.targetDisplayPath, 'Road Trip/Artist - Song.flac');
  });
}
