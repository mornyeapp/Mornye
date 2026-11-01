import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/settings/cache_management_page.dart';
import 'package:mornye/services/explore_cache_store.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/settings_group.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

Future<void> _write(String path, int bytes) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(List.filled(bytes, 0));
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cache_page_test');
    final dirs = {
      'getApplicationCacheDirectory': '${root.path}/cache',
      'getTemporaryDirectory': '${root.path}/tmp',
      'getApplicationSupportDirectory': '${root.path}/support',
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _pathProvider,
          (call) async => dirs[call.method],
        );
    SharedPreferences.setMockInitialValues({});
    await _write('${root.path}/cache/a.bin', 1000);
    await _write('${root.path}/cache/nested/b.bin', 500);
    await _write('${root.path}/tmp/c.bin', 2048);
    await _write('${root.path}/support/audio_analysis_cache/d.bin', 300);
    await _write('${root.path}/support/motion_artwork/e.mp4', 4096);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await root.delete(recursive: true);
  });

  for (final mornye in [false, true]) {
    testWidgets('cache rows show sizes and confirm before clearing '
        '(Mornye: $mornye)', (tester) async {
      tester.view.physicalSize = const Size(430, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const CacheManagementPage(),
            ),
          ),
        );
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
          if (find.byType(SettingsItem).evaluate().isNotEmpty) break;
        }
      });
      await tester.pump();

      final l10n = tester.element(find.byType(CacheManagementPage)).l10n;
      String sized(int bytes, int files) =>
          l10n.cacheSizeWithFiles(formatBytes(bytes), files);
      final rows = tester
          .widgetList<SettingsItem>(find.byType(SettingsItem))
          .toList();
      expect(
        [
          for (final row in rows)
            (row.icon, row.title, row.subtitle, row.showDivider),
        ],
        [
          (
            Icons.folder_outlined,
            l10n.cacheAppDirectory,
            '${l10n.cacheAppDirectoryDesc}\n${sized(1500, 2)}',
            true,
          ),
          (
            Icons.timer_outlined,
            l10n.cacheTempDirectory,
            '${l10n.cacheTempDirectoryDesc}\n${sized(2048, 1)}',
            true,
          ),
          (
            Icons.image_outlined,
            l10n.cacheCoverImage,
            '${l10n.cacheCoverImageDesc}\n${l10n.cacheNoData}',
            true,
          ),
          (
            Icons.library_music_outlined,
            l10n.cacheLibraryCover,
            '${l10n.cacheLibraryCoverDesc}\n${l10n.cacheNoData}',
            true,
          ),
          (
            Icons.graphic_eq_outlined,
            l10n.cacheAudioAnalysis,
            '${l10n.cacheAudioAnalysisDesc}\n${sized(300, 1)}',
            true,
          ),
          (
            Icons.video_library_outlined,
            l10n.cacheMotionArtwork,
            '${l10n.cacheMotionArtworkDesc}\n${formatBytes(4096)}',
            true,
          ),
          (
            Icons.explore_outlined,
            l10n.cacheExploreFeed,
            '${l10n.cacheExploreFeedDesc}\n${l10n.cacheNoData}',
            true,
          ),
          (
            Icons.memory_outlined,
            l10n.cacheTrackLookup,
            '${l10n.cacheTrackLookupDesc}\n${l10n.cacheNoData}',
            false,
          ),
          (
            Icons.cleaning_services_outlined,
            l10n.cacheCleanupUnused,
            '${l10n.cacheCleanupUnusedDesc}\n'
                '${l10n.cacheCleanupUnusedSubtitle}',
            false,
          ),
        ],
      );
      for (final row in rows) {
        expect(row.trailing, isA<ExpressiveButton>(), reason: row.title);
      }

      // A row's clear button names that cache in the confirm dialog, and
      // cancelling clears nothing.
      final coverRow = find.byWidget(rows[2]);
      await tester.tap(
        find.descendant(of: coverRow, matching: find.byType(ExpressiveButton)),
      );
      await tester.pumpAndSettle();
      final dialog = tester.widget<AppAlertDialog>(find.byType(AppAlertDialog));
      expect((dialog.title! as Text).data, l10n.cacheClearConfirmTitle);
      expect(
        (dialog.content! as Text).data,
        l10n.cacheClearConfirmMessage(l10n.cacheCoverImage),
      );
      await tester.tap(find.text(l10n.dialogCancel));
      await tester.pumpAndSettle();
      expect(find.byType(AppAlertDialog), findsNothing);
      expect(File('${root.path}/cache/a.bin').existsSync(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('unrelated_setting', true);
      await tester.runAsync(
        () => ExploreCacheStore(prefs).write('{"sections":[]}'),
      );
      final exploreFile = File(
        '${root.path}/support/preference_blobs/explore_feed.json',
      );
      final bytes = await tester.runAsync(exploreFile.length);
      SettingsItem? exploreRow() => tester
          .widgetList<SettingsItem>(find.byType(SettingsItem))
          .where((row) => row.title == l10n.cacheExploreFeed)
          .firstOrNull;
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip(l10n.cacheRefresh));
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
          if (exploreRow()?.subtitle?.contains(
                l10n.cacheSizeOnly(formatBytes(bytes!)),
              ) ==
              true) {
            break;
          }
        }
      });
      expect(
        exploreRow()?.subtitle,
        contains(l10n.cacheSizeOnly(formatBytes(bytes!))),
      );
      await tester.tap(
        find.descendant(
          of: find.byWidget(exploreRow()!),
          matching: find.byType(ExpressiveButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text(l10n.dialogClear).hitTestable());
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
          if (!await exploreFile.exists() &&
              exploreRow()?.subtitle?.contains(l10n.cacheNoData) == true) {
            break;
          }
        }
      });
      await tester.pumpAndSettle();
      expect(await tester.runAsync(exploreFile.exists), isFalse);
      expect(prefs.getBool('unrelated_setting'), isTrue);
      expect(prefs.containsKey('explore_home_feed_cache'), isFalse);
      expect(exploreRow()?.subtitle, contains(l10n.cacheNoData));
      expect(tester.takeException(), isNull);
    });
  }
}
