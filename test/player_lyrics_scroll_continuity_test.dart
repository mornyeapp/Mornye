import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/lyric_scroll_motion.dart';
import 'package:mornye/widgets/player_lyrics.dart';

void main() {
  tearDown(() => debugDesktopPlatformOverride = null);

  test('the line scroll eases in, arrives on time and never steps back', () {
    final curve = LyricScrollMotion.scrollCurve;
    final total = LyricScrollMotion.scrollDuration.inMilliseconds;
    double at(int milliseconds) => curve.transform(milliseconds / total);
    // The first frames barely move, so a late one cannot show as a jump.
    expect(at(16), lessThan(0.01));
    expect(at(33), lessThan(0.04));
    expect(at(33) - at(16), greaterThan(at(16)));
    expect(at(200), greaterThan(0.7));
    expect(at(300), greaterThan(0.9));
    expect(at(total), 1);
    for (var ms = 1; ms <= total; ms++) {
      expect(at(ms), greaterThanOrEqualTo(at(ms - 1)));
    }
  });

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

    testWidgets('$style opens a backing row without rebuilding the others', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 892);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final playback = StreamController<PlaybackState>.broadcast();
      final preview = ValueNotifier<Duration?>(null);
      addTearDown(playback.close);
      addTearDown(preview.dispose);
      final theme = mornye
          ? MornyeTheme.build(Brightness.dark)
          : AppTheme.dark();
      const lyrics = ParsedLyrics(
        synced: true,
        wordSynced: false,
        plainText: '',
        lines: [
          LyricLine(
            time: Duration.zero,
            end: Duration(seconds: 4),
            text: 'Lead phrase',
          ),
          LyricLine(
            time: Duration(seconds: 1),
            end: Duration(seconds: 3),
            text: 'Backing phrase',
            isBackground: true,
          ),
          LyricLine(time: Duration(seconds: 5), text: 'Second phrase'),
          LyricLine(time: Duration(seconds: 10), text: 'Third phrase'),
        ],
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
      Future<void> report(int milliseconds) async {
        playback.add(
          PlaybackState(
            processingState: AudioProcessingState.ready,
            updatePosition: Duration(milliseconds: milliseconds),
          ),
        );
        await tester.pump();
        await tester.pump();
      }

      await report(100);
      await tester.pumpAndSettle();
      expect(find.text('Backing phrase'), findsNothing);
      Widget row(String text) => tester.widget(
        find.ancestor(
          of: find.text(text),
          matching: find.byType(LyricScrollMotion),
        ),
      );
      double top(String text) => tester.getTopLeft(find.text(text)).dy;

      await report(1000);
      final second = row('Second phrase');
      final third = row('Third phrase');
      final tops = <double>[top('Second phrase')];
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        tops.add(top('Second phrase'));
        expect(
          row('Second phrase'),
          same(second),
          reason: 'A reveal frame rebuilds only the row that opens',
        );
        expect(row('Third phrase'), same(third));
      }
      expect(find.text('Backing phrase'), findsOneWidget);
      expect(
        tops.last,
        greaterThan(tops.first + 4),
        reason: 'The row below still moves as the backing row opens',
      );
      for (var frame = 1; frame < tops.length; frame++) {
        expect(tops[frame], greaterThanOrEqualTo(tops[frame - 1] - 0.01));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$style keeps its rows when the parent rebuilds unchanged', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final playback = StreamController<PlaybackState>.broadcast();
      final preview = ValueNotifier<Duration?>(null);
      addTearDown(playback.close);
      addTearDown(preview.dispose);
      final theme = mornye
          ? MornyeTheme.build(Brightness.dark)
          : AppTheme.dark();
      var colorScheme = theme.colorScheme;
      var writers = 'Fixture writer';
      late StateSetter rebuildParent;
      const texts = [
        'Fixture phrase 0',
        'Fixture phrase 1',
        'Fixture phrase 2',
        'Fixture phrase 3',
      ];
      final lyrics = ParsedLyrics(
        synced: true,
        wordSynced: false,
        plainText: '',
        lines: [
          for (final (index, text) in texts.indexed)
            LyricLine(
              time: Duration(seconds: index * 5),
              text: text,
            ),
        ],
      );
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
              body: StatefulBuilder(
                builder: (context, setState) {
                  rebuildParent = setState;
                  // A new credits widget and callback on every build, as the
                  // lyrics section passes them.
                  return SyncedLyricsView(
                    lyrics: lyrics,
                    seekPreview: preview,
                    credits: LyricsCredits(writers: writers),
                    colorScheme: colorScheme,
                    isActive: true,
                    showPronunciation: false,
                    showTranslation: false,
                    onLongPressLine: (_) {},
                  );
                },
              ),
            ),
          ),
        ),
      );
      playback.add(
        PlaybackState(
          processingState: AudioProcessingState.ready,
          updatePosition: const Duration(seconds: 6),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      Map<String, Widget> rows() => {
        for (final text in texts)
          text: tester.widget(
            find.ancestor(
              of: find.text(text),
              matching: find.byType(LyricScrollMotion),
            ),
          ),
      };
      int rebuiltRows(Map<String, Widget> before) {
        final after = rows();
        return texts
            .where((text) => !identical(before[text], after[text]))
            .length;
      }

      double offset() => tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .pixels;
      final before = rows();
      final credits = tester.widget(find.byType(LyricsCredits));
      final scrolled = offset();
      rebuildParent(() {});
      await tester.pump();
      expect(
        rebuiltRows(before),
        0,
        reason: 'An unchanged parent rebuild builds no lyric row',
      );
      expect(tester.widget(find.byType(LyricsCredits)), same(credits));
      expect(offset(), scrolled);
      expect(tester.hasRunningAnimations, isFalse);

      final unchanged = rows();
      rebuildParent(
        () => colorScheme = colorScheme.copyWith(
          onSurface: const Color(0xFF00FF00),
        ),
      );
      await tester.pump();
      expect(rebuiltRows(unchanged), texts.length);
      if (!mornye) {
        expect(
          tester.widget<Text>(find.text('Fixture phrase 1')).style?.color,
          const Color(0xFF00FF00),
          reason: 'The active line takes the new scheme',
        );
      }

      rebuildParent(() => writers = 'Another writer');
      await tester.pump();
      expect(find.textContaining('Another writer'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$style lines without a direction follow the app\'s', (
      tester,
    ) async {
      final preview = ValueNotifier<Duration?>(null);
      addTearDown(preview.dispose);
      final theme = mornye
          ? MornyeTheme.build(Brightness.dark)
          : AppTheme.dark();
      var direction = TextDirection.ltr;
      late StateSetter rebuildParent;
      const lyrics = ParsedLyrics(
        synced: true,
        wordSynced: false,
        plainText: '',
        lines: [
          LyricLine(time: Duration.zero, text: '1 2 3'),
          LyricLine(time: Duration(seconds: 5), text: '4 5 6'),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: theme,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  rebuildParent = setState;
                  return Directionality(
                    textDirection: direction,
                    child: SyncedLyricsView(
                      lyrics: lyrics,
                      seekPreview: preview,
                      colorScheme: theme.colorScheme,
                      isActive: true,
                      showPronunciation: false,
                      showTranslation: false,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      TextDirection lineDirection() =>
          Directionality.of(tester.element(find.text('4 5 6')));
      expect(lineDirection(), TextDirection.ltr);

      rebuildParent(() => direction = TextDirection.rtl);
      await tester.pumpAndSettle();
      expect(lineDirection(), TextDirection.rtl);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
