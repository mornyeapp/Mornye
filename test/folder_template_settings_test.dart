import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/files_settings_page.dart';
import 'package:mornye/services/backend/native_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

Object? _result(String method, Object? args) {
  if (method != 'buildFilename') return null;
  final template = (args as Map)['template'];
  return switch (template) {
    '{artist}' => 'Example Artist',
    '{date} - {album}' => '2026-05-04 - Example Album',
    _ => 'Example Album',
  };
}

class _Transport implements NativeBackendTransport {
  late NativeMessageListener listener;
  @override
  void init(Uint8List configJson, NativeMessageListener listener) =>
      this.listener = listener;
  @override
  void call(int id, String method, Uint8List argsJson, Uint8List? bytes) {
    scheduleMicrotask(
      () => listener(
        id,
        NativeMessageKind.result,
        utf8.encode(
          jsonEncode(_result(method, jsonDecode(utf8.decode(argsJson)))),
        ),
      ),
    );
  }

  @override
  void subscribe(int kind) {}
  @override
  void unsubscribe(int kind) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    debugDesktopPlatformOverride = null;
    RustFfiBackend.debugShared = null;
  });

  test(
    'custom setting persists and older settings retain the preset',
    () async {
      final old = AppSettings.fromJson({'folderOrganization': 'artist_album'});
      expect(old.folderOrganization, 'artist_album');
      expect(old.folderPathTemplate, '{artist}/{album}');
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () =>
                FixedSettingsNotifier(const AppSettings(separateSingles: true)),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      notifier.setFolderPathTemplate(' {artist}/{date} - {album} ');
      final settings = container.read(settingsProvider);
      expect(settings.folderOrganization, 'custom');
      expect(settings.separateSingles, isFalse);
      expect(
        AppSettings.fromJson(settings.toJson()).folderPathTemplate,
        '{artist}/{date} - {album}',
      );
      notifier.setFolderPathTemplate('../{album}');
      expect(container.read(settingsProvider), same(settings));
      await pumpEventQueue();
      final saved =
          jsonDecode(
                (await SharedPreferences.getInstance()).getString(
                  'app_settings',
                )!,
              )
              as Map<String, dynamic>;
      expect(
        AppSettings.fromJson(saved).folderPathTemplate,
        settings.folderPathTemplate,
      );
    },
  );

  for (final mornye in [false, true]) {
    testWidgets(
      '${mornye ? 'Mornye' : 'Material'} edits, validates and previews folder templates',
      (tester) async {
        final desktop = const {
          TargetPlatform.windows,
          TargetPlatform.macOS,
          TargetPlatform.linux,
        }.contains(defaultTargetPlatform);
        debugDesktopPlatformOverride = desktop;
        tester.view.physicalSize = desktop
            ? const Size(1200, 1000)
            : const Size(430, 932);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => _result(call.method, call.arguments),
        );
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        RustFfiBackend.debugShared = RustFfiBackend(
          openTransport: _Transport.new,
          loadConfig: () async => const DesktopBackendConfig(
            appSupportDir: '/support',
            documentsDir: '/documents',
            tempDir: '/tmp',
          ),
        );
        final container = ProviderContainer(
          overrides: [settingsProvider.overrideWith(FixedSettingsNotifier.new)],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.light)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const FilesSettingsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // On a phone the row is below the part of the list that is built.
        await tester.scrollUntilVisible(
          find.text('Custom Folder Structure'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Custom Folder Structure'));
        await tester.pumpAndSettle();
        final input = find.byType(EditableText);
        await tester.enterText(input, '../{album}');
        await tester.pumpAndSettle();
        final save = find.widgetWithText(AppDialogAction, 'Save');
        expect(tester.widget<AppDialogAction>(save).onPressed, isNull);
        expect(
          find.textContaining('Enter a relative folder path'),
          findsOneWidget,
        );

        await tester.enterText(input, '{artist}/{date} - {album}');
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
        expect(
          find.text('Example Artist/2026-05-04 - Example Album'),
          findsOneWidget,
        );
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(
          container.read(settingsProvider).folderPathTemplate,
          '{artist}/{date} - {album}',
        );
        expect(container.read(settingsProvider).folderOrganization, 'custom');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }

  testWidgets('Remove Empty Folders starts on, turns off and is '
      'searchable', (tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => _result(call.method, call.arguments),
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    RustFfiBackend.debugShared = RustFfiBackend(
      openTransport: _Transport.new,
      loadConfig: () async => const DesktopBackendConfig(
        appSupportDir: '/support',
        documentsDir: '/documents',
        tempDir: '/tmp',
      ),
    );
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(FixedSettingsNotifier.new)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const FilesSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('remove-empty-folders'));
    await tester.scrollUntilVisible(
      row,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).removeEmptyFolders, isTrue);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).removeEmptyFolders, isFalse);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(FilesSettingsPage)),
    );
    expect(
      SettingsSearchCatalog(
        l10n,
      ).files.any((entry) => entry.title == l10n.removeEmptyFoldersTitle),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
