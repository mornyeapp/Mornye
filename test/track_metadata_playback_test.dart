import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/tooltip_finder.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(playerMode: 'internal');
}

class _Handler extends Fake implements MusicPlayerHandler {}

class _Player extends MusicPlayerController {
  final played = <PlayableMedia>[];

  @override
  Future<MusicPlayerHandler?> ensureInitialized() async => _Handler();

  @override
  Future<void> playSingle(PlayableMedia item) async => played.add(item);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'safStat' => jsonEncode({'exists': true, 'size': 100}),
        'readAudioMetadata' ||
        'readFileMetadata' ||
        'getSafFileModTimes' => '{}',
        'extractCoverToFile' => jsonEncode({'error': 'No cover'}),
        _ => null,
      };
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final mornye in [false, true]) {
    for (final local in [false, true]) {
      for (final format in ['flac', 'opus']) {
        for (final menu in [false, if (mornye) true]) {
          testWidgets('metadata Play carries $format file information '
              '(Mornye=$mornye, local=$local, menu=$menu)', (tester) async {
            await tester.binding.setSurfaceSize(const Size(393, 852));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final player = _Player();
            final bitDepth = format == 'flac' ? 24 : null;
            final sampleRate = format == 'flac' ? 96000 : 48000;
            final bitrate = format == 'flac' ? 2800 : 192;
            final path = 'content://library/document/song.$format';
            final screen = local
                ? TrackMetadataScreen(
                    localItem: LocalLibraryItem(
                      id: 'local-song',
                      trackName: 'Song',
                      artistName: 'Artist',
                      albumName: 'Album',
                      filePath: path,
                      scannedAt: DateTime(2026),
                      duration: 210,
                      bitDepth: bitDepth,
                      sampleRate: sampleRate,
                      bitrate: bitrate,
                      format: format,
                      explicit: true,
                    ),
                  )
                : TrackMetadataScreen(
                    item: DownloadHistoryItem(
                      id: 'downloaded-song',
                      trackName: 'Song',
                      artistName: 'Artist',
                      albumName: 'Album',
                      filePath: path,
                      service: 'example-provider',
                      downloadedAt: DateTime(2026),
                      duration: 210,
                      bitDepth: bitDepth,
                      sampleRate: sampleRate,
                      bitrate: bitrate,
                      format: format,
                      quality: format == 'flac'
                          ? '24-bit/96kHz'
                          : 'OPUS 192kbps',
                      explicit: true,
                    ),
                  );
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  settingsProvider.overrideWith(_Settings.new),
                  musicPlayerControllerProvider.overrideWithValue(player),
                ],
                child: MaterialApp(
                  theme: mornye
                      ? MornyeTheme.build(Brightness.dark)
                      : AppTheme.dark(),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: screen,
                ),
              ),
            );
            await tester.pumpAndSettle();
            if (menu) {
              await tester.tap(findByTooltip('Show menu'));
              await tester.pumpAndSettle();
              await tester.tap(
                find.descendant(
                  of: find.byType(MornyeContextMenu),
                  matching: find.text('Play'),
                ),
              );
            } else {
              await tester.scrollUntilVisible(
                find.text('Play').hitTestable(),
                300,
                scrollable: find.byType(Scrollable).first,
              );
              await tester.pumpAndSettle();
              await tester.tap(find.text('Play'));
            }
            await tester.pumpAndSettle();

            final media = player.played.single;
            expect(media.source, path);
            expect(media.title, 'Song');
            expect(media.artist, 'Artist');
            expect(media.album, 'Album');
            expect(media.duration, const Duration(seconds: 210));
            expect(media.bitDepth, bitDepth);
            expect(media.sampleRate, sampleRate);
            expect(media.bitrate, bitrate);
            expect(media.format, format);
            expect(media.explicit, isTrue);

            final reads = <String>[];
            final metadata = PlayerMetadataController(
              readMetadata: (path) async {
                reads.add(path);
                return {};
              },
            );
            addTearDown(metadata.dispose);
            // The player must show the known quality without opening Lyrics
            // or copying the SAF document for a full metadata probe.
            await metadata.load(media.toMediaItem());
            expect(
              metadata.qualityLabel,
              format == 'flac'
                  ? 'FLAC  ·  24-bit  ·  96 kHz'
                  : 'OPUS  ·  48 kHz  ·  192 kbps',
            );
            expect(reads, isEmpty);
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }
}
