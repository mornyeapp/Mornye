import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/settings/about_page.dart';
import 'package:mornye/screens/settings/settings_tab.dart';
import 'package:mornye/services/app_remote_config_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/page_back.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    AppRemoteConfigService? service,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: theme ?? AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SettingsTab(
              remoteConfigService:
                  service ??
                  AppRemoteConfigService(
                    client: MockClient((_) async => http.Response('{}', 200)),
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Map<String, Object?> goalConfig({
    double progress = 0.09,
    bool active = true,
    bool percentage = true,
  }) => {
    'donate': {
      'monthly_goal': {
        'enabled': true,
        'active': active,
        'progress_ratio': progress,
        'progress_percent': progress * 100,
        'display': {'percentage': percentage},
      },
    },
  };

  for (final mornye in [false, true]) {
    testWidgets('support row updates cached progress after refresh ($mornye)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'app_remote_config_cached_json': jsonEncode(goalConfig()),
      });
      final response = Completer<http.Response>();
      final service = AppRemoteConfigService(
        client: MockClient((_) => response.future),
      );
      await pumpSettings(
        tester,
        service: service,
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
      );
      final support = find.byWidgetPredicate(
        (widget) =>
            widget is SettingsItem && widget.title == 'Support Development',
      );
      final progress = find.descendant(
        of: support,
        matching: find.byType(AppProgressIndicator),
      );
      expect(
        find.descendant(of: support, matching: find.text('9%')),
        findsOneWidget,
      );
      expect(tester.widget<AppProgressIndicator>(progress).value, 0.09);

      response.complete(
        http.Response(jsonEncode(goalConfig(progress: 0.27)), 200),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: support, matching: find.text('27%')),
        findsOneWidget,
      );
      expect(tester.widget<AppProgressIndicator>(progress).value, 0.27);
      expect(find.text('9%'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final active in [false, true]) {
    testWidgets('support row respects active and percentage flags ($active)', (
      tester,
    ) async {
      final service = AppRemoteConfigService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(goalConfig(active: active, percentage: false)),
            200,
          ),
        ),
      );
      await pumpSettings(tester, service: service);
      expect(find.text('9%'), findsNothing);
      expect(
        find.byType(AppProgressIndicator),
        active ? findsOneWidget : findsNothing,
      );
    });
  }

  testWidgets('finds controls nested inside a settings page', (tester) async {
    await pumpSettings(tester);

    await tester.enterText(find.byType(TextField), 'parallel downloads');
    await tester.pump();

    expect(find.text('Concurrent downloads'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(
      find.text('No settings found for "parallel downloads"'),
      findsNothing,
    );
  });

  for (final mornye in [false, true]) {
    testWidgets('broad search builds only visible grouped results ($mornye)', (
      tester,
    ) async {
      await pumpSettings(
        tester,
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
      );
      await tester.enterText(find.byType(TextField), 'a');
      await tester.pump();
      final group = tester.widget<SliverSettingsGroup>(
        find.byType(SliverSettingsGroup),
      );
      expect(group.itemCount, greaterThan(30));
      final rows = find.descendant(
        of: find.byType(SliverSettingsGroup),
        matching: find.byType(SettingsItem),
      );
      expect(rows.evaluate().length, lessThan(group.itemCount ~/ 2));
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('network protocols are discoverable from Settings', (
    tester,
  ) async {
    await pumpSettings(tester);
    for (final query in ['SMB', 'WebDAV', 'NAS']) {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump();
      expect(find.text('Network storage'), findsOneWidget);
    }
  });

  testWidgets(
    'returning from a search result does not restore keyboard focus',
    (tester) async {
      await pumpSettings(tester);

      final searchField = find.byType(TextField);
      await tester.tap(searchField);
      await tester.enterText(searchField, 'build number');
      await tester.pump();

      final focusedField = tester.widget<TextField>(searchField);
      expect(focusedField.focusNode?.hasFocus, isTrue);
      expect(find.text('Version'), findsOneWidget);

      await tester.tap(find.text('Version'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutPage), findsOneWidget);

      await pageBack(tester);
      await tester.pumpAndSettle();

      final restoredField = tester.widget<TextField>(find.byType(TextField));
      expect(restoredField.focusNode?.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.text('Version'), findsOneWidget);
    },
  );

  testWidgets('search target scrolls into view with standard selected color', (
    tester,
  ) async {
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: SettingsSearchHighlightScope(
          targetLabel: 'Target setting',
          child: Scaffold(
            body: CustomScrollView(
              controller: scrollController,
              slivers: const [
                SliverToBoxAdapter(child: SizedBox(height: 1200)),
                SliverToBoxAdapter(
                  child: SettingsItem(title: 'Target setting'),
                ),
                SliverToBoxAdapter(child: SizedBox(height: 600)),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(scrollController.offset, greaterThan(0));
    final highlightFinder = find.byKey(
      const ValueKey('settings-highlight:Target setting'),
    );
    final highlighted = tester.widget<AnimatedContainer>(highlightFinder);
    final highlightedDecoration = highlighted.decoration! as BoxDecoration;
    final colorScheme = Theme.of(tester.element(highlightFinder)).colorScheme;
    expect(
      highlightedDecoration.color,
      colorScheme.primaryContainer.withValues(alpha: 0.3),
    );
    expect(highlightedDecoration.border, isNull);
    expect(highlightedDecoration.boxShadow, isNull);

    await tester.pump(const Duration(milliseconds: 1900));
    await tester.pump(const Duration(milliseconds: 400));
    final faded = tester.widget<AnimatedContainer>(highlightFinder);
    final fadedDecoration = faded.decoration! as BoxDecoration;
    expect(fadedDecoration.color, Colors.transparent);
  });
}
