import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/collection_track_sort_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/collection_reorder_sliver.dart';
import 'package:mornye/widgets/desktop/track_list_table.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';
import 'support/tooltip_finder.dart';

CollectionTrackEntry _entry(
  String key,
  String name,
  String artist,
  String album,
  int day, {
  int? number,
}) => CollectionTrackEntry(
  key: key,
  addedAt: DateTime(2026, 1, day),
  track: Track(
    id: key,
    name: name,
    artistName: artist,
    albumName: album,
    trackNumber: number,
    duration: 180,
  ),
);

/// Saved order a, b, c. By title c, b, a; by artist b, c, a; by album
/// b, a, c; newest first c, a, b.
final _entries = [
  _entry('a', 'Zebra', 'Cara', 'Blue', 2, number: 2),
  _entry('b', 'apple 10', 'Ana', 'Blue', 1, number: 1),
  _entry('c', 'Apple 2', 'Ben', 'Red', 3),
];

List<String> _keys(Iterable<CollectionTrackEntry> entries) => [
  for (final entry in entries) entry.key,
];

class _Collections extends LibraryCollectionsNotifier {
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

Future<void> _open(
  WidgetTester tester, {
  bool desktop = false,
  bool mornye = false,
  LibraryTracksFolderMode mode = LibraryTracksFolderMode.playlist,
}) async {
  debugDesktopPlatformOverride = desktop;
  tester.view.physicalSize = desktop
      ? const Size(1200, 900)
      : const Size(430, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(FixedSettingsNotifier.new),
        libraryCollectionsProvider.overrideWith(_Collections.new),
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
}

/// The song titles from the top of the page down.
List<String> _shown(WidgetTester tester, {bool desktop = false}) {
  if (desktop) {
    return [
      for (final track
          in tester.widget<TrackListTable>(find.byType(TrackListTable)).tracks)
        track.name,
    ];
  }
  final names = ['Zebra', 'apple 10', 'Apple 2'];
  return names..sort(
    (a, b) => tester
        .getTopLeft(find.text(a))
        .dy
        .compareTo(tester.getTopLeft(find.text(b)).dy),
  );
}

Future<void> _pick(WidgetTester tester, String label) async {
  await tester.tap(findByTooltip('Sort Songs').hitTestable().first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDesktopPlatformOverride = null);

  test('each sort orders the songs and ties keep the saved order', () {
    List<String> sorted(CollectionTrackSort sort) =>
        _keys(sortCollectionEntries(_entries, sort));

    expect(sorted(CollectionTrackSort.custom), ['a', 'b', 'c']);
    // Case is ignored and "2" comes before "10".
    expect(sorted(CollectionTrackSort.title), ['c', 'b', 'a']);
    expect(sorted(CollectionTrackSort.artist), ['b', 'c', 'a']);
    // An album lists its songs by number.
    expect(sorted(CollectionTrackSort.album), ['b', 'a', 'c']);
    expect(sorted(CollectionTrackSort.latest), ['c', 'a', 'b']);

    final same = [
      _entry('x', 'Same', 'One', 'Album', 1),
      _entry('y', 'Same', 'One', 'Album', 1),
      _entry('z', 'Same', 'One', 'Album', 1),
    ];
    for (final sort in CollectionTrackSort.values) {
      expect(_keys(sortCollectionEntries(same, sort)), ['x', 'y', 'z']);
    }
    // The saved list itself is never reordered.
    expect(_keys(_entries), ['a', 'b', 'c']);
  });

  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      testWidgets('a playlist lists its songs by the chosen sort and keeps '
          'the choice (desktop: $desktop, Mornye: $mornye)', (tester) async {
        await _open(tester, desktop: desktop, mornye: mornye);
        expect(_shown(tester, desktop: desktop), [
          'Zebra',
          'apple 10',
          'Apple 2',
        ]);

        await _pick(tester, 'Title (A-Z)');
        expect(_shown(tester, desktop: desktop), [
          'Apple 2',
          'apple 10',
          'Zebra',
        ]);
        final prefs = await SharedPreferences.getInstance();
        expect(jsonDecode(prefs.getString('collection_track_sorts')!), {
          'playlist:mix': 'title',
        });

        await _pick(tester, 'Custom Order');
        expect(_shown(tester, desktop: desktop), [
          'Zebra',
          'apple 10',
          'Apple 2',
        ]);
        expect(jsonDecode(prefs.getString('collection_track_sorts')!), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('a saved choice applies when the playlist opens, and to that '
      'playlist only', (tester) async {
    SharedPreferences.setMockInitialValues({
      'collection_track_sorts': jsonEncode({'playlist:mix': 'artist'}),
    });
    await _open(tester);
    expect(_shown(tester), ['apple 10', 'Apple 2', 'Zebra']);

    await _open(tester, mode: LibraryTracksFolderMode.loved);
    expect(_shown(tester), ['Zebra', 'apple 10', 'Apple 2']);
  });

  testWidgets('Edit order works on the saved order whatever the page shows', (
    tester,
  ) async {
    await _open(tester);
    await _pick(tester, 'Title (A-Z)');

    await tester.tap(find.byType(HeaderMoreButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit order'));
    await tester.pumpAndSettle();

    expect(
      _keys(
        tester
            .widget<CollectionReorderSliver>(
              find.byType(CollectionReorderSliver),
            )
            .entries,
      ),
      ['a', 'b', 'c'],
    );
    // Sorting waits until the order is saved or the edit is cancelled.
    expect(findByTooltip('Sort Songs'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
