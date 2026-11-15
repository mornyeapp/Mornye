import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/open_on_platform_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'theme rebuild retains completed lookup; identifiers replace it',
    (tester) async {
      const channel = MethodChannel('com.zarz.mornye/backend');
      final calls = <MethodCall>[];
      final pending = Completer<Map<String, dynamic>>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (calls.length == 1) {
          return {
            'platforms': {'spotify': 'https://example.test/one'},
          };
        }
        return pending.future;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      Widget app(Brightness brightness, String id) => MaterialApp(
        theme: ThemeData(brightness: brightness),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: OpenOnPlatformSheet(spotifyId: id)),
      );
      await tester.pumpWidget(app(Brightness.light, 'one'));
      await tester.pumpAndSettle();
      expect(find.text('Spotify'), findsOneWidget);
      await tester.pumpWidget(app(Brightness.dark, 'one'));
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      expect(find.text('Spotify'), findsOneWidget);
      expect(find.byType(AppLoadingIndicator), findsNothing);
      await tester.pumpWidget(app(Brightness.dark, 'two'));
      await tester.pump();
      expect(calls.length, 2);
      expect(calls.last.arguments, {'spotify_id': 'two', 'isrc': ''});
      expect(find.byType(AppLoadingIndicator), findsOneWidget);
      pending.complete({
        'platforms': {'appleMusic': 'https://example.test/two'},
      });
      await tester.pumpAndSettle();
      expect(find.text('Apple Music'), findsOneWidget);
      expect(find.text('Spotify'), findsNothing);
    },
  );
}
