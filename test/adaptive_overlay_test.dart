import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/download_settings_page.dart';
import 'package:mornye/services/app_remote_config_service.dart';
import 'package:mornye/services/update_checker.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/material_symbols.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_announcement_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/update_dialog.dart';

Widget _app(ThemeData theme, Widget home) => ProviderScope(
  child: MaterialApp(
    theme: theme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

class _ChoiceSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(autoConvertDownloads: true);
}

void main() {
  for (final mornye in [false, true]) {
    for (final brightness in Brightness.values) {
      final theme = mornye
          ? MornyeTheme.build(brightness)
          : ThemeData(brightness: brightness);
      final variant = 'Mornye: $mornye, $brightness';

      testWidgets('choice rows preserve adaptive appearance ($variant)', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            _app(
              theme,
              Scaffold(
                body: Column(
                  children: [
                    for (final selected in [false, true]) ...[
                      AppSheetOption(
                        title: Text('Legacy $selected'),
                        subtitle: const Text('Subtitle'),
                        leading: const AppIcon(Icons.speed_outlined),
                        selected: selected,
                        trailing: selected
                            ? AppIcon(
                                Icons.check,
                                color: theme.colorScheme.primary,
                              )
                            : null,
                        onTap: () {},
                      ),
                      AppSheetOption.choice(
                        title: Text('Choice $selected'),
                        subtitle: const Text('Subtitle'),
                        leading: const AppIcon(Icons.speed_outlined),
                        selected: selected,
                        onTap: () {},
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
          for (final selected in [false, true]) {
            Finder row(String name) => find.ancestor(
              of: find.text('$name $selected'),
              matching: find.byType(AppSheetOption),
            );
            Finder icons(String name) =>
                find.descendant(of: row(name), matching: find.byType(Icon));
            expect(
              tester.getSize(row('Choice')),
              tester.getSize(row('Legacy')),
            );
            final legacyIcons = tester
                .widgetList<Icon>(icons('Legacy'))
                .toList();
            final choiceIcons = tester
                .widgetList<Icon>(icons('Choice'))
                .toList();
            expect(choiceIcons.length, selected ? 2 : 1);
            for (var i = 0; i < choiceIcons.length; i++) {
              expect(choiceIcons[i].icon, legacyIcons[i].icon);
              expect(choiceIcons[i].color, legacyIcons[i].color);
              expect(
                tester.getSize(icons('Choice').at(i)),
                tester.getSize(icons('Legacy').at(i)),
              );
            }
            expect(
              tester.getSemantics(find.text('Choice $selected')),
              isSemantics(isSelected: selected, hasTapAction: true),
            );
            if (mornye) {
              expect(
                tester.getSemantics(find.text('Choice $selected')),
                isSemantics(isInMutuallyExclusiveGroup: true),
              );
            }
          }
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });

      testWidgets('download choices update and dismiss ($variant)', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(412, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        try {
          // A page-local accent must survive capture by the root modal route.
          final pageTheme = theme.copyWith(
            colorScheme: theme.colorScheme.copyWith(primary: Colors.green),
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [settingsProvider.overrideWith(_ChoiceSettings.new)],
              child: _app(
                theme,
                Theme(
                  data: pageTheme,
                  child: const MornyeSettingsTheme(
                    child: DownloadSettingsPage(),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final container = ProviderScope.containerOf(
            tester.element(find.byType(DownloadSettingsPage)),
          );
          final check = mornye
              ? mornyeIconFor(Icons.check)
              : materialSymbolFor(Icons.check)!.icon;
          for (final (picker, initial, next) in [
            ('Output format', 'MP3', 'Opus'),
            ('Output quality', '320 kbps', '160 kbps'),
            ('Output format', 'Opus', 'FLAC'),
            ('Maximum bit depth', '16-bit', '24-bit'),
            ('Maximum sample rate', '48 kHz', '96 kHz'),
            (
              'Concurrent downloads',
              '1 track at a time',
              'Up to 3 tracks at once',
            ),
          ]) {
            Future<void> open() async {
              await tester.ensureVisible(find.text(picker));
              await tester.pumpAndSettle();
              await tester.tap(find.text(picker));
              await tester.pumpAndSettle();
            }

            Finder option(String label) => find.descendant(
              of: find.byType(AppBottomSheet),
              matching: find.text(label),
            );
            await open();
            expect(
              tester.getSemantics(option(initial)),
              isSemantics(isSelected: true, hasTapAction: true),
            );
            expect(
              tester.getSemantics(option(next)),
              isSemantics(isSelected: false, hasTapAction: true),
            );
            final checkmark = find.descendant(
              of: find.byType(AppBottomSheet),
              matching: find.byIcon(check),
            );
            expect(checkmark, findsOneWidget);
            expect(tester.widget<Icon>(checkmark).color, Colors.green);
            expect(tester.getSize(checkmark), Size.square(mornye ? 20 : 24));
            await tester.tap(option(next));
            await tester.pumpAndSettle();
            expect(find.byType(AppBottomSheet), findsNothing);
            final settings = container.read(settingsProvider);
            switch (picker) {
              case 'Output format':
                expect(settings.autoConvertFormat, next.toLowerCase());
              case 'Output quality':
                expect(settings.autoConvertBitrate, '160k');
              case 'Maximum bit depth':
                expect(settings.autoConvertMaxBitDepth, 24);
              case 'Maximum sample rate':
                expect(settings.autoConvertMaxSampleRate, 96000);
              case 'Concurrent downloads':
                expect(settings.concurrentDownloads, 3);
            }
            await open();
            expect(
              tester.getSemantics(option(next)),
              isSemantics(isSelected: true),
            );
            // Selecting the current option must still invoke its dismissal.
            await tester.tap(option(next));
            await tester.pumpAndSettle();
            expect(find.byType(AppBottomSheet), findsNothing);
          }
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });

      testWidgets(
        'short sheets fit their content and resize with options ($variant)',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final count = ValueNotifier(2);
          addTearDown(count.dispose);
          await tester.pumpWidget(
            _app(
              theme,
              Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    child: const Text('Open options'),
                    onPressed: () => showAppScrollableBottomSheet<void>(
                      context: context,
                      title: 'Options',
                      builder: (context, controller) =>
                          ValueListenableBuilder<int>(
                            valueListenable: count,
                            builder: (context, count, _) =>
                                SingleChildScrollView(
                                  controller: controller,
                                  child: Column(
                                    children: [
                                      for (var i = 0; i < count; i++)
                                        AppSheetOption(
                                          title: Text('Option $i'),
                                          onTap: () {},
                                        ),
                                    ],
                                  ),
                                ),
                          ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open options'));
          await tester.pumpAndSettle();
          final sheet = find.byType(AppBottomSheet);
          final shortHeight = tester.getSize(sheet).height;
          expect(shortHeight, lessThan(844 * 0.5));
          expect(
            tester.getRect(sheet).bottom -
                tester.getRect(find.text('Option 1')).bottom,
            lessThan(40),
          );
          final scroll = find.descendant(
            of: sheet,
            matching: find.byType(SingleChildScrollView),
          );
          await tester.drag(scroll, const Offset(0, -250));
          await tester.pumpAndSettle();
          expect(tester.getSize(sheet).height, closeTo(shortHeight, 1));
          count.value = 4;
          await tester.pumpAndSettle();
          expect(tester.getSize(sheet).height, greaterThan(shortHeight));
          expect(tester.getSize(sheet).height, lessThan(844 * 0.85));
          count.value = 40;
          await tester.pumpAndSettle();
          expect(tester.getSize(sheet).height, closeTo(844 * 0.85, 1));
          await tester.drag(scroll, const Offset(0, -400));
          await tester.pumpAndSettle();
          count.value = 1;
          await tester.pumpAndSettle();
          expect(tester.getSize(sheet).height, lessThan(shortHeight));
          expect(find.text('Option 0').hitTestable(), findsOneWidget);
          await tester.fling(scroll, const Offset(0, 200), 1200);
          await tester.pumpAndSettle();
          expect(sheet, findsNothing);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'scrollable sheet keeps its header and dismisses from body or handle ($variant)',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          int? selected;
          await tester.pumpWidget(
            _app(
              theme,
              Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    child: const Text('Open options'),
                    onPressed: () async {
                      selected = await showAppScrollableBottomSheet<int>(
                        context: context,
                        title: 'Options',
                        builder: (context, controller) => SingleChildScrollView(
                          controller: controller,
                          child: Column(
                            children: [
                              for (var i = 0; i < 40; i++)
                                AppSheetOption(
                                  title: Text('Option $i'),
                                  onTap: () => Navigator.pop(context, i),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          Future<void> open() async {
            await tester.tap(find.text('Open options'));
            await tester.pumpAndSettle();
            expect(
              tester.getSize(find.byType(AppBottomSheet)).height,
              closeTo(844 * 0.85, 1),
            );
            expect(find.byType(AppSheetHandle).hitTestable(), findsOneWidget);
          }

          await open();
          final scroll = find.descendant(
            of: find.byType(AppBottomSheet),
            matching: find.byType(SingleChildScrollView),
          );
          await tester.drag(scroll, const Offset(0, -400));
          await tester.pumpAndSettle();
          expect(
            tester.getSize(find.byType(AppBottomSheet)).height,
            closeTo(844 * 0.95, 1),
          );
          expect(find.text('Options').hitTestable(), findsOneWidget);
          expect(find.byType(AppSheetHandle).hitTestable(), findsOneWidget);
          await tester.ensureVisible(find.text('Option 39'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Option 39'));
          await tester.pumpAndSettle();
          expect(selected, 39);
          await open();
          await tester.fling(scroll, const Offset(0, 400), 1200);
          await tester.pumpAndSettle();
          expect(find.byType(AppBottomSheet), findsNothing);
          await open();
          await tester.drag(scroll, const Offset(0, -400));
          await tester.pumpAndSettle();
          await tester.fling(
            find.byType(AppSheetHandle),
            const Offset(0, 300),
            1200,
          );
          await tester.pumpAndSettle();
          expect(find.byType(AppBottomSheet), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('sheet selects, disables and returns values ($variant)', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var selected = false;
        var disabledTaps = 0;
        bool? result;
        await tester.pumpWidget(
          _app(
            theme,
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Open'),
                  onPressed: () async {
                    result = await showAppBottomSheet<bool>(
                      context: context,
                      title: 'Library filter',
                      builder: (context) => StatefulBuilder(
                        builder: (context, setSheetState) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Wrap(
                              children: [
                                AppChoiceChip(
                                  label: const Text('Downloaded tracks'),
                                  selected: selected,
                                  onSelected: (value) => setSheetState(() {
                                    selected = value;
                                  }),
                                ),
                              ],
                            ),
                            AppSheetOption(
                              enabled: false,
                              title: const Text('Unavailable'),
                              onTap: () => disabledTaps++,
                            ),
                            AppSheetOption(
                              title: const Text('Apply'),
                              onTap: () => Navigator.pop(context, selected),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
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
        expect(find.byType(M3EChip), mornye ? findsNothing : findsOneWidget);
        await tester.tap(find.text('Unavailable'));
        expect(disabledTaps, 0);
        await tester.tap(find.text('Downloaded tracks'));
        await tester.pumpAndSettle();
        expect(selected, isTrue);
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        expect(result, isTrue);
        expect(find.text('Library filter'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('nested dialog retains theme and navigation ($variant)', (
        tester,
      ) async {
        final nestedNavigator = GlobalKey<NavigatorState>();
        bool? result;
        await tester.pumpWidget(
          _app(
            ThemeData(),
            Navigator(
              key: nestedNavigator,
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => Theme(
                  data: theme,
                  child: Builder(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        child: const Text('Open import'),
                        onPressed: () async {
                          result = await showAppDialog<bool>(
                            context: context,
                            useRootNavigator: false,
                            builder: (context) => AppAlertDialog(
                              title: const Text('Import playlist'),
                              actions: [
                                AppDialogAction(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Confirm'),
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
            ),
          ),
        );
        await tester.tap(find.text('Open import'));
        await tester.pumpAndSettle();
        expect(nestedNavigator.currentState!.canPop(), isTrue);
        expect(
          find.byType(MornyeGlassPanel),
          mornye ? findsOneWidget : findsNothing,
        );
        expect(
          Theme.of(tester.element(find.text('Import playlist'))).brightness,
          brightness,
        );
        await tester.tap(find.text('Confirm'));
        await tester.pumpAndSettle();
        expect(result, isTrue);
        expect(nestedNavigator.currentState!.canPop(), isFalse);
        expect(find.text('Open import'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('required update resists back and barrier ($variant)', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(393, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          _app(
            theme,
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Update'),
                  onPressed: () => showUpdateDialog(
                    context,
                    updateInfo: UpdateInfo(
                      version: '9.0.0',
                      changelog: 'Playback and library improvements.\n' * 8,
                      downloadUrl: 'https://example.com/release',
                      releasesBehind: 3,
                    ),
                    onDisableUpdates: () =>
                        fail('Cannot disable required update'),
                    forced: true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Update'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(5, 5));
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(UpdateDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('announcement keeps explicit dismissal (Mornye: $mornye)', (
      tester,
    ) async {
      var dismissals = 0;
      await tester.pumpWidget(
        _app(
          mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Open notice'),
                onPressed: () => showAppAnnouncementDialog(
                  context,
                  announcement: const RemoteAnnouncement(
                    id: 'notice',
                    enabled: true,
                    title: 'Service notice',
                    message: 'An announcement without an external action.',
                    dismissible: false,
                  ),
                  onDismiss: () => dismissals++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open notice'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Service notice'), findsOneWidget);
      expect(dismissals, 0);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Service notice'), findsNothing);
      expect(dismissals, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
