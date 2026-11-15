import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/view_queue_snackbar_action.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:mornye/services/shell_navigation_service.dart';

import 'support/tooltip_finder.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('snackbar retains backdrop color during entry in $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(393, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: MornyeTheme.build(brightness),
            builder: (_, child) => RepaintBoundary(
              key: capture,
              child: AppScaffoldMessenger(child: child!),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    const Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: ColoredBox(color: Colors.blue)),
                        Expanded(child: ColoredBox(color: Colors.red)),
                      ],
                    ),
                    Center(
                      child: TextButton(
                        onPressed: () => showAppSnackBar(
                          context,
                          content: const Text('Extension installed'),
                        ),
                        child: const Text('Show'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show'));
      await tester.pump();
      for (final elapsed in [16, 80, 250]) {
        await tester.pump(Duration(milliseconds: elapsed));
        final rect = tester.getRect(find.byType(MornyeGlassPanel));
        final colors = await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(capture),
          );
          final image = await boundary.toImage();
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final colors = <Color>[];
          for (final fraction in [0.25, 0.75]) {
            final x = (rect.left + rect.width * fraction).floor();
            final y = (rect.bottom - 8).floor();
            final offset = (y * image.width + x) * 4;
            colors.add(
              Color.fromARGB(
                bytes.getUint8(offset + 3),
                bytes.getUint8(offset),
                bytes.getUint8(offset + 1),
                bytes.getUint8(offset + 2),
              ),
            );
          }
          image.dispose();
          return colors;
        });
        // The painted dark tint attenuates chroma along with luminance. Both
        // backdrop hues must remain visibly distinct throughout the transition.
        expect(colors![0].b - colors[0].r, greaterThan(0.16));
        expect(colors[1].r - colors[1].b, greaterThan(0.16));
        final foreground = MornyeTheme.build(brightness).colorScheme.onSurface;
        for (final background in colors) {
          final luminances = [
            foreground.computeLuminance(),
            background.computeLuminance(),
          ]..sort();
          expect(
            (luminances.last + 0.05) / (luminances.first + 0.05),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final mornye in [true, false]) {
    testWidgets(
      'new messages replace old ones and still dismiss (Mornye: $mornye)',
      (tester) async {
        late BuildContext messageContext;
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
              builder: (_, child) => AppScaffoldMessenger(child: child!),
              home: Builder(
                builder: (context) {
                  messageContext = context;
                  return const Scaffold(body: SizedBox.expand());
                },
              ),
            ),
          ),
        );
        final first = showAppSnackBar(
          messageContext,
          content: const Text('First'),
          duration: const Duration(seconds: 1),
        );
        await tester.pumpAndSettle();
        expect(find.text('First'), findsOneWidget);
        final second = showAppSnackBar(
          messageContext,
          content: const Text('Second'),
        );
        await tester.pumpAndSettle();
        expect(await first.closed, SnackBarClosedReason.remove);
        expect(find.text('First'), findsNothing);
        expect(find.text('Second'), findsOneWidget);
        await tester.drag(find.text('Second'), const Offset(0, 300));
        await tester.pumpAndSettle();
        expect(await second.closed, SnackBarClosedReason.swipe);
        expect(find.text('Second'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('View Queue times out and has a close button ($mornye)', (
      tester,
    ) async {
      late BuildContext messageContext;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            builder: (_, child) => AppScaffoldMessenger(child: child!),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                messageContext = context;
                return const Scaffold(body: SizedBox.expand());
              },
            ),
          ),
        ),
      );
      showAddedToQueueSnackBar(messageContext, 'Track');
      await tester.pumpAndSettle();
      expect(find.text('View Queue'), findsOneWidget);
      expect(findByTooltip('Close'), findsOneWidget);
      expect(
        find.byType(MornyeGlassPanel),
        mornye ? findsOneWidget : findsNothing,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);

      showAddedToQueueSnackBar(messageContext, 'Another track');
      await tester.pumpAndSettle();
      await tester.tap(findByTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('queue confirmation keeps its View action ($mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late BuildContext messageContext;
      ShellTab? requestedTab;
      final owner = Object();
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: (tab) => requestedTab = tab,
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(owner),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.light) : ThemeData(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(mornye ? 2 : 1)),
              child: AppScaffoldMessenger(child: child!),
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                messageContext = context;
                return const Scaffold(body: SizedBox.expand());
              },
            ),
          ),
        ),
      );
      showAddedToQueueSnackBar(messageContext, 'Track');
      await tester.pumpAndSettle();
      await tester.tap(find.text('View Queue'));
      await tester.pumpAndSettle();
      expect(requestedTab, ShellTab.library);
      expect(find.byType(SnackBar), findsNothing);
      showQueuedSnackbar(messageContext, 3, 0);
      await tester.pumpAndSettle();
      expect(
        find.text(messageContext.l10n.snackbarAddedTracksToQueue(3)),
        findsOneWidget,
      );
      expect(
        find.byType(MornyeGlassPanel),
        mornye ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'a new message ${reducedMotion ? 'cuts' : 'lets the current '
                'one exit'} (reduced motion: $reducedMotion)',
      (tester) async {
        late BuildContext messageContext;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: AppScaffoldMessenger(child: child!),
            ),
            home: Builder(
              builder: (context) {
                messageContext = context;
                return const Scaffold(body: SizedBox.expand());
              },
            ),
          ),
        );
        ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
          String text,
        ) => ScaffoldMessenger.of(
          messageContext,
        ).showSnackBar(SnackBar(content: Text(text)));

        final first = show('First');
        await tester.pumpAndSettle();
        show('Second');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        if (reducedMotion) {
          expect(find.text('First'), findsNothing);
          expect(find.text('Second'), findsOneWidget);
        } else {
          // The first message is leaving; the second waits for it.
          expect(find.text('First'), findsOneWidget);
          expect(find.text('Second'), findsNothing);
          await tester.pump(const Duration(milliseconds: 110));
          expect(find.text('First'), findsNothing);
          expect(find.text('Second'), findsOneWidget);
        }
        expect(await first.closed, SnackBarClosedReason.remove);
        await tester.pumpAndSettle();

        // A third message during the exit drops the waiting one.
        show('Third');
        await tester.pump(const Duration(milliseconds: 50));
        final fourth = show('Fourth');
        final fifth = show('Fifth');
        await tester.pumpAndSettle();
        expect(find.text('Fifth'), findsOneWidget);
        expect(find.text('Fourth'), findsNothing);
        expect(await fourth.closed, SnackBarClosedReason.remove);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(await fifth.closed, SnackBarClosedReason.timeout);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('clearing during an exit completes the waiting message', (
    tester,
  ) async {
    late BuildContext messageContext;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScaffoldMessenger(child: child!),
        home: Builder(
          builder: (context) {
            messageContext = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );
    final messenger = ScaffoldMessenger.of(messageContext);
    ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
      String text,
    ) => messenger.showSnackBar(SnackBar(content: Text(text)));

    show('First');
    await tester.pumpAndSettle();
    final second = show('Second');
    SnackBarClosedReason? secondReason;
    second.closed.then((reason) => secondReason = reason);
    await tester.pump(const Duration(milliseconds: 50));

    // A caller clears the messenger and shows its own message, as batch
    // actions do, while the second message still waits behind the exit.
    messenger.clearSnackBars();
    final third = show('Third');
    await tester.pumpAndSettle();
    expect(secondReason, SnackBarClosedReason.remove);
    expect(find.text('Third'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(await third.closed, SnackBarClosedReason.timeout);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing a waiting message cancels it before it shows', (
    tester,
  ) async {
    late BuildContext messageContext;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => AppScaffoldMessenger(child: child!),
        home: Builder(
          builder: (context) {
            messageContext = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );
    ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
      String text,
    ) => ScaffoldMessenger.of(
      messageContext,
    ).showSnackBar(SnackBar(content: Text(text)));

    final first = show('First');
    await tester.pumpAndSettle();
    final waiting = show('Waiting');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('First'), findsOneWidget);
    closeAppSnackBar(messageContext, waiting);
    await tester.pump();
    expect(find.text('First'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Waiting'), findsNothing);
    expect(await first.closed, SnackBarClosedReason.remove);
    expect(await waiting.closed, SnackBarClosedReason.hide);

    // Closing it again leaves a newer message alone; closing the shown
    // message plays its exit.
    final next = show('Next');
    await tester.pumpAndSettle();
    closeAppSnackBar(messageContext, waiting);
    await tester.pumpAndSettle();
    expect(find.text('Next'), findsOneWidget);
    closeAppSnackBar(messageContext, next);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Next'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Next'), findsNothing);
    expect(await next.closed, SnackBarClosedReason.hide);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid messages never leave a backlog or persist an action', (
    tester,
  ) async {
    late BuildContext messageContext;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => AppScaffoldMessenger(child: child!),
        home: Builder(
          builder: (context) {
            messageContext = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );
    final controllers = [
      for (var i = 0; i < 10; i++)
        ScaffoldMessenger.of(messageContext).showSnackBar(
          SnackBar(
            content: Text('Message $i'),
            action: SnackBarAction(label: 'Action', onPressed: () {}),
            duration: const Duration(minutes: 1),
          ),
        ),
    ];
    await tester.pumpAndSettle();
    expect(find.text('Message 9'), findsOneWidget);
    expect(find.text('Message 0'), findsNothing);
    for (final controller in controllers.take(9)) {
      expect(await controller.closed, SnackBarClosedReason.remove);
    }
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(await controllers.last.closed, SnackBarClosedReason.timeout);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
