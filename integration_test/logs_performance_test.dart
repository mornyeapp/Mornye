import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/app_crash_provider.dart';
import 'package:mornye/screens/settings/log_screen.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:path_provider/path_provider.dart';

import 'performance_probe.dart';

void main() {
  final binding = PerformanceTestBinding.ensureInitialized();
  for (final mornye in [false, true]) {
    final style = mornye ? 'mornye' : 'material';
    testWidgets('$style production logs scrolling, burst and idle', (
      tester,
    ) async {
      final probe = PerformanceProbe(binding, tester, suite: '${style}_logs');
      final buffer = LogBuffer();
      var sequence = 0;
      LogEntry entry() {
        final index = sequence++;
        return LogEntry(
          timestamp: DateTime(2026, 11, 1).add(Duration(milliseconds: index)),
          level: 'ERROR',
          tag: 'Fixture',
          message: index.isEven
              ? 'Synthetic diagnostic entry $index'
              : 'Synthetic diagnostic entry $index\nSecond line\nThird line',
        );
      }

      // Fill the bounded in-memory buffer; no app startup, database, stored
      // crash reports, log export or real native log polling is involved.
      buffer.addAll(List.generate(LogBuffer.maxEntries, (_) => entry()));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [latestAppCrashProvider.overrideWith((ref) async => null)],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LogScreen(),
          ),
        ),
      );
      // benchmarkLive ignores pumped frames. Wait for the real engine frame
      // that mounts and lays out the page before reading its controller.
      await tester.runAsync(() async {
        binding.scheduleFrame();
        await binding.endOfFrame.timeout(const Duration(seconds: 10));
        await probe.wait(const Duration(milliseconds: 500));
        // A fresh isolated macOS bundle has no cache directory yet.
        await (await getTemporaryDirectory()).create(recursive: true);
      });
      buffer.stopNativeLogPolling();
      final scroll = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      final controller = scroll.controller!;
      final rows = find.descendant(
        of: find.byType(SliverSettingsGroup),
        matching: find.byType(InkWell),
      );
      final initialMountedRows = rows.evaluate().length;
      expect(initialMountedRows, lessThan(40));

      await probe.measure('scroll_500_multiline_logs', () async {
        await probe.scroll(controller, distance: 6000);
        await probe.scroll(controller, distance: -6000);
      }, repetitions: 2);
      await probe.measure(
        'burst_200_individual_logs_with_auto_scroll',
        () async {
          for (var index = 0; index < 200; index++) {
            buffer.add(entry());
          }
          await probe.wait(const Duration(milliseconds: 1500));
        },
        repetitions: 2,
      );
      expect(controller.position.extentAfter, lessThan(1));
      await probe.measure(
        'logs_idle',
        () => probe.wait(const Duration(milliseconds: 1500)),
        repetitions: 2,
        allowIdle: true,
      );
      expect(rows.evaluate().length, lessThan(40));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        binding.scheduleFrame();
        await binding.endOfFrame.timeout(const Duration(seconds: 10));
      });
      await probe.finish(
        metadata: {
          'style': style,
          'buffered_entries': buffer.length,
          'initial_mounted_rows': initialMountedRows,
          'scope':
              'Production LogScreen with 500 synthetic in-memory multiline logs, '
              'native polling stopped, crash provider overridden; no stored user data.',
        },
      );
    });
  }
}
