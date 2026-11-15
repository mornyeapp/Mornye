import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';

import 'support/tooltip_finder.dart';

const _dialogKey = ValueKey('app-sheet-dialog');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDesktopPlatformOverride = true;
  });
  tearDown(() => debugDesktopPlatformOverride = null);

  Future<void> open(
    WidgetTester tester,
    void Function(BuildContext context) show, {
    bool mornye = false,
    double width = 1200,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => show(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Rect surface(WidgetTester tester, Finder dialog) => tester.getRect(
    find.descendant(of: dialog, matching: find.byType(Material)).first,
  );

  Widget rows(BuildContext context) => SingleChildScrollView(
    child: Column(
      children: [
        for (var i = 0; i < 60; i++)
          SizedBox(height: 40, child: Text('Row $i')),
      ],
    ),
  );

  for (final size in AppDialogSize.values) {
    testWidgets('a ${size.name} sheet dialog is ${size.width} wide', (
      tester,
    ) async {
      await open(
        tester,
        (context) => showAppBottomSheet<void>(
          context: context,
          title: 'Title',
          dialogSize: size,
          builder: (_) => const Text('Body'),
        ),
      );
      final rect = surface(tester, find.byKey(_dialogKey));
      expect(rect.width, size.width);
      expect(rect.center.dx, closeTo(600, 1));
    });
  }

  testWidgets('scrollable sheets and a narrow window keep the class cap', (
    tester,
  ) async {
    await open(
      tester,
      width: 600,
      (context) => showAppScrollableBottomSheet<void>(
        context: context,
        title: 'Title',
        dialogSize: AppDialogSize.wide,
        builder: (_, controller) =>
            ListView(controller: controller, children: const [Text('Body')]),
      ),
    );
    // The 24dp window margin on each side wins over the 720dp class.
    expect(surface(tester, find.byKey(_dialogKey)).width, 600 - 48);
  });

  testWidgets(
    'Material keeps the header fixed over a scrolling body with a visible bar',
    (tester) async {
      await open(
        tester,
        (context) => showAppBottomSheet<void>(
          context: context,
          title: 'Title',
          builder: rows,
        ),
      );
      final dialog = find.byKey(_dialogKey);
      final title = tester.getRect(find.text('Title'));
      expect(
        find.descendant(of: dialog, matching: find.byType(Scrollbar)),
        findsOneWidget,
      );
      final scrollbars = ScrollbarTheme.of(tester.element(find.text('Row 0')));
      expect(scrollbars.thumbVisibility?.resolve({}), isTrue);

      await tester.drag(find.text('Row 2'), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('Title')), title);
      expect(find.text('Row 0').hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(findByTooltip('Close'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('dialog corners follow the sheet radius of each style', (
    tester,
  ) async {
    for (final mornye in [false, true]) {
      await open(
        tester,
        mornye: mornye,
        (context) => showAppBottomSheet<void>(
          context: context,
          title: 'Title',
          builder: (_) => const Text('Body'),
        ),
      );
      final shape =
          tester.widget<Dialog>(find.byKey(_dialogKey)).shape!
              as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(28));
      expect(findByTooltip('Close'), mornye ? findsNothing : findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  group('Material alert dialogs stay within M3 widths', () {
    Future<Rect> alert(WidgetTester tester, String message) async {
      await open(
        tester,
        (context) => showAppDialog<void>(
          context: context,
          builder: (context) => AppAlertDialog(
            title: const Text('Remove?'),
            content: Text(message),
            actions: [
              AppDialogAction(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      );
      return surface(tester, find.byType(AlertDialog));
    }

    testWidgets('a long message wraps at 560dp', (tester) async {
      final rect = await alert(tester, 'This removes the files. ' * 20);
      expect(rect.width, 560);
    });

    testWidgets('a short question starts at the compact width on desktop', (
      tester,
    ) async {
      final rect = await alert(tester, 'Remove it?');
      expect(rect.width, 440);
    });

    testWidgets('phones keep the 280dp minimum', (tester) async {
      debugDesktopPlatformOverride = false;
      final rect = await alert(tester, 'Remove it?');
      expect(rect.width, lessThan(440));
      expect(rect.width, greaterThanOrEqualTo(280));
    });
  });
}
