import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final reduceMotion in [false, true]) {
      testWidgets(
        'confirmation keeps blur during entry and cancels promptly ($brightness, reduce motion: $reduceMotion)',
        (tester) async {
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                theme: MornyeTheme.build(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: reduceMotion),
                  child: child!,
                ),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      child: const Text('Open'),
                      onPressed: () => showAppDialog<void>(
                        context: context,
                        builder: (context) => AppAlertDialog(
                          title: const Text('Delete Selected'),
                          content: const Text(
                            'This will also delete the files.',
                          ),
                          actions: [
                            AppDialogAction(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pump();
          for (final elapsed in [16, 64, 180]) {
            await tester.pump(Duration(milliseconds: elapsed));
            final blur = find.descendant(
              of: find.byType(AppAlertDialog),
              matching: find.byType(BackdropFilter),
            );
            expect(blur, findsOneWidget);
            // An opacity layer isolates the filter from the underlying page
            // until the route finishes entering.
            final fades = tester.widgetList<FadeTransition>(
              find.ancestor(of: blur, matching: find.byType(FadeTransition)),
            );
            expect(fades.every((fade) => fade.opacity.value == 1), isTrue);
            final bodyContext = tester.element(
              find.text('This will also delete the files.'),
            );
            expect(
              DefaultTextStyle.of(bodyContext).style.color,
              Theme.of(bodyContext).colorScheme.onSurface,
            );
          }
          // Let the fast spring settle, so the dialog closes from fully open.
          await tester.pump(const Duration(milliseconds: 150));
          final panel = find.byType(MornyeGlassPanel);
          final openWidth = tester.getRect(panel).width;
          await tester.tap(find.text('Cancel'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
          if (!reduceMotion) {
            // Closing must move on the first frame, rather than holding the
            // fully open scale while a reversed entrance curve settles.
            expect(tester.getRect(panel).width, lessThan(openWidth - 1));
            await tester.pump(const Duration(milliseconds: 164));
            await tester.pump();
          }
          expect(find.byType(AppAlertDialog), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final mornye in [true, false]) {
    testWidgets(
      'confirmation preserves cancel and confirm results (Mornye: $mornye)',
      (tester) async {
        bool? result;
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    child: const Text('Open'),
                    onPressed: () async {
                      result = await showAppDialog<bool>(
                        context: context,
                        builder: (context) => AppAlertDialog(
                          title: const Text('Remove extension'),
                          content: const Text('Remove this example extension?'),
                          actions: [
                            AppDialogAction(
                              isDefault: true,
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel'),
                            ),
                            AppDialogAction(
                              filled: true,
                              isDestructive: true,
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Remove'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(
          find.byType(MornyeGlassPanel),
          mornye ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(AlertDialog),
          mornye ? findsNothing : findsOneWidget,
        );
        if (mornye) {
          final remove = find.widgetWithText(CupertinoButton, 'Remove');
          final cancel = find.widgetWithText(CupertinoButton, 'Cancel');
          expect(
            tester.getRect(remove).bottom,
            lessThan(tester.getRect(cancel).top),
          );
          expect(tester.getRect(remove).width, tester.getRect(cancel).width);
          expect(
            DefaultTextStyle.of(
              tester.element(find.text('Remove')),
            ).style.color,
            CupertinoColors.systemRed.darkColor,
          );
          expect(find.byType(CupertinoAlertDialog), findsNothing);
          expect(find.byType(FilledButton), findsNothing);
        }
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(result, isFalse);

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove'));
        await tester.pumpAndSettle();
        expect(result, isTrue);

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(result, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  Future<void> pumpOpener(
    WidgetTester tester, {
    required ThemeData theme,
    required void Function(BuildContext context) open,
  }) => tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('Open'),
              onPressed: () => open(context),
            ),
          ),
        ),
      ),
    ),
  );

  double opacityAbove(WidgetTester tester, Finder target) => tester
      .widgetList<FadeTransition>(
        find.ancestor(of: target, matching: find.byType(FadeTransition)),
      )
      .fold(1.0, (opacity, fade) => opacity * fade.opacity.value);

  double scaleAbove(WidgetTester tester, Finder target) => tester
      .widgetList<ScaleTransition>(
        find.ancestor(of: target, matching: find.byType(ScaleTransition)),
      )
      .fold(1.0, (scale, transition) => scale * transition.scale.value);

  testWidgets('Mornye sheet dialogs keep their glass frosted while entering', (
    tester,
  ) async {
    await pumpOpener(
      tester,
      theme: MornyeTheme.build(Brightness.light),
      open: (context) => showAppSheetDialog<void>(
        context: context,
        builder: (context) => const SizedBox(height: 200, child: Text('Sheet')),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final blur = find.descendant(
      of: find.byType(AppSheetDialog),
      matching: find.byType(BackdropFilter),
    );
    expect(blur, findsWidgets);
    expect(opacityAbove(tester, blur.first), 1);
    expect(scaleAbove(tester, blur.first), lessThan(1));
    await tester.pumpAndSettle();
    expect(scaleAbove(tester, blur.first), 1);
  });

  for (final sheet in [false, true]) {
    testWidgets('Material ${sheet ? 'sheet ' : ''}dialog exits with a short '
        'fade and no scale', (tester) async {
      Widget content(BuildContext context) => TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      );
      await pumpOpener(
        tester,
        theme: ThemeData(),
        open: (context) => sheet
            ? showAppSheetDialog<void>(context: context, builder: content)
            : showAppDialog<void>(context: context, builder: content),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final close = find.text('Close');
      expect(opacityAbove(tester, close), lessThan(1));
      expect(scaleAbove(tester, close), lessThan(1));
      await tester.pumpAndSettle();

      await tester.tap(close);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(opacityAbove(tester, close), lessThan(1));
      expect(scaleAbove(tester, close), 1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(close, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Material dialog opens and closes immediately under Reduce Motion',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Open'),
                  onPressed: () => showAppDialog<void>(
                    context: context,
                    builder: (context) => AppAlertDialog(
                      title: const Text('Reduced'),
                      actions: [
                        AppDialogAction(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      final close = find.text('Close');
      expect(close, findsOneWidget);
      expect(opacityAbove(tester, close), 1);
      expect(scaleAbove(tester, close), 1);
      await tester.tap(close);
      await tester.pump();
      expect(close, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('glass confirmation keeps actions reachable with long text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.light),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: AppAlertDialog(
              title: const Text('Delete these tracks from your library?'),
              content: Text(
                List.filled(12, 'This removes the selected files.').join(' '),
              ),
              actions: [
                AppDialogAction(onPressed: () {}, child: const Text('Cancel')),
                AppDialogAction(
                  isDestructive: true,
                  onPressed: () {},
                  child: const Text('Delete from Library'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cancel').hitTestable(), findsOneWidget);
    expect(find.text('Delete from Library').hitTestable(), findsOneWidget);
    final scroll = find.byType(SingleChildScrollView).first;
    await tester.drag(scroll, const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(find.text('Cancel').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
