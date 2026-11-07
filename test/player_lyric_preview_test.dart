import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/player_lyric_preview.dart';
import 'package:mornye/widgets/player_lyrics.dart';

import 'support/fixed_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final lrc = '''
[00:00.00]
[00:05.00]paisa mera dialect par -
[00:10.00]Next line of rap
''';

  group('PlayerLyricPreview Widget Tests', () {
    testWidgets(
      'displays real-time active lyric line and chevron, and triggers onTap when clicked',
      (tester) async {
        final parsedLyrics = LyricsParser.parse(lrc);
        final metadata = PlayerMetadataController(
          parseLyrics: (_) async => parsedLyrics,
          readMetadata: (_) async => {
            'title': 'Vibrate',
            'artist': 'KR\$NA',
            'lyrics': lrc,
          },
        );
        final item = MediaItem(
          id: 'vibrate',
          title: 'Vibrate',
          artist: 'KR\$NA, Badshah, Phenom',
          duration: const Duration(minutes: 3),
          extras: {'source': '/music/vibrate.flac'},
        );
        await metadata.load(item);

        final seekPreview = PlaybackSeekPreview();
        var openedLyrics = false;
        final positionController = StreamController<PlaybackState>.broadcast();
        addTearDown(positionController.close);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackStateProvider.overrideWith(
                (ref) => positionController.stream,
              ),
              settingsProvider.overrideWith(
                () => FixedSettingsNotifier(
                  const AppSettings(playerShowLyricSnippet: true),
                ),
              ),
            ],
            child: MaterialApp(
              theme: MornyeTheme.build(Brightness.dark),
              home: Scaffold(
                body: PlayerLyricPreview(
                  metadata: metadata,
                  seekPreview: seekPreview,
                  colorScheme: const ColorScheme.dark(),
                  onTap: () => openedLyrics = true,
                ),
              ),
            ),
          ),
        );

        await tester.pump();

        // At position 00:01 (before 00:05 line):
        positionController.add(
          PlaybackState(
            playing: true,
            updatePosition: const Duration(seconds: 1),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('•••'), findsOneWidget);
        expect(find.byIcon(CupertinoIcons.chevron_right), findsOneWidget);

        // At position 00:06 (active line "paisa mera dialect par -"):
        positionController.add(
          PlaybackState(
            playing: true,
            updatePosition: const Duration(seconds: 6),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('paisa mera dialect par -'), findsOneWidget);
        expect(find.byIcon(CupertinoIcons.chevron_right), findsOneWidget);

        // Tap the preview line:
        await tester.tap(find.text('paisa mera dialect par -'));
        await tester.pump();
        expect(openedLyrics, isTrue);

        // At position 00:11 (active line "Next line of rap"):
        positionController.add(
          PlaybackState(
            playing: true,
            updatePosition: const Duration(seconds: 11),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Next line of rap'), findsOneWidget);
      },
    );

    testWidgets('hides when playerShowLyricSnippet is disabled in settings', (
      tester,
    ) async {
      final parsedLyrics = LyricsParser.parse(lrc);
      final metadata = PlayerMetadataController(
        parseLyrics: (_) async => parsedLyrics,
        readMetadata: (_) async => {'title': 'Vibrate', 'lyrics': lrc},
      );
      final item = MediaItem(
        id: 'vibrate',
        title: 'Vibrate',
        extras: {'source': '/music/vibrate.flac'},
      );
      await metadata.load(item);

      final seekPreview = PlaybackSeekPreview();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(
              () => FixedSettingsNotifier(
                const AppSettings(playerShowLyricSnippet: false),
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PlayerLyricPreview(
                metadata: metadata,
                seekPreview: seekPreview,
                colorScheme: const ColorScheme.dark(),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('paisa mera dialect par -'), findsNothing);
      expect(find.byType(PlayerLyricPreview), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.chevron_right), findsNothing);
    });

    testWidgets('renders WordTimedLyricLine for word-by-word synced lyrics', (
      tester,
    ) async {
      final parsed = ParsedLyrics(
        synced: true,
        wordSynced: true,
        lines: [
          LyricLine(
            time: const Duration(seconds: 4),
            end: const Duration(seconds: 8),
            text: 'word by word preview',
            words: [
              LyricWord(
                time: const Duration(seconds: 4),
                end: const Duration(seconds: 5),
                text: 'word ',
              ),
              LyricWord(
                time: const Duration(seconds: 5),
                end: const Duration(seconds: 6),
                text: 'by ',
              ),
              LyricWord(
                time: const Duration(seconds: 6),
                end: const Duration(seconds: 7),
                text: 'word ',
              ),
              LyricWord(
                time: const Duration(seconds: 7),
                end: const Duration(seconds: 8),
                text: 'preview',
              ),
            ],
          ),
        ],
        plainText: 'word by word preview',
      );

      final metadata = PlayerMetadataController(
        parseLyrics: (_) async => parsed,
        readMetadata: (_) async => {'title': 'Vibrate', 'lyrics': 'dummy'},
      );
      final item = MediaItem(
        id: 'vibrate',
        title: 'Vibrate',
        extras: {'source': '/music/vibrate.flac'},
      );
      await metadata.load(item);

      final seekPreview = PlaybackSeekPreview();
      final positionController = StreamController<PlaybackState>.broadcast();
      addTearDown(positionController.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackStateProvider.overrideWith(
              (ref) => positionController.stream,
            ),
            settingsProvider.overrideWith(
              () => FixedSettingsNotifier(
                const AppSettings(playerShowLyricSnippet: true),
              ),
            ),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            home: Scaffold(
              body: PlayerLyricPreview(
                metadata: metadata,
                seekPreview: seekPreview,
                colorScheme: const ColorScheme.dark(),
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      // At position 00:05 (active word-timed line):
      positionController.add(
        PlaybackState(
          playing: true,
          updatePosition: const Duration(seconds: 5),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(WordTimedLyricLine), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.chevron_right), findsOneWidget);
    });
  });
}
