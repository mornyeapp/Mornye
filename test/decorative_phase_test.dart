import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/expressive_seek_track.dart';
import 'package:mornye/widgets/now_playing_indicator.dart';

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

Future<List<int>> _pixels(WidgetTester tester, Finder finder) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.descendant(of: finder, matching: find.byType(RepaintBoundary)).first,
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      return (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List().toList(growable: false);
    } finally {
      image.dispose();
    }
  }))!;
}

Widget _host(Widget child, {bool reduceMotion = false, bool visible = true}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: TickerMode(
          enabled: visible,
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );

void main() {
  tearDown(DecorativePhase.debugResetClock);

  group('DecorativePhase', () {
    testWidgets('advances at most 30 times a second at loop speed', (
      tester,
    ) async {
      final phase = DecorativePhase(const Duration(seconds: 2));
      addTearDown(phase.dispose);
      var notifications = 0;
      phase
        ..addListener(() => notifications++)
        ..start();
      expect(DecorativePhase.debugClockRunning, isTrue);

      await tester.binding.delayed(const Duration(seconds: 1));
      expect(notifications, inInclusiveRange(29, 30));
      // Each tick advances by the time that passed, so one second of a
      // two second loop is half a cycle.
      expect(phase.value, closeTo(0.5, 34 / 2000));

      phase.stop();
      expect(DecorativePhase.debugClockRunning, isFalse);
      final held = phase.value;
      await tester.binding.delayed(const Duration(seconds: 1));
      expect(notifications, inInclusiveRange(29, 30));
      expect(phase.value, held);

      phase.start();
      await tester.binding.delayed(DecorativePhase.interval);
      expect(phase.value, closeTo(held + 34 / 2000, 1e-9));
      phase.stop();
    });

    testWidgets('shares one clock that runs while any phase runs', (
      tester,
    ) async {
      final first = DecorativePhase(const Duration(seconds: 1));
      final second = DecorativePhase(const Duration(seconds: 3));
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      first.start();
      second.start();
      await tester.binding.delayed(const Duration(milliseconds: 340));
      expect(first.value, closeTo(0.34, 1e-9));
      expect(second.value, closeTo(0.34 / 3, 1e-9));

      first.stop();
      expect(DecorativePhase.debugClockRunning, isTrue);
      await tester.binding.delayed(const Duration(milliseconds: 340));
      expect(first.value, closeTo(0.34, 1e-9));
      expect(second.value, closeTo(0.68 / 3, 1e-9));

      second.stop();
      expect(DecorativePhase.debugClockRunning, isFalse);
    });

    testWidgets('holds while the app is hidden and resumes from there', (
      tester,
    ) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final phase = DecorativePhase(const Duration(seconds: 1));
      addTearDown(phase.dispose);
      phase.start();
      await tester.binding.delayed(const Duration(milliseconds: 340));
      expect(phase.value, closeTo(0.34, 1e-9));

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        expect(DecorativePhase.debugClockRunning, state == .inactive);
      }
      await tester.binding.delayed(const Duration(seconds: 1));
      expect(phase.value, closeTo(0.34, 1e-9));

      // Starting while hidden waits for frames too.
      phase.stop();
      phase.start();
      expect(DecorativePhase.debugClockRunning, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(DecorativePhase.debugClockRunning, isTrue);
      await tester.binding.delayed(DecorativePhase.interval);
      expect(phase.value, closeTo(0.374, 1e-9));
      phase.stop();
    });
  });

  group('NowPlayingIndicator', () {
    testWidgets('moves at no more than 30 frames a second while playing', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const NowPlayingIndicator(playing: true)));
      final indicator = find.byType(NowPlayingIndicator);
      final before = await _pixels(tester, indicator);
      expect(await _framesInOneSecond(tester), inInclusiveRange(29, 30));
      await tester.binding.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      expect(await _pixels(tester, indicator), isNot(orderedEquals(before)));
    });

    testWidgets('requests no frames while paused, hidden or reduced', (
      tester,
    ) async {
      for (final host in [
        _host(const NowPlayingIndicator(playing: false)),
        _host(const NowPlayingIndicator(playing: true), visible: false),
        _host(const NowPlayingIndicator(playing: true), reduceMotion: true),
      ]) {
        await tester.pumpWidget(
          _host(const NowPlayingIndicator(playing: true)),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpWidget(host);
        await tester.pump();
        expect(DecorativePhase.debugClockRunning, isFalse);
        expect(await _framesInOneSecond(tester), 0);
      }
    });

    testWidgets('stops waking the app while it is in the background', (
      tester,
    ) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await tester.pumpWidget(_host(const NowPlayingIndicator(playing: true)));
      await tester.pump(const Duration(milliseconds: 300));
      final indicator = find.byType(NowPlayingIndicator);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(DecorativePhase.debugClockRunning, isFalse);
      final held = await _pixels(tester, indicator);
      await tester.binding.delayed(const Duration(seconds: 1));
      expect(DecorativePhase.debugClockRunning, isFalse);
      expect(await _pixels(tester, indicator), orderedEquals(held));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(DecorativePhase.debugClockRunning, isTrue);
      expect(await _framesInOneSecond(tester), inInclusiveRange(29, 30));
      expect(await _pixels(tester, indicator), isNot(orderedEquals(held)));
    });
  });

  group('ExpressiveSeekTrack', () {
    Widget track({bool playing = true}) => ExpressiveSeekTrack(
      playing: playing,
      child: Slider(value: 0.5, onChanged: (_) {}),
    );

    testWidgets('waves at no more than 30 frames a second while playing', (
      tester,
    ) async {
      await tester.pumpWidget(_host(track()));
      // Let the amplitude rise, which animates at the display rate.
      await tester.pump(const Duration(milliseconds: 400));
      final wave = find.byType(ExpressiveSeekTrack);
      final before = await _pixels(tester, wave);
      expect(await _framesInOneSecond(tester), inInclusiveRange(29, 30));
      expect(await _pixels(tester, wave), isNot(orderedEquals(before)));
    });

    testWidgets('requests no frames once paused, hidden or reduced', (
      tester,
    ) async {
      for (final host in [
        _host(track(playing: false)),
        _host(track(), visible: false),
        _host(track(), reduceMotion: true),
      ]) {
        await tester.pumpWidget(_host(track()));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpWidget(host);
        await tester.pumpAndSettle();
        expect(DecorativePhase.debugClockRunning, isFalse);
        expect(await _framesInOneSecond(tester), 0);
      }
    });
  });
}
