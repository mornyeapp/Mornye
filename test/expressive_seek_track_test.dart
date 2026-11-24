import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/expressive_seek_track.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';

Widget _host({
  bool playing = true,
  bool reduceMotion = false,
  bool visible = true,
  bool mornye = false,
  TextDirection direction = TextDirection.ltr,
  Duration position = const Duration(seconds: 30),
  Duration duration = const Duration(seconds: 100),
  Future<void> Function(Duration)? onSeek,
}) => MaterialApp(
  theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Directionality(
      textDirection: direction,
      child: TickerMode(
        enabled: visible,
        child: Scaffold(
          body: Center(
            child: PlaybackSeekSlider(
              playing: playing,
              position: position,
              duration: duration,
              onSeek: onSeek ?? (_) async {},
            ),
          ),
        ),
      ),
    ),
  ),
);

ExpressiveSeekTrackShape _track(WidgetTester tester) =>
    SliderTheme.of(tester.element(find.byType(Slider))).trackShape!
        as ExpressiveSeekTrackShape;

void main() {
  testWidgets(
    'wave ticks repaint raster pixels without rebuilding slider theme',
    (tester) async {
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExpressiveSeekTrack(
              playing: true,
              child: Builder(
                builder: (context) {
                  SliderTheme.of(context);
                  builds++;
                  return Slider(value: 0.5, onChanged: (_) {});
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find
            .descendant(
              of: find.byType(ExpressiveSeekTrack),
              matching: find.byType(RepaintBoundary),
            )
            .first,
      );
      Future<List<int>> pixels() async => (await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          return (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List().toList(growable: false);
        } finally {
          image.dispose();
        }
      }))!;
      final shape = _track(tester);
      final initialBuilds = builds;
      final before = await pixels();
      await tester.pump(const Duration(milliseconds: 150));
      final after = await pixels();
      expect(after, isNot(orderedEquals(before)));
      expect(builds, initialBuilds);
      expect(_track(tester), same(shape));
      expect(shape.amplitude, 1);
    },
  );

  testWidgets('wave ticks retain slider theme and its dependent subtree', (
    tester,
  ) async {
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExpressiveSeekTrack(
            playing: true,
            child: Builder(
              builder: (context) {
                SliderTheme.of(context);
                builds++;
                return Slider(value: 0.3, onChanged: (_) {});
              },
            ),
          ),
        ),
      ),
    );
    final shape = _track(tester);
    final initialBuilds = builds;
    final initialPhase = shape.phase;
    for (var frame = 0; frame < 90; frame++) {
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(builds, initialBuilds);
    expect(_track(tester), same(shape));
    expect(shape.phase, isNot(initialPhase));
    expect(shape.amplitude, 1);
  });

  testWidgets('wave travels during playback and settles smoothly on pause', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 400));
    final phase = _track(tester).phase;
    expect(_track(tester).amplitude, 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_track(tester).phase, isNot(phase));
    expect(tester.widget<Slider>(find.byType(Slider)).value, 30000);

    await tester.pumpWidget(_host(playing: false));
    await tester.pump(const Duration(milliseconds: 150));
    expect(_track(tester).amplitude, greaterThan(0));
    expect(_track(tester).amplitude, lessThan(1));
    await tester.pumpAndSettle();
    expect(_track(tester).amplitude, 0);
    final pausedPhase = _track(tester).phase;
    await tester.pump(const Duration(seconds: 2));
    expect(_track(tester).phase, pausedPhase);
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 400));
    expect(_track(tester).amplitude, 1);
    expect(_track(tester).phase, isNot(pausedPhase));
  });

  testWidgets('scrubbing flattens the track and playback restores the wave', (
    tester,
  ) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(_host(onSeek: (target) async => seeks.add(target)));
    await tester.pump(const Duration(milliseconds: 400));
    final bounds = tester.getRect(find.byType(Slider));
    final gesture = await tester.startGesture(bounds.center);
    await gesture.moveBy(Offset(bounds.width * 0.2, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_track(tester).amplitude, 0);
    expect(seeks, isEmpty);
    final preview = tester.widget<Slider>(find.byType(Slider)).value;
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(seeks, [Duration(milliseconds: preview.round())]);
    expect(_track(tester).amplitude, 1);
  });

  testWidgets('reduced motion and hidden routes stop the animation', (
    tester,
  ) async {
    for (final reduceMotion in [true, false]) {
      await tester.pumpWidget(_host());
      await tester.pump(const Duration(milliseconds: 400));
      expect(_track(tester).amplitude, 1);
      await tester.pumpWidget(
        _host(reduceMotion: reduceMotion, visible: reduceMotion),
      );
      await tester.pumpAndSettle();
      expect(_track(tester).amplitude, 0);
      final phase = _track(tester).phase;
      await tester.pump(const Duration(seconds: 2));
      expect(_track(tester).phase, phase);
      expect(tester.binding.hasScheduledFrame, isFalse);
    }
  });

  testWidgets('unknown and completed tracks do not animate', (tester) async {
    for (final duration in [Duration.zero, const Duration(seconds: 30)]) {
      await tester.pumpWidget(_host(duration: duration));
      await tester.pumpAndSettle();
      expect(_track(tester).amplitude, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
    }
  });

  testWidgets('Mornye keeps its continuous track without a wave or handle', (
    tester,
  ) async {
    await tester.pumpWidget(_host(mornye: true));
    await tester.pumpAndSettle();
    expect(find.byType(ExpressiveSeekTrack), findsNothing);
    final theme = SliderTheme.of(tester.element(find.byType(Slider)));
    expect(theme.trackShape, isA<RoundedRectSliderTrackShape>());
    expect(theme.thumbShape, SliderComponentShape.noThumb);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('RTL seeking and screen reader adjustment remain available', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final seeks = <Duration>[];
    await tester.pumpWidget(
      _host(
        direction: TextDirection.rtl,
        onSeek: (target) async => seeks.add(target),
      ),
    );
    final bounds = tester.getRect(find.byType(Slider));
    await tester.tapAt(
      Offset(bounds.left + bounds.width * 0.2, bounds.center.dy),
    );
    await tester.pump();
    expect(seeks.single.inSeconds, greaterThan(70));
    final node = tester.semantics.simulatedAccessibilityTraversal().singleWhere(
      (node) => node.getSemanticsData().flagsCollection.isSlider,
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
    node.owner!.performAction(node.id, SemanticsAction.increase);
    await tester.pump();
    expect(seeks, hasLength(2));
    expect(seeks.last.inSeconds, greaterThan(30));
    semantics.dispose();
  });
}
