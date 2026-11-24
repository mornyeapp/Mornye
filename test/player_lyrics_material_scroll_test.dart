import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/player_lyrics.dart';

void main() {
  testWidgets('Material opens on a far line taller than the estimate', (
    tester,
  ) async {
    // A narrow desktop panel: each line wraps and carries a romanization,
    // several times the estimated row height.
    tester.view.physicalSize = const Size(340, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = StreamController<PlaybackState>.broadcast();
    final seek = ValueNotifier<Duration?>(null);
    addTearDown(playback.close);
    addTearDown(seek.dispose);
    final theme = AppTheme.dark();
    final lyrics = ParsedLyrics(
      synced: true,
      wordSynced: false,
      plainText: '',
      lines: List.generate(
        80,
        (index) => LyricLine(
          time: Duration(seconds: index * 3),
          end: Duration(seconds: (index + 1) * 3),
          text: 'Fixture line $index wraps across the narrow panel twice',
          romanization: 'Romanized line $index also wraps across the panel',
        ),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackStateProvider.overrideWith((ref) => playback.stream),
          musicPlayerControllerProvider.overrideWith(
            (ref) => throw StateError('Unexpected audio access'),
          ),
        ],
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SyncedLyricsView(
              lyrics: lyrics,
              seekPreview: seek,
              colorScheme: theme.colorScheme,
              isActive: true,
              showPronunciation: true,
              showTranslation: false,
            ),
          ),
        ),
      ),
    );
    // Halfway through the song, as when the panel opens mid-track.
    playback.add(
      PlaybackState(
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 181),
      ),
    );
    await tester.pumpAndSettle();
    // The romanization sits in the lower half of the centered row.
    final line = find.textContaining('Romanized line 60 ', findRichText: true);
    expect(line, findsOneWidget);
    expect(tester.getCenter(line).dy, inInclusiveRange(400, 560));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Material offscreen seek resumes line progression', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2424);
    tester.view.devicePixelRatio = 2.625;
    tester.view.padding = const FakeViewPadding(top: 142, bottom: 63);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    final font = FontLoader('Google Sans Flex')
      ..addFont(rootBundle.load('assets/fonts/GoogleSansFlex.ttf'));
    await font.load();
    // The new font is announced on a real event-loop turn. Take it now, or
    // it lands after the test and relays out the binding's closing message.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    final playback = StreamController<PlaybackState>.broadcast();
    final seek = ValueNotifier<Duration?>(null);
    addTearDown(playback.close);
    addTearDown(seek.dispose);
    final theme = AppTheme.dark();
    final lyrics = ParsedLyrics(
      synced: true,
      wordSynced: true,
      plainText: '',
      lines: List.generate(200, (index) {
        final words = ['Fixture ', 'line ', '$index ', 'flows ', 'on'];
        return LyricLine(
          time: Duration(seconds: index * 2),
          end: Duration(seconds: (index + 1) * 2),
          text: words.join(),
          words: [
            for (var word = 0; word < words.length; word++)
              LyricWord(
                time: Duration(milliseconds: index * 2000 + word * 400),
                end: Duration(milliseconds: index * 2000 + (word + 1) * 400),
                text: words[word],
              ),
          ],
        );
      }),
    );
    void report(int milliseconds, {bool playing = false}) => playback.add(
      PlaybackState(
        playing: playing,
        processingState: AudioProcessingState.ready,
        updatePosition: Duration(milliseconds: milliseconds),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackStateProvider.overrideWith((ref) => playback.stream),
          musicPlayerControllerProvider.overrideWith(
            (ref) => throw StateError('Unexpected audio access'),
          ),
        ],
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SafeArea(
              child: SyncedLyricsView(
                lyrics: lyrics,
                seekPreview: seek,
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
    await tester.pump(const Duration(milliseconds: 100));
    report(40000);
    seek.value = const Duration(seconds: 40);
    report(40000);
    for (var i = 0; i < 31; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    seek.value = null;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    final before = position.pixels;
    Finder highlighted(int line) => find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == lyrics.lines[line].text,
    );
    expect(highlighted(20), findsOneWidget);
    expect(
      tester.getCenter(highlighted(20)).dy,
      closeTo(tester.getCenter(find.byType(ListView)).dy, 1),
    );
    for (var i = 0; i < 13; i++) {
      report(40000 + i * 200, playing: true);
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }
    expect(highlighted(21), findsOneWidget);
    expect(position.pixels, greaterThan(before + 20));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
