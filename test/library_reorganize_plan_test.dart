import 'dart:async';
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
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_reorganizer.dart';

import 'support/fixed_settings.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
  @override
  Future<void> ensureInitialized() async {}
}

class _HeldReorganizer extends LibraryReorganizer {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<LibraryReorganizationResult> run(
    LibraryReorganizationPlan plan, {
    void Function(int done, LibraryReorganizationMove move)? onProgress,
    bool Function()? isCancelled,
  }) async {
    entered.complete();
    await release.future;
    return const LibraryReorganizationResult();
  }
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

Map<String, Object?> _libraryRow(
  String id,
  String filePath, {
  required String title,
  String artist = 'Artist',
  String album = 'Album',
  int? trackNumber,
  int? totalTracks,
}) => {
  'id': id,
  'source_id': 'music',
  'track_name': title,
  'artist_name': artist,
  'album_name': album,
  'file_path': filePath,
  'scanned_at': '2026-01-01T00:00:00.000Z',
  'track_number': trackNumber,
  'total_tracks': totalTracks,
};

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;

  late Directory root;
  late List<Map<String, Object?>> historyRows;
  late List<Map<String, Object?>> libraryRows;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-reorganize-plan-');
    historyRows = [];
    libraryRows = [];
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
        final path = args['path'] as String;
        versions[id] = path.endsWith('history.db')
            ? HistoryDatabase.schemaVersion
            : path.endsWith('local_library.db')
            ? LibraryDatabase.schemaVersion
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
      } else if (sql.startsWith(
        'select * from ${LibraryDatabase.visibleLibraryView}',
      )) {
        final offset =
            int.tryParse(RegExp(r'offset (\d+)').firstMatch(sql)?[1] ?? '') ??
            0;
        rows = libraryRows.skip(offset).toList();
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
    'reorganization rejects overlapping runs and releases the queue gate',
    () async {
      final queue = await queueWith(AppSettings(downloadDirectory: root.path));
      final plan = LibraryReorganizationPlan(
        root: root.path,
        safMode: false,
        moves: [],
      );
      final held = _HeldReorganizer();
      final first = queue.applyLibraryReorganization(plan, reorganizer: held);
      await held.entered.future;
      await expectLater(
        queue.applyLibraryReorganization(plan),
        throwsStateError,
      );
      held.release.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      final next = await queue.applyLibraryReorganization(plan);
      expect(next.failed, 0);
    },
  );

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
          onSourceRelocated: (_, _) async {},
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
          relinkLibraryPath: (_, _) async => true,
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

  test(
    'files from the Local Library scan are organized by their tags too',
    () async {
      final downloaded = await write('Song A - Artist.flac');
      final scanned = await write('incoming/04 Other Song.mp3');
      final untagged = await write('incoming/voice memo.m4a');
      final organized = await write('Band/LP/Band - Kept.flac');
      historyRows = [
        _historyRow('a', downloaded.path, title: 'Song A', totalTracks: 10),
      ];
      libraryRows = [
        // The same file as the download: history metadata wins.
        _libraryRow('lib_a', downloaded.path, title: 'Wrong', totalTracks: 10),
        _libraryRow(
          'lib_b',
          scanned.path,
          title: 'Other Song',
          artist: 'Band',
          album: 'LP',
          trackNumber: 4,
          totalTracks: 9,
        ),
        _libraryRow(
          'lib_c',
          untagged.path,
          title: 'voice memo',
          artist: 'Unknown Artist',
          album: 'Unknown Album',
        ),
        _libraryRow(
          'lib_d',
          organized.path,
          title: 'Kept',
          artist: 'Band',
          album: 'LP',
          totalTracks: 9,
        ),
        _libraryRow('lib_cue', '${scanned.path}#track03', title: 'Cue'),
      ];
      final queue = await queueWith(
        AppSettings(
          downloadDirectory: root.path,
          folderOrganization: 'artist_album',
          filenameFormat: '{artist} - {title}',
        ),
      );
      final plan = await queue.planLibraryReorganization();

      expect(plan.untagged, 1);
      expect(plan.missing, 0); // The CUE track is skipped, not missing.
      expect(plan.alreadyOrganized, 1);
      expect(
        {for (final m in plan.moves) m.sourceDisplayPath: m.targetDisplayPath},
        {
          'Song A - Artist.flac': 'Artist/Album/Artist - Song A.flac',
          'incoming/04 Other Song.mp3': 'Band/LP/Band - Other Song.mp3',
        },
      );
      final scannedMove = plan.moves.firstWhere(
        (m) => m.sourceFileName == '04 Other Song.mp3',
      );
      expect(scannedMove.historyIds, isEmpty);

      final relinked = <String, String>{};
      final result = await queue.applyLibraryReorganization(
        plan,
        reorganizer: LibraryReorganizer(
          onSourceRelocated: (_, _) async {},
          updateHistoryPath:
              (
                id,
                newFilePath, {
                newSafFileName,
                newSafRelativeDir,
                required expectedFilePath,
              }) async => true,
          relinkLibraryPath: (oldPath, newPath) async {
            relinked[oldPath] = newPath;
            return true;
          },
        ),
      );
      expect(result.moved, 2);
      expect(
        await File(
          p.join(root.path, 'Band', 'LP', 'Band - Other Song.mp3'),
        ).exists(),
        isTrue,
      );
      expect(await untagged.exists(), isTrue);
      expect(
        relinked[scanned.path],
        p.join(root.path, 'Band', 'LP', 'Band - Other Song.mp3'),
      );
    },
  );
}
