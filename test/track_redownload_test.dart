import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/controllers/track_redownload.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/local_track_redownload_service.dart';

const _provider = Extension(
  id: 'example.provider',
  name: 'example.provider',
  displayName: 'Example Provider',
  version: '1.0.0',
  description: 'Example provider',
  enabled: true,
  status: 'loaded',
  hasDownloadProvider: true,
  hasMetadataProvider: true,
);

const _extensions = ExtensionState(
  isInitialized: true,
  extensions: [_provider],
);

final _item = LocalLibraryItem(
  id: 'local-song',
  trackName: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  filePath: '/music/Artist/Album/01 Song.flac',
  scannedAt: DateTime(2026),
  isrc: 'USAAA2600001',
  duration: 240,
  format: 'flac',
);

Map<String, dynamic> _result(
  String id,
  String name,
  String artist, {
  String? isrc,
}) => {
  'id': id,
  'name': name,
  'artists': artist,
  'album_name': 'Album',
  'duration_ms': 240000,
  'isrc': ?isrc,
};

DownloadItem _queued(Track track, DownloadStatus status) => DownloadItem(
  id: 'queued-${track.id}',
  track: track,
  service: 'example.provider',
  status: status,
  createdAt: DateTime(2026),
);

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(askQualityBeforeDownload: false);
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => _extensions;
}

class _Queue extends DownloadQueueNotifier {
  final added = <(String, String, bool)>[];

  @override
  DownloadQueueState build() => const DownloadQueueState();

  @override
  String addToQueue(
    Track track,
    String service, {
    String? qualityOverride,
    String? playlistName,
    int? playlistPosition,
    bool keepBoth = false,
  }) {
    added.add((track.id, service, keepBoth));
    return 'item-${track.id}';
  }
}

/// The real queue, paused so nothing downloads.
class _PausedQueue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState(isPaused: true);
  }
}

class _VariantSettings extends SettingsNotifier {
  _VariantSettings(this.allowVariants);

  final bool allowVariants;

  @override
  AppSettings build() => AppSettings(
    downloadDirectory: '/fixture/output',
    allowQualityVariants: allowVariants,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var results = <Map<String, dynamic>>[];
  var searches = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    searches = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'searchTracksWithMetadataProviders') return null;
      searches++;
      expect((call.arguments as Map)['include_extensions'], isTrue);
      return results;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('planRedownload', () {
    test('a confident match is planned with the default service', () async {
      results = [
        _result('catalog:2', 'Song (Live)', 'Artist'),
        _result('catalog:1', 'Song', 'Artist', isrc: 'USAAA2600001'),
      ];
      final plan = await LocalTrackRedownloadService.planRedownload(
        _item,
        settings: const AppSettings(),
        extensionState: _extensions,
      );
      expect(plan.status, TrackRedownloadStatus.matched);
      expect(plan.match?.id, 'catalog:1');
      expect(plan.service, 'example.provider');
    });

    test('no confident match plans nothing', () async {
      results = [_result('catalog:3', 'Other Tune', 'Someone Else')];
      final plan = await LocalTrackRedownloadService.planRedownload(
        _item,
        settings: const AppSettings(),
        extensionState: _extensions,
      );
      expect(plan.status, TrackRedownloadStatus.noMatch);
      expect(plan.match, isNull);
    });

    test('no download service skips the search', () async {
      final plan = await LocalTrackRedownloadService.planRedownload(
        _item,
        settings: const AppSettings(),
        extensionState: const ExtensionState(isInitialized: true),
      );
      expect(plan.status, TrackRedownloadStatus.noService);
      expect(searches, 0);
    });

    test('a match already waiting in the queue is not planned again', () async {
      results = [_result('catalog:1', 'Song', 'Artist', isrc: 'USAAA2600001')];
      final waiting = Track(
        id: 'catalog:1',
        name: 'Different title',
        artistName: 'Different artist',
        albumName: 'Album',
        duration: 240,
      );
      final plan = await LocalTrackRedownloadService.planRedownload(
        LocalLibraryItem(
          id: 'untagged',
          trackName: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: '/music/song.mp3',
          scannedAt: DateTime(2026),
          isrc: 'USAAA2600001',
        ),
        settings: const AppSettings(),
        extensionState: _extensions,
        queue: [_queued(waiting, DownloadStatus.downloading)],
      );
      expect(plan.status, TrackRedownloadStatus.alreadyQueued);
    });
  });

  test('isQueued counts only unfinished downloads of the same song', () {
    final same = Track(
      id: 'catalog:9',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 240,
    );
    final other = Track(
      id: 'catalog:8',
      name: 'Another Song',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 200,
    );
    bool queued(List<DownloadItem> queue, {String? sourceTrackId}) =>
        LocalTrackRedownloadService.isQueued(
          _item,
          queue,
          sourceTrackId: sourceTrackId,
        );
    expect(queued([_queued(same, DownloadStatus.queued)]), isTrue);
    expect(queued([_queued(same, DownloadStatus.finalizing)]), isTrue);
    expect(queued([_queued(same, DownloadStatus.completed)]), isFalse);
    expect(queued([_queued(same, DownloadStatus.failed)]), isFalse);
    expect(queued([_queued(other, DownloadStatus.queued)]), isFalse);
    expect(
      queued([
        _queued(other, DownloadStatus.queued),
      ], sourceTrackId: 'catalog:8'),
      isTrue,
    );
  });

  group('redownloadTrack', () {
    Future<_Queue> run(WidgetTester tester) async {
      final queue = _Queue();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            extensionProvider.overrideWith(_Extensions.new),
            downloadQueueProvider.overrideWith(() => queue),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => redownloadTrack(context, ref, _item),
                  child: const Text('Start'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(find.textContaining('The current file is kept.'), findsOneWidget);
      await tester.tap(find.text('Re-download').last);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      return queue;
    }

    testWidgets('queues a confident match with the default service', (
      tester,
    ) async {
      results = [_result('catalog:1', 'Song', 'Artist', isrc: 'USAAA2600001')];
      final queue = await run(tester);
      // Keeps both files, whatever the quality variants setting says.
      expect(queue.added, [('catalog:1', 'example.provider', true)]);
      expect(find.text('Added "Song" to queue'), findsOneWidget);
    });

    testWidgets('queues nothing without a confident match', (tester) async {
      results = [_result('catalog:3', 'Other Tune', 'Someone Else')];
      final queue = await run(tester);
      expect(queue.added, isEmpty);
      expect(
        find.text('No reliable online match found for this song'),
        findsOneWidget,
      );
    });
  });

  for (final allowVariants in [false, true]) {
    test(
      'only Re-download forces a kept variant (setting: $allowVariants)',
      () {
        const track = Track(
          id: 'catalog:1',
          name: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 240,
        );
        final container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(
              () => _VariantSettings(allowVariants),
            ),
            extensionProvider.overrideWith(_Extensions.new),
            downloadQueueProvider.overrideWith(_PausedQueue.new),
          ],
        );
        try {
          final queue = container.read(downloadQueueProvider.notifier);
          queue.addToQueue(track, 'example.provider');
          queue.addToQueue(track, 'example.provider', keepBoth: true);
          final items = container.read(downloadQueueProvider).items;
          expect(items.first.preserveQualityVariant, allowVariants);
          expect(items.last.preserveQualityVariant, isTrue);
        } finally {
          container.dispose();
        }
      },
    );
  }

  group('non-Latin tags', () {
    final song = LocalLibraryItem(
      id: 'non-latin',
      trackName: '星の歌',
      artistName: '山田',
      albumName: '夜の記録',
      filePath: '/music/song.flac',
      scannedAt: DateTime(2026),
      duration: 240,
    );
    Map<String, dynamic> found(String name, String artist) => {
      'id': 'catalog:jp',
      'name': name,
      'artists': artist,
      'album_name': '夜の記録',
      'duration_ms': 240000,
    };

    test('a different song with non-Latin tags does not match', () async {
      results = [found('海の詩', '佐藤')];
      final resolution = await LocalTrackRedownloadService.resolveBestMatch(
        song,
        includeExtensions: true,
      );
      expect(resolution.match, isNull);
    });

    test('the same non-Latin song still matches itself', () async {
      results = [found('星の歌', '山田')];
      final resolution = await LocalTrackRedownloadService.resolveBestMatch(
        song,
        includeExtensions: true,
      );
      expect(resolution.match?.id, 'catalog:jp');
    });
  });
}
