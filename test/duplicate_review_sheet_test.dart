import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/duplicate_review_sheet.dart';

import 'support/fixed_settings.dart';

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
    testWidgets('duplicate query can retry on $platform', (tester) async {
      debugDesktopPlatformOverride = true;
      addTearDown(() => debugDesktopPlatformOverride = null);
      final previousDebugPrint = debugPrint;
      final logs = <String>[];
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = previousDebugPrint);
      var attempts = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            localLibraryProvider.overrideWith(_Library.new),
            duplicateReviewGroupsLoaderProvider.overrideWithValue(() async {
              if (++attempts == 1) throw StateError('Duplicate query failed');
              return _groups(platform);
            }),
          ],
          child: MaterialApp(
            theme: AppTheme.dark().copyWith(platform: platform),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: DuplicateReviewSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No duplicate tracks found.'), findsNothing);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(
        logs.any((line) => line.contains('Could not load duplicate copies')),
        isTrue,
      );
      expect(find.text('Track 0').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugPrint = previousDebugPrint;
    });

    for (final mornye in [false, true]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'duplicate rows with percent paths render on $platform ($mornye, $brightness)',
          (tester) async {
            debugDesktopPlatformOverride = true;
            addTearDown(() => debugDesktopPlatformOverride = null);
            tester.view.physicalSize = const Size(1280, 720);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final theme = mornye
                ? MornyeTheme.build(brightness)
                : brightness == Brightness.dark
                ? AppTheme.dark()
                : AppTheme.light();
            final count = brightness == Brightness.dark ? 10 : 24;
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  settingsProvider.overrideWith(FixedSettingsNotifier.new),
                  localLibraryProvider.overrideWith(_Library.new),
                  duplicateReviewGroupsLoaderProvider.overrideWithValue(
                    () async => _groups(platform, count: count),
                  ),
                ],
                child: MaterialApp(
                  theme: theme.copyWith(platform: platform),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: Scaffold(
                    body: Builder(
                      builder: (context) => TextButton(
                        onPressed: () => DuplicateReviewSheet.show(context),
                        child: const Text('Review'),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('Review'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text('Track 0').hitTestable(), findsOneWidget);
            if (count > 12) {
              await tester.scrollUntilVisible(
                find.text('Track ${count - 1}'),
                300,
              );
              await tester.pumpAndSettle();
              expect(
                find.text('Track ${count - 1}').hitTestable(),
                findsOneWidget,
              );
              tester
                  .state<ScrollableState>(find.byType(Scrollable).last)
                  .position
                  .jumpTo(0);
              await tester.pumpAndSettle();
            }
            await tester.tap(find.text('Keep best for all'));
            await tester.pump(const Duration(milliseconds: 400));
            expect(find.textContaining('$count tracks'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.tap(find.text('Cancel'));
            await tester.pumpAndSettle();
            expect(find.text('Track 0').hitTestable(), findsOneWidget);
          },
        );
      }
    }
  }
}

List<IsrcDuplicateGroup> _groups(TargetPlatform platform, {int count = 10}) => [
  for (var group = 0; group < count; group++)
    IsrcDuplicateGroup(
      isrc: 'ISRC$group',
      entries: [
        for (var copy = 0; copy < 2; copy++)
          IsrcDuplicateEntry(
            id: '$group-$copy',
            source: 'local',
            trackName: 'Track $group',
            artistName: 'Artist',
            filePath: platform == TargetPlatform.windows
                ? r'C:\Music\Albums\Artist\100% Hits'
                      '\\$copy\\Track $group.flac'
                : '/music/Albums/Artist/100% Hits/$copy/Track $group.flac',
            bitDepth: 16,
            sampleRate: 44100,
            format: 'flac',
          ),
      ],
    ),
];
