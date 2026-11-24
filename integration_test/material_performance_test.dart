import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';

import 'mornye_artwork_performance_test.dart' as artwork;
import 'mornye_lyrics_performance_test.dart' as lyrics;
import 'performance_probe.dart';

void main() {
  final binding = PerformanceTestBinding.ensureInitialized();
  lyrics.runLyricsPerformanceTests(mornye: false);
  artwork.runArtworkPerformanceTests(mornye: false);
  for (final mornye in [false, true]) {
    final style = mornye ? 'mornye' : 'material';
    testWidgets('$style production seek track playback, drag and idle', (
      tester,
    ) async {
      final probe = PerformanceProbe(binding, tester, suite: '${style}_seek');
      final playing = ValueNotifier(true);
      final seeks = <Duration>[];
      addTearDown(playing.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
          home: Scaffold(
            body: Center(
              child: ValueListenableBuilder<bool>(
                valueListenable: playing,
                builder: (_, value, _) => PlaybackSeekSlider(
                  playing: value,
                  position: const Duration(seconds: 40),
                  duration: const Duration(minutes: 4),
                  onSeek: (target) async => seeks.add(target),
                ),
              ),
            ),
          ),
        ),
      );
      await probe.measure(
        'playing_track_fixed_position',
        () => probe.wait(const Duration(milliseconds: 1500)),
        // A fixed Mornye progress track has no decorative animation.
        allowIdle: true,
      );
      await probe.measure('seek_drag', () async {
        final bounds = tester.getRect(find.byType(PlaybackSeekSlider));
        final touch = await tester.startGesture(
          Offset(bounds.left + bounds.width * 0.25, bounds.center.dy),
        );
        try {
          for (var step = 0; step < 20; step++) {
            await touch.moveBy(Offset(bounds.width * 0.02, 0));
            await probe.wait(const Duration(milliseconds: 16));
          }
        } finally {
          await touch.up();
        }
        await probe.wait(const Duration(milliseconds: 400));
      });
      expect(seeks, isNotEmpty);
      await tester.runAsync(() async {
        playing.value = false;
        await probe.wait(const Duration(milliseconds: 500));
      });
      await probe.measure(
        'paused_track_idle',
        () => probe.wait(const Duration(milliseconds: 1000)),
        allowIdle: true,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await probe.finish(
        metadata: {
          'style': style,
          'scope':
              'Production PlaybackSeekSlider with fixed position; no audio, '
              'database, network or provider timers. Same gestures in both styles.',
          'seek_commits': seeks.length,
        },
      );
    });
  }
}
