import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/extension_detail_page.dart';
import 'package:mornye/screens/settings/extensions_page.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/fixed_settings.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    extensions: [
      Extension(
        id: 'example.account',
        name: 'example.account',
        displayName: 'Example Music',
        version: '1.0.0',
        description: 'Music with optional personal account access.',
        enabled: true,
        status: 'loaded',
        settings: [
          ExtensionSetting(
            key: 'mode',
            label: 'Download account',
            type: 'select',
            defaultValue: 'Shared account',
            description: 'Choose the account used to download your music.',
            options: [
              'Shared account',
              'Personal account with extended access',
            ],
          ),
          ExtensionSetting(
            key: 'connect',
            label: 'Connect my music account and complete verification',
            type: 'button',
            action: 'connectAccount',
            description:
                'Sign in using your own account. You may be asked for a verification code.',
          ),
        ],
      ),
    ],
  );
}

void main() {
  const channel = MethodChannel('com.zarz.mornye/backend');
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'account settings work at narrow width and large text ($mornye)',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final updates = <Map<String, dynamic>>[];
        final actions = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'getExtensionSettings') return '{}';
              if (call.method == 'setExtensionSettings') {
                updates.add(
                  jsonDecode((call.arguments as Map)['settings'] as String)
                      as Map<String, dynamic>,
                );
                return null;
              }
              if (call.method == 'invokeExtensionAction') {
                actions.add((call.arguments as Map)['action'] as String);
                return jsonEncode({
                  'success': true,
                  'action_form': {
                    'version': 1,
                    'title': 'Account login',
                    'submit_action': 'submitAccount',
                    'cancel_action': '',
                    'fields': [
                      {
                        'key': 'password',
                        'label': 'Password',
                        'type': 'password',
                      },
                    ],
                  },
                });
              }
              return null;
            });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(FixedSettingsNotifier.new),
              extensionProvider.overrideWith(_Extensions.new),
            ],
            child: MaterialApp(
              theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.3)),
                child: child!,
              ),
              home: const ExtensionDetailPage(extensionId: 'example.account'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final mode = find.byWidgetPredicate(
          (widget) =>
              widget is SettingsItem && widget.title == 'Download account',
        );
        await tester.scrollUntilVisible(mode, 150);
        await tester.tap(find.text('Download account'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Personal account with extended access'));
        await tester.pumpAndSettle();
        expect(updates, [
          {'mode': 'Personal account with extended access'},
        ]);

        final connect = find.byWidgetPredicate(
          (widget) =>
              widget is SettingsItem &&
              widget.title ==
                  'Connect my music account and complete verification',
        );
        await tester.scrollUntilVisible(connect, 150);
        await tester.tap(
          find.text('Connect my music account and complete verification'),
        );
        // The action row remains busy while its account dialog is open.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('Account login'), findsOneWidget);
        expect(
          find.byType(mornye ? CupertinoTextField : TextFormField),
          findsOneWidget,
        );
        expect(
          find.text('The extension returned an invalid account form.'),
          findsNothing,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(actions, ['connectAccount']);
        expect(updates.single.containsKey('password'), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final page in [
    const ExtensionDetailPage(extensionId: 'example.account'),
    const ExtensionsPage(),
  ]) {
    testWidgets('${page.runtimeType} glass skips the plain page backdrop', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'getExtensionSettings' ? '{}' : null,
          );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            extensionProvider.overrideWith(_Extensions.new),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final glass = find.ancestor(
        of: find.text(
          page is ExtensionsPage
              ? 'Install Extension'
              : 'Music with optional personal account access.',
        ),
        matching: find.byType(MornyeGlass),
      );
      expect(glass, findsOneWidget);
      expect(tester.widget<MornyeGlass>(glass).samplesBackdrop, isFalse);
      expect(
        find.descendant(of: glass, matching: find.byType(BackdropFilter)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
