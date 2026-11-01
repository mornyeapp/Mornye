import 'package:audio_service/audio_service.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/playback_time_builder.dart';

PlaybackState _state(
  int milliseconds, {
  bool playing = true,
  double speed = 1,
  AudioProcessingState processing = AudioProcessingState.ready,
}) => PlaybackState(
  playing: playing,
  processingState: processing,
  updatePosition: Duration(milliseconds: milliseconds),
  speed: speed,
);

Widget _app(
  PlaybackState state, {
  Duration? preview,
  bool visible = true,
  Duration duration = const Duration(minutes: 3),
}) => MaterialApp(
  home: TickerMode(
    enabled: visible,
    child: PlaybackTimeBuilder(
      position: state.updatePosition,
      duration: duration,
      playback: state,
      preview: preview,
      builder: (context, seconds) => Text('$seconds'),
    ),
  ),
);

void main() {
  testWidgets('late native samples cannot roll a second backwards', (
    tester,
  ) async {
    await withClock(Clock(tester.binding.clock.now), () async {
      await tester.pumpWidget(_app(_state(10200)));
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('11'), findsOneWidget);

      await tester.pumpWidget(_app(_state(10990)));
      expect(find.text('11'), findsOneWidget);
      expect(find.text('10'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1010));
      expect(find.text('12'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('13'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('pause, buffering and scrubbing hold their exact positions', (
    tester,
  ) async {
    await withClock(Clock(tester.binding.clock.now), () async {
      await tester.pumpWidget(_app(_state(5500)));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('6'), findsOneWidget);
      await tester.pumpWidget(_app(_state(6000, playing: false)));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('6'), findsOneWidget);
      await tester.pumpWidget(
        _app(_state(6000, processing: AudioProcessingState.buffering)),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('6'), findsOneWidget);
      await tester.pumpWidget(_app(_state(30000), preview: Duration.zero));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('0'), findsOneWidget);
      await tester.pumpWidget(_app(_state(0, playing: false)));
      expect(find.text('0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('time follows playback speed and seeks immediately', (
    tester,
  ) async {
    await withClock(Clock(tester.binding.clock.now), () async {
      await tester.pumpWidget(_app(_state(7200, speed: 2)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('8'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('10'), findsOneWidget);
      await tester.pumpWidget(_app(_state(10200, speed: 0.5)));
      await tester.pump(const Duration(milliseconds: 1600));
      expect(find.text('11'), findsOneWidget);
      await tester.pumpWidget(_app(_state(2000)));
      expect(find.text('2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('hidden clocks sleep and resynchronize when shown', (
    tester,
  ) async {
    await withClock(Clock(tester.binding.clock.now), () async {
      final state = _state(200);
      await tester.pumpWidget(_app(state, visible: false));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('0'), findsOneWidget);
      await tester.pumpWidget(_app(state));
      expect(find.text('3'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('4'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('time stops at the duration boundary', (tester) async {
    await withClock(Clock(tester.binding.clock.now), () async {
      await tester.pumpWidget(
        _app(_state(9700), duration: const Duration(seconds: 10)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('10'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('10'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('background clocks resume from the current media time', (
    tester,
  ) async {
    await withClock(Clock(tester.binding.clock.now), () async {
      try {
        await tester.pumpWidget(_app(_state(200)));
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.text('1'), findsOneWidget);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(find.text('1'), findsOneWidget);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(find.text('3'), findsOneWidget);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });
}
