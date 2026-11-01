import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/player_lyrics.dart';

import 'performance_probe.dart';

final _lyrics = _timedLyrics(lineMilliseconds: 2000);
final _fastLyrics = _timedLyrics(lineMilliseconds: 300);

ParsedLyrics _timedLyrics({required int lineMilliseconds}) => ParsedLyrics(
  synced: true,
  wordSynced: true,
  plainText: '',
  lines: List.generate(200, (index) {
    final words = ['Fixture ', 'line ', '$index ', 'flows ', 'on'];
    return LyricLine(
      time: Duration(milliseconds: index * lineMilliseconds),
      end: Duration(milliseconds: (index + 1) * lineMilliseconds),
      text: words.join(),
      words: [
        for (var word = 0; word < words.length; word++)
          LyricWord(
            time: Duration(
              milliseconds:
                  index * lineMilliseconds + word * lineMilliseconds ~/ 5,
            ),
            end: Duration(
              milliseconds:
                  index * lineMilliseconds + (word + 1) * lineMilliseconds ~/ 5,
            ),
            text: words[word],
          ),
      ],
    );
  }),
);

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

void main() => runLyricsPerformanceTests(mornye: true);

/// Identical playback, lyrics and gestures for both visual styles.
void runLyricsPerformanceTests({required bool mornye}) {
  final binding = PerformanceTestBinding.ensureInitialized();
  final style = mornye ? 'mornye' : 'material';
  testWidgets('$style production word-synced lyrics and manual scrolling', (
    tester,
  ) async {
    final probe = PerformanceProbe(binding, tester, suite: '${style}_lyrics');
    final playback = StreamController<PlaybackState>.broadcast();
    final seek = ValueNotifier<Duration?>(null);
    final active = ValueNotifier(true);
    final fastPhrases = ValueNotifier(false);
    final elapsed = Stopwatch();
    Timer? timer;
    void report(bool playing) => playback.add(
      PlaybackState(
        playing: playing,
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 40) + elapsed.elapsed,
      ),
    );
    void stop() {
      timer?.cancel();
      timer = null;
      elapsed.stop();
      report(false);
    }

    void start() {
      elapsed.start();
      report(true);
      timer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => report(true),
      );
    }

    addTearDown(() async {
      timer?.cancel();
      await playback.close();
      seek.dispose();
      active.dispose();
      fastPhrases.dispose();
    });
    final theme = mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          playbackStateProvider.overrideWith((ref) => playback.stream),
          musicPlayerControllerProvider.overrideWith(
            (ref) => throw StateError('Unexpected audio controller access'),
          ),
        ],
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SafeArea(
              child: ValueListenableBuilder<bool>(
                valueListenable: active,
                builder: (_, value, _) => ValueListenableBuilder<bool>(
                  valueListenable: fastPhrases,
                  builder: (_, fast, _) => SyncedLyricsView(
                    lyrics: fast ? _fastLyrics : _lyrics,
                    seekPreview: seek,
                    colorScheme: theme.colorScheme,
                    isActive: value,
                    showPronunciation: false,
                    showTranslation: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      binding.scheduleFrame();
      await binding.endOfFrame.timeout(const Duration(seconds: 10));
    });
    ScrollPosition position() =>
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    String progressionFailure(double before) {
      final context = tester.element(find.byType(SyncedLyricsView));
      final container = ProviderScope.containerOf(context);
      final highlighted = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .map((widget) => widget.properties.label)
          .whereType<String>()
          .where((label) => label.startsWith('Fixture line '))
          .join(', ');
      return 'lifecycle=${binding.lifecycleState}, '
          'tickers=${TickerMode.valuesOf(context).enabled}, '
          'positionMs=${container.read(playbackPositionProvider).inMilliseconds}, '
          'playing=${container.read(playbackPlayingProvider)}, '
          'scroll=${position().pixels}, before=$before, '
          'scrolling=${position().isScrollingNotifier.value}, '
          'highlighted=[$highlighted]';
    }

    Future<void> reset() async {
      stop();
      elapsed.reset();
      active.value = true;
      seek.value = const Duration(seconds: 40);
      report(false);
      await probe.wait(const Duration(milliseconds: 500));
      seek.value = null;
      await probe.wait(const Duration(milliseconds: 150));
    }

    await tester.runAsync(() => probe.wait(const Duration(milliseconds: 100)));
    await probe.measure('lyrics_word_highlight_and_line_progression', () async {
      await reset();
      final before = position().pixels;
      start();
      // A line boundary still needs a rendered frame and its scroll
      // animation. Include that completion latency in the measured action.
      while (elapsed.elapsed < const Duration(seconds: 6) &&
          (elapsed.elapsed < const Duration(seconds: 2) ||
              position().pixels <= before + 20)) {
        await probe.wait(const Duration(milliseconds: 16));
      }
      stop();
      expect(elapsed.elapsed, greaterThan(const Duration(seconds: 2)));
      expect(
        position().pixels,
        greaterThan(before + 20),
        reason: position().pixels > before + 20
            ? null
            : progressionFailure(before),
      );
    });
    await probe.measure('lyrics_manual_scroll_during_playback', () async {
      await reset();
      final before = position().pixels;
      start();
      final touch = await tester.startGesture(
        tester.getCenter(find.byType(ListView)),
      );
      try {
        await touch.moveBy(const Offset(0, -24));
        await probe.wait(const Duration(milliseconds: 50));
        await touch.moveBy(const Offset(0, -100));
        await probe.wait(const Duration(milliseconds: 100));
        final held = position().pixels;
        expect(held, greaterThan(before + 30));
        await probe.wait(const Duration(milliseconds: 2300));
        expect(elapsed.elapsed, greaterThan(const Duration(seconds: 2)));
        expect(position().pixels, closeTo(held, 1));
      } finally {
        stop();
        await touch.up();
      }
    });
    await probe.measure('lyrics_fast_phrase_scroll', () async {
      fastPhrases.value = true;
      await reset();
      final before = position().pixels;
      start();
      await probe.wait(const Duration(milliseconds: 1800));
      stop();
      expect(position().pixels, greaterThan(before + 60));
    });
    await tester.runAsync(() async {
      stop();
      active.value = false;
      await probe.wait(const Duration(milliseconds: 700));
    });
    await probe.measure(
      'lyrics_inactive_paused_idle',
      () => probe.wait(const Duration(milliseconds: 800)),
      allowIdle: true,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => probe.wait(const Duration(milliseconds: 350)));
    await probe.finish(
      metadata: {
        'scope':
            'Production SyncedLyricsView; 200 generated five-word lines, '
            '200ms in-memory playback stream; normal phrases are 2s and fast '
            'phrases are 300ms. No audio, metadata, database, '
            'preferences or network. Active samples include a 650ms paused '
            'seek reset to 40s. Idle is inactive and paused.',
        'lineCount': _lyrics.lines.length,
        'style': style,
        'wordsPerLine': 5,
        'manualScrollTolerancePixels': 1,
        'progressionTimeoutMs': 6000,
        'fastPhraseDurationMs': 300,
      },
    );
  });
}
