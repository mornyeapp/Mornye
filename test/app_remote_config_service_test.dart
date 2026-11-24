import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/settings/donate_page.dart';
import 'package:mornye/services/app_remote_config_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';

class _TrackedClient extends MockClient {
  _TrackedClient(super.handler);

  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('default request closes its client on success and failure', () async {
    for (final fail in [false, true]) {
      final client = _TrackedClient((_) async {
        if (fail) throw StateError('network unavailable');
        return http.Response('{}', 200);
      });
      final snapshot = await http.runWithClient(
        () => AppRemoteConfigService().fetchConfigSnapshot(),
        () => client,
      );
      expect(snapshot, fail ? isNull : isNotNull);
      expect(client.closed, isTrue);
    }
  });

  test('injected client remains owned by its caller', () async {
    final client = _TrackedClient((_) async => http.Response('{}', 200));
    final service = AppRemoteConfigService(client: client);
    expect(await service.fetchConfigSnapshot(), isNotNull);
    expect(client.closed, isFalse);
    expect(await service.fetchConfigSnapshot(), isNotNull);
    client.close();
  });

  test(
    'parses monthly donation progress and display settings from the API',
    () {
      final config = DonateConfig.fromJson({
        'monthly_goal': _monthlyGoalPayload(),
      });
      final goal = config.monthlyGoal!;
      expect(goal.isVisible, isTrue);
      expect(goal.period, '2026-10');
      expect(goal.progressPercent, 9);
      expect(goal.progressRatio, 0.09);
      expect(goal.supporterCount, 14);
      expect(goal.showPercentage, isTrue);
      expect(goal.showSupporterCount, isTrue);
      expect(goal.showAmounts, isFalse);
      expect(goal.showSourceBreakdown, isFalse);
      expect(goal.sources['kofi']?.amount, 80);
      expect(DonateConfig.fallback().monthlyGoal, isNull);
      expect(DonateConfig.fromJson({}).monthlyGoal, isNull);
    },
  );

  test('bounds progress without losing an overfunded percentage', () {
    final goal = MonthlyDonationGoal.fromJson({
      ..._monthlyGoalPayload(),
      'progress_percent': '125.5',
      'progress_ratio': 1.255,
      'goal_reached': true,
    });
    expect(goal.progressPercent, 125.5);
    expect(goal.progressRatio, 1);
    expect(goal.goalReached, isTrue);
    final invalid = MonthlyDonationGoal.fromJson({
      'progress_percent': 'NaN',
      'progress_ratio': double.infinity,
      'supporter_count': -4,
      'display': 'invalid',
    });
    expect(invalid.progressPercent, 0);
    expect(invalid.progressRatio, 0);
    expect(invalid.supporterCount, 0);
    expect(invalid.isVisible, isFalse);
  });

  for (final brightness in Brightness.values) {
    testWidgets('monthly goal shows progress without counts in $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = AppRemoteConfigService(
        client: MockClient((request) async {
          expect(request.headers['Accept'], 'application/json');
          expect(request.headers['User-Agent'], startsWith('Mornye/'));
          return http.Response(
            jsonEncode({
              'donate': {'monthly_goal': _monthlyGoalPayload()},
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: MornyeTheme.build(brightness),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('id'),
          home: DonatePage(remoteConfigService: service),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Monthly development goal'), findsOneWidget);
      expect(find.text('Oktober 2026'), findsOneWidget);
      expect(find.text('9%'), findsOneWidget);
      expect(find.text('14 supporters'), findsNothing);
      expect(
        tester
            .widget<AppProgressIndicator>(find.byType(AppProgressIndicator))
            .value,
        0.09,
      );
      expect(find.textContaining('90,00'), findsNothing);
      expect(find.text('Ko-fi · 12 supporters'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final flag in ['enabled', 'active']) {
    testWidgets('monthly goal is hidden when $flag is false', (tester) async {
      final service = AppRemoteConfigService(
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'donate': {
                'monthly_goal': {..._monthlyGoalPayload(), flag: false},
              },
            }),
            200,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: DonatePage(remoteConfigService: service)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Monthly development goal'), findsNothing);
      expect(find.byType(AppProgressIndicator), findsNothing);
    });
  }

  testWidgets(
    'display flags control optional goal details and reached status',
    (tester) async {
      final service = AppRemoteConfigService(
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'donate': {
                'monthly_goal': {
                  ..._monthlyGoalPayload(),
                  'goal_reached': true,
                  'progress_ratio': 1.2,
                  'display': {
                    'amounts': true,
                    'percentage': false,
                    'supporter_count': true,
                    'source_breakdown': true,
                  },
                },
              },
            }),
            200,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: DonatePage(remoteConfigService: service)),
      );
      await tester.pumpAndSettle();
      expect(find.text(r'$90.00 / $1,000.00'), findsOneWidget);
      expect(find.text(r'Ko-fi · $80.00'), findsOneWidget);
      expect(find.text('Goal reached'), findsOneWidget);
      expect(find.text('9%'), findsNothing);
      expect(find.text('14 supporters'), findsNothing);
      expect(
        tester
            .widget<AppProgressIndicator>(find.byType(AppProgressIndicator))
            .value,
        1,
      );
    },
  );

  test(
    'refreshes remote config despite a legacy recent-fetch timestamp',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_remote_config_cached_json': jsonEncode(
          _configPayload(
            announcementId: 'cached-announcement',
            donateTitle: 'Cached donation',
          ),
        ),
        'app_remote_config_last_fetch_at': DateTime.now().toIso8601String(),
      });

      var requestCount = 0;
      final service = AppRemoteConfigService(
        endpoint: 'https://example.test/config',
        client: MockClient((request) async {
          requestCount++;
          return http.Response(
            jsonEncode(
              _configPayload(
                announcementId: 'fresh-announcement',
                donateTitle: 'Fresh donation',
              ),
            ),
            200,
          );
        }),
      );

      final snapshot = await service.fetchConfigSnapshot(locale: 'en-US');

      expect(requestCount, 1);
      expect(snapshot?.changed, isTrue);
      expect(snapshot?.config.announcement?.id, 'fresh-announcement');
      expect(snapshot?.config.donate.title, 'Fresh donation');
    },
  );

  test('checks the endpoint again for each remote config request', () async {
    var requestCount = 0;
    final service = AppRemoteConfigService(
      endpoint: 'https://example.test/config',
      client: MockClient((request) async {
        requestCount++;
        return http.Response(
          jsonEncode(
            _configPayload(
              announcementId: 'announcement-$requestCount',
              donateTitle: 'Donation $requestCount',
            ),
          ),
          200,
        );
      }),
    );

    final first = await service.fetchConfigSnapshot(locale: 'en-US');
    final second = await service.fetchConfigSnapshot(locale: 'en-US');

    expect(requestCount, 2);
    expect(first?.config.announcement?.id, 'announcement-1');
    expect(second?.config.announcement?.id, 'announcement-2');
  });

  testWidgets('donate page applies a refreshed config without reopening', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'app_remote_config_cached_json': jsonEncode(
        _configPayload(
          announcementId: 'cached-announcement',
          donateTitle: 'Cached donation',
          monthlyGoal: _monthlyGoalPayload(),
        ),
      ),
    });

    final response = Completer<http.Response>();
    final service = AppRemoteConfigService(
      endpoint: 'https://example.test/config',
      client: MockClient((request) => response.future),
    );

    await tester.pumpWidget(
      MaterialApp(home: DonatePage(remoteConfigService: service)),
    );
    await tester.pump();

    expect(find.text('Cached donation'), findsOneWidget);
    expect(find.text('9%'), findsOneWidget);

    response.complete(
      http.Response(
        jsonEncode(
          _configPayload(
            announcementId: 'fresh-announcement',
            donateTitle: 'Fresh donation',
            monthlyGoal: {
              ..._monthlyGoalPayload(),
              'progress_ratio': 0.27,
              'progress_percent': 27,
            },
          ),
        ),
        200,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cached donation'), findsNothing);
    expect(find.text('Fresh donation'), findsOneWidget);
    expect(find.text('9%'), findsNothing);
    expect(find.text('27%'), findsOneWidget);
  });
}

Map<String, Object?> _configPayload({
  required String announcementId,
  required String donateTitle,
  Map<String, Object?>? monthlyGoal,
}) {
  return {
    'announcement': {
      'id': announcementId,
      'enabled': true,
      'title': 'Announcement',
      'message': 'Announcement message',
    },
    'donate': {
      'enabled': true,
      'title': donateTitle,
      'message': 'Donation message',
      'methods': [
        {
          'id': 'support',
          'title': 'Support',
          'subtitle': 'Support this project',
          'url': 'https://example.test/support',
        },
      ],
      'supporters': <String>[],
      'notices': ['Donation notice'],
      'monthly_goal': ?monthlyGoal,
    },
  };
}

Map<String, Object?> _monthlyGoalPayload() => {
  'enabled': true,
  'active': true,
  'period': '2026-10',
  'title': 'Monthly development goal',
  'description': 'Support ongoing development and hosting.',
  'progress_percent': 9,
  'progress_ratio': 0.09,
  'goal_reached': false,
  'display': {
    'amounts': false,
    'percentage': true,
    'supporter_count': true,
    'source_breakdown': false,
  },
  'currency': 'USD',
  'raised_amount': 90,
  'target_amount': 1000,
  'supporter_count': 14,
  'sources': {
    'kofi': {'amount': 80, 'supporter_count': 12},
    'patreon': {'amount': 10, 'supporter_count': 2},
  },
};
