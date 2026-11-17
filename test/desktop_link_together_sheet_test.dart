import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/link/desktop/link_desktop_backend.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_link_devices_button.dart';
import 'package:mornye/widgets/desktop/desktop_link_devices_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/tooltip_finder.dart';

const _pixel = LinkClientInfo(
  deviceId: 'p1',
  name: 'Pixel',
  platform: 'android',
);
const _galaxy = LinkClientInfo(
  deviceId: 'p2',
  name: 'Galaxy',
  platform: 'android',
);

/// A running host with two phones connected, without a server behind it.
class _Host extends LinkDesktopHost {
  _Host({this.together});

  final String? together;
  final ended = <bool>[];

  @override
  LinkDesktopHostState build() => LinkDesktopHostState(
    loaded: true,
    enabled: true,
    name: 'Studio',
    phase: LinkHostPhase.running,
    server: const LinkHostServer(
      port: 47710,
      fingerprint: 'ab12',
      serverId: 's1',
      name: 'Studio',
    ),
    clients: const [_pixel, _galaxy],
    togetherPhone: together,
  );

  @override
  String deviceName(String deviceId) =>
      deviceId == _pixel.deviceId ? _pixel.name : _galaxy.name;

  @override
  Future<bool> endTogether({required bool keepHere}) async {
    ended.add(keepHere);
    state = state.copyWith(togetherPhone: null);
    return true;
  }

  void start(String deviceId) =>
      state = state.copyWith(togetherPhone: deviceId);

  void end() => state = state.copyWith(togetherPhone: null);
}

void main() {
  setUp(() => debugDesktopPlatformOverride = true);
  tearDown(() => debugDesktopPlatformOverride = null);

  Finder row(String key) => find.byKey(ValueKey(key));
  Finder together() => row('desktop-link-together');
  SettingsItem item(WidgetTester tester, String key) =>
      tester.widget<SettingsItem>(row(key));

  Future<_Host> pump(
    WidgetTester tester, {
    String? together,
    bool mornye = false,
    bool reduceMotion = false,
    Widget body = const DesktopLinkDevicesSheet(),
  }) async {
    final host = _Host(together: together);
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [linkDesktopHostProvider.overrideWith(() => host)],
        child: MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
          home: Scaffold(body: body),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return host;
  }

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style: alone, this computer is checked and nothing says '
        'Play together', (tester) async {
      await pump(tester, mornye: mornye);
      expect(together(), findsNothing);
      expect(item(tester, 'link-device-computer').selected, isTrue);
      expect(item(tester, 'link-device-computer').onTap, isNull);
      expect(item(tester, 'link-device-phone-p1').onTap, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style: playing together shows a checked row and no '
        'checked device', (tester) async {
      await pump(tester, together: 'p1', mornye: mornye);
      expect(together(), findsOneWidget);
      expect(
        find.descendant(of: together(), matching: find.text('Play together')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: together(),
          matching: find.text('This computer and Pixel'),
        ),
        findsOneWidget,
      );
      // The phone starts and times it: the row is checked and no button.
      final status = tester.widget<SettingsItem>(
        find.descendant(of: together(), matching: find.byType(SettingsItem)),
      );
      expect(status.selected, isTrue);
      expect(status.trailing, isNotNull);
      expect(status.onTap, isNull);

      expect(item(tester, 'link-device-computer').selected, isFalse);
      expect(item(tester, 'link-device-computer').trailing, isNull);
      expect(item(tester, 'link-device-phone-p1').selected, isFalse);
      // Another phone waits until the two stop.
      expect(item(tester, 'link-device-phone-p2').onTap, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('choosing this computer ends it with the computer playing', (
    tester,
  ) async {
    final host = await pump(
      tester,
      together: 'p1',
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDesktopLinkDevicesSheet(context),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(row('link-device-computer'));
    await tester.pumpAndSettle();
    expect(host.ended, [true]);
    expect(row('desktop-link-devices-sheet'), findsNothing);
  });

  testWidgets('choosing the phone ends it with the phone playing', (
    tester,
  ) async {
    final host = await pump(
      tester,
      together: 'p1',
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDesktopLinkDevicesSheet(context),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(row('link-device-phone-p1'));
    await tester.pumpAndSettle();
    expect(host.ended, [false]);
  });

  testWidgets('the row opens and closes with the sheet open', (tester) async {
    final host = await pump(tester);
    final closed = tester.getTopLeft(row('link-file-changes-entry')).dy;

    host.start('p1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // On its way: the rows below have started to move, not jumped.
    final opening = tester.getTopLeft(row('link-file-changes-entry')).dy;
    expect(opening, greaterThan(closed));
    await tester.pumpAndSettle();
    final open = tester.getTopLeft(row('link-file-changes-entry')).dy;
    expect(open, greaterThan(opening));
    expect(together(), findsOneWidget);

    host.end();
    await tester.pumpAndSettle();
    expect(together(), findsNothing);
    expect(tester.getTopLeft(row('link-file-changes-entry')).dy, closed);
  });

  testWidgets('reduced motion opens the row at once', (tester) async {
    final host = await pump(tester, reduceMotion: true);
    final closed = tester.getTopLeft(row('link-file-changes-entry')).dy;
    host.start('p1');
    await tester.pump();
    await tester.pump();
    final open = tester.getTopLeft(row('link-file-changes-entry')).dy;
    expect(open, greaterThan(closed));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(row('link-file-changes-entry')).dy, open);
  });

  testWidgets('the player bar button names Play together and, in Material, '
      'draws primary', (tester) async {
    Color? color(WidgetTester tester) => IconTheme.of(
      tester.element(
        find.descendant(
          of: find.byKey(const ValueKey('desktop-link-devices-button')),
          matching: find.byType(Icon),
        ),
      ),
    ).color;

    final host = await pump(tester, body: const DesktopLinkDevicesButton());
    final scheme = Theme.of(
      tester.element(find.byType(DesktopLinkDevicesButton)),
    ).colorScheme;
    expect(findByTooltip('Devices'), findsOneWidget);
    expect(color(tester), isNot(scheme.primary));

    host.start('p1');
    await tester.pumpAndSettle();
    expect(findByTooltip('Play together'), findsOneWidget);
    expect(color(tester), scheme.primary);
  });

  testWidgets('Mornye keeps the player bar button in neutral ink', (
    tester,
  ) async {
    await pump(
      tester,
      together: 'p1',
      mornye: true,
      body: const DesktopLinkDevicesButton(),
    );
    final scheme = Theme.of(
      tester.element(find.byType(DesktopLinkDevicesButton)),
    ).colorScheme;
    expect(findByTooltip('Play together'), findsOneWidget);
    final icon = find.descendant(
      of: find.byKey(const ValueKey('desktop-link-devices-button')),
      matching: find.byType(Icon),
    );
    expect(IconTheme.of(tester.element(icon)).color, scheme.onSurface);
  });
}
