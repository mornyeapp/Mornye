import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/extensions_page.dart';
import 'package:mornye/screens/setup_screen.dart';
import 'package:mornye/services/extension_storage_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/desktop_folders.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/extension_storage_setting.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/fixed_settings.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(error: 'Keyring unavailable');

  @override
  Future<void> ensureInitialized() async {
    if (state.isInitialized) return;
    try {
      await ExtensionStorageService.prepare();
      state = state.copyWith(isInitialized: true, error: null);
    } catch (error) {
      state = state.copyWith(error: error.toString());
      rethrow;
    }
  }
}

class _Settings extends FixedSettingsNotifier {
  @override
  Future<void> ensureLoaded() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late ProviderContainer container;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('extension-storage-ui-');
    debugDesktopPlatformOverride = true;
    debugDesktopMusicDirectoryOverride = '${directory.path}/Music';
    ExtensionStorageService.resetForTesting();
    SharedPreferences.setMockInitialValues({
      'setup_progress_v1': jsonEncode({
        'step': 2,
        'directory': '${directory.path}/Music',
      }),
    });
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(
      secure,
      (_) async => throw PlatformException(
        code: 'Libsecret error',
        message: 'secret_service_get_sync: The name is not activatable',
      ),
    );
    container = ProviderContainer(
      overrides: [
        extensionProvider.overrideWith(_Extensions.new),
        settingsProvider.overrideWith(_Settings.new),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    ExtensionStorageService.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
    debugDesktopPlatformOverride = null;
    debugDesktopMusicDirectoryOverride = null;
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(secure, null);
    await directory.delete(recursive: true);
  });

  Widget app(Widget child, bool mornye) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: mornye ? MornyeTheme.build(Brightness.light) : ThemeData(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );

  Future<void> settleStorage(WidgetTester tester) async {
    final row = find.descendant(
      of: find.byType(ExtensionStorageSetting),
      matching: find.byType(SettingsSwitchItem),
    );
    for (var attempt = 0; attempt < 100; attempt++) {
      // Filesystem and chmod complete outside the widget test's fake clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (row.evaluate().isNotEmpty &&
          tester.widget<SettingsSwitchItem>(row).enabled) {
        await tester.pumpAndSettle();
        return;
      }
    }
    final local = File(
      '${directory.path}/extension_data/.master_key_unsecured',
    );
    fail(
      'Storage did not finish: ${container.read(unsecuredExtensionStorageProvider)}, '
      'extension=${container.read(extensionProvider).error}, '
      'localBytes=${local.existsSync() ? local.lengthSync() : -1}',
    );
  }

  for (final mornye in [false, true]) {
    testWidgets('Linux extension settings recover without keyring ($mornye)', (
      tester,
    ) async {
      await tester.pumpWidget(app(const ExtensionsPage(), mornye));
      await settleStorage(tester);
      final setting = find.byType(ExtensionStorageSetting);
      expect(find.text('Use unsecured extension storage'), findsOneWidget);
      expect(find.textContaining('anyone with access'), findsOneWidget);
      expect(
        tester
            .widget<SettingsSwitchItem>(
              find.descendant(
                of: setting,
                matching: find.byType(SettingsSwitchItem),
              ),
            )
            .value,
        isFalse,
      );
      await tester.runAsync(() async {
        await tester.tap(
          find.descendant(of: setting, matching: find.byType(AppSwitch)),
        );
      });
      await settleStorage(tester);
      expect(container.read(extensionProvider).isInitialized, isTrue);
      expect(
        tester
            .widget<SettingsSwitchItem>(
              find.descendant(
                of: setting,
                matching: find.byType(SettingsSwitchItem),
              ),
            )
            .value,
        isTrue,
      );
      await tester.runAsync(() async {
        await tester.tap(
          find.descendant(of: setting, matching: find.byType(AppSwitch)),
        );
      });
      await settleStorage(tester);
      expect(
        find.textContaining('Start or unlock it before switching'),
        findsOneWidget,
      );
      expect(
        await tester.runAsync(
          ExtensionStorageService.isUnsecuredStorageEnabled,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('Linux folder setup offers unsecured storage ($mornye)', (
      tester,
    ) async {
      await tester.pumpWidget(app(const SetupScreen(), mornye));
      await settleStorage(tester);
      expect(find.byType(ExtensionStorageSetting), findsOneWidget);
      expect(find.text('Use unsecured extension storage'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant({TargetPlatform.linux}));
  }

  testWidgets('other platforms do not expose unsecured storage', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(const Scaffold(body: ExtensionStorageSetting()), false),
    );
    expect(find.byType(SettingsSwitchItem), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));
}
