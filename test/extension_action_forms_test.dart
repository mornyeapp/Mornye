import 'dart:convert';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/controllers/extension_action_forms.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';

import 'support/fixed_settings.dart';

void main() {
  const channel = MethodChannel('com.zarz.mornye/backend');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  Future<void> showHost(
    WidgetTester tester,
    Future<void> Function(BuildContext) action, {
    bool mornye = false,
  }) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith(FixedSettingsNotifier.new)],
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => action(context),
                child: const Text('Connect'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  for (final mornye in [false, true]) {
    testWidgets('empty cancel action allows account setup ($mornye)', (
      tester,
    ) async {
      final actions = <String>[];
      final inputs = <Map<String, dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map;
            actions.add(args['action'] as String);
            if (args['arguments_json'] != null) {
              inputs.add(
                Map<String, dynamic>.from(
                  (jsonDecode(args['arguments_json'] as String) as List).single
                      as Map,
                ),
              );
              return '{"success":true,"state":"active"}';
            }
            return jsonEncode({
              'success': true,
              'result': {
                'success': true,
                'byoa_form': {
                  'version': 1,
                  'title': 'Connect your account',
                  'submit_action': 'connectAccount',
                  'cancel_action': '',
                  'fields': [
                    {
                      'key': 'region',
                      'label': 'Account region',
                      'type': 'select',
                      'options': ['Europe', 'Asia'],
                    },
                    {
                      'key': 'port',
                      'label': 'Port',
                      'type': 'number',
                      'required': true,
                    },
                    {
                      'key': 'password',
                      'label': 'Password',
                      'type': 'password',
                      'required': true,
                    },
                  ],
                },
              },
            });
          });
      Map<String, dynamic>? result;
      await showHost(tester, (context) async {
        result = await runExtensionActionWithForms(
          context,
          'example.account',
          'connectAccount',
        );
      }, mornye: mornye);
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Connect your account'), findsOneWidget);
      expect(result, isNull);

      final fields = find.byType(mornye ? CupertinoTextField : TextFormField);
      await tester.enterText(fields.first, 'invalid');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid number.'), findsOneWidget);
      expect(find.text('Enter a value.'), findsOneWidget);
      expect(actions, ['connectAccount']);

      await tester.enterText(fields.first, '443');
      await tester.enterText(fields.last, 'fixture-password');
      if (mornye) {
        final text = tester.widget<CupertinoTextField>(fields.last);
        expect(text.obscureText, isTrue);
        expect(text.enableIMEPersonalizedLearning, isFalse);
      }
      await tester.tap(find.text('Europe'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBottomSheet), findsOneWidget);
      expect(find.byType(AppSheetOption), findsNWidgets(2));
      expect(tester.testTextInput.isVisible, isFalse);

      // Dismissing the picker must leave both the choice and typed fields intact.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Europe'), findsOneWidget);
      await tester.tap(find.text('Europe'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Asia'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBottomSheet), findsNothing);
      expect(find.text('Asia'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(result!['state'], 'active');
      expect(inputs, [
        {'region': 'Asia', 'port': 443, 'password': 'fixture-password'},
      ]);
      expect(actions, ['connectAccount', 'connectAccount']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty cancel action does not invoke an unnamed action', (
    tester,
  ) async {
    final actions = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          actions.add((call.arguments as Map)['action'] as String);
          return '{"success":true,"action_form":{"version":1,'
              '"submit_action":"loginAccount","cancel_action":"",'
              '"fields":[{"key":"password","type":"password"}]}}';
        });
    await showHost(tester, (context) async {
      await runExtensionActionWithForms(
        context,
        'example.account',
        'loginAccount',
      );
    });
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(actions, ['loginAccount']);
  });

  testWidgets('nonempty malformed cancel actions are still rejected', (
    tester,
  ) async {
    for (final cancelAction in ['not an action', 42]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => jsonEncode({
              'success': true,
              'action_form': {
                'version': 1,
                'submit_action': 'loginAccount',
                'cancel_action': cancelAction,
                'fields': [
                  {'key': 'password', 'type': 'password'},
                ],
              },
            }),
          );
      Map<String, dynamic>? result;
      await showHost(tester, (context) async {
        result = await runExtensionActionWithForms(
          context,
          'example.account',
          'loginAccount',
        );
      });
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(result!['success'], isFalse);
      expect(find.byType(TextFormField), findsNothing);
    }
  });

  testWidgets('password form submits transient input and clears its text', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if ((call.arguments as Map)['arguments_json'] != null) {
            return '{"success":true,"state":"active"}';
          }
          return '{"success":true,"action_form":{"version":1,"title":"Account login",'
              '"submit_action":"loginAccount","fields":[{"key":"password",'
              '"label":"Password","type":"password","required":true,"secret":true}]}}';
        });
    Map<String, dynamic>? result;
    await showHost(tester, (context) async {
      result = await runExtensionActionWithForms(
        context,
        'example.account',
        'loginAccount',
      );
    });
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextFormField>(find.byType(TextFormField));
    final controller = field.controller!;
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
    await tester.enterText(find.byType(TextFormField), 'fixture-password');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(result!['state'], 'active');
    expect(controller.text, isEmpty);
    expect(calls.map((call) => call.method), [
      'invokeExtensionAction',
      'invokeExtensionAction',
    ]);
    expect(
      (calls.last.arguments as Map)['arguments_json'],
      contains('fixture-password'),
    );
  });

  testWidgets('malformed forms fail without opening a dialog', (tester) async {
    for (final fields in [
      [
        {'key': 'code', 'type': 'otp', 'label': 42},
      ],
      [
        {
          'key': 'region',
          'type': 'select',
          'options': ['one', 'one'],
        },
      ],
      [
        {
          'key': 'region',
          'type': 'select',
          'options': ['one', 42],
        },
      ],
      [
        {'key': 'code', 'type': 'otp'},
        {'key': 'code', 'type': 'otp'},
      ],
    ]) {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls++;
            return jsonEncode({
              'success': true,
              'action_form': {
                'version': 1,
                'submit_action': 'loginAccount',
                'fields': fields,
              },
            });
          });
      Map<String, dynamic>? result;
      await showHost(tester, (context) async {
        result = await runExtensionActionWithForms(
          context,
          'example.account',
          'loginAccount',
        );
      });
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(result!['success'], isFalse);
      expect(find.byType(TextFormField), findsNothing);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('password and OTP are sent as separate transient actions', (
    tester,
  ) async {
    final inputs = <Map<String, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          final raw = args['arguments_json'];
          if (raw != null) {
            inputs.add(
              Map<String, dynamic>.from(
                (jsonDecode(raw as String) as List).single as Map,
              ),
            );
          }
          if (args['action'] == 'submitCode') {
            return '{"success":true,"state":"active"}';
          }
          final otp = raw != null;
          return jsonEncode({
            'success': true,
            'action_form': {
              'version': 1,
              'submit_action': otp ? 'submitCode' : 'loginAccount',
              'fields': [
                {
                  'key': otp ? 'code' : 'password',
                  'type': otp ? 'otp' : 'password',
                  'secret': true,
                },
              ],
            },
          });
        });
    Map<String, dynamic>? result;
    await showHost(tester, (context) async {
      result = await runExtensionActionWithForms(
        context,
        'example.account',
        'loginAccount',
      );
    });
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'fixture-secret');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      isEmpty,
    );
    await tester.enterText(find.byType(TextFormField), 'A12345');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(inputs, [
      {'password': 'fixture-secret'},
      {'code': 'A12345'},
    ]);
    expect(result!['state'], 'active');
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled OTP form cancels auth without submitting its code', (
    tester,
  ) async {
    final actions = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          actions.add(args['action'] as String);
          expect(args.containsKey('arguments_json'), isFalse);
          if (args['action'] == 'cancelAccountAuth') return '{"success":true}';
          return '{"success":true,"byoa_form":{"version":1,"title":"OTP",'
              '"submit_action":"submitAccountOTP","cancel_action":"cancelAccountAuth",'
              '"fields":[{"key":"code","label":"Code","type":"otp","secret":true}]}}';
        });
    await showHost(tester, (context) async {
      await runExtensionActionWithForms(
        context,
        'example.account',
        'submitAccountOTP',
      );
    });
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '123456');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(actions, ['submitAccountOTP', 'cancelAccountAuth']);
  });
}
