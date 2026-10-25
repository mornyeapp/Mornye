import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/services/autoplay_ranker.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/song_analysis.dart';
import 'package:mornye/services/song_analysis_store.dart';
import 'package:mornye/services/song_features.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  for (final mornye in [false, true]) {
    testWidgets('personalization switch persists and is searchable ($mornye)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(const AppSettings()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark, accent: MornyeAccent.blue)
                : AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const PlaybackSettingsPage(),
          ),
        ),
      );
      final label = find.text('Personalized autoplay');
      await tester.scrollUntilVisible(
        label,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      // On by default; the reset action belongs to the enabled state.
      expect(container.read(settingsProvider).autoplayPersonalization, isTrue);
      expect(find.text('Reset recommendation learning'), findsOneWidget);
      // A stray tap only asks; cancelling keeps what was learned.
      await tester.tap(find.text('Reset recommendation learning'));
      await tester.pumpAndSettle();
      expect(find.text('Reset recommendation learning?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Reset recommendation learning?'), findsNothing);
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).autoplayPersonalization, isFalse);
      expect(container.read(settingsProvider).autoplay, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        AppSettings.fromJson(
          jsonDecode(prefs.getString('app_settings')!) as Map<String, dynamic>,
        ).autoplayPersonalization,
        isFalse,
      );
      expect(find.text('Reset recommendation learning'), findsNothing);
      await tester.ensureVisible(label);
      await tester.pumpAndSettle();
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).autoplayPersonalization, isTrue);
      final l10n = AppLocalizations.of(tester.element(label));
      expect(
        SettingsSearchCatalog(l10n).playback.any(
          (entry) => entry.matches(SettingsSearchQuery('machine learning')),
        ),
        isTrue,
      );
      container.read(settingsProvider.notifier).setPlayerMode('external');
      await tester.pump();
      expect(
        tester
            .widget<SettingsSwitchItem>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is SettingsSwitchItem &&
                    widget.title == 'Personalized autoplay',
              ),
            )
            .enabled,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('reset learning tells how well ranking learned ($mornye)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      sqfliteFfiInit();
      final db = (await tester.runAsync(
        () => AutoplayRanker.openWithFactory(
          databaseFactoryFfi,
          inMemoryDatabasePath,
        ),
      ))!;
      addTearDown(() => tester.runAsync(db.close));
      var evaluation = const AutoplayRankEvaluation(outcomes: 12);
      final ranker = AutoplayRanker(
        open: () async => db,
        train: (_) async =>
            (weights: const <String, double>{}, evaluation: evaluation),
      );
      await tester.runAsync(ranker.train);
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(const AppSettings()),
          musicPlayerRuntimeProvider.overrideWithValue(
            MusicPlayerRuntime(
              dependencies: PlaybackDependencies(createRanker: () => ranker),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark, accent: MornyeAccent.blue)
                : AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const PlaybackSettingsPage(),
          ),
        ),
      );
      final progress = find.text(
        'Ranking tunes to you after 40 Autoplay songs (12 so far)',
      );
      await tester.scrollUntilVisible(
        progress,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(progress, findsOneWidget);

      evaluation = const AutoplayRankEvaluation(
        outcomes: 80,
        tested: 20,
        starting: 0.642,
        learned: 0.71,
      );
      await tester.runAsync(ranker.train);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Tuned to you: 71% accurate on your latest songs '
          '(standard 64%)',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('song analysis shows its progress and clears ($mornye)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = _MemoryStore();
      for (var i = 0; i < 1234; i++) {
        store.rows['/$i.flac'] = const SongAnalysisRecord(
          stamp: (size: 1, modified: 1),
          version: SongFeatures.version,
          failed: false,
        );
      }
      final analysis = SongAnalysis(
        store: store,
        librarySongs: () async => [
          for (var i = 0; i < 5000; i++)
            (path: '/$i.flac', duration: null, local: false),
        ],
        sweep: SongAnalysisSweep.never,
        isAndroid: false,
      );
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(
            const AppSettings(songAnalysis: true),
          ),
          musicPlayerRuntimeProvider.overrideWithValue(
            MusicPlayerRuntime(
              dependencies: PlaybackDependencies(
                createSongAnalysis: (_) => analysis,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark, accent: MornyeAccent.blue)
                : AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const PlaybackSettingsPage(),
          ),
        ),
      );
      final clear = find.text('Clear song analysis');
      await tester.scrollUntilVisible(
        clear,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('1,234 of 5,000 songs analyzed'), findsOneWidget);
      // The charging rule is Android's.
      expect(find.text('Only while charging'), findsNothing);

      final label = find.text('Song analysis');
      await tester.ensureVisible(label);
      await tester.pumpAndSettle();
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).songAnalysis, isFalse);
      // What was analyzed can still be cleared.
      expect(clear, findsOneWidget);
      await tester.ensureVisible(clear);
      await tester.pumpAndSettle();
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(find.text('Clear song analysis?'), findsOneWidget);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(store.rows, isEmpty);
      expect(clear, findsNothing);

      final l10n = AppLocalizations.of(
        tester.element(find.text('Song analysis')),
      );
      expect(
        SettingsSearchCatalog(
          l10n,
        ).playback.any((entry) => entry.matches(SettingsSearchQuery('bpm'))),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

/// Song analysis kept in memory.
class _MemoryStore implements SongAnalysisStore {
  final rows = <String, SongAnalysisRecord>{};

  @override
  int get version => SongFeatures.version;

  @override
  Future<Map<String, Float32List>> features(Iterable<String> paths) async =>
      const {};

  @override
  Future<Map<String, SongAnalysisRecord>> records([
    Iterable<String>? paths,
  ]) async => {
    for (final MapEntry(:key, :value) in rows.entries)
      if (paths == null || paths.contains(key)) key: value,
  };

  @override
  Future<void> save(
    String path,
    SongFileStamp stamp,
    Float32List? features,
  ) async => rows[path] = SongAnalysisRecord(
    stamp: stamp,
    version: version,
    failed: features == null,
  );

  @override
  Future<void> remove(Iterable<String> paths) async =>
      rows.removeWhere((path, _) => paths.contains(path));

  @override
  Future<void> clear() async => rows.clear();
}
