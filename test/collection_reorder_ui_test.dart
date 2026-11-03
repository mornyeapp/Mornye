import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/collection_reorder_sliver.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

final _entries = [
  for (final id in ['a', 'b', 'c'])
    CollectionTrackEntry(
      key: id,
      addedAt: DateTime(2026),
      track: Track(
        id: id,
        name: 'Song $id',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
      ),
    ),
];

class _Collections extends LibraryCollectionsNotifier {
  int _writes = 0;
  bool _failSave = false;

  @override
  LibraryCollectionsState build() => LibraryCollectionsState(
    isLoaded: true,
    loved: _entries,
    wishlist: _entries,
    playlists: [
      UserPlaylistCollection(
        id: 'mix',
        name: 'My mix',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        tracks: _entries,
      ),
    ],
  );

  @override
  Future<void> ensurePlaylistLoaded(String id) async {}

  @override
  Future<bool> reorderPlaylistTracks(String id, List<String> keys) async {
    if (_failSave) throw StateError('Storage unavailable');
    _writes++;
    final playlist = state.playlistById(id)!;
    final byKey = {for (final entry in playlist.tracks) entry.key: entry};
    state = state.copyWith(
      playlists: [
        playlist.copyWith(tracks: [for (final key in keys) byKey[key]!]),
      ],
    );
    return true;
  }

  @override
  Future<bool> reorderSavedTracks(
    LibraryTracksFolderMode mode,
    List<String> keys,
  ) async {
    if (_failSave) throw StateError('Storage unavailable');
    _writes++;
    final byKey = {for (final entry in _entries) entry.key: entry};
    final entries = [for (final key in keys) byKey[key]!];
    state = mode == LibraryTracksFolderMode.loved
        ? state.copyWith(loved: entries)
        : state.copyWith(wishlist: entries);
    return true;
  }
}

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Host extends LinkDesktopHost {
  @override
  LinkDesktopHostState build() => const LinkDesktopHostState();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDesktopPlatformOverride = null);

  Future<_Collections> open(
    WidgetTester tester, {
    bool desktop = false,
    bool mornye = false,
    LibraryTracksFolderMode mode = LibraryTracksFolderMode.loved,
  }) async {
    debugDesktopPlatformOverride = desktop;
    tester.view.physicalSize = desktop
        ? const Size(1200, 900)
        : const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final collections = _Collections();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          libraryCollectionsProvider.overrideWith(() => collections),
          linkDesktopHostProvider.overrideWith(_Host.new),
          localLibraryProvider.overrideWith(_Library.new),
          downloadHistoryProvider.overrideWith(_History.new),
          downloadHistoryVisibleBatchExistsProvider.overrideWith(
            (ref, request) => const {},
          ),
          localLibraryCoverProvider.overrideWith((ref, request) async => null),
          localLibraryFirstCoverProvider.overrideWith(
            (ref, request) async => null,
          ),
        ],
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LibraryTracksFolderScreen(
            mode: mode,
            playlistId: mode == LibraryTracksFolderMode.playlist ? 'mix' : null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('collection-edit-order')));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryTracksFolderScreen), findsOneWidget);
    expect(find.byType(CollectionReorderSliver), findsOneWidget);
    return collections;
  }

  Future<void> moveFirstToLast(
    WidgetTester tester, {
    bool holdRow = false,
    bool desktop = false,
  }) async {
    final handle = find.byKey(const ValueKey('collection-order-handle-a'));
    await tester.ensureVisible(handle);
    await tester.pumpAndSettle();
    final origin = holdRow
        ? tester.getCenter(find.text('Song a'))
        : tester.getCenter(handle);
    final lastBottom = tester.getBottomRight(
      find.byKey(const ValueKey('collection-order-handle-c')),
    );
    final target = Offset(origin.dx, lastBottom.dy + 80);
    final gesture = await tester.startGesture(
      origin,
      kind: desktop ? PointerDeviceKind.mouse : PointerDeviceKind.touch,
    );
    if (holdRow) await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveBy(const Offset(0, 4));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(target);
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CollectionReorderSliver>(find.byType(CollectionReorderSliver))
          .entries
          .map((entry) => entry.key),
      ['b', 'c', 'a'],
    );
  }

  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      for (final mode in LibraryTracksFolderMode.values) {
        testWidgets(
          'reorder ${mode.name} in place (desktop=$desktop, mornye=$mornye)',
          (tester) async {
            final semantics = desktop && !mornye
                ? tester.ensureSemantics()
                : null;
            try {
              final collections = await open(
                tester,
                desktop: desktop,
                mornye: mornye,
                mode: mode,
              );
              await moveFirstToLast(
                tester,
                desktop: desktop,
                holdRow: !desktop,
              );
              expect(collections._writes, 0);
              await tester.tap(
                find.byKey(const ValueKey('collection-order-save')),
              );
              await tester.pumpAndSettle();
              expect(collections._writes, 1);
              expect(find.byType(CollectionReorderSliver), findsNothing);
              expect(find.text('Song order saved'), findsOneWidget);
              expect(tester.takeException(), isNull);
            } finally {
              semantics?.dispose();
            }
          },
        );
      }
    }
  }

  testWidgets('discard keeps the original order', (tester) async {
    final collections = await open(tester);
    await moveFirstToLast(tester);
    await tester.tap(find.byTooltip('Close').first);
    await tester.pumpAndSettle();
    expect(find.text('Discard Changes?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(CollectionReorderSliver), findsNothing);
    expect(collections._writes, 0);
  });

  testWidgets('failed save keeps the draft available for retry', (
    tester,
  ) async {
    final collections = await open(tester);
    collections._failSave = true;
    await moveFirstToLast(tester);
    await tester.tap(find.byKey(const ValueKey('collection-order-save')));
    await tester.pumpAndSettle();
    expect(find.byType(CollectionReorderSliver), findsOneWidget);
    expect(
      find.text('Could not save the song order. Try again.'),
      findsOneWidget,
    );
    expect(collections._writes, 0);
  });

  testWidgets('cancelling a drag leaves previous edits ready to save', (
    tester,
  ) async {
    final collections = await open(tester);
    await moveFirstToLast(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('collection-order-handle-b'))),
    );
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widget<ExpressiveButton>(
            find.byKey(const ValueKey('collection-order-save')),
          )
          .onPressed,
      isNull,
    );
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ExpressiveButton>(
            find.byKey(const ValueKey('collection-order-save')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('collection-order-save')));
    await tester.pumpAndSettle();
    expect(collections._writes, 1);
  });
}
