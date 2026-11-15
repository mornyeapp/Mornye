import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/files_settings_page.dart';
import 'package:mornye/screens/setup_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';

class _SetupSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> ensureLoaded() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Completer<Map<String, String>?> picker;
  late SharedPreferences prefs;
  var pickerCalls = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    pickerCalls = 0;
    messenger.setMockMethodCallHandler(backend, (call) async {
      expect(call.method, 'pickIosDirectory');
      pickerCalls++;
      return picker.future;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(backend, null);
  });

  Future<ProviderContainer> openPicker(
    WidgetTester tester, {
    bool mornye = false,
  }) async {
    picker = Completer<Map<String, String>?>();
    tester.view.physicalSize = const Size(820, 1180);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        initialSettingsProvider.overrideWithValue(
          const AppSettings(downloadDirectory: '/old/Music'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.light) : ThemeData(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const FilesSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download Directory'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose from Files'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    // The native reply arrives after its originating sheet has been disposed.
    expect(find.text('Choose from Files'), findsNothing);
    expect(pickerCalls, 1);
    return container;
  }

  for (final mornye in [false, true]) {
    testWidgets(
      'picker failure stays visible after the sheet closes ($mornye)',
      (tester) async {
        final container = await openPicker(tester, mornye: mornye);
        picker.completeError(
          PlatformException(code: 'BOOKMARK_FAILED', message: 'Access denied'),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Failed to open folder picker:'),
          findsOneWidget,
        );
        expect(
          container.read(settingsProvider).downloadDirectory,
          '/old/Music',
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets('a granted folder is saved even with a cloud-shaped path', (
    tester,
  ) async {
    final container = await openPicker(tester);
    const path =
        '/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Music';
    picker.complete({'path': path, 'bookmark': 'native-access-bookmark'});
    await tester.pumpAndSettle();
    final settings = container.read(settingsProvider);
    expect(settings.downloadDirectory, path);
    expect(settings.downloadDirectoryBookmark, 'native-access-bookmark');
    expect(prefs.getString('app_settings'), contains('native-access-bookmark'));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('cancelling Files preserves the previous download folder', (
    tester,
  ) async {
    final container = await openPicker(tester);
    picker.complete(null);
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).downloadDirectory, '/old/Music');
    expect(find.textContaining('Failed to open folder picker:'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('setup retains the chosen folder and its grant in the draft', (
    tester,
  ) async {
    picker = Completer<Map<String, String>?>();
    const permissions = MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    messenger.setMockMethodCallHandler(permissions, (_) async => 1);
    addTearDown(() => messenger.setMockMethodCallHandler(permissions, null));
    await prefs.setString('setup_progress_v1', '{"step":3}');
    tester.view.physicalSize = const Size(820, 1180);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith(_SetupSettings.new)],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SetupScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Select Folder'), findsOneWidget);
    await tester.tap(find.text('Select Folder'));
    // Setup keeps its loading indicator active while the options sheet is open.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Choose from Files'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(pickerCalls, 1);
    const path =
        '/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Music';
    picker.complete({'path': path, 'bookmark': 'native-access-bookmark'});
    await tester.pumpAndSettle();
    final draft = jsonDecode(prefs.getString('setup_progress_v1')!) as Map;
    expect(draft['directory'], path);
    expect(draft['bookmark'], 'native-access-bookmark');
    expect(draft['step'], 3);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
