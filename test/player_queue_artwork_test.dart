import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/widgets/mornye_player_queue.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/player_queue_artwork.dart';
import 'package:mornye/widgets/player_queue_sheet.dart';

import 'support/fixed_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII=',
  );
  late Directory directory;
  late List<String> extracted;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('queue_artwork_');
    extracted = [];
    DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(
      Directory('${directory.path}/previews'),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'extractCoverToFile');
      final args = call.arguments as Map;
      extracted.add(args['audio_path'] as String);
      await File(args['output_path'] as String).writeAsBytes(png);
      return jsonEncode({'success': true});
    });
  });

  tearDown(() async {
    await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting(
      preservePersistentFiles: false,
    );
    DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(null);
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  Future<void> waitForCovers(WidgetTester tester, int count) async {
    bool ready() =>
        tester
            .widgetList<PlayerArtwork>(find.byType(PlayerArtwork))
            .where((widget) => widget.artUri?.contains('/previews/') == true)
            .length ==
        count;
    for (var turn = 0; turn < 200 && !ready(); turn++) {
      await tester.runAsync(() => directory.stat());
      await tester.pump();
    }
    expect(ready(), isTrue);
  }

  for (final mornye in [false, true]) {
    testWidgets('queued phone files recover covers before playback ($mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final first = await tester.runAsync(
        () => File('${directory.path}/first.flac').writeAsBytes([1]),
      );
      final second = await tester.runAsync(
        () => File('${directory.path}/second.flac').writeAsBytes([2]),
      );
      final queue = [
        const MediaItem(id: 'current', title: 'Current'),
        MediaItem(id: 'first', title: 'First', extras: {'source': first!.path}),
        MediaItem(
          id: 'second',
          title: 'Second',
          artUri: Uri.file('${directory.path}/expired.jpg'),
          extras: {'source': second!.uri.toString()},
        ),
        MediaItem(
          id: 'repeat-first',
          title: 'First again',
          extras: {'source': first.path},
        ),
      ];
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
      final app = ProviderScope(
        overrides: [
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(queue.first),
          ),
          playQueueProvider.overrideWith((ref) => Stream.value(queue)),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(PlaybackState(queueIndex: 0)),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: mornye
                ? MornyePlayerQueue(colorScheme: scheme)
                : PlayerQueueSheet(
                    colorScheme: scheme,
                    scrollController: scroll,
                    embedded: true,
                  ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(app);
      });
      await waitForCovers(tester, 3);
      expect(extracted, unorderedEquals([first.path, second.path]));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      var reset = false;
      final clearing =
          DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting().then(
            (_) => reset = true,
          );
      for (var turn = 0; turn < 200 && !reset; turn++) {
        await tester.runAsync(() => directory.stat());
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(reset, isTrue);
      await clearing;
    });
  }

  testWidgets('a remote audio URL is never treated as a local audio file', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerQueueArtwork(
          item: const MediaItem(
            id: 'remote',
            title: 'Remote',
            extras: {'source': 'https://example.invalid/song.flac'},
          ),
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          cacheWidth: 132,
        ),
      ),
    );
    await tester.pump();
    expect(extracted, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
