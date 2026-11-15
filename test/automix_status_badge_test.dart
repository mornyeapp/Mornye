import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/automix_status.dart';
import 'package:mornye/widgets/automix_status_badge.dart';

void main() {
  testWidgets(
    'badge follows actual transition state and disappears after cancellation',
    (tester) async {
      addTearDown(() => autoMixStatus.value = AutoMixStatus.idle);
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: AutoMixStatusBadge()),
        ),
      );
      expect(find.text('Mixing'), findsNothing);
      autoMixStatus.value = AutoMixStatus.mixing;
      await tester.pump();
      expect(find.text('Mixing'), findsOneWidget);
      autoMixStatus.value = AutoMixStatus.crossfading;
      await tester.pump();
      expect(find.text('Crossfade'), findsOneWidget);
      autoMixStatus.value = AutoMixStatus.idle;
      await tester.pump();
      expect(find.text('Crossfade'), findsNothing);
    },
  );
}
