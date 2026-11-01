import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/lyric_scroll_motion.dart';
import 'package:mornye/widgets/player_lyrics.dart';

void main() {
  tearDown(() => debugDesktopPlatformOverride = null);

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';
    testWidgets(
      '$style desktop keeps upcoming rows continuous on fast phrases',
      (tester) async {
        debugDesktopPlatformOverride = true;
        tester.view.physicalSize = const Size(700, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final playback = StreamController<PlaybackState>.broadcast();
        final preview = ValueNotifier<Duration?>(null);
        addTearDown(playback.close);
        addTearDown(preview.dispose);
        final theme = mornye
            ? MornyeTheme.build(Brightness.dark)
            : AppTheme.dark();
        final lyrics = ParsedLyrics(
          synced: true,
          wordSynced: false,
          plainText: '',
          lines: List.generate(
            40,
            (index) => LyricLine(
              time: Duration(milliseconds: index * 300),
              text: 'Fixture phrase $index',
            ),
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackStateProvider.overrideWith((ref) => playback.stream),
            ],
            child: MaterialApp(
              theme: theme,
              home: Scaffold(
                body: SyncedLyricsView(
                  lyrics: lyrics,
                  seekPreview: preview,
                  colorScheme: theme.colorScheme,
                  isActive: true,
                  showPronunciation: false,
                  showTranslation: false,
                ),
              ),
            ),
          ),
        );
        Future<void> report(int line, {int phaseMilliseconds = 0}) async {
          playback.add(
            PlaybackState(
              processingState: AudioProcessingState.ready,
              updatePosition: Duration(
                milliseconds: line * 300 + phaseMilliseconds,
              ),
            ),
          );
          await tester.pump();
          await tester.pump();
        }

        await report(8);
        await tester.pumpAndSettle();
        double top(int row) =>
            tester.getTopLeft(find.text('Fixture phrase $row')).dy;
        await report(9);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        final stagger = find.descendant(
          of: find.ancestor(
            of: find.text('Fixture phrase 12'),
            matching: find.byType(LyricScrollMotion),
          ),
          matching: find.byType(Transform),
        );
        expect(
          tester.widget<Transform>(stagger).transform.getTranslation().y,
          greaterThan(1),
          reason: 'Both styles retain the upward stagger between lyric rows',
        );
        final before = top(12);
        await report(9, phaseMilliseconds: 200);
        expect(
          top(12),
          closeTo(before, 0.01),
          reason:
              'Position reports within one phrase must not restart its scroll',
        );
        // A focus change arrives during the preceding row spring. Processing
        // the event without advancing a frame must not teleport upcoming text.
        await report(10);
        expect(top(12), closeTo(before, 0.01));
        await tester.pump(const Duration(milliseconds: 100));
        final during = top(12);
        await report(11);
        expect(top(12), closeTo(during, 0.01));
        await tester.pump(const Duration(milliseconds: 100));
        final upcoming = top(12);
        await report(12);
        expect(
          top(12),
          closeTo(upcoming, 0.01),
          reason:
              'Becoming active must preserve the remaining row displacement',
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
