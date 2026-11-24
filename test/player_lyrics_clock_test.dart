import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:clock/clock.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/player_lyrics.dart';

void main() {
  for (final mornye in [false, true]) {
    testWidgets('a late position report keeps the line ($mornye)', (
      tester,
    ) async {
      var now = DateTime(2026);
      await withClock(Clock(() => now), () async {
        final playback = StreamController<PlaybackState>.broadcast();
        final preview = ValueNotifier<Duration?>(null);
        addTearDown(playback.close);
        addTearDown(preview.dispose);
        final theme = mornye
            ? MornyeTheme.build(Brightness.dark)
            : AppTheme.dark();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackStateProvider.overrideWith((ref) => playback.stream),
            ],
            child: MaterialApp(
              theme: theme,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SyncedLyricsView(
                  lyrics: LyricsParser.parse(
                    '[00:01.00]First phrase\n[00:04.00]Second phrase\n'
                    '[00:07.00]Third phrase',
                  ),
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
        PlaybackState at(Duration position) => PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
          updatePosition: position,
        );
        double emphasis(String phrase) => tester
            .widget<AnimatedOpacity>(
              find.ancestor(
                of: find.text(phrase),
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .opacity;

        playback.add(at(const Duration(seconds: 3)));
        await tester.pump();
        await tester.pump();
        expect(emphasis('First phrase'), 1);
        // The line timer moves on when the next line starts.
        now = now.add(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        expect(emphasis('Second phrase'), 1);

        // A report from just before that line, as one arriving late over
        // a network is, keeps it instead of stepping back for a moment.
        playback.add(at(const Duration(milliseconds: 3800)));
        await tester.pump();
        expect(emphasis('Second phrase'), 1);
        expect(emphasis('First phrase'), lessThan(1));

        // A seek back moves at once.
        playback.add(at(const Duration(seconds: 2)));
        await tester.pump();
        expect(emphasis('First phrase'), 1);
        expect(emphasis('Second phrase'), lessThan(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });

    testWidgets('a late position report keeps a finished line finished '
        '($mornye)', (tester) async {
      var now = DateTime(2026);
      await withClock(Clock(() => now), () async {
        final playback = StreamController<PlaybackState>.broadcast();
        final preview = ValueNotifier<Duration?>(null);
        addTearDown(playback.close);
        addTearDown(preview.dispose);
        final theme = mornye
            ? MornyeTheme.build(Brightness.dark)
            : AppTheme.dark();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackStateProvider.overrideWith((ref) => playback.stream),
            ],
            child: MaterialApp(
              theme: theme,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SyncedLyricsView(
                  // As in TTML, the first line is still sung when the second
                  // starts.
                  lyrics: const ParsedLyrics(
                    synced: true,
                    wordSynced: false,
                    plainText: '',
                    lines: [
                      LyricLine(
                        time: Duration(seconds: 1),
                        end: Duration(milliseconds: 4300),
                        text: 'First phrase',
                      ),
                      LyricLine(
                        time: Duration(seconds: 4),
                        end: Duration(seconds: 7),
                        text: 'Second phrase',
                      ),
                      LyricLine(
                        time: Duration(seconds: 7),
                        end: Duration(seconds: 9),
                        text: 'Third phrase',
                      ),
                    ],
                  ),
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
        PlaybackState at(int milliseconds) => PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
          updatePosition: Duration(milliseconds: milliseconds),
        );
        double emphasis(String phrase) => tester
            .widget<AnimatedOpacity>(
              find.ancestor(
                of: find.text(phrase),
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .opacity;
        Future<void> advance(int milliseconds) async {
          now = now.add(Duration(milliseconds: milliseconds));
          await tester.pump(Duration(milliseconds: milliseconds));
        }

        playback.add(at(3500));
        await tester.pump();
        await tester.pump();
        await advance(600);
        expect(emphasis('First phrase'), 1);
        expect(emphasis('Second phrase'), 1);
        await advance(250);
        expect(emphasis('First phrase'), lessThan(1));

        // The report says 4.25 s where the lyric clock is at 4.35 s. The
        // first line ended in between and stays ended.
        playback.add(at(4250));
        await tester.pump();
        await tester.pump();
        expect(emphasis('First phrase'), lessThan(1));
        expect(emphasis('Second phrase'), 1);
        // Playback goes on from the report without the line coming back.
        for (var step = 0; step < 10; step++) {
          await advance(20);
          expect(emphasis('First phrase'), lessThan(1));
        }
        await advance(2600);
        expect(emphasis('Third phrase'), 1);

        // A seek back still moves at once.
        playback.add(at(4100));
        await tester.pump();
        await tester.pump();
        expect(emphasis('First phrase'), 1);
        expect(emphasis('Third phrase'), lessThan(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });

    for (final refreshRate in [60.0, 120.0]) {
      testWidgets('playing lyrics change line a display delay early '
          '($mornye, $refreshRate Hz)', (tester) async {
        tester.view.display.refreshRate = refreshRate;
        addTearDown(tester.view.display.reset);
        final now = DateTime(2026);
        await withClock(Clock(() => now), () async {
          final playback = StreamController<PlaybackState>.broadcast();
          final preview = ValueNotifier<Duration?>(null);
          addTearDown(playback.close);
          addTearDown(preview.dispose);
          final theme = mornye
              ? MornyeTheme.build(Brightness.dark)
              : AppTheme.dark();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                playbackStateProvider.overrideWith((ref) => playback.stream),
              ],
              child: MaterialApp(
                theme: theme,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: SyncedLyricsView(
                    lyrics: LyricsParser.parse(
                      '[00:01.00]First phrase\n[00:04.00]Second phrase\n'
                      '[00:07.00]Third phrase',
                    ),
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
          Future<void> report(int milliseconds, {required bool playing}) async {
            playback.add(
              PlaybackState(
                playing: playing,
                processingState: AudioProcessingState.ready,
                updatePosition: Duration(milliseconds: milliseconds),
              ),
            );
            await tester.pump();
            await tester.pump();
          }

          double emphasis(String phrase) => tester
              .widget<AnimatedOpacity>(
                find.ancestor(
                  of: find.text(phrase),
                  matching: find.byType(AnimatedOpacity),
                ),
              )
              .opacity;

          // Two frames at this refresh rate: 33 ms at 60 Hz, 17 ms at 120 Hz.
          final lead = (2000 / refreshRate).ceil();
          await report(4000 - lead - 5, playing: true);
          expect(emphasis('First phrase'), 1);
          await report(4000 - lead + 1, playing: true);
          expect(
            emphasis('Second phrase'),
            1,
            reason: 'The frame drawn now is on screen as the line starts',
          );
          expect(emphasis('First phrase'), lessThan(1));

          // A paused song shows the line its position is in.
          await report(4000 - lead + 1, playing: false);
          expect(emphasis('First phrase'), 1);
          expect(emphasis('Second phrase'), lessThan(1));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      });
    }

    for (final speed in [1.0, 1.5]) {
      testWidgets('late lyric timers catch up to playback ($mornye, $speed)', (
        tester,
      ) async {
        var now = DateTime(2026);
        await withClock(Clock(() => now), () async {
          final playback = StreamController<PlaybackState>.broadcast();
          final preview = ValueNotifier<Duration?>(null);
          addTearDown(playback.close);
          addTearDown(preview.dispose);
          final theme = mornye
              ? MornyeTheme.build(Brightness.dark)
              : AppTheme.dark();
          final lyrics = LyricsParser.parse('''
[00:13.161]First phrase
[00:26.065]Second phrase
[00:39.067]Third phrase
[00:51.938]Fourth phrase
[04:34.977]Final phrase
''');
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                playbackStateProvider.overrideWith((ref) => playback.stream),
              ],
              child: MaterialApp(
                theme: theme,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
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
          playback.add(
            PlaybackState(
              playing: true,
              processingState: AudioProcessingState.ready,
              updatePosition: Duration.zero,
              speed: speed,
            ),
          );
          await tester.pump();
          await tester.pump();

          double emphasis(String phrase) => tester
              .widget<AnimatedOpacity>(
                find.ancestor(
                  of: find.text(phrase),
                  matching: find.byType(AnimatedOpacity),
                ),
              )
              .opacity;

          final startedAt = now;
          final firstBoundary = Duration(
            microseconds: (13161000 / speed).ceil(),
          );
          now = startedAt.add(firstBoundary);
          await tester.pump(firstBoundary);
          expect(emphasis('First phrase'), 1);

          // The audio clock keeps moving while a timer callback is delayed.
          // No fresh position event is needed to catch up to the real song.
          now = startedAt.add(Duration(milliseconds: (45000 / speed).round()));
          await tester.pump(Duration(microseconds: (12904000 / speed).ceil()));
          expect(emphasis('Third phrase'), 1);
          expect(emphasis('First phrase'), lessThan(1));

          now = now.add(Duration(milliseconds: (231000 / speed).round()));
          await tester.pump(const Duration(seconds: 7));
          expect(emphasis('Final phrase'), 1);
          expect(emphasis('Third phrase'), lessThan(1));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      });
    }
  }
}
