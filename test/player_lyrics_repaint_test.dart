import 'dart:async';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/player_lyrics.dart';

const _text = 'AAAA BBBB';
const _lyrics = ParsedLyrics(
  synced: true,
  wordSynced: true,
  plainText: '',
  lines: [
    LyricLine(
      time: Duration.zero,
      end: Duration(seconds: 20),
      text: _text,
      words: [
        LyricWord(
          time: Duration.zero,
          end: Duration(seconds: 10),
          text: 'AAAA ',
        ),
        LyricWord(
          time: Duration(seconds: 10),
          end: Duration(seconds: 20),
          text: 'BBBB',
        ),
      ],
    ),
  ],
);

Finder get _paint => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == _text,
  ),
  matching: find.byType(CustomPaint),
);

List<List<Rect>> _segmentBoxes(WidgetTester tester) {
  // Inspect the existing painter payload without adding production test hooks.
  // ignore: avoid_dynamic_calls
  return (tester.widget<CustomPaint>(_paint).painter as dynamic).segmentBoxes
      as List<List<Rect>>;
}

Future<List<int>> _pixels(WidgetTester tester) async {
  final painter = tester.widget<CustomPaint>(_paint).painter!;
  final size = tester.getSize(_paint);
  return (await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final result = bytes.buffer.asUint8List().toList();
    image.dispose();
    picture.dispose();
    return result;
  }))!;
}

void main() {
  for (final mornye in [false, true]) {
    for (final reducedMotion in [false, true]) {
      for (final milliseconds in [200, 650]) {
        testWidgets('short final word completes its lift clock '
            '(Mornye: $mornye, reduced: $reducedMotion, ms: $milliseconds)', (
          tester,
        ) async {
          final playback = StreamController<PlaybackState>.broadcast();
          final preview = ValueNotifier<Duration?>(null);
          addTearDown(playback.close);
          addTearDown(preview.dispose);
          final theme = mornye
              ? MornyeTheme.build(Brightness.dark)
              : ThemeData.dark();
          final position = Duration(milliseconds: milliseconds);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                playbackStateProvider.overrideWith((ref) => playback.stream),
              ],
              child: MaterialApp(
                theme: theme,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: reducedMotion),
                  child: child!,
                ),
                home: Scaffold(
                  body: WordTimedLyricLine(
                    line: const LyricLine(
                      time: Duration.zero,
                      end: Duration(milliseconds: 100),
                      text: _text,
                      words: [
                        LyricWord(
                          time: Duration.zero,
                          end: Duration(milliseconds: 100),
                          text: _text,
                        ),
                      ],
                    ),
                    initialPosition: position,
                    seekPreview: preview,
                    style: theme.textTheme.titleLarge!,
                  ),
                ),
              ),
            ),
          );
          playback.add(
            PlaybackState(
              playing: true,
              processingState: AudioProcessingState.ready,
              updatePosition: position,
            ),
          );
          await tester.pump();
          final painter = tester.widget<CustomPaint>(_paint).painter!;
          var paints = 0;
          void onPaint() => paints++;
          painter.addListener(onPaint);
          await tester.pump(const Duration(milliseconds: 16));
          expect(paints > 0, !reducedMotion && milliseconds == 200);
          painter.removeListener(onPaint);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }

  for (final mornye in [false, true]) {
    testWidgets(
      'playing lyrics retain their painter and refresh stopped highlights ($mornye)',
      (tester) async {
        final playback = StreamController<PlaybackState>.broadcast();
        final preview = ValueNotifier<Duration?>(null);
        addTearDown(playback.close);
        addTearDown(preview.dispose);
        final theme = mornye
            ? MornyeTheme.build(Brightness.dark)
            : ThemeData.dark();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackStateProvider.overrideWith((ref) => playback.stream),
            ],
            child: MaterialApp(
              theme: theme,
              home: Scaffold(
                body: SyncedLyricsView(
                  lyrics: _lyrics,
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
        Future<void> report(
          int seconds, {
          bool playing = false,
          AudioProcessingState state = AudioProcessingState.ready,
        }) async {
          playback.add(
            PlaybackState(
              playing: playing,
              processingState: state,
              updatePosition: Duration(seconds: seconds),
            ),
          );
          await tester.pump();
          await tester.pump();
        }

        await report(2);
        await tester.pumpAndSettle();
        await report(2, playing: true);
        await tester.pump(const Duration(milliseconds: 500));
        final retained = tester.widget<CustomPaint>(_paint).painter!;
        final retainedBoxes = _segmentBoxes(tester);
        final early = await _pixels(tester);
        var repaintNotifications = 0;
        void repaint() => repaintNotifications++;
        retained.addListener(repaint);
        await report(6, playing: true);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<CustomPaint>(_paint).painter, same(retained));
        expect(repaintNotifications, greaterThan(0));
        expect(await _pixels(tester), isNot(orderedEquals(early)));
        retained.removeListener(repaint);

        await report(8);
        await tester.pumpAndSettle();
        expect(_segmentBoxes(tester), same(retainedBoxes));
        final paused = await _pixels(tester);
        await tester.pump(const Duration(seconds: 1));
        expect(await _pixels(tester), orderedEquals(paused));
        await report(3);
        await tester.pumpAndSettle();
        expect(await _pixels(tester), isNot(orderedEquals(paused)));

        await report(4, playing: true, state: AudioProcessingState.buffering);
        await tester.pumpAndSettle();
        if (mornye) {
          expect(_paint, findsNothing);
        } else {
          final buffered = await _pixels(tester);
          await tester.pump(const Duration(seconds: 1));
          expect(await _pixels(tester), orderedEquals(buffered));
          await report(7, playing: true, state: AudioProcessingState.buffering);
          await tester.pumpAndSettle();
          expect(await _pixels(tester), isNot(orderedEquals(buffered)));
        }

        preview.value = const Duration(seconds: 2);
        await tester.pumpAndSettle();
        final sought = await _pixels(tester);
        final soughtBoxes = _segmentBoxes(tester);
        preview.value = const Duration(seconds: 8);
        await tester.pumpAndSettle();
        expect(_segmentBoxes(tester), same(soughtBoxes));
        expect(await _pixels(tester), isNot(orderedEquals(sought)));
        preview.value = const Duration(seconds: 2);
        await tester.pumpAndSettle();
        expect(await _pixels(tester), orderedEquals(sought));
        await report(12, playing: true, state: AudioProcessingState.buffering);
        await tester.pumpAndSettle();
        expect(await _pixels(tester), orderedEquals(sought));
        preview.value = null;
        await report(2);
        await tester.pumpAndSettle();
        expect(await _pixels(tester), orderedEquals(sought));

        // The last lead remains visible during an outro, but its completed
        // highlight must stop scheduling frames after the glow has faded.
        await report(22, playing: true);
        await tester.pumpAndSettle();
        final completedPainter = tester.widget<CustomPaint>(_paint).painter!;
        var completedRepaints = 0;
        void completedRepaint() => completedRepaints++;
        completedPainter.addListener(completedRepaint);
        await tester.pump(const Duration(milliseconds: 500));
        expect(completedRepaints, 0);
        await report(25, playing: true);
        await tester.pump(const Duration(milliseconds: 16));
        expect(completedRepaints, 0);
        expect(
          tester.widget<CustomPaint>(_paint).painter,
          same(completedPainter),
        );
        await report(4, playing: true);
        await tester.pump(const Duration(milliseconds: 16));
        expect(completedRepaints, greaterThan(0));
        completedPainter.removeListener(completedRepaint);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('word sweep follows the AutoMix playback rate ($mornye)', (
      tester,
    ) async {
      final playback = StreamController<PlaybackState>.broadcast();
      final preview = ValueNotifier<Duration?>(null);
      addTearDown(playback.close);
      addTearDown(preview.dispose);
      final theme = mornye
          ? MornyeTheme.build(Brightness.dark)
          : ThemeData.dark();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackStateProvider.overrideWith((ref) => playback.stream),
          ],
          child: MaterialApp(
            theme: theme,
            home: Scaffold(
              body: WordTimedLyricLine(
                line: _lyrics.lines.single,
                initialPosition: const Duration(seconds: 2),
                seekPreview: preview,
                style: theme.textTheme.titleLarge!,
              ),
            ),
          ),
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      Duration position() {
        final painter = tester.widget<CustomPaint>(_paint).painter!;
        // Inspect the clock already supplied to the painter.
        // ignore: avoid_dynamic_calls
        return (painter as dynamic).currentPosition() as Duration;
      }

      // AutoMix changes rate while playing. No further report arrives between
      // these samples, so the word sweep must extrapolate at that rate itself.
      for (final speed in [2.0, 0.5]) {
        playback.add(
          PlaybackState(
            playing: true,
            processingState: AudioProcessingState.ready,
            updatePosition: const Duration(seconds: 2),
            speed: speed,
          ),
        );
        await tester.pump();
        final before = position();
        final elapsed = Stopwatch()..start();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 160)),
        );
        final advanced = (position() - before).inMicroseconds;
        elapsed.stop();
        expect(advanced, closeTo(elapsed.elapsedMicroseconds * speed, 40000));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final mornye in [false, true]) {
    testWidgets(
      'sung words rise in both styles, glow only in Mornye ($mornye)',
      (tester) async {
        final playback = StreamController<PlaybackState>.broadcast();
        final preview = ValueNotifier<Duration?>(null);
        addTearDown(playback.close);
        addTearDown(preview.dispose);
        final theme = mornye
            ? MornyeTheme.build(Brightness.dark)
            : ThemeData.dark();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackStateProvider.overrideWith((ref) => playback.stream),
            ],
            child: MaterialApp(
              theme: theme,
              home: Scaffold(
                body: SyncedLyricsView(
                  lyrics: _lyrics,
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
        // The first word is held, the second still waits.
        playback.add(
          PlaybackState(
            processingState: AudioProcessingState.ready,
            updatePosition: const Duration(seconds: 2),
          ),
        );
        await tester.pumpAndSettle();
        // Inspect the painter payload without adding production test hooks.
        // ignore: avoid_dynamic_calls
        final painter = tester.widget<CustomPaint>(_paint).painter! as dynamic;
        // ignore: avoid_dynamic_calls
        expect(painter.highlightLift as double, greaterThan(0));
        // ignore: avoid_dynamic_calls
        final glow = painter.glowSigma as double;
        expect(glow, mornye ? greaterThan(0) : 0);

        // The sung word stands above the waiting one.
        final size = tester.getSize(_paint);
        final pixels = await _pixels(tester);
        final width = size.width.ceil();
        double inkTop(int from, int to) {
          for (var y = 0; y < size.height.ceil(); y++) {
            for (var x = from; x < to; x++) {
              if (pixels[(y * width + x) * 4 + 3] >= 16) return y.toDouble();
            }
          }
          return double.infinity;
        }

        final boxes = _segmentBoxes(tester);
        final first = boxes.first.first;
        final second = boxes.last.first;
        expect(
          inkTop(first.left.ceil(), first.right.floor()),
          lessThan(inkTop(second.left.ceil(), second.right.floor())),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('the word sweep keeps moving behind another app window', (
    tester,
  ) async {
    final playback = StreamController<PlaybackState>.broadcast();
    final preview = ValueNotifier<Duration?>(null);
    addTearDown(playback.close);
    addTearDown(preview.dispose);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final theme = MornyeTheme.build(Brightness.dark);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackStateProvider.overrideWith((ref) => playback.stream),
        ],
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SyncedLyricsView(
              lyrics: _lyrics,
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
        updatePosition: const Duration(seconds: 2),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Focus moves to another app's window; no position report follows.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    final before = await _pixels(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(await _pixels(tester), isNot(orderedEquals(before)));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final hiddenByLifecycle in [false, true]) {
    testWidgets(
      'hidden lyrics suspend their timeline and resume the latest position ($hiddenByLifecycle)',
      (tester) async {
        final playback = StreamController<PlaybackState>.broadcast();
        final preview = ValueNotifier<Duration?>(null);
        addTearDown(playback.close);
        addTearDown(preview.dispose);
        final visibility = ValueNotifier(true);
        addTearDown(visibility.dispose);
        const nextText = 'Next voice';
        const lyrics = ParsedLyrics(
          synced: true,
          wordSynced: true,
          plainText: '',
          lines: [
            LyricLine(
              time: Duration.zero,
              end: Duration(seconds: 10),
              text: _text,
              words: [
                LyricWord(
                  time: Duration.zero,
                  end: Duration(seconds: 10),
                  text: _text,
                ),
              ],
            ),
            LyricLine(
              time: Duration(seconds: 10),
              end: Duration(seconds: 40),
              text: nextText,
              words: [
                LyricWord(
                  time: Duration(seconds: 10),
                  end: Duration(seconds: 40),
                  text: nextText,
                ),
              ],
            ),
          ],
        );
        final theme = MornyeTheme.build(Brightness.dark);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackStateProvider.overrideWith((ref) => playback.stream),
            ],
            child: MaterialApp(
              theme: theme,
              home: ValueListenableBuilder<bool>(
                valueListenable: visibility,
                builder: (context, visible, child) =>
                    TickerMode(enabled: visible, child: child!),
                child: Scaffold(
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
          ),
        );
        Future<void> report(int seconds) async {
          playback.add(
            PlaybackState(
              playing: true,
              processingState: AudioProcessingState.ready,
              updatePosition: Duration(seconds: seconds),
            ),
          );
          await tester.pump();
          await tester.pump();
        }

        Finder timed(String text) => find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == text,
        );
        await report(2);
        expect(timed(_text), findsOneWidget);
        if (hiddenByLifecycle) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        } else {
          visibility.value = false;
        }
        await tester.pump();
        await report(15);
        await tester.pump(const Duration(seconds: 20));
        expect(timed(_text), findsOneWidget);
        expect(timed(nextText), findsNothing);
        if (hiddenByLifecycle) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else {
          visibility.value = true;
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(timed(nextText), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'long lyrics measure in batches without moving the visible anchor',
    (tester) async {
      const focus = 250;
      final lines = List.generate(
        600,
        (index) => LyricLine(
          time: Duration(seconds: index),
          end: Duration(seconds: index + 1),
          text:
              'Line $index ${List.filled(index % 4 + 1, 'with enough words to wrap across several lines').join(' ')}',
          romanization: 'Pronunciation for line $index',
          translation: 'Translation for line $index',
        ),
      );
      final lyrics = ParsedLyrics(
        synced: true,
        wordSynced: false,
        plainText: '',
        lines: lines,
      );
      final preview = ValueNotifier<Duration?>(const Duration(seconds: focus));
      addTearDown(preview.dispose);
      final theme = MornyeTheme.build(Brightness.dark);
      var width = 420.0;
      Future<void> pumpView() => tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: theme,
            home: Scaffold(
              body: SizedBox(
                width: width,
                child: SyncedLyricsView(
                  lyrics: lyrics,
                  seekPreview: preview,
                  colorScheme: theme.colorScheme,
                  isActive: true,
                  showPronunciation: true,
                  showTranslation: true,
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> stableAnchor({bool manualScroll = false}) async {
        await tester.pump();
        var line = find.text(lines[focus].text);
        if (manualScroll) {
          await tester.drag(find.byType(ListView), const Offset(0, -220));
          await tester.pump();
          final visibleText = tester
              .widgetList<Text>(find.byType(Text))
              .map((widget) => widget.data)
              .whereType<String>()
              .where((text) => text.startsWith('Line '))
              .firstWhere((text) {
                final bounds = tester.getRect(find.text(text));
                return bounds.bottom > 0 && bounds.top < 500;
              });
          line = find.text(visibleText);
        }
        expect(line, findsOneWidget);
        final y = tester.getTopLeft(line).dy;
        for (var frame = 0; frame < 60; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getTopLeft(line).dy, closeTo(y, 0.01));
          expect(tester.takeException(), isNull);
        }
      }

      await pumpView();
      await stableAnchor(manualScroll: true);
      width = 300;
      await pumpView();
      await stableAnchor();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'timed geometry survives rebuilds and tracks layout and boundaries',
    (tester) async {
      final preview = ValueNotifier<Duration?>(const Duration(seconds: 5));
      addTearDown(preview.dispose);
      final words = _lyrics.lines.single.words.toList();
      final lyrics = ParsedLyrics(
        synced: true,
        wordSynced: true,
        plainText: '',
        lines: [
          LyricLine(
            time: Duration.zero,
            end: const Duration(seconds: 20),
            text: _text,
            words: words,
            translation: 'Translation',
          ),
        ],
      );
      var width = 620.0;
      var fontSize = 28.0;
      var scale = 1.0;
      var direction = TextDirection.ltr;
      var locale = const Locale('en');
      var supplements = false;
      var viewKey = 0;
      Future<void> pump() async {
        final theme = ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.copyWith(
            headlineSmall: TextStyle(fontSize: fontSize),
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: theme,
              locale: locale,
              supportedLocales: const [Locale('en'), Locale('en', 'US')],
              home: Scaffold(
                body: Directionality(
                  textDirection: direction,
                  child: MediaQuery(
                    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                    child: SizedBox(
                      width: width,
                      child: SyncedLyricsView(
                        key: ValueKey(viewKey),
                        lyrics: lyrics,
                        seekPreview: preview,
                        colorScheme: theme.colorScheme,
                        isActive: true,
                        showPronunciation: false,
                        showTranslation: supplements,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> matchesFreshLayout() async {
        final cached = await _pixels(tester);
        viewKey++;
        await pump();
        expect(await _pixels(tester), orderedEquals(cached));
      }

      await pump();
      var boxes = _segmentBoxes(tester);
      final initial = await _pixels(tester);
      await pump();
      expect(_segmentBoxes(tester), same(boxes));
      supplements = true;
      await pump();
      expect(_segmentBoxes(tester), same(boxes));
      expect(await _pixels(tester), orderedEquals(initial));

      // Timing-only edits must repaint even though the geometry is retained.
      final oldPainter = tester.widget<CustomPaint>(_paint).painter!;
      words[0] = const LyricWord(
        time: Duration.zero,
        end: Duration(seconds: 6),
        text: 'AAAA ',
      );
      await pump();
      expect(_segmentBoxes(tester), same(boxes));
      expect(
        tester.widget<CustomPaint>(_paint).painter!.shouldRepaint(oldPainter),
        isTrue,
      );
      expect(await _pixels(tester), isNot(orderedEquals(initial)));

      // The paragraph is unchanged, but the timed selections have new bounds.
      words[0] = const LyricWord(
        time: Duration.zero,
        end: Duration(seconds: 10),
        text: 'AA',
      );
      words[1] = const LyricWord(
        time: Duration(seconds: 10),
        end: Duration(seconds: 20),
        text: 'AA BBBB',
      );
      await pump();
      expect(_segmentBoxes(tester), isNot(same(boxes)));
      expect(_segmentBoxes(tester), isNot(equals(boxes)));
      await matchesFreshLayout();

      for (final change in <VoidCallback>[
        () => width = 180,
        () => direction = TextDirection.rtl,
        () => scale = 1.4,
        () => fontSize = 32,
        () => locale = const Locale('en', 'US'),
        () => width = 620,
      ]) {
        boxes = _segmentBoxes(tester);
        change();
        await pump();
        expect(_segmentBoxes(tester), isNot(same(boxes)));
        if (width == 180) {
          expect(
            _segmentBoxes(
              tester,
            ).expand((boxes) => boxes).map((box) => box.top).toSet().length,
            greaterThan(1),
          );
        }
        await matchesFreshLayout();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
