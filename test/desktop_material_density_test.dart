import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/selection_action_button.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/widgets/settings_group.dart';

void main() {
  setUp(() => debugDesktopPlatformOverride = true);
  tearDown(() => debugDesktopPlatformOverride = null);

  Widget app({required bool mornye, required Widget child}) => MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );

  test('Material desktop registers the compact tokens', () {
    expect(AppTheme.light().extension<AppTokens>(), same(AppTokens.desktop));
    debugDesktopPlatformOverride = false;
    expect(AppTheme.light().extension<AppTokens>(), same(AppTokens.standard));

    final desktop = AppTokens.desktop;
    final standard = AppTokens.standard;
    expect(desktop.rowPaddingV, lessThan(standard.rowPaddingV));
    expect(desktop.coverList, lessThan(standard.coverList));
    expect(
      desktop.headerExpandedHeight,
      lessThan(standard.headerExpandedHeight),
    );
    // Shapes, motion and the control target are not density.
    expect(desktop.radiusCard, standard.radiusCard);
    expect(desktop.motionMedium, standard.motionMedium);
    expect(desktop.minTouchTarget, standard.minTouchTarget);
  });

  testWidgets('desktop lists center past the style reading width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final mornye in [false, true]) {
      late double inset;
      late double rowHeight;
      await tester.pumpWidget(
        app(
          mornye: mornye,
          child: Builder(
            builder: (context) {
              inset = wideListInset(context);
              rowHeight = TrackTableLayout.rowMinHeightFor(context);
              return const SizedBox();
            },
          ),
        ),
      );
      // MaterialApp animates a theme change; settle so the new theme applies.
      await tester.pumpAndSettle();
      expect(
        inset,
        mornye
            ? (1920 - desktopContentMaxWidth) / 2
            : (1920 - desktopMaterialContentMaxWidth) / 2,
        reason: 'Mornye=$mornye',
      );
      expect(rowHeight, mornye ? 40 : 44, reason: 'Mornye=$mornye');
    }
  });

  testWidgets('Material desktop settings rows use the compact density', (
    tester,
  ) async {
    for (final desktop in [true, false]) {
      debugDesktopPlatformOverride = desktop;
      await tester.pumpWidget(
        app(
          mornye: false,
          child: SettingsGroup(
            children: [
              SettingsItem(
                icon: Icons.tune,
                title: 'Row',
                onTap: () {},
                showDivider: false,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final height = tester.getSize(find.byType(SettingsItem)).height;
      expect(
        height,
        desktop ? lessThanOrEqualTo(48) : greaterThanOrEqualTo(56),
        reason: 'desktop=$desktop',
      );
    }
  });

  testWidgets('desktop selection toolbar drops the handle and lays actions '
      'in a row', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget bar() => Align(
      alignment: Alignment.bottomCenter,
      child: SelectionBottomBar(
        selectedCount: 2,
        allSelected: false,
        onClose: () {},
        onToggleSelectAll: () {},
        bottomPadding: 0,
        children: [
          SelectionActionGrid(
            children: [
              for (final label in ['Convert', 'Apply ReplayGain to 2 songs'])
                Builder(
                  builder: (context) => SelectionActionButton(
                    icon: Icons.swap_horiz,
                    label: label,
                    onPressed: () {},
                    colorScheme: Theme.of(context).colorScheme,
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    for (final desktop in [true, false]) {
      debugDesktopPlatformOverride = desktop;
      await tester.pumpWidget(app(mornye: false, child: bar()));
      await tester.pumpAndSettle();
      final buttons = find.byType(SelectionActionButton);
      final first = tester.getRect(buttons.at(0));
      final second = tester.getRect(buttons.at(1));
      // The button surface inside the focus ring outset and the tap target
      // padding. The expressive button renders its own Material copy and
      // excludes inner semantics, so match by name and walk every element.
      final surface = tester.getSize(
        find
            .descendant(
              of: buttons.at(0),
              matching: find.byWidgetPredicate(
                (widget) => widget.runtimeType.toString() == 'Material',
                skipOffstage: false,
              ),
              skipOffstage: false,
            )
            .first,
      );
      if (desktop) {
        expect(find.byType(AppSheetHandle), findsNothing);
        expect(find.textContaining('Tap'), findsNothing);
        expect(second.top, closeTo(first.top, 0.01));
        expect(second.width, isNot(closeTo(first.width, 0.01)));
        expect(surface.height, 40);
      } else {
        expect(find.byType(AppSheetHandle), findsOneWidget);
        expect(second.width, closeTo(first.width, 0.01));
        expect(surface.height, greaterThanOrEqualTo(48));
      }
    }
  });

  for (final height in [1000.0, 700.0]) {
    testWidgets('a pushed page title clears its back button at $height', (
      tester,
    ) async {
      tester.view.physicalSize = Size(1280, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        app(
          mornye: false,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                    body: CustomScrollView(
                      slivers: [AppSliverHeader.page(title: 'Playlists')],
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The tab root keeps the compact desktop header; a back button gets
      // the full one, with room between the button and the large title.
      final back = tester.getRect(find.byType(AppIconButton));
      final title = tester.getRect(find.text('Playlists'));
      expect(title.top - back.bottom, greaterThanOrEqualTo(12));
    });
  }
}
