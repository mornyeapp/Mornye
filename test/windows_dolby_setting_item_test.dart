import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/windows_dolby_setting_item.dart';
import 'package:mornye/services/windows_media_playback_deck.dart';

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Future<WindowsDolbySupport?> Function() loadSupport, {
  AppSettings settings = const AppSettings(),
}) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [initialSettingsProvider.overrideWithValue(settings)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: WindowsDolbySettingItem(loadSupport: loadSupport)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('shows which Dolby formats this PC can play', (tester) async {
    await _pump(
      tester,
      () async => const WindowsDolbySupport(
        dolbyDigitalPlus: true,
        ac4: false,
        spatialSound: true,
      ),
    );
    expect(
      find.textContaining('E-AC-3: supported on this PC.'),
      findsOneWidget,
    );
    expect(find.textContaining('AC-4: no decoder on this PC.'), findsOneWidget);
    expect(find.textContaining('Spatial sound: on'), findsOneWidget);
  });

  testWidgets('says when Atmos needs a spatial sound format', (tester) async {
    await _pump(
      tester,
      () async => const WindowsDolbySupport(
        dolbyDigitalPlus: true,
        ac4: true,
        spatialSound: false,
      ),
    );
    expect(find.textContaining('AC-4: supported on this PC.'), findsOneWidget);
    expect(find.textContaining('Spatial sound: off'), findsOneWidget);
  });

  testWidgets('without the Windows engine only the switch shows', (
    tester,
  ) async {
    final container = await _pump(tester, () async => null);
    expect(find.text('Dolby Atmos through Windows'), findsOneWidget);
    expect(find.textContaining('E-AC-3: '), findsNothing);

    await tester.tap(find.text('Dolby Atmos through Windows'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).windowsDolbyEngine, isFalse);
  });

  testWidgets('notes that exclusive output keeps Dolby songs in the app', (
    tester,
  ) async {
    await _pump(
      tester,
      () async => null,
      settings: const AppSettings(exclusiveOutput: true),
    );
    expect(
      find.textContaining('Exclusive output is on, so Dolby songs play'),
      findsOneWidget,
    );
  });
}
