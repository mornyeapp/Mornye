import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/settings/log_screen.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/logger.dart';

import 'support/app_icon_finder.dart';

void main() {
  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';
    testWidgets(
      '$style logs build only nearby entries and filter the full buffer',
      (tester) async {
        final buffer = LogBuffer()..clear();
        addTearDown(buffer.clear);
        buffer.addAll([
          for (var index = 0; index < LogBuffer.maxEntries; index++)
            LogEntry(
              timestamp: DateTime(2026),
              level: 'ERROR',
              tag: 'Fixture',
              message: 'fixture log $index',
            ),
        ]);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.light)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const LogScreen(),
            ),
          ),
        );
        await tester.pump();

        final entries = find.byWidgetPredicate(
          (widget) =>
              widget is Text && widget.data?.startsWith('fixture log ') == true,
        );
        expect(entries.evaluate().length, lessThan(30));
        expect(find.text('fixture log 499'), findsNothing);
        final scroll = tester.widget<CustomScrollView>(
          find.byType(CustomScrollView),
        );
        scroll.controller!.jumpTo(scroll.controller!.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(entries, findsWidgets);
        expect(entries.evaluate().length, lessThan(30));
        scroll.controller!.jumpTo(0);
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(EditableText), 'fixture log 499');
        await tester.pumpAndSettle();
        scroll.controller!.jumpTo(scroll.controller!.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(entries, findsOneWidget);
        expect(entries.evaluate().length, 1);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('log bursts follow the final multiline entry in a lazy list', (
    tester,
  ) async {
    final buffer = LogBuffer()..clear();
    addTearDown(buffer.clear);
    buffer.add(
      LogEntry(
        timestamp: DateTime(2026),
        level: 'ERROR',
        tag: 'Fixture',
        message: 'initial entry',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const LogScreen(),
        ),
      ),
    );
    await tester.pump();

    for (var index = 0; index < 100; index++) {
      buffer.add(
        LogEntry(
          timestamp: DateTime(2026),
          level: 'ERROR',
          tag: 'Fixture',
          message: index < 30
              ? 'short $index'
              : 'multiline $index\nsecond\nthird',
        ),
      );
    }
    await tester.pumpAndSettle();
    expect(find.text('multiline 99\nsecond\nthird'), findsOneWidget);
    final scroll = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scroll.controller!.position.extentAfter, lessThan(1));
    expect(tester.takeException(), isNull);

    buffer.add(
      LogEntry(
        timestamp: DateTime(2026),
        level: 'ERROR',
        tag: 'Fixture',
        message: 'queued before disposal',
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test(
    'native log batches notify once and preserve redaction and capacity',
    () {
      final buffer = LogBuffer()..clear();
      var updates = 0;
      void listener() => updates++;
      buffer.addListener(listener);
      addTearDown(() {
        buffer.removeListener(listener);
        buffer.clear();
      });
      buffer.addAll([
        for (var index = 0; index < 600; index++)
          LogEntry(
            timestamp: DateTime(2026),
            level: 'ERROR',
            tag: 'Native',
            message: '$index -decryption_key secret-value',
          ),
      ]);
      expect(updates, 1);
      expect(buffer.length, LogBuffer.maxEntries);
      expect(buffer.entries.first.message, startsWith('100 '));
      expect(buffer.entries.last.message, startsWith('599 '));
      expect(formatLogEntries(buffer.entries), isNot(contains('secret-value')));
      buffer.addAll(const []);
      expect(updates, 1);
    },
  );

  test('selected log export keeps chronological lines only', () {
    final entries = [
      LogEntry(
        timestamp: DateTime(2026, 8, 11, 10, 20, 30, 40),
        level: 'INFO',
        tag: 'Search',
        message: 'first',
      ),
      LogEntry(
        timestamp: DateTime(2026, 8, 11, 10, 20, 31, 50),
        level: 'ERROR',
        tag: 'Download',
        message: 'second',
        error: 'failed',
        isFromNative: true,
      ),
    ];

    expect(
      formatLogEntries(entries),
      '[10:20:30.040] [INFO] [Search] first\n'
      '[10:20:31.050] [ERROR] [Native] [Download] second | failed',
    );
  });

  test('log buffer redacts media keys and bounds exported payloads', () {
    final buffer = LogBuffer()..clear();
    addTearDown(buffer.clear);
    buffer.add(
      LogEntry(
        timestamp: DateTime(2026, 8, 31),
        level: 'ERROR',
        tag: 'FFmpeg',
        message:
            '-decryption_key raw-media-key ${List.filled(5000, 'x').join()}',
      ),
    );

    final stored = buffer.entries.single.message;
    expect(stored, isNot(contains('raw-media-key')));
    expect(stored, contains('[REDACTED]'));
    expect(stored, endsWith('...[truncated]'));
    expect(stored.length, lessThan(4100));
  });

  testWidgets('long press selects multiple log rows for copying', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map<Object?, Object?>)['text']
              ?.toString();
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    LogBuffer().clear();
    addTearDown(LogBuffer().clear);
    LogBuffer().add(
      LogEntry(
        timestamp: DateTime(2026, 8, 11, 10),
        level: 'ERROR',
        tag: 'One',
        message: 'first selected message',
      ),
    );
    LogBuffer().add(
      LogEntry(
        timestamp: DateTime(2026, 8, 11, 10, 0, 1),
        level: 'ERROR',
        tag: 'Two',
        message: 'second selected message',
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const LogScreen(),
        ),
      ),
    );

    await tester.longPress(find.text('first selected message'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.ensureVisible(find.text('second selected message'));
    await tester.pump();
    await tester.tap(find.text('second selected message'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(findAppIcon(Icons.copy));
    await tester.pump();

    expect(clipboardText, contains('first selected message'));
    expect(clipboardText, contains('second selected message'));
    expect(find.text('2 selected'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
