import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final mornye in [false, true]) {
    testWidgets('artist picker offers each featured credit ($mornye)', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => navigateToArtistCredits(
                    context,
                    artistNames: 'First Artist featured Second Artist',
                  ),
                  child: const Text('Artists'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();
      expect(find.text('First Artist'), findsOneWidget);
      expect(find.text('Second Artist'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
