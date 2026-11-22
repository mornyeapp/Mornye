import 'dart:ui' show Tristate;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show AdaptiveGlass;
import 'package:material_ui/material_ui.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_liquid_backdrop.dart';
import 'package:mornye/widgets/mornye_slider.dart';

Widget _harness(
  Widget slider, {
  MornyeGlassLevel level = MornyeGlassLevel.liquid,
  TextDirection direction = TextDirection.ltr,
  double clarity = 0.75,
  double? scale,
  Brightness brightness = Brightness.light,
}) => ProviderScope(
  overrides: [mornyeGlassLevelProvider.overrideWithValue(level)],
  child: MaterialApp(
    theme: MornyeTheme.build(brightness, glassClarity: clarity),
    builder: scale == null
        ? null
        : (context, child) => AdaptiveUiScaler(userScale: scale, child: child!),
    home: Scaffold(
      body: Directionality(
        textDirection: direction,
        // A slider fills a bounded height, so it sits in a column as on a
        // settings page.
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [SizedBox(width: 300, child: slider)],
        ),
      ),
    ),
  ),
);

/// The slider's own semantics node, below any label merged around it.
SemanticsNode _sliderNode(WidgetTester tester) {
  SemanticsNode? found;
  bool visit(SemanticsNode node) {
    if (node.getSemanticsData().flagsCollection.isSlider) {
      found = node;
      return false;
    }
    node.visitChildren(visit);
    return found == null;
  }

  visit(tester.getSemantics(find.byType(MornyeSlider)));
  return found!;
}

Finder get _lens => find.byWidgetPredicate(
  (widget) => widget is MornyeLiquidBackdrop && widget.interaction,
);

Finder get _restingThumb => find.byWidgetPredicate(
  (widget) =>
      widget is DecoratedBox &&
      widget.decoration is BoxDecoration &&
      (widget.decoration as BoxDecoration).color == Colors.white &&
      (widget.decoration as BoxDecoration).boxShadow != null,
);

/// Holds the thumb in the middle of a 300 wide slider.
Future<TestGesture> _hold(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(MornyeSlider)),
  );
  await gesture.moveBy(const Offset(24, 0));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return gesture;
}

void main() {
  setUp(() => MornyeGlass.debugShaderFilterSupport = true);
  tearDown(() => MornyeGlass.debugShaderFilterSupport = null);

  testWidgets('Mornye AppSlider is the iOS slider; Material keeps its own', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(AppSlider(value: 0.5, onChanged: (_) {})));
    expect(find.byType(MornyeSlider), findsOneWidget);
    final mornyeHeight = tester.getSize(find.byType(AppSlider)).height;

    // The standard slider Mornye showed before is the touch band to keep.
    await tester.pumpWidget(_harness(Slider(value: 0.5, onChanged: (_) {})));
    expect(mornyeHeight, tester.getSize(find.byType(Slider)).height);
    expect(mornyeHeight, 48);

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      ProviderScope(
        key: const ValueKey('material'),
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: AppSlider(value: 0.5, onChanged: (_) {}),
              ),
            ),
          ),
        ),
      ),
    );
    // Material under reduced motion keeps the standard slider.
    expect(find.byType(MornyeSlider), findsNothing);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('a resting slider mounts no glass and the held thumb is a lens', (
    tester,
  ) async {
    double? ended;
    var value = 0.5;
    await tester.pumpWidget(
      _harness(
        StatefulBuilder(
          builder: (context, setState) => AppSlider(
            value: value,
            onChanged: (next) => setState(() => value = next),
            onChangeEnd: (next) => ended = next,
          ),
        ),
      ),
    );
    final slider = find.byType(MornyeSlider);
    Finder inSlider(Type type) =>
        find.descendant(of: slider, matching: find.byType(type));
    expect(_lens, findsNothing);
    expect(inSlider(AdaptiveGlass), findsNothing);
    expect(inSlider(BackdropFilter), findsNothing);
    expect(inSlider(ShaderMask), findsNothing);
    expect(_restingThumb, findsOneWidget);

    final gesture = await _hold(tester);
    expect(_lens, findsOneWidget);
    expect(inSlider(AdaptiveGlass), findsOneWidget);
    final lens = tester.widget<MornyeLiquidBackdrop>(_lens);
    expect(lens.progress, closeTo(1, 0.1));
    expect(lens.refractiveIndex, MornyeSlider.lensRefractiveIndex);
    expect(value, greaterThan(0.5));
    // The lens swells around the thumb's place on the track.
    final lensSize = tester.getSize(_lens);
    expect(
      lensSize.width,
      closeTo(MornyeSlider.thumbLength * (1 + MornyeSlider.heldGrowth), 2),
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(ended, value);
    expect(_lens, findsNothing);
    expect(inSlider(AdaptiveGlass), findsNothing);
    expect(_restingThumb, findsOneWidget);
  });

  for (final (name, level, clarity, shaders, highContrast, reduceMotion) in [
    ('frosted glass', MornyeGlassLevel.frosted, 0.75, true, false, false),
    ('flat glass', MornyeGlassLevel.flat, 0.75, true, false, false),
    ('low clarity', MornyeGlassLevel.liquid, 0.2, true, false, false),
    ('no shader filters', MornyeGlassLevel.liquid, 0.75, false, false, false),
    ('increased contrast', MornyeGlassLevel.liquid, 0.75, true, true, false),
    ('reduced motion', MornyeGlassLevel.liquid, 0.75, true, false, true),
  ]) {
    testWidgets('no lens while held with $name', (tester) async {
      MornyeGlass.debugShaderFilterSupport = shaders;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(
            highContrast: highContrast,
            disableAnimations: reduceMotion,
          );
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      var value = 0.5;
      await tester.pumpWidget(
        _harness(
          level: level,
          clarity: clarity,
          StatefulBuilder(
            builder: (context, setState) => AppSlider(
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      );
      final gesture = await _hold(tester);
      expect(value, greaterThan(0.5));
      expect(_lens, findsNothing);
      expect(find.byType(AdaptiveGlass), findsNothing);
      // The plain white thumb, at its resting size.
      expect(_restingThumb, findsOneWidget);
      expect(
        tester.getSize(_restingThumb),
        const Size(MornyeSlider.thumbLength, MornyeSlider.thumbThickness),
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });
  }

  testWidgets('the lift follows the Animation speed setting', (tester) async {
    Future<double> liftAfter(Duration time) async {
      var value = 0.5;
      await tester.pumpWidget(
        _harness(
          StatefulBuilder(
            builder: (context, setState) => AppSlider(
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(MornyeSlider)),
      );
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await tester.pump(time);
      final progress = tester.widget<MornyeLiquidBackdrop>(_lens).progress;
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      return progress;
    }

    const early = Duration(milliseconds: 60);
    final normal = await liftAfter(early);
    MotionPace.speed = 0.25;
    addTearDown(() => MotionPace.speed = 1);
    final slow = await liftAfter(early);
    expect(slow, lessThan(normal * 0.5));
  });

  testWidgets('divisions snap and the thumb sits on its stop', (tester) async {
    final values = <double>[];
    var value = 0.0;
    await tester.pumpWidget(
      _harness(
        StatefulBuilder(
          builder: (context, setState) => AppSlider(
            value: value,
            divisions: 4,
            label: '$value',
            onChanged: (next) {
              values.add(next);
              setState(() => value = next);
            },
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byType(MornyeSlider));
    final gesture = await tester.startGesture(
      box.centerLeft + const Offset(20, 0),
    );
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(17, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(values, isNotEmpty);
    for (final v in values) {
      expect((v * 4).roundToDouble(), v * 4, reason: '$v');
    }
    expect(tester.widget<Slider>(find.byType(Slider)).label, '$value');
    // The drawn thumb stands where the slider reports its thumb, on every
    // stop.
    final owner = _sliderNode(tester).owner!;
    while (value > 0) {
      owner.performAction(_sliderNode(tester).id, SemanticsAction.decrease);
      await tester.pumpAndSettle();
    }
    for (var stop = 0; stop <= 4; stop++) {
      // The slider's node is a thumb-sized box in the slider's own space.
      final node = _sliderNode(tester);
      expect(node.transform, isNull);
      expect(node.parent!.rect.size, const Size(300, 48));
      expect(value, stop / 4);
      final slider = tester.getTopLeft(find.byType(MornyeSlider));
      expect(
        tester.getCenter(_restingThumb).dx - slider.dx,
        closeTo(node.rect.center.dx, 0.5),
        reason: '$stop',
      );
      owner.performAction(node.id, SemanticsAction.increase);
      await tester.pumpAndSettle();
    }
  });

  testWidgets('right to left puts the minimum on the right', (tester) async {
    var value = 0.5;
    await tester.pumpWidget(
      _harness(
        direction: TextDirection.rtl,
        StatefulBuilder(
          builder: (context, setState) => AppSlider(
            value: value,
            onChanged: (next) => setState(() => value = next),
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byType(MornyeSlider));
    await tester.tapAt(box.centerLeft + const Offset(19, 0));
    await tester.pumpAndSettle();
    expect(value, closeTo(1, 0.02));
    expect(tester.getCenter(_restingThumb).dx, closeTo(box.left + 18.5, 1));
    await tester.tapAt(box.centerRight - const Offset(19, 0));
    await tester.pumpAndSettle();
    expect(value, closeTo(0, 0.02));
    expect(tester.getCenter(_restingThumb).dx, closeTo(box.right - 18.5, 1));
  });

  testWidgets('a vertical slider runs bottom to top with an upright thumb', (
    tester,
  ) async {
    var value = 0.0;
    await tester.pumpWidget(
      _harness(
        direction: TextDirection.rtl,
        SizedBox(
          height: 240,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatefulBuilder(
                builder: (context, setState) => AppSlider(
                  vertical: true,
                  centered: true,
                  min: -10,
                  max: 10,
                  value: value,
                  onChanged: (next) => setState(() => value = next),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byType(MornyeSlider));
    expect(box.width, 48);
    expect(box.height, 240);
    await tester.tapAt(box.topCenter + const Offset(0, 19));
    await tester.pumpAndSettle();
    expect(value, closeTo(10, 0.3));
    expect(
      tester.getSize(_restingThumb),
      const Size(MornyeSlider.thumbThickness, MornyeSlider.thumbLength),
    );
    expect(tester.getCenter(_restingThumb).dy, closeTo(box.top + 18.5, 1));
    await tester.tapAt(box.bottomCenter - const Offset(0, 19));
    await tester.pumpAndSettle();
    expect(value, closeTo(-10, 0.3));
    expect(tester.getCenter(_restingThumb).dy, closeTo(box.bottom - 18.5, 1));

    // Held, the lens stands upright too.
    final gesture = await tester.startGesture(box.center);
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final lens = tester.getSize(_lens);
    expect(lens.height, greaterThan(lens.width));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a centered slider grows its active track from the middle', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        AppSlider(centered: true, min: -1, max: 1, value: 1, onChanged: (_) {}),
      ),
    );
    final scheme = Theme.of(
      tester.element(find.byType(MornyeSlider)),
    ).colorScheme;
    final track = find.descendant(
      of: find.byType(MornyeSlider),
      matching: find.byType(CustomPaint),
    );
    const thickness = MornyeSlider.trackThickness;
    const top = (48 - thickness) / 2;
    expect(
      tester.renderObject(track.last),
      paints
        ..rrect(
          rrect: RRect.fromLTRBR(
            0,
            top,
            300,
            top + thickness,
            const Radius.circular(3),
          ),
        )
        ..rrect(
          rrect: RRect.fromLTRBR(
            150,
            top,
            300 - 18.5,
            top + thickness,
            const Radius.circular(3),
          ),
          color: scheme.primary,
        ),
    );
  });

  testWidgets('a disabled slider ignores a finger and grows no lens', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _harness(const AppSlider(value: 0.5, onChanged: null)),
    );
    final gesture = await _hold(tester);
    expect(_lens, findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    final data = _sliderNode(tester).getSemanticsData();
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    expect(data.hasAction(SemanticsAction.increase), isFalse);
    expect(data.hasAction(SemanticsAction.decrease), isFalse);
    handle.dispose();
  });

  testWidgets('semantics increase and decrease and read the formatter', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var value = 0.5;
    await tester.pumpWidget(
      _harness(
        StatefulBuilder(
          builder: (context, setState) => AppSlider(
            value: value,
            divisions: 10,
            semanticLabel: 'Clarity',
            semanticFormatterCallback: (v) => '${(v * 100).round()} percent',
            onChanged: (next) => setState(() => value = next),
          ),
        ),
      ),
    );
    // AppSlider merges its label into the slider's node.
    final labelled = tester.getSemantics(find.byType(Slider));
    final data = labelled.getSemanticsData();
    expect(data.label, 'Clarity');
    expect(data.value, '50 percent');
    expect(data.increasedValue, '60 percent');
    expect(data.decreasedValue, '40 percent');
    final owner = labelled.owner!;
    owner.performAction(labelled.id, SemanticsAction.increase);
    await tester.pumpAndSettle();
    expect(value, closeTo(0.6, 1e-9));
    for (var i = 0; i < 2; i++) {
      owner.performAction(
        tester.getSemantics(find.byType(Slider)).id,
        SemanticsAction.decrease,
      );
      await tester.pumpAndSettle();
    }
    expect(value, closeTo(0.4, 1e-9));
    // An adjustment is no hold: the thumb never lifts.
    expect(_lens, findsNothing);
    handle.dispose();
  });

  testWidgets('arrow keys adjust a focused slider and show its focus', (
    tester,
  ) async {
    var value = 0.5;
    await tester.pumpWidget(
      _harness(
        StatefulBuilder(
          builder: (context, setState) => AppSlider(
            value: value,
            divisions: 10,
            onChanged: (next) => setState(() => value = next),
          ),
        ),
      ),
    );
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    tester.widget<Slider>(find.byType(Slider)).focusNode!.requestFocus();
    await tester.pump();
    final ring = find.descendant(
      of: _restingThumb,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox && widget.decoration is ShapeDecoration,
      ),
    );
    expect(ring, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(value, closeTo(0.6, 1e-9));
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
    }
    expect(value, closeTo(0.4, 1e-9));
  });

  testWidgets('the held lens measures the window under an interface scale', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(800, 1600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final scale in [0.8, 1.0, 1.3]) {
      var value = 0.5;
      await tester.pumpWidget(
        _harness(
          scale: scale,
          StatefulBuilder(
            builder: (context, setState) => AppSlider(
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      );
      final applied = AdaptiveUiScale.of(
        tester.element(find.byType(MornyeSlider)),
      );
      expect(applied, closeTo(scale, 0.001));
      final gesture = await _hold(tester);
      final glass = find.byType(AdaptiveGlass);
      final window = MediaQuery.of(tester.element(glass));
      expect(window.size.width, closeTo(400, 0.001), reason: '$scale');
      expect(window.devicePixelRatio, closeTo(2, 0.001), reason: '$scale');
      final box = tester.renderObject<RenderBox>(glass);
      expect(
        box.getTransformTo(null).getMaxScaleOnAxis(),
        closeTo(1, 0.000001),
        reason: '$scale',
      );
      // The lens covers the thumb's place, in screen pixels.
      final lens = tester.getRect(_lens);
      final surface = tester.getRect(glass);
      expect(surface.left, closeTo(lens.left, 0.01), reason: '$scale');
      expect(surface.width, closeTo(lens.width, 0.01), reason: '$scale');
      expect(surface.height, closeTo(lens.height, 0.01), reason: '$scale');
      expect(
        lens.width,
        closeTo(
          MornyeSlider.thumbLength * (1 + MornyeSlider.heldGrowth) * scale,
          2 * scale,
        ),
        reason: '$scale',
      );
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    }
    expect(tester.takeException(), isNull);
  });
}
