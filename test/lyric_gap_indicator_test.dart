import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/lyric_gap_indicator.dart';

const _vsync = Duration(microseconds: 8333);

/// Steps one second of 120 Hz display refreshes and counts those a frame was
/// requested for.
Future<int> _framesInOneSecond(WidgetTester tester) async {
  var frames = 0;
  for (var vsync = 0; vsync < 120; vsync++) {
    await tester.binding.delayed(_vsync);
    if (tester.binding.hasScheduledFrame) frames++;
    await tester.pump();
  }
  return frames;
}

Widget _host({required bool playing, bool visible = true}) => ProviderScope(
  overrides: [
    playbackPositionProvider.overrideWith((ref) => const Duration(seconds: 3)),
    playbackPlayingProvider.overrideWith((ref) => playing),
    playbackLoadingProvider.overrideWith((ref) => false),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: TickerMode(
      enabled: visible,
      child: const Scaffold(
        body: Center(
          child: LyricGapIndicator(
            start: Duration(seconds: 2),
            end: Duration(seconds: 12),
            color: Colors.white,
          ),
        ),
      ),
    ),
  ),
);

double _dotScale(WidgetTester tester) => tester
    .widget<Transform>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('lyric-gap-dot-0')),
            matching: find.byType(Transform),
          )
          .first,
    )
    .transform
    .getMaxScaleOnAxis();

void main() {
  tearDown(DecorativePhase.debugResetClock);

  testWidgets('an instrumental gap pulses at no more than 30 Hz', (
    tester,
  ) async {
    await tester.pumpWidget(_host(playing: true));
    await tester.pump();
    expect(DecorativePhase.debugClockRunning, isTrue);

    final start = _dotScale(tester);
    expect(await _framesInOneSecond(tester), lessThanOrEqualTo(31));
    expect(_dotScale(tester), isNot(start), reason: 'The dots still breathe');
  });

  testWidgets('a paused or hidden gap holds its pulse', (tester) async {
    await tester.pumpWidget(_host(playing: false));
    await tester.pump();
    expect(DecorativePhase.debugClockRunning, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(_host(playing: true, visible: false));
    await tester.pump();
    expect(DecorativePhase.debugClockRunning, isFalse);
  });
}
