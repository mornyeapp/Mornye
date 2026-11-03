import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/desktop/link_library_executor.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/desktop_platform.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
  @override
  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {}
}

class _History extends DownloadHistoryNotifier {
  final removed = <String>[];
  String? _savedTitle;
  @override
  DownloadHistoryState build() => DownloadHistoryState();
  @override
  Future<void> updateMetadataForItem({
    required String id,
    required String trackName,
    required String artistName,
    required String albumName,
    String? coverUrl,
    String? albumArtist,
    String? isrc,
    int? trackNumber,
    int? totalTracks,
    int? discNumber,
    int? totalDiscs,
    String? releaseDate,
    String? genre,
    String? composer,
    String? label,
    String? copyright,
    bool? explicit,
    bool? hasLyrics,
    int? lyricsMetadataScanVersion,
  }) async {
    _savedTitle = trackName;
  }

  @override
  Future<void> removePhysicalFiles(Iterable<String> paths) async {
    for (final path in paths) {
      expect(await File(path).exists(), isFalse);
      removed.add(path);
    }
  }
}

class _Library extends LocalLibraryNotifier {
  final removed = <String>[];
  @override
  LocalLibraryState build() => LocalLibraryState();
  @override
  Future<void> removePhysicalFiles(Iterable<String> paths) async {
    for (final path in paths) {
      expect(await File(path).exists(), isFalse);
      removed.add(path);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory directory;
  late File audio;
  late LocalLibraryItem item;
  late ProviderContainer container;
  late LinkLibraryExecutor executor;
  late List<MethodCall> calls;

  setUp(() async {
    debugDesktopPlatformOverride = false;
    directory = await Directory.systemTemp.createTemp('link-executor-test-');
    audio = await File(
      '${directory.path}/Imported.flac',
    ).writeAsString('unchanged audio');
    item = LocalLibraryItem(
      id: 'one',
      trackName: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      filePath: audio.path,
      scannedAt: DateTime(2026),
    );
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        downloadHistoryProvider.overrideWith(_History.new),
        localLibraryProvider.overrideWith(_Library.new),
      ],
    );
    calls = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments as Map;
      switch (call.method) {
        case 'readFileMetadata':
          return jsonEncode({
            'title': 'Song',
            'artist': 'Artist',
            'lyrics': '[00:01]Words',
            'cover_path': '/private/cache',
          });
        case 'extractCoverToFile':
          await File(args['output_path'] as String).writeAsString('picture');
          return jsonEncode({'success': true});
        case 'fetchAndSaveLyrics':
          await File(
            args['output_path'] as String,
          ).writeAsString('[00:01]Words');
          return jsonEncode({'success': true});
      }
      return null;
    });
    executor = LinkLibraryExecutor(
      container: container,
      index: () => DesktopLinkCatalogIndex(
        serverId: 'desktop',
        songs: [
          LinkCatalogSong(
            id: 'l:one',
            title: 'Song',
            artist: 'Artist',
            path: audio.path,
          ),
        ],
      ),
      readLocalRecord: (_) async => item.toJson(),
    );
  });
  tearDown(() async {
    container.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(paths, null);
    debugDesktopPlatformOverride = null;
    await directory.delete(recursive: true);
  });

  Future<Map<String, dynamic>> run(
    LinkLibraryAction action, {
    Map<String, dynamic> options = const {},
    String id = 'l:one',
  }) => executor.call(
    LinkLibraryWork(
      id: 'job_12345',
      deviceId: 'phone',
      action: action,
      songIds: [id],
      options: options,
    ),
    id,
  );

  test(
    'catalog ID resolves live file and does not reveal private cover paths',
    () async {
      final result = await run(LinkLibraryAction.readMetadata);
      expect((result['metadata'] as Map)['title'], 'Song');
      expect(result['metadata'], isNot(contains('cover_path')));
      expect((calls.single.arguments as Map)['file_path'], audio.path);
      expect(await run(LinkLibraryAction.delete, id: 'l:missing'), {
        'error': 'not_found',
      });
      expect(await audio.exists(), isTrue);
    },
  );

  test(
    'deletion removes the file before cleaning history and scanned rows',
    () async {
      expect(await run(LinkLibraryAction.delete), isEmpty);
      expect(await audio.exists(), isFalse);
      expect(
        (container.read(downloadHistoryProvider.notifier) as _History).removed,
        [audio.path],
      );
      expect(
        (container.read(localLibraryProvider.notifier) as _Library).removed,
        [audio.path],
      );
      expect(await run(LinkLibraryAction.delete), {'error': 'not_found'});
      expect(
        (container.read(downloadHistoryProvider.notifier) as _History)
            .removed
            .length,
        1,
      );
    },
  );

  test(
    'saved tags reach the index before notification, failed edits do not notify',
    () async {
      final historyItem = DownloadHistoryItem(
        id: 'download',
        trackName: 'Old title',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: audio.path,
        service: 'provider-a',
        downloadedAt: DateTime(2026),
      );
      final history =
          container.read(downloadHistoryProvider.notifier) as _History;
      final published = <String?>[];
      addTearDown(
        SourceMetadataEvents.instance.subscribe((source) async {
          expect(source, audio.path);
          published.add(history._savedTitle);
        }),
      );
      var fail = false;
      final tags = <String, dynamic>{'title': 'Old title', 'artist': 'Artist'};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'editFileMetadata') {
              if (fail) return jsonEncode({'error': 'write_failed'});
              final args = call.arguments as Map;
              tags.addAll(
                Map<String, dynamic>.from(
                  jsonDecode(args['metadata_json'] as String) as Map,
                ),
              );
              return jsonEncode({'success': true, 'method': 'native'});
            }
            if (call.method == 'extractCoverToFile') {
              return jsonEncode({'error': 'no_cover'});
            }
            return jsonEncode(tags);
          });
      executor = LinkLibraryExecutor(
        container: container,
        index: () => DesktopLinkCatalogIndex(
          serverId: 'desktop',
          songs: [
            LinkCatalogSong(
              id: 'd:download',
              title: 'Old title',
              artist: 'Artist',
              path: audio.path,
            ),
          ],
        ),
        readDownloadRecord: (_) async => historyItem.toJson(),
      );
      expect(
        await run(
          LinkLibraryAction.editMetadata,
          id: 'd:download',
          options: {
            'metadata': {'title': 'Edited title'},
          },
        ),
        isEmpty,
      );
      expect(published, ['Edited title']);
      fail = true;
      expect(
        await run(
          LinkLibraryAction.editMetadata,
          id: 'd:download',
          options: {
            'metadata': {'title': 'Failed title'},
          },
        ),
        {'error': 'metadata_failed'},
      );
      expect(published, ['Edited title']);
      expect(history._savedTitle, 'Edited title');
    },
  );

  test('stale catalog cannot mutate a record whose path changed', () async {
    item = LocalLibraryItem.fromJson({
      ...item.toJson(),
      'filePath': '${directory.path}/another.flac',
    });
    expect(await run(LinkLibraryAction.delete), {'error': 'not_found'});
    expect(await audio.readAsString(), 'unchanged audio');
    expect(calls, isEmpty);
  });

  test(
    'JPG and LRC are published beside source without moving audio or leaking temps',
    () async {
      expect(await run(LinkLibraryAction.saveCover), {
        'fileName': 'Imported.jpg',
      });
      expect(await run(LinkLibraryAction.saveLyrics), {
        'fileName': 'Imported.lrc',
      });
      expect(
        await File('${directory.path}/Imported.jpg').readAsString(),
        'picture',
      );
      expect(
        await File('${directory.path}/Imported.lrc').readAsString(),
        '[00:01]Words',
      );
      expect(await audio.readAsString(), 'unchanged audio');
      expect(
        await directory.list().where((entry) => entry is Directory).toList(),
        isEmpty,
      );
    },
  );

  test(
    'unavailable cover keeps existing sidecar intact and cleans staging',
    () async {
      final sidecar = await File(
        '${directory.path}/Imported.jpg',
      ).writeAsString('keep');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => jsonEncode({'error': 'no cover'}),
          );
      expect(await run(LinkLibraryAction.saveCover), {
        'error': 'cover_missing',
      });
      expect(await sidecar.readAsString(), 'keep');
      expect(
        await directory.list().where((entry) => entry is Directory).toList(),
        isEmpty,
      );
    },
  );

  test(
    'metadata requests cannot inject filesystem options and apply needs a preview',
    () async {
      expect(
        await run(
          LinkLibraryAction.editMetadata,
          options: {
            'metadata': {'cover_path': '/another/file'},
          },
        ),
        {'error': 'invalid_fields'},
      );
      expect(
        await run(
          LinkLibraryAction.reEnrich,
          options: {'previewJobId': 'missing', 'file_path': audio.path},
        ),
        {'error': 'preview_expired'},
      );
      expect(calls, isEmpty);
    },
  );
}
