import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/song_share_sheet.dart';

import 'support/search_results_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  const share = MethodChannel('dev.fluttercommunity.plus/share');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> shared;
  late List<Map<String, dynamic>> requests;

  setUp(() {
    shared = [];
    requests = [];
    messenger.setMockMethodCallHandler(share, (call) async {
      shared.add((call.arguments as Map)['text'] as String);
      return 'dev.fluttercommunity.plus/share/success';
    });
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method != 'findCollectionAcrossExtensions') return null;
      requests.add(
        jsonDecode(call.arguments as String) as Map<String, dynamic>,
      );
      return jsonEncode([
        {
          'extension_id': 'example-provider',
          'display_name': 'Example Provider',
          'found': true,
          'url': 'https://example.com/track/2',
          'item_name': 'Example Song',
        },
        {
          'extension_id': 'example-other',
          'display_name': 'Example Other',
          'found': false,
        },
      ]);
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(share, null);
    messenger.setMockMethodCallHandler(backend, null);
  });

  Future<void> open(WidgetTester tester, {required bool mornye}) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          extensionProvider.overrideWith(SearchFixtureExtensions.new),
        ],
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSongShare(
                  context,
                  title: 'Example Song',
                  artist: 'Example Artist',
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  test('the shared text leaves out a missing artist', () {
    expect(
      songShareText(' Example Song ', 'Example Artist'),
      'Example Song - Example Artist',
    );
    expect(songShareText('Example Song', ' '), 'Example Song');
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style: Share name sends the title and artist', (
      tester,
    ) async {
      await open(tester, mornye: mornye);
      expect(find.text('Example Song - Example Artist'), findsOneWidget);
      expect(find.text('Share link'), findsOneWidget);

      await tester.tap(find.text('Share name'));
      await tester.pumpAndSettle();
      expect(shared, ['Example Song - Example Artist']);
      expect(find.text('Share name'), findsNothing);
      // Nothing was searched for a name.
      expect(requests, isEmpty);
    });

    testWidgets('$style: Share link shares the link of the picked service', (
      tester,
    ) async {
      await open(tester, mornye: mornye);
      await tester.tap(find.text('Share link'));
      await tester.pumpAndSettle();

      expect(requests.single['type'], 'track');
      expect(requests.single['name'], 'Example Song');
      expect(requests.single['artists'], 'Example Artist');
      expect(find.text('Share name'), findsNothing);
      expect(find.text('Share link'), findsOneWidget);
      expect(find.text('Example Provider'), findsOneWidget);
      expect(find.text('Not found'), findsOneWidget);

      await tester.tap(find.text('Example Provider'));
      await tester.pumpAndSettle();
      expect(shared, ['https://example.com/track/2']);
      expect(find.text('Example Provider'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
