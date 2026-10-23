import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/components/progress_indicators/components/m3e_linear_progress_painter.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

final _wave = find.ancestor(
  of: find.byWidgetPredicate(
    (widget) =>
        widget is CustomPaint && widget.painter is M3ELinearProgressPainter,
  ),
  matching: find.byType(RepaintBoundary),
);

Future<List<int>> _pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(_wave.first);
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

Widget _player({
  bool playing = true,
  bool visible = true,
  bool reduceMotion = false,
}) => ProviderScope(
  overrides: [
    currentMediaItemProvider.overrideWithBuild(
      (ref, notifier) => Stream.value(
        const MediaItem(
          id: 'song',
          title: 'Song',
          artist: 'Artist',
          duration: Duration(minutes: 2),
        ),
      ),
    ),
    playbackStateProvider.overrideWith((ref) => const Stream.empty()),
    playbackPlayingProvider.overrideWithValue(playing),
    playbackPositionProvider.overrideWithValue(const Duration(minutes: 1)),
    mornyeLiquidGlassProvider.overrideWithValue(false),
    backdropBlurEnabledProvider.overrideWithValue(false),
  ],
  child: MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: TickerMode(enabled: visible, child: child!),
    ),
    home: const Scaffold(
      bottomNavigationBar: SizedBox(width: 360, child: MiniPlayer()),
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(DecorativePhase.debugResetClock);

  group('Material mini player wave', () {
    testWidgets('moves at no more than 30 frames a second while playing', (
      tester,
    ) async {
      await tester.pumpWidget(_player());
      await tester.pump(const Duration(milliseconds: 400));
      final before = await _pixels(tester);
      expect(await _framesInOneSecond(tester), inInclusiveRange(29, 30));
      expect(await _pixels(tester), isNot(orderedEquals(before)));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('requests no frames once paused, hidden or reduced', (
      tester,
    ) async {
      for (final host in [
        _player(playing: false),
        _player(visible: false),
        _player(reduceMotion: true),
      ]) {
        await tester.pumpWidget(_player());
        await tester.pump(const Duration(milliseconds: 400));
        expect(DecorativePhase.debugClockRunning, isTrue);
        await tester.pumpWidget(host);
        await tester.pumpAndSettle();
        expect(DecorativePhase.debugClockRunning, isFalse);
        expect(await _framesInOneSecond(tester), 0);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('holds while the app is in the background', (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await tester.pumpWidget(_player());
      await tester.pump(const Duration(milliseconds: 400));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(DecorativePhase.debugClockRunning, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(await _framesInOneSecond(tester), inInclusiveRange(29, 30));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('paints and reads like the package wavy indicator', (
      tester,
    ) async {
      // Hidden before the first clock tick, the wave keeps its first phase,
      // as a muted package ticker does.
      await tester.pumpWidget(_player());
      await tester.pump();
      expect(_wave.first, findsOneWidget);
      await tester.pumpWidget(_player(visible: false));
      expect(DecorativePhase.debugClockRunning, isFalse);
      final semantics = tester.ensureSemantics();
      final element = tester.element(_wave.first);
      final theme = Theme.of(element);
      final width = tester.getSize(_wave.first).width;
      final wave = await _pixels(tester);
      final waveData = tester.getSemantics(_wave.first).getSemanticsData();

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: TickerMode(
            enabled: false,
            child: Center(
              child: SizedBox(
                width: width,
                child: MaterialExpressiveScope(
                  child: M3EProgressIndicator.linearWavy(
                    value: 0.5,
                    linearSize: M3EProgressIndicatorSize.s,
                    trackColor: theme.colorScheme.surfaceContainerHighest,
                    amplitudeForProgress: (value) =>
                        (math.min(value, 1 - value) / 0.05).clamp(0.0, 1.0),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(await _pixels(tester), orderedEquals(wave));
      final reference = tester.getSemantics(_wave.first).getSemanticsData();
      expect(waveData.role, SemanticsRole.progressBar);
      expect(waveData.value, '50%');
      expect(reference.role, waveData.role);
      expect(reference.value, waveData.value);
      semantics.dispose();
    });
  });
}
