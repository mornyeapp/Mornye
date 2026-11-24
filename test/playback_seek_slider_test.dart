import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';

void main() {
  testWidgets('scrubbing previews locally and commits only the final target', (
    tester,
  ) async {
    final seeks = <Duration>[];
    final sharedPreview = PlaybackSeekPreview();
    addTearDown(sharedPreview.dispose);
    final completion = Completer<void>();
    Widget app(Duration position) => MaterialApp(
      home: Scaffold(
        body: PlaybackSeekSlider(
          preview: sharedPreview,
          playing: true,
          position: position,
          duration: const Duration(seconds: 100),
          onSeek: (target) {
            seeks.add(target);
            return completion.future;
          },
        ),
      ),
    );

    await tester.pumpWidget(app(const Duration(seconds: 10)));
    final bounds = tester.getRect(find.byType(Slider));
    final gesture = await tester.startGesture(
      Offset(bounds.left + bounds.width * 0.3, bounds.center.dy),
    );
    await gesture.moveBy(Offset(bounds.width * 0.3, 0));
    await tester.pump();
    final preview = tester.widget<Slider>(find.byType(Slider)).value;
    expect(preview, greaterThan(50000));
    expect(sharedPreview.value, Duration(milliseconds: preview.round()));
    expect(seeks, isEmpty);

    await tester.pumpWidget(app(const Duration(seconds: 11)));
    expect(tester.widget<Slider>(find.byType(Slider)).value, preview);
    expect(sharedPreview.value, Duration(milliseconds: preview.round()));
    await gesture.up();
    await tester.pump();
    expect(seeks, [Duration(milliseconds: preview.round())]);
    expect(tester.widget<Slider>(find.byType(Slider)).value, preview);

    await tester.pumpWidget(app(seeks.single));
    completion.complete();
    await tester.pump();
    await tester.pump();
    expect(sharedPreview.value, isNull);
    expect(
      tester.widget<Slider>(find.byType(Slider)).value,
      seeks.single.inMilliseconds.toDouble(),
    );
  });

  testWidgets('an earlier seek completion does not erase a new drag', (
    tester,
  ) async {
    final completions = <Completer<void>>[];
    final sharedPreview = PlaybackSeekPreview();
    addTearDown(sharedPreview.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackSeekSlider(
            preview: sharedPreview,
            position: Duration.zero,
            duration: const Duration(seconds: 100),
            onSeek: (_) {
              final completion = Completer<void>();
              completions.add(completion);
              return completion.future;
            },
          ),
        ),
      ),
    );
    final bounds = tester.getRect(find.byType(Slider));
    await tester.tapAt(Offset(bounds.center.dx, bounds.center.dy));
    await tester.pump();
    expect(completions, hasLength(1));

    final gesture = await tester.startGesture(
      Offset(bounds.left + bounds.width * 0.8, bounds.center.dy),
    );
    await tester.pump();
    final preview = tester.widget<Slider>(find.byType(Slider)).value;
    completions.first.complete();
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, preview);
    expect(sharedPreview.value, Duration(milliseconds: preview.round()));
    await gesture.up();
    expect(completions, hasLength(2));
    completions.last.complete();
    await tester.pump();
    await tester.pump();
    expect(sharedPreview.value, isNull);
  });

  testWidgets('removing a Mornye slider releases its pending preview safely', (
    tester,
  ) async {
    final preview = PlaybackSeekPreview();
    addTearDown(preview.dispose);
    final completion = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        theme: MornyeTheme.build(Brightness.dark),
        home: Scaffold(
          body: PlaybackSeekSlider(
            preview: preview,
            position: Duration.zero,
            duration: const Duration(seconds: 100),
            onSeek: (_) => completion.future,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(Slider));
    await tester.pump();
    expect(preview.value, isNotNull);
    await tester.pumpWidget(const SizedBox());
    expect(preview.value, isNull);
    final session = preview.begin(const Duration(seconds: 20));
    completion.complete();
    await tester.pump();
    expect(preview.value, const Duration(seconds: 20));
    preview.end(session);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed seeks release the shared preview', (tester) async {
    final preview = PlaybackSeekPreview();
    addTearDown(preview.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackSeekSlider(
            preview: preview,
            position: Duration.zero,
            duration: const Duration(seconds: 100),
            onSeek: (_) async => throw StateError('Seek failed'),
          ),
        ),
      ),
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(50000);
    slider.onChanged!(50000);
    final commit = slider.onChangeEnd! as Future<void> Function(double);
    await expectLater(commit(50000), throwsStateError);
    expect(preview.value, isNull);
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0);
  });

  test('track reset invalidates pending preview sessions', () {
    final preview = PlaybackSeekPreview();
    addTearDown(preview.dispose);
    final oldSession = preview.begin(const Duration(seconds: 30));
    preview.reset();
    preview.update(oldSession, const Duration(seconds: 40));
    expect(preview.value, isNull);
    preview.begin(const Duration(seconds: 10));
    preview.end(oldSession);
    expect(preview.value, const Duration(seconds: 10));
  });

  testWidgets('unknown duration disables seek and clamps stale position', (
    tester,
  ) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackSeekSlider(
            position: const Duration(minutes: 2),
            duration: Duration.zero,
            onSeek: (target) async => seeks.add(target),
          ),
        ),
      ),
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 0);
    expect(slider.onChanged, isNull);
    await tester.tap(find.byType(Slider));
    expect(seeks, isEmpty);
  });
}
