import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/expressive_button_group.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/expressive_navigation_bar.dart';
import 'package:mornye/widgets/selection_action_button.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/track_card.dart';

import 'support/app_icon_finder.dart';
import 'support/tooltip_finder.dart';

Widget _host(
  Widget child, {
  ThemeData? theme,
  bool reduceMotion = false,
  double textScale = 1,
  Locale locale = const Locale('en'),
}) => ProviderScope(
  child: MaterialApp(
    theme: theme ?? AppTheme.light(),
    locale: locale,
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: reduceMotion,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets('bridge retains dynamic colors, AMOLED, font and locale', (
    tester,
  ) async {
    for (final systemFont in [false, true]) {
      final scheme = ColorScheme.fromSeed(
        seedColor: Colors.green,
        brightness: Brightness.dark,
      ).copyWith(primary: const Color(0xffc6f192));
      final theme = AppTheme.dark(
        dynamicScheme: scheme,
        isAmoled: true,
        useSystemFont: systemFont,
      );
      late ThemeData adapted;
      late M3EThemeData expressive;
      late ThemeData host;
      late String adaptedCancel;
      late String hostCancel;
      await tester.pumpWidget(
        _host(
          MaterialExpressiveScope(
            child: Builder(
              builder: (context) {
                adapted = Theme.of(context);
                expressive = M3ETheme.of(context);
                host = Theme.of(context);
                adaptedCancel = MaterialLocalizations.of(
                  context,
                ).cancelButtonLabel;
                hostCancel = MaterialLocalizations.of(
                  context,
                ).cancelButtonLabel;
                return const SizedBox();
              },
            ),
          ),
          theme: theme,
          locale: const Locale('id'),
        ),
      );
      await tester.pumpAndSettle();
      expect(adapted.colorScheme.primary, scheme.primary);
      expect(adapted.colorScheme.primaryFixed, scheme.primaryFixed);
      expect(adapted.colorScheme.surface, scheme.surface);
      expect(adapted.scaffoldBackgroundColor, Colors.black);
      expect(
        expressive.typeScale.bodyMedium.fontFamily,
        theme.textTheme.bodyMedium!.fontFamily,
      );
      expect(host.colorScheme, scheme);
      expect(adaptedCancel, hostCancel);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('switch row and thumb toggle once and support keyboard', (
    tester,
  ) async {
    var value = false;
    var calls = 0;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            return AppSwitchListTile(
              title: const Text('Autoplay'),
              value: value,
              onChanged: (next) => setState(() {
                value = next;
                calls++;
              }),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(findAppIcon(Icons.check), findsNothing);
    await tester.tap(find.text('Autoplay'));
    await tester.pumpAndSettle();
    expect(value, isTrue);
    expect(calls, 1);
    expect(findAppIcon(Icons.check), findsOneWidget);
    await tester.tap(find.byType(M3ESwitch));
    await tester.pumpAndSettle();
    expect(value, isFalse);
    expect(calls, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chips preserve select and deselect callbacks', (tester) async {
    var selected = false;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => AppChoiceChip(
            label: const Text('Albums'),
            icon: const Icon(Icons.album_outlined),
            count: 12,
            selected: selected,
            singleChoice: true,
            onSelected: (next) => setState(() => selected = next),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('12'), findsOneWidget);
    expect(findAppIcon(Icons.album_outlined), findsOneWidget);
    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    expect(selected, isFalse);
  });

  testWidgets('actions respect disabled state, custom colors and touch size', (
    tester,
  ) async {
    var enabled = false;
    var calls = 0;
    late StateSetter update;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return ExpressiveButton(
              onPressed: enabled ? () => calls++ : null,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.teal,
                foregroundColor: Colors.white,
              ),
              child: const Text('Play'),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    expect(calls, 0);
    update(() => enabled = true);
    await tester.pumpAndSettle();
    final button = tester.widget<M3EButton>(find.byType(M3EButton));
    expect(button.decoration!.backgroundColor!.resolve({}), Colors.teal);
    expect(
      tester.getSize(find.byType(M3EButton)).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.text('Play'));
    expect(calls, 1);
  });

  testWidgets('large labels fit narrow settings and selection actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SettingsGroup(
              children: [
                AppSwitchListTile(
                  value: true,
                  onChanged: (_) {},
                  title: const Text('Continue playing music from your Library'),
                ),
              ],
            ),
            Row(
              children: [
                for (final label in [
                  'Remove ReplayGain (10)',
                  'Convert 10 tracks',
                ])
                  Expanded(
                    child: SelectionActionButton(
                      icon: Icons.music_note,
                      label: label,
                      onPressed: () {},
                      colorScheme: AppTheme.light().colorScheme,
                    ),
                  ),
              ],
            ),
          ],
        ),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('navigation preserves badges, RTL order and safe area', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var selected = 0;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => Directionality(
            textDirection: TextDirection.rtl,
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(padding: const EdgeInsets.only(bottom: 24)),
              child: ExpressiveNavigationBar(
                selectedIndex: selected,
                onDestinationSelected: (index) =>
                    setState(() => selected = index),
                backgroundColor: Colors.black,
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
                  NavigationDestination(
                    icon: Badge(label: Text('3'), child: Icon(Icons.download)),
                    label: 'Downloads',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.settings),
                    label: 'Settings',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ExpressiveNavigationBar)).height, 88);
    expect(find.text('3'), findsOneWidget);
    expect(find.bySemanticsLabel('Home'), findsOneWidget);
    expect(find.bySemanticsLabel('Home\nHome'), findsNothing);
    expect(
      tester.getCenter(find.text('Home')).dx,
      greaterThan(tester.getCenter(find.text('Settings')).dx),
    );
    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();
    expect(selected, 1);
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    for (final reduceMotion in [false, true]) {
      testWidgets('navigation tint continues through system insets '
          '(dark: $dark, reduced motion: $reduceMotion)', (tester) async {
        final capture = GlobalKey();
        const backdrop = Color(0xff725ca8);
        final theme = dark ? AppTheme.dark() : AppTheme.light();
        final tint = theme.colorScheme.surfaceContainer.withValues(alpha: 0.72);
        for (final bottomInset in [24.0, 48.0]) {
          await tester.pumpWidget(
            _host(
              Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(padding: EdgeInsets.only(bottom: bottomInset)),
                  child: RepaintBoundary(
                    key: capture,
                    child: SizedBox(
                      width: 320,
                      child: ColoredBox(
                        color: backdrop,
                        child: ExpressiveNavigationBar(
                          selectedIndex: 0,
                          onDestinationSelected: (_) {},
                          backgroundColor: tint,
                          destinations: const [
                            NavigationDestination(
                              icon: Icon(Icons.home),
                              label: 'Home',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.settings),
                              label: 'Settings',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              theme: theme,
              reduceMotion: reduceMotion,
            ),
          );
          await tester.pumpAndSettle();
          final colors = await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(capture),
            );
            final image = await boundary.toImage();
            try {
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              return [
                // Sample between destinations and at the physical bottom.
                for (final y in [32, image.height - 1])
                  Color.fromARGB(
                    bytes.getUint8((y * image.width + 160) * 4 + 3),
                    bytes.getUint8((y * image.width + 160) * 4),
                    bytes.getUint8((y * image.width + 160) * 4 + 1),
                    bytes.getUint8((y * image.width + 160) * 4 + 2),
                  ),
              ];
            } finally {
              image.dispose();
            }
          });
          expect(colors![0], colors[1]);
          final expected = Color.alphaBlend(tint, backdrop);
          expect(colors[0].r, closeTo(expected.r, 1 / 255));
          expect(colors[0].g, closeTo(expected.g, 1 / 255));
          expect(colors[0].b, closeTo(expected.b, 1 / 255));
          expect(
            tester.getSize(find.byType(ExpressiveNavigationBar)).height,
            64 + bottomInset,
          );
          expect(tester.takeException(), isNull);
        }
      });
    }
  }

  testWidgets('reduced motion keeps interactive Material fallback', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExpressiveButton(
              onPressed: () => calls++,
              child: const Text('Play'),
            ),
            ExpressiveIconButton(
              icon: const Icon(Icons.skip_next),
              tooltip: 'Next',
              onPressed: () => calls++,
            ),
            AppSwitch(value: false, onChanged: (_) => calls++),
          ],
        ),
        reduceMotion: true,
      ),
    );
    expect(find.byType(M3EButton), findsNothing);
    expect(find.byType(M3EIconButton), findsNothing);
    expect(find.byType(M3ESwitch), findsNothing);
    await tester.tap(find.text('Play'));
    await tester.tap(findByTooltip('Next'));
    await tester.tap(find.byType(Switch));
    expect(calls, 3);
  });

  testWidgets('Mornye keeps Cupertino actions and its own surfaces', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppActionButton(
              onPressed: () {},
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play'),
            ),
            AppChoiceChip(
              label: const Text('Albums'),
              selected: true,
              onSelected: (_) {},
            ),
            const AppContentCard(child: Text('Details')),
            AppSwitch(value: true, onChanged: (_) {}),
          ],
        ),
        theme: MornyeTheme.build(Brightness.dark),
        reduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MaterialExpressiveScope), findsNothing);
    expect(find.byType(CupertinoButton), findsAtLeast(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('standard settings rows connect; custom content keeps a card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SettingsGroup(
          children: [
            SettingsItem(title: 'First', onTap: () {}),
            SettingsSwitchItem(title: 'Second', value: true, onChanged: (_) {}),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final group = find.byType(SettingsGroup);
    expect(
      find.descendant(of: group, matching: find.byType(M3ECard)),
      findsNothing,
    );
    expect(
      find.descendant(of: group, matching: find.byType(Divider)),
      findsNothing,
    );
    final first = tester.getRect(find.text('First'));
    final second = tester.getRect(find.text('Second'));
    expect(second.top, greaterThan(first.bottom));

    await tester.pumpWidget(
      _host(
        SettingsGroup(
          children: [
            SettingsItem(title: 'Field', onTap: () {}),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(M3ECard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('button group squishes neighbours and keeps a plain fallback', (
    tester,
  ) async {
    var calls = 0;
    Widget group() => SizedBox(
      width: 360,
      child: ExpressiveButtonGroup(
        flexible: const {1},
        children: [
          ExpressiveIconButton(
            icon: const Icon(Icons.favorite_border),
            tooltip: 'Love',
            backgroundColor: Colors.grey,
            onPressed: () => calls++,
          ),
          ExpressiveButton(
            onPressed: () => calls++,
            child: const Text('Download'),
          ),
          ExpressiveIconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: 'Add',
            backgroundColor: Colors.grey,
            onPressed: () => calls++,
          ),
        ],
      ),
    );
    await tester.pumpWidget(_host(group()));
    await tester.pumpAndSettle();
    final slot = find.byType(ExpressiveButtonGroupSlot).first;
    final download = find.byType(M3EButton);
    final restingSlot = tester.getSize(slot).width;
    final restingDownload = tester.getSize(download).width;
    expect(restingSlot, 48);
    expect(restingDownload, closeTo(360 - 2 * 48 - 2 * 12, 1));

    final gesture = await tester.startGesture(
      tester.getCenter(findByTooltip('Love')),
    );
    // Stay under the long-press delay so the release still taps.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getSize(slot).width, greaterThan(restingSlot));
    expect(tester.getSize(download).width, lessThan(restingDownload));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getSize(slot).width, restingSlot);
    expect(calls, 1);

    await tester.pumpWidget(_host(group(), reduceMotion: true));
    await tester.pumpAndSettle();
    expect(find.byType(ExpressiveButtonGroupSlot), findsNothing);
    expect(
      tester.getSize(find.byType(FilledButton)).width,
      lessThan(restingDownload),
    );
    await tester.tap(find.text('Download'));
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('track rows connect only on the Material theme', (tester) async {
    BorderRadius? radius;
    Widget segment({required bool first, required bool last}) =>
        TrackCardSegment(
          first: first,
          last: last,
          child: Builder(
            builder: (context) {
              radius = TrackCardSegment.radiusOf(context);
              return const SizedBox();
            },
          ),
        );
    await tester.pumpWidget(_host(segment(first: true, last: false)));
    expect(radius?.topLeft, const Radius.circular(20));
    expect(radius?.bottomLeft, const Radius.circular(4));
    await tester.pumpWidget(_host(segment(first: false, last: true)));
    expect(radius?.topLeft, const Radius.circular(4));
    expect(radius?.bottomLeft, const Radius.circular(20));
    await tester.pumpWidget(
      _host(
        segment(first: true, last: true),
        theme: MornyeTheme.build(Brightness.dark),
      ),
    );
    await tester.pumpAndSettle();
    expect(radius, isNull);
  });
}
