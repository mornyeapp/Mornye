import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/widgets/app_choice_chip.dart';

import 'support/app_icon_finder.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    isInitialized: true,
    extensions: [
      Extension(
        id: 'example-provider',
        name: 'example-provider',
        displayName: 'Example Music',
        version: '1.0.0',
        description: 'Metadata fixture',
        enabled: true,
        status: 'loaded',
        hasMetadataProvider: true,
      ),
    ],
  );
}

Future<void> _settleFileIo(WidgetTester tester) async {
  // Real file operations need an event-loop turn between pumped frames.
  // pumpAndSettle alone only advances the test's fake clock.
  await tester.runAsync(() async {
    var idleFrames = 0;
    for (var i = 0; i < 200 && idleFrames < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 25));
      idleFrames = tester.binding.hasScheduledFrame ? 0 : idleFrames + 1;
    }
    expect(idleFrames, 3, reason: 'Metadata file operations did not settle');
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const ffmpegEvents = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    messenger.setMockMethodCallHandler(ffmpegEvents, (_) async => null);
  });
  tearDown(() => messenger.setMockMethodCallHandler(ffmpegEvents, null));
  const coverUrl = 'https://example.invalid/artwork/album.jpg';
  final imageBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );

  for (final scenario in [
    'track details',
    'album details',
    'selected provider album',
    'unicode',
    'search cover survives detail failure',
    'download failure',
  ]) {
    testWidgets('cover auto-fill resolves $scenario', (tester) async {
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final title = scenario == 'unicode' ? '春の歌' : 'Song';
      final artist = scenario == 'unicode' ? '歌手' : 'Artist';
      final albumLookup = scenario.contains('album');
      final searchHasCover =
          scenario == 'unicode' ||
          scenario == 'search cover survives detail failure';
      final lookups = <String>[];
      final downloadedUrls = <String>[];
      final candidate = <String, Object>{
        'id': 'song-1',
        'name': title,
        'artists': artist,
        'album_name': 'Album',
        'album_id': 'album-1',
        'provider_id': 'example-provider',
        if (searchHasCover) 'cover_url': coverUrl,
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'searchTracksWithMetadataProviders':
          case 'searchTracksWithMetadataProvider':
            expect((call.arguments as Map)['query'], '$title $artist');
            return jsonEncode([candidate]);
          case 'getProviderMetadata':
            final args = call.arguments as Map;
            expect(args['provider_id'], 'example-provider');
            final type = args['resource_type'] as String;
            lookups.add(type);
            if (scenario == 'search cover survives detail failure') {
              throw PlatformException(code: 'lookup_failed');
            }
            if (type == 'album') {
              expect(args['resource_id'], 'album-1');
              return jsonEncode({
                'album_info': {'images': coverUrl},
              });
            }
            expect(args['resource_id'], 'song-1');
            return jsonEncode({
              'track': {...candidate, if (!albumLookup) 'cover_url': coverUrl},
            });
          case 'downloadCoverToFile':
            final args = call.arguments as Map;
            downloadedUrls.add(args['cover_url'] as String);
            if (scenario == 'download failure') {
              return jsonEncode({'error': 'Artwork request failed'});
            }
            await File(args['output_path'] as String).writeAsBytes(imageBytes);
            return jsonEncode({'success': true});
          default:
            return switch (call.method) {
              'safStat' => jsonEncode({'exists': true, 'size': 100}),
              'readAudioMetadata' => '{}',
              'readFileMetadata' => jsonEncode({'audio_codec': 'flac'}),
              'getLyricsLRCWithSource' => jsonEncode({'lyrics': ''}),
              'extractCoverToFile' => jsonEncode({'error': 'No cover'}),
              'getSafFileModTimes' => '{}',
              _ => null,
            };
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await PlatformBridge.clearTrackCache();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [extensionProvider.overrideWith(_Extensions.new)],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: TrackMetadataScreen(
              item: DownloadHistoryItem(
                id: 'local-song',
                trackName: title,
                artistName: artist,
                albumName: 'Album',
                filePath: 'content://library/document/song.flac',
                service: 'example-provider',
                downloadedAt: DateTime(2026),
                format: 'flac',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(findAppIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Edit audio file'), findsNothing);
      expect(find.text('Similar songs in Library'), findsNothing);
      await tester.ensureVisible(find.text('Edit Metadata'));
      await tester.tap(find.text('Edit Metadata'));
      await _settleFileIo(tester);
      await tester.tap(find.text('Auto-fill from online'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('None'));
      await tester.pump();
      await tester.tap(find.widgetWithText(AppChoiceChip, 'Cover Art'));
      await tester.pump();
      if (scenario == 'selected provider album') {
        await tester.tap(find.text('Automatic (provider priority)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Example Music'));
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(find.text('Find metadata'));
      await tester.tap(find.text('Find metadata'));
      await tester.pump();
      if (scenario == 'selected provider album') {
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.widgetWithText(ListTile, title));
      }
      await _settleFileIo(tester);
      expect(lookups, ['track', 'album']);
      expect(downloadedUrls, contains(coverUrl));
      expect(find.text('No matching metadata found online'), findsNothing);
      expect(find.text('Apply selected data'), findsOneWidget);
      await tester.ensureVisible(find.text('Apply selected data'));
      await tester.tap(find.text('Apply selected data'));
      await _settleFileIo(tester);
      if (scenario == 'download failure') {
        expect(find.text('Download failed'), findsOneWidget);
        expect(find.text('Apply selected data'), findsOneWidget);
        expect(find.text('No matching metadata found online'), findsNothing);
      } else {
        expect(find.text('Apply selected data'), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    });
  }
}
