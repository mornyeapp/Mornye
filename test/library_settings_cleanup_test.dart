import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/library_settings_page.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/fixed_settings.dart';

class _Library extends LocalLibraryNotifier {
  _Library(this._initial, this._cleanup);

  final LocalLibraryState _initial;
  final Future<int> Function() _cleanup;

  @override
  LocalLibraryState build() => _initial;

  @override
  Future<int> cleanupMissingFiles({String? iosBookmark}) => _cleanup();

  void _beginScan() => state = state.copyWith(isScanning: true);
}

class _History extends DownloadHistoryNotifier {
  _History(this._count, this._cleanup, {this.findMoved});

  final int _count;
  final Future<int> Function() _cleanup;
  final Future<({int relinked, int missing})> Function()? findMoved;

  @override
  DownloadHistoryState build() => DownloadHistoryState(totalCount: _count);

  @override
  Future<int> cleanupOrphanedDownloads() => _cleanup();

  @override
  Future<({int relinked, int missing})> findMovedDownloads() =>
      findMoved?.call() ?? Future.value((relinked: 0, missing: 0));
}

class _RetryLibrary extends _Library {
  _RetryLibrary()
    : super(
        LocalLibraryState(
          loadFailed: true,
          sources: const [
            LocalLibrarySource(
              id: 'sd-card',
              path: 'content://storage/tree/sd-card',
              displayName: 'Saved music',
              available: false,
            ),
          ],
        ),
        () async => 0,
      );

  int _reloadCalls = 0;

  @override
  Future<void> reloadFromStorage() async {
    _reloadCalls++;
    state = state.copyWith(loadFailed: false, totalCount: 5);
  }
}

Finder get _cleanupRow => find.byWidgetPredicate(
  (widget) => widget is SettingsItem && widget.title == 'Cleanup Missing Files',
);

Finder get _findMovedRow => find.byWidgetPredicate(
  (widget) => widget is SettingsItem && widget.title == 'Find Moved Downloads',
);

Future<void> _mount(
  WidgetTester tester, {
  required bool mornye,
  required _Library library,
  required _History history,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(430, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(
            const AppSettings(localLibraryEnabled: true),
          ),
        ),
        localLibraryProvider.overrideWith(() => library),
        downloadHistoryProvider.overrideWith(() => history),
      ],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LibrarySettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text('Cleanup Missing Files'), 300);
  await tester.pumpAndSettle();
}

void main() {
  for (final mornye in [false, true]) {
    testWidgets('source shows the scan failure reason (Mornye: $mornye)', (
      tester,
    ) async {
      const error =
          'The previous library scan was interrupted. Scan again to continue.';
      final library = _Library(
        LocalLibraryState(
          totalCount: 1877,
          sources: const [
            LocalLibrarySource(
              id: 'music',
              path: '/music',
              displayName: 'Saved music',
              trackCount: 1877,
              lastScanError: error,
            ),
          ],
        ),
        () async => 0,
      );
      await _mount(
        tester,
        mornye: mornye,
        library: library,
        history: _History(0, () async => 0),
      );
      // The folder rows sit above the actions the setup scrolled to.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Saved music'), 200);
      await tester.pumpAndSettle();
      expect(find.textContaining(error), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('failed load shows saved folder and offers retry ($mornye)', (
      tester,
    ) async {
      final library = _RetryLibrary();
      await _mount(
        tester,
        mornye: mornye,
        library: library,
        history: _History(0, () async => 0),
      );
      await tester.scrollUntilVisible(find.text('Retry'), -300);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Library could not be loaded'),
        findsOneWidget,
      );
      expect(find.text('Saved music'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(library._reloadCalls, 1);
      expect(find.textContaining('Library could not be loaded'), findsNothing);
      expect(find.text('Saved music'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cleanup works for download-only Library ($mornye)', (
      tester,
    ) async {
      final localDone = Completer<int>();
      final downloadsDone = Completer<int>();
      var localCalls = 0;
      var downloadCalls = 0;
      await _mount(
        tester,
        mornye: mornye,
        library: _Library(LocalLibraryState(), () {
          localCalls++;
          return localDone.future;
        }),
        history: _History(8, () {
          downloadCalls++;
          return downloadsDone.future;
        }),
      );
      expect(tester.widget<SettingsItem>(_cleanupRow).onTap, isNotNull);
      await tester.tap(find.text('Cleanup Missing Files'));
      await tester.pump();
      expect(localCalls, 1);
      expect(tester.widget<SettingsItem>(_cleanupRow).onTap, isNull);
      expect(
        find.descendant(
          of: _cleanupRow,
          matching: find.byType(AppLoadingIndicator),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cleanup Missing Files'));
      await tester.pump();
      expect(localCalls, 1);
      localDone.complete(0);
      await tester.pump();
      expect(downloadCalls, 1);
      downloadsDone.complete(2);
      await tester.pumpAndSettle();
      expect(find.text('Removed 2 missing files from library'), findsOneWidget);
      expect(tester.widget<SettingsItem>(_cleanupRow).onTap, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cleanup reports errors and can retry ($mornye)', (
      tester,
    ) async {
      var calls = 0;
      var downloadCalls = 0;
      await _mount(
        tester,
        mornye: mornye,
        library: _Library(LocalLibraryState(totalCount: 1), () async {
          calls++;
          if (calls == 1) throw StateError('cleanup failed');
          return 1;
        }),
        history: _History(1, () async {
          downloadCalls++;
          return 2;
        }),
      );
      await tester.tap(find.text('Cleanup Missing Files'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Error:'), findsOneWidget);
      expect(downloadCalls, 0);
      expect(tester.widget<SettingsItem>(_cleanupRow).onTap, isNotNull);
      await tester.tap(find.text('Cleanup Missing Files'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Removed 3 missing files from library'), findsOneWidget);
      expect(calls, 2);
      expect(downloadCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Find Moved Downloads relinks without removing ($mornye)', (
      tester,
    ) async {
      final done = Completer<({int relinked, int missing})>();
      var findCalls = 0;
      var cleanupCalls = 0;
      await _mount(
        tester,
        mornye: mornye,
        library: _Library(LocalLibraryState(), () async {
          cleanupCalls++;
          return 0;
        }),
        history: _History(
          3,
          () async {
            cleanupCalls++;
            return 0;
          },
          findMoved: () {
            findCalls++;
            return done.future;
          },
        ),
      );
      await tester.ensureVisible(find.text('Find Moved Downloads'));
      await tester.pumpAndSettle();
      expect(tester.widget<SettingsItem>(_findMovedRow).onTap, isNotNull);
      await tester.tap(find.text('Find Moved Downloads'));
      await tester.pump();
      expect(findCalls, 1);
      expect(
        find.descendant(
          of: _findMovedRow,
          matching: find.byType(AppLoadingIndicator),
        ),
        findsOneWidget,
      );
      // Neither action can start while the other runs.
      expect(tester.widget<SettingsItem>(_findMovedRow).onTap, isNull);
      expect(tester.widget<SettingsItem>(_cleanupRow).onTap, isNull);

      done.complete((relinked: 2, missing: 1));
      await tester.pumpAndSettle();
      expect(
        find.text('Relinked 2 downloads · 1 file still missing'),
        findsOneWidget,
      );
      expect(cleanupCalls, 0);
      expect(tester.widget<SettingsItem>(_findMovedRow).onTap, isNotNull);
      expect(tester.widget<SettingsItem>(_cleanupRow).onTap, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Find Moved Downloads reports errors ($mornye)', (
      tester,
    ) async {
      await _mount(
        tester,
        mornye: mornye,
        library: _Library(LocalLibraryState(), () async => 0),
        history: _History(
          1,
          () async => 0,
          findMoved: () async => throw StateError('folder unavailable'),
        ),
      );
      await tester.ensureVisible(find.text('Find Moved Downloads'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find Moved Downloads'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Error:'), findsOneWidget);
      expect(tester.widget<SettingsItem>(_findMovedRow).onTap, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Find Moved Downloads needs downloads ($mornye)', (
      tester,
    ) async {
      await _mount(
        tester,
        mornye: mornye,
        library: _Library(LocalLibraryState(totalCount: 4), () async => 0),
        history: _History(0, () async => 0),
      );
      await tester.ensureVisible(find.text('Find Moved Downloads'));
      await tester.pumpAndSettle();
      expect(tester.widget<SettingsItem>(_findMovedRow).onTap, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cleanup stays available for hidden source rows ($mornye)', (
      tester,
    ) async {
      await _mount(
        tester,
        mornye: mornye,
        library: _Library(
          LocalLibraryState(
            sources: const [
              LocalLibrarySource(
                id: 'sd-card',
                path: 'content://storage/tree/sd-card',
                displayName: 'Music',
                available: false,
                trackCount: 5,
                isRemovable: true,
              ),
            ],
          ),
          () async => 0,
        ),
        history: _History(0, () async => 0),
      );
      expect(tester.widget<SettingsItem>(_cleanupRow).onTap, isNotNull);
      await tester.tap(find.text('Cleanup Missing Files'));
      await tester.pumpAndSettle();
      expect(find.text('Removed 0 missing files from library'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cleanup cannot race an active scan ($mornye)', (tester) async {
      var localCalls = 0;
      var downloadCalls = 0;
      final library = _Library(LocalLibraryState(totalCount: 1), () async {
        localCalls++;
        return 0;
      });
      await _mount(
        tester,
        mornye: mornye,
        library: library,
        history: _History(1, () async {
          downloadCalls++;
          return 0;
        }),
      );
      final originalTap = tester.widget<SettingsItem>(_cleanupRow).onTap!;
      library._beginScan();
      await tester.pump();
      expect(tester.widget<SettingsItem>(_cleanupRow).onTap, isNull);
      originalTap();
      await tester.pump();
      expect(localCalls, 0);
      expect(downloadCalls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  test('the Find Moved Downloads result reads naturally', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      l10n.libraryFindMovedDownloadsResult(0, 0),
      'No moved downloads found',
    );
    expect(l10n.libraryFindMovedDownloadsResult(1, 0), 'Relinked 1 download');
    expect(
      l10n.libraryFindMovedDownloadsResult(0, 3),
      'No moved downloads found · 3 files still missing',
    );
    expect(
      l10n.libraryFindMovedDownloadsResult(5, 1),
      'Relinked 5 downloads · 1 file still missing',
    );
  });
}
