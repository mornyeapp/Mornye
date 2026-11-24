import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_navigation.dart';
import 'package:mornye/widgets/desktop/desktop_row_ink.dart';
import 'package:mornye/widgets/desktop/track_table.dart';

import 'support/fixed_settings.dart';

Widget _app(Widget child, {bool mornye = false}) => ProviderScope(
  overrides: [
    settingsProvider.overrideWith(
      () =>
          FixedSettingsNotifier(const AppSettings(localLibraryEnabled: false)),
    ),
  ],
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

/// Desktop themes spread an [InkRipple], drawn as a circle.
final _desktops = TargetPlatformVariant({
  TargetPlatform.macOS,
  TargetPlatform.windows,
  TargetPlatform.linux,
});

/// The ink layer of the [Material] nearest to [target].
RenderObject _inkLayer(WidgetTester tester, Finder target) =>
    tester.renderObject(
      find
          .ancestor(
            of: target,
            matching: find.byWidgetPredicate(
              (widget) => widget.runtimeType.toString() == '_InkFeatures',
            ),
          )
          .first,
    );

/// Holds a mouse press on [target] long enough for a ripple to spread.
Future<TestGesture> _press(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(
    tester.getCenter(target),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));
  return gesture;
}

void main() {
  tearDown(() => debugDesktopPlatformOverride = null);

  for (final (name, desktop, mornye, expected) in [
    ('desktop Material', true, false, true),
    ('desktop Mornye', true, true, false),
    ('phone Material', false, false, false),
  ]) {
    testWidgets('desktopRowInk is a state layer only on $name', (tester) async {
      debugDesktopPlatformOverride = desktop;
      late ({
        InteractiveInkFeatureFactory? splashFactory,
        Color? highlightColor,
      })
      ink;
      await tester.pumpWidget(
        _app(
          mornye: mornye,
          Builder(
            builder: (context) {
              ink = desktopRowInk(context, content: const Color(0xff123456));
              return const SizedBox();
            },
          ),
        ),
      );
      if (expected) {
        expect(ink.splashFactory, same(NoSplash.splashFactory));
        expect(
          ink.highlightColor,
          const Color(0xff123456).withValues(alpha: 0.1),
        );
      } else {
        expect(ink.splashFactory, isNull);
        expect(ink.highlightColor, isNull);
      }
    });
  }

  testWidgets('a desktop Material table row press shows no ripple', (
    tester,
  ) async {
    debugDesktopPlatformOverride = true;
    await tester.pumpWidget(
      _app(
        CustomScrollView(
          slivers: [
            SliverTrackTable(
              rows: const [TrackTableRow(id: 'a', title: 'First song')],
              columns: TrackTableColumn.values,
              selectedIds: const {},
              onSelect: (_, _, _) {},
              onActivate: (_) {},
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.text('First song');
    final gesture = await _press(tester, row);
    final layer = _inkLayer(tester, row);
    expect(layer, paintsExactlyCountTimes(#drawCircle, 0));
    // The pressed state layer fills the row.
    expect(layer, paints..rect());
    await gesture.up();
    await tester.pumpAndSettle();
  }, variant: _desktops);

  testWidgets('a desktop Material rail press shows no ripple', (tester) async {
    debugDesktopPlatformOverride = true;
    await tester.pumpWidget(
      _app(
        Align(
          alignment: Alignment.centerLeft,
          child: DesktopNavigationRail(
            destinations: [
              for (final tab in [ShellTab.home, ShellTab.library])
                DesktopDestination(
                  tab: tab,
                  icon: Icons.circle_outlined,
                  selectedIcon: Icons.circle,
                  label: tab.name,
                ),
            ],
            selected: ShellTab.home,
            onSelected: (_) {},
            extended: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final library = find.text('library');
    final gesture = await _press(tester, library);
    expect(_inkLayer(tester, library), paintsExactlyCountTimes(#drawCircle, 0));
    await gesture.up();
    await tester.pumpAndSettle();
  }, variant: _desktops);
}
