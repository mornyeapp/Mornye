import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/download_state_switcher.dart';

void main() {
  Widget control(DownloadStatus status) => switch (status) {
    DownloadStatus.downloading => const SizedBox(
      key: ValueKey('stop'),
      width: 40,
      height: 40,
    ),
    _ => const SizedBox(key: ValueKey('done'), width: 88, height: 40),
  };

  Future<void> pump(
    WidgetTester tester,
    DownloadStatus status, {
    ThemeData? theme,
    bool reducedMotion = false,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reducedMotion),
        child: Align(
          alignment: Alignment.topRight,
          child: DownloadStateSwitcher(state: status, child: control(status)),
        ),
      ),
    ),
  );

  Size switcherSize(WidgetTester tester) =>
      tester.getSize(find.byType(DownloadStateSwitcher));

  Finder inSwitcher(Type type) => find.descendant(
    of: find.byType(DownloadStateSwitcher),
    matching: find.byType(type),
  );

  for (final mornye in [false, true]) {
    testWidgets('switches state with a short transition (Mornye: $mornye)', (
      tester,
    ) async {
      final theme = mornye ? MornyeTheme.build(Brightness.light) : null;
      await pump(tester, DownloadStatus.downloading, theme: theme);
      expect(switcherSize(tester).width, 40);

      await pump(tester, DownloadStatus.completed, theme: theme);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('stop')), findsOneWidget);
      expect(find.byKey(const ValueKey('done')), findsOneWidget);
      final opacity = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('done')),
              matching: inSwitcher(FadeTransition),
            )
            .first,
      );
      expect(opacity.opacity.value, inExclusiveRange(0, 1));
      // The old control fades out at the same time instead of staying
      // opaque on top of the new one.
      final outgoing = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('stop')),
              matching: inSwitcher(FadeTransition),
            )
            .first,
      );
      expect(outgoing.opacity.value, inExclusiveRange(0, 1));
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('done')),
          matching: inSwitcher(ScaleTransition),
        ),
        mornye ? findsNothing : findsOneWidget,
      );
      expect(switcherSize(tester).width, inExclusiveRange(40, 88));

      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stop')), findsNothing);
      expect(find.byKey(const ValueKey('done')), findsOneWidget);
      expect(switcherSize(tester).width, 88);
    });
  }

  testWidgets('reduced motion switches in place', (tester) async {
    await pump(tester, DownloadStatus.downloading, reducedMotion: true);
    await pump(tester, DownloadStatus.completed, reducedMotion: true);
    expect(find.byKey(const ValueKey('stop')), findsNothing);
    expect(find.byKey(const ValueKey('done')), findsOneWidget);
    expect(inSwitcher(FadeTransition), findsNothing);
    expect(switcherSize(tester).width, 88);
  });
}
