import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/dither_type_choice.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _title = 'Dither type';
const _spatial = EventChannel('com.zarz.mornye/spatial_audio');

Future<ProviderContainer> _pumpPage(
  WidgetTester tester, {
  required bool mornye,
  required AppSettings settings,
}) async {
  SharedPreferences.setMockInitialValues({});
  debugAndroidAudioSettingsOverride = true;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockStreamHandler(
    _spatial,
    MockStreamHandler.inline(onListen: (_, events) => events.success(null)),
  );
  addTearDown(() => messenger.setMockStreamHandler(_spatial, null));
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [initialSettingsProvider.overrideWithValue(settings)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const PlaybackSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  tearDown(() => debugAndroidAudioSettingsOverride = null);

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style: the direct USB driver offers plain or high-pass '
        'dither', (tester) async {
      final container = await _pumpPage(
        tester,
        mornye: mornye,
        settings: const AppSettings(usbBitPerfect: true, usbDirect: true),
      );
      await tester.scrollUntilVisible(
        find.byType(DitherTypeChoice),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text(_title), findsOneWidget);
      expect(container.read(settingsProvider).usbDitherHighPass, isFalse);
      expect(find.textContaining('Plain TPDF spreads'), findsOneWidget);

      // The button group may build a label twice: take the first.
      Finder option(String label) => find
          .descendant(
            of: find.byType(DitherTypeChoice),
            matching: find.text(label),
          )
          .first;
      await tester.ensureVisible(option('TPDF HP'));
      await tester.pumpAndSettle();
      await tester.tap(option('TPDF HP'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).usbDitherHighPass, isTrue);
      expect(find.textContaining('High-pass TPDF moves'), findsOneWidget);

      await tester.tap(option('TPDF'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).usbDitherHighPass, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style: the dither choice is hidden while the direct driver '
        'is off', (tester) async {
      await _pumpPage(
        tester,
        mornye: mornye,
        settings: const AppSettings(usbBitPerfect: true),
      );
      await tester.scrollUntilVisible(
        find.text('Direct USB driver'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(DitherTypeChoice), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
