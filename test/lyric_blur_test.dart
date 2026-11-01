import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/lyric_blur.dart';

const _devicePixelRatio = 3.0;

class _Line {
  const _Line({
    this.text = 'A defocused line',
    this.fontSize = 30,
    this.color = Colors.white,
    this.brightness = Brightness.dark,
    this.textScale = 1,
    this.width = 300,
    this.sigma = 3.6,
    this.settled = true,
    this.devicePixelRatio = _devicePixelRatio,
  });

  final String text;
  final double fontSize;
  final Color color;
  final Brightness brightness;
  final double textScale;
  final double width;
  final double sigma;
  final bool settled;
  final double devicePixelRatio;

  Widget build({ValueListenable<double>? offset}) => MaterialApp(
    theme: ThemeData(brightness: brightness),
    themeAnimationDuration: Duration.zero,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          devicePixelRatio: devicePixelRatio,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: const ValueKey('capture'),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ValueListenableBuilder<double>(
                valueListenable: offset ?? ValueNotifier(0),
                builder: (context, offset, child) => Transform.translate(
                  offset: Offset(0, offset),
                  child: child,
                ),
                child: SizedBox(
                  width: width,
                  child: LyricBlur(
                    sigma: sigma,
                    settled: settled,
                    child: Builder(
                      builder: (context) => Text(
                        text,
                        style: Theme.of(context).textTheme.headlineSmall!
                            .copyWith(fontSize: fontSize, color: color)
                            .merge(
                              TextStyle(
                                // Theme brightness reaches the painted text.
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.surface,
                              ),
                            ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

RenderLyricBlurSnapshot _render(WidgetTester tester) =>
    tester.renderObject<RenderLyricBlurSnapshot>(
      find.descendant(
        of: find.byType(LyricBlur),
        matching: find.byElementPredicate(
          (element) =>
              element is RenderObjectElement &&
              element.renderObject is RenderLyricBlurSnapshot,
        ),
      ),
    );

ui.Image? _snapshot(WidgetTester tester) => _render(tester).debugSnapshot;

Future<ui.Image> _settle(WidgetTester tester, Widget line) async {
  await tester.pumpWidget(line);
  // The first settled frame blurs live; the next unchanged frame snapshots.
  expect(_snapshot(tester), isNull);
  await tester.pump();
  return _snapshot(tester)!;
}

bool _hasLiveBlur(WidgetTester tester) {
  var found = false;
  void visit(Layer layer) {
    if (layer is ImageFilterLayer) found = true;
    if (layer is ContainerLayer) {
      for (
        var child = layer.firstChild;
        child != null;
        child = child.nextSibling
      ) {
        visit(child);
      }
    }
  }

  visit(_render(tester).debugLayer!);
  return found;
}

Future<List<int>> _pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _devicePixelRatio);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    image.dispose();
    return bytes.buffer.asUint8List().toList();
  }))!;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  for (final state in AppLifecycleState.values) {
    if (state == AppLifecycleState.resumed) continue;
    testWidgets('releases the snapshot while $state and rebuilds on resume', (
      tester,
    ) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final before = await _settle(tester, const _Line().build());

      tester.binding.handleAppLifecycleStateChanged(state);
      expect(before.debugDisposed, isTrue);
      for (var frame = 0; frame < 3; frame++) {
        tester.binding.scheduleForcedFrame();
        await tester.pump();
        expect(_snapshot(tester), isNull);
      }
      expect(tester.binding.hasScheduledFrame, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(_snapshot(tester), isNull);
      expect(_hasLiveBlur(tester), isTrue);
      await tester.pump();
      final after = _snapshot(tester)!;
      expect(after, isNot(same(before)));
      expect(after.debugDisposed, isFalse);
    });
  }

  testWidgets('a pending snapshot repaint stops when focus is lost mid-frame', (
    tester,
  ) async {
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    tester.binding.addPostFrameCallback((_) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    });
    await tester.pumpWidget(const _Line().build());
    for (var frame = 0; frame < 3; frame++) {
      tester.binding.scheduleFrame();
      await tester.pump();
      expect(_snapshot(tester), isNull);
    }
    expect(tester.binding.hasScheduledFrame, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(_snapshot(tester), isNotNull);
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a line blurs live until its blur settles', (tester) async {
    await tester.pumpWidget(const _Line(sigma: 2, settled: false).build());
    await tester.pump();
    expect(
      tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
      true,
    );
    expect(_snapshot(tester), isNull);

    final offset = ValueNotifier<double>(0);
    addTearDown(offset.dispose);
    final snapshot = await _settle(tester, const _Line().build(offset: offset));
    expect(
      tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
      false,
    );
    expect(_hasLiveBlur(tester), isFalse);

    // Moving the row reuses the image instead of blurring again.
    for (var frame = 1; frame <= 3; frame++) {
      offset.value = frame * 4;
      await tester.pump();
      expect(_snapshot(tester), same(snapshot));
      expect(_hasLiveBlur(tester), isFalse);
    }

    await tester.pumpWidget(const _Line(sigma: 4, settled: false).build());
    expect(snapshot.debugDisposed, isTrue);
    expect(_snapshot(tester), isNull);
    expect(
      tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
      true,
    );
  });

  testWidgets('an unblurred line is never snapshotted', (tester) async {
    await tester.pumpWidget(const _Line(sigma: 0).build());
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump();
      expect(_snapshot(tester), isNull);
    }
    expect(_render(tester).isRepaintBoundary, isTrue);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('the snapshot matches the live blur', (tester) async {
    await tester.pumpWidget(const _Line(settled: false).build());
    await tester.pump();
    final live = await _pixels(tester);
    await _settle(tester, const _Line().build());
    expect(_hasLiveBlur(tester), isFalse);
    // The host renderer draws the snapshot exactly like the live blur.
    expect(await _pixels(tester), live);
  });

  const changes = {
    'text': _Line(text: 'Another defocused line'),
    'style': _Line(fontSize: 34),
    'colour': _Line(color: Colors.amber),
    'theme': _Line(brightness: Brightness.light),
    'text scale': _Line(textScale: 1.3),
    'size': _Line(width: 260),
    'sigma': _Line(sigma: 4.8),
    'device pixel ratio': _Line(devicePixelRatio: 2),
  };
  for (final MapEntry(key: input, value: changed) in changes.entries) {
    testWidgets('a $input change replaces the snapshot', (tester) async {
      final before = await _settle(tester, const _Line().build());
      await tester.pumpWidget(changed.build());
      expect(before.debugDisposed, isTrue);
      // The changed frame blurs live, then the new line is snapshotted.
      expect(_snapshot(tester), isNull);
      expect(_hasLiveBlur(tester), isTrue);
      await tester.pump();
      final after = _snapshot(tester)!;
      expect(after, isNot(same(before)));
      expect(after.debugDisposed, isFalse);
    });
  }

  testWidgets('a line keeps blurring live while it keeps changing', (
    tester,
  ) async {
    await _settle(tester, const _Line().build());
    for (var frame = 0; frame < 4; frame++) {
      await tester.pumpWidget(_Line(fontSize: 30 + frame + 1.0).build());
      expect(_snapshot(tester), isNull);
      expect(_hasLiveBlur(tester), isTrue);
    }
    await tester.pump();
    expect(_snapshot(tester), isNotNull);
  });

  testWidgets('a rebuild under a nested layer replaces the snapshot', (
    tester,
  ) async {
    Widget build(Color color) => MaterialApp(
      home: Center(
        child: LyricBlur(
          sigma: 3.6,
          settled: true,
          child: Opacity(
            opacity: 0.8,
            child: Text('Supplement', style: TextStyle(color: color)),
          ),
        ),
      ),
    );

    final before = await _settle(tester, build(Colors.white));
    await tester.pumpWidget(build(Colors.amber));
    expect(before.debugDisposed, isTrue);
    expect(_hasLiveBlur(tester), isTrue);
    await tester.pump();
    expect(_snapshot(tester), isNotNull);
  });

  testWidgets('switching content snapshots only after the fade', (
    tester,
  ) async {
    Widget build(String text) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 300,
          child: LyricBlur(
            sigma: 3.6,
            settled: true,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: LyricBlur.fadeTransition,
              child: Text(text, key: ValueKey(text)),
            ),
          ),
        ),
      ),
    );

    await _settle(tester, build('First'));
    await tester.pumpWidget(build('Second'));
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(_snapshot(tester), isNull);
      expect(_hasLiveBlur(tester), isTrue);
    }
    await tester.pumpAndSettle();
    expect(_snapshot(tester), isNotNull);
    expect(find.text('First'), findsNothing);
  });

  testWidgets('removing the line disposes its snapshot', (tester) async {
    final snapshot = await _settle(tester, const _Line().build());
    await tester.pumpWidget(const SizedBox());
    expect(snapshot.debugDisposed, isTrue);
  });
}
