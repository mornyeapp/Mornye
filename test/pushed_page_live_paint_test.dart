import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/animation_utils.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

/// Records the value its entrance animation had each time it was painted.
class _PaintProbe extends StatelessWidget {
  const _PaintProbe(this.painted);

  final List<double> painted;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      builder: (context, value, _) => CustomPaint(
        size: const Size(100, 100),
        painter: _RecordingPainter(value, painted),
      ),
    ),
  );
}

class _RecordingPainter extends CustomPainter {
  _RecordingPainter(this.value, this.painted);

  final double value;
  final List<double> painted;

  @override
  void paint(Canvas canvas, Size size) => painted.add(value);

  @override
  bool shouldRepaint(_RecordingPainter oldDelegate) =>
      oldDelegate.value != value;
}

void main() {
  setUp(() => MotionPace.speed = 1);

  for (final (name, push) in [
    (
      'pushPage',
      (WidgetBuilder builder) =>
          pushPage<void>(_navigatorKey.currentContext!, builder),
    ),
    (
      'pushViaPreferredNavigator',
      (WidgetBuilder builder) =>
          pushViaPreferredNavigator(_navigatorKey.currentContext!, builder),
    ),
    (
      'slidePageRoute',
      (WidgetBuilder builder) => _navigatorKey.currentState!.push(
        slidePageRoute<void>(page: Builder(builder: builder)),
      ),
    ),
  ]) {
    testWidgets('Material Android $name paints the arriving page live', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: _navigatorKey,
          theme: AppTheme.light().copyWith(platform: TargetPlatform.android),
          home: const Scaffold(body: Text('home')),
        ),
      );
      final painted = <double>[];
      push((_) => _PaintProbe(painted));
      await tester.pump();

      final transition = ModalRoute.of(
        tester.element(find.byType(_PaintProbe, skipOffstage: false)),
      )!.animation!;
      final duringTransition = <double>[];
      while (transition.isAnimating) {
        await tester.pump(const Duration(milliseconds: 16));
        if (transition.isAnimating) duringTransition.addAll(painted);
        painted.clear();
      }

      // A route snapshot paints the page once and shows that image until
      // the push ends, so the entrance animation would never be drawn.
      expect(duringTransition.toSet().length, greaterThan(5));
      expect(duringTransition.last, 1);
      await tester.pumpAndSettle();
    });
  }
}
