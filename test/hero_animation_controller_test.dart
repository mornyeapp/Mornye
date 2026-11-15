import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'HeroControllerScope.none reaches the MaterialApp root Navigator',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          builder: (context, child) =>
              HeroControllerScope.none(child: child ?? const SizedBox.shrink()),
          home: const SizedBox.shrink(),
        ),
      );

      final navigatorContext = navigatorKey.currentContext!;
      final scope = navigatorContext
          .getInheritedWidgetOfExactType<HeroControllerScope>();
      expect(scope, isNotNull);
      expect(scope!.controller, isNull);
    },
  );

  testWidgets('removing an explicit HeroController detaches it', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final controller = MaterialApp.createMaterialHeroController();
    var enabled = true;
    late StateSetter setHostState;

    await tester.pumpWidget(
      MaterialApp(
        home: HeroControllerScope.none(
          child: StatefulBuilder(
            builder: (context, setState) {
              setHostState = setState;
              return Navigator(
                key: navigatorKey,
                observers: [if (enabled) controller],
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => const SizedBox.shrink(),
                ),
              );
            },
          ),
        ),
      ),
    );

    expect(controller.navigator, same(navigatorKey.currentState));

    setHostState(() => enabled = false);
    await tester.pump();

    expect(controller.navigator, isNull);
    controller.dispose();
  });
}
