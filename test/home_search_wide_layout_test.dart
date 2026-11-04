import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3EButton;
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/desktop/desktop_scroll_arrows.dart';

import 'support/search_results_fixture.dart';

// Tall enough for every section of the All view.
const _desktop = Size(1280, 1800);
const _tablet = Size(1180, 1800);

const _grid = AppSettings(
  searchProvider: 'example',
  hasSearchedBefore: true,
  searchViewMode: 'grid',
);

/// The list or grid view tool: a tooltip button on Mornye, a tool in the
/// grouped toolbar on Material.
Finder _viewTool(String tooltip) => find
    .byWidgetPredicate(
      (widget) =>
          (widget is Tooltip && widget.message == tooltip) ||
          (widget is M3EButton && widget.tooltip == tooltip),
    )
    .hitTestable();

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

/// The cover save started: its progress notice, or the failure a test
/// binding reports in its place.
void _expectCoverSaveStarted() {
  expect(
    find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          ((widget.data ?? '').startsWith('Downloading') ||
              (widget.data ?? '').startsWith('Failed')),
    ),
    findsOneWidget,
  );
}

/// The cover cell of the fixture's song [index]; its key also carries the
/// result index.
Finder _songCell(int index) => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> && key.value.startsWith('track-track-$index#');
});

Future<void> _dismissSnackBars(WidgetTester tester) async {
  ScaffoldMessenger.of(
    tester.element(find.byType(Scaffold).first),
  ).clearSnackBars();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Mornye desktop results move between kinds without chips', (
    tester,
  ) async {
    final results = SearchFixtureResults(count: 3, songCount: 8);
    await pumpSearchFixture(
      tester,
      size: _desktop,
      mornye: true,
      desktop: true,
      settings: _grid,
      results: results,
      filters: searchFixtureAllFilters,
    );
    expect(find.text('Albums filter'), findsNothing);
    expect(find.text('All'), findsNothing);

    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    expect(results.requestedFilters.last, 'album');

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.text('All'), findsNothing);
    expect(find.byKey(const ValueKey('top-album-album-0')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final view in ['list', 'grid']) {
    testWidgets('Mornye $view keeps custom and empty filters reachable', (
      tester,
    ) async {
      final results = SearchFixtureResults(count: 0, songCount: 2);
      await pumpSearchFixture(
        tester,
        size: _desktop,
        mornye: true,
        desktop: true,
        settings: _grid.copyWith(searchViewMode: view),
        results: results,
        filters: const [
          SearchFilter(id: 'all', label: 'All entries'),
          ...searchFixtureAllFilters,
          SearchFilter(id: 'spoken', label: 'Spoken audio'),
        ],
      );
      expect(find.text('Albums'), findsNothing);
      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      expect(find.text('All'), findsOneWidget);
      expect(find.text('All entries'), findsNothing);
      await tester.tap(find.text('Albums filter'));
      await tester.pumpAndSettle();
      expect(results.requestedFilters.last, 'album');

      // The previous search has no results, but other filters remain usable.
      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spoken audio'));
      await tester.pumpAndSettle();
      expect(results.requestedFilters.last, 'spoken');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Mornye All view opens with Search Results cards', (
    tester,
  ) async {
    await pumpSearchFixture(
      tester,
      size: const Size(1000, 1800),
      mornye: true,
      desktop: true,
      settings: _grid,
      results: SearchFixtureResults(count: 3, songCount: 8),
      filters: searchFixtureAllFilters,
    );
    // A song first, then the album, more songs and the playlist.
    Finder card(String key) => find.byKey(ValueKey(key));
    expect(card('top-album-album-0'), findsOneWidget);
    expect(card('top-playlist-playlist-0'), findsOneWidget);
    final album = tester.getRect(card('top-album-album-0'));
    final playlist = tester.getRect(card('top-playlist-playlist-0'));
    expect(album.height, searchTopResultHeight);
    expect(album.top, lessThan(playlist.top));
    expect(playlist.left, greaterThan(album.left));
    final segments = find.textContaining(' · ');
    expect(segments.evaluate().length, 6);
    // Artists go by name alone, bigger than a phone's list row.
    final artist = tester.getSize(
      find.byKey(const ValueKey('artist-artist-0')),
    );
    final albumCell = tester.getSize(
      find.byKey(const ValueKey('album-album-0')),
    );
    expect(artist.width, lessThan(albumCell.width));
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style wide results keep the rows until grid is picked', (
      tester,
    ) async {
      await pumpSearchFixture(
        tester,
        size: _desktop,
        mornye: mornye,
        desktop: true,
        results: SearchFixtureResults(count: 3, songCount: 8),
        filters: searchFixtureAllFilters,
      );
      expect(_songCell(0), findsNothing);
      expect(find.byType(DesktopScrollArrows), findsNothing);
      expect(find.text('Found track 7'), findsOneWidget);

      await tester.tap(_viewTool('Grid'));
      await tester.pumpAndSettle();
      expect(_songCell(0), findsOneWidget);
      expect(find.byType(DesktopScrollArrows), findsNWidgets(4));
      expect(_viewTool('Grid'), findsNothing);

      await tester.tap(_viewTool('List'));
      await tester.pumpAndSettle();
      expect(_songCell(0), findsNothing);
      expect(_viewTool('Grid'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final (platform, size, desktop) in [
      ('desktop', _desktop, true),
      ('tablet', _tablet, false),
    ]) {
      testWidgets('$style $platform album filter shows a grid of covers', (
        tester,
      ) async {
        final results = SearchFixtureResults(
          count: 6,
          coverUrl: 'https://example.com/cover.jpg',
        );
        await pumpSearchFixture(
          tester,
          size: size,
          mornye: mornye,
          desktop: desktop,
          settings: _grid,
          results: results,
          filters: searchFixtureAllFilters,
        );
        await tester.tap(
          find.text(mornye && desktop ? 'Albums' : 'Albums filter'),
        );
        await tester.pumpAndSettle();
        expect(results.requestedFilters.last, 'album');

        expect(find.byType(SliverGrid), findsOneWidget);
        final cells = [
          for (var i = 0; i < 6; i++) find.byKey(ValueKey('album-album-$i')),
        ];
        for (final cell in cells) {
          expect(cell, findsOneWidget);
        }
        // One row of adaptive cells across the pane, as wide as the cover
        // geometry the skeleton shares.
        final first = tester.getRect(cells.first);
        final second = tester.getRect(cells[1]);
        expect(second.top, first.top);
        expect(second.left - first.right, searchCoverGap);
        expect(first.width, inInclusiveRange(searchCoverMinExtent, 210));
        expect(find.text('Example artist 0'), findsOneWidget);
        expect(find.byIcon(Icons.chevron_right), findsNothing);

        // A tap opens the album through the same route as the phone row.
        await tester.tap(find.text('Found album 0'));
        await tester.pump();
        expect(
          find.text('Cannot load album: missing extension source'),
          findsOneWidget,
        );
        await _dismissSnackBars(tester);

        // The cover stays savable: a right-click menu on desktop, a long
        // press on the cover elsewhere.
        if (desktop) {
          await _rightClick(tester, cells.first);
          expect(find.text('Open'), findsOneWidget);
          await tester.tap(find.text('Save Cover Art'));
          await tester.pump();
          await tester.pump();
        } else {
          await tester.longPress(cells.first);
          await tester.pump();
        }
        _expectCoverSaveStarted();
        await _dismissSnackBars(tester);

        // Sort orders the grid and each cell keeps its key.
        await tester.tap(find.text('Sort').hitTestable());
        await tester.pumpAndSettle();
        await tester.tap(find.text('Title (Z-A)'));
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byKey(const ValueKey('album-album-5'))).left,
          first.left,
        );
        expect(
          tester.getCenter(find.text('Found album 5')).dx,
          lessThan(tester.getCenter(find.text('Found album 0')).dx),
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('$style artist filter keeps the shaped avatars', (
      tester,
    ) async {
      await pumpSearchFixture(
        tester,
        size: _desktop,
        mornye: mornye,
        desktop: true,
        settings: _grid,
        results: SearchFixtureResults(count: 4),
        filters: searchFixtureAllFilters,
      );
      await tester.tap(find.text(mornye ? 'Artists' : 'Artists filter'));
      await tester.pumpAndSettle();
      final cell = find.byKey(const ValueKey('artist-artist-0'));
      expect(cell, findsOneWidget);
      expect(
        find.descendant(
          of: cell,
          matching: find.byType(mornye ? ClipRRect : ClipPath),
        ),
        findsWidgets,
      );
      // Artist names sit centered under the avatar.
      expect(
        tester.getCenter(find.text('Found artist 0')).dx,
        moreOrLessEquals(tester.getCenter(cell).dx, epsilon: 0.5),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style wide All view shows one shelf per kind', (
      tester,
    ) async {
      final results = SearchFixtureResults(count: 3, songCount: 8);
      await pumpSearchFixture(
        tester,
        size: _desktop,
        mornye: mornye,
        desktop: true,
        settings: _grid,
        results: results,
        filters: searchFixtureAllFilters,
      );
      expect(results.requestedFilters, [null]);

      // Material opens with songs, as covers like every other kind. Mornye
      // opens with a mixed preview, and songs follow the albums.
      final headers = [
        for (final title in [
          if (mornye) ...[
            'Search Results',
            'Artists',
            'Albums',
            'Songs',
            'Playlists',
          ] else ...[
            'Songs',
            'Artists',
            'Albums',
            'Playlists',
          ],
        ])
          tester.getTopLeft(find.text(title)).dy,
      ];
      expect(headers, orderedEquals([...headers]..sort()));
      // Sort ends the filter row, so each Show all ends its own header.
      final sortTop = tester.getCenter(find.text('Sort').hitTestable()).dy;
      expect(sortTop, lessThan(headers.first));
      if (!mornye) {
        expect(
          tester.getCenter(find.text('All')).dy,
          moreOrLessEquals(sortTop, epsilon: 12),
        );
      }
      final songShelf = find.byKey(const ValueKey('search-shelf-track'));
      expect(songShelf, findsOneWidget);
      expect(
        find.descendant(of: songShelf, matching: _songCell(0)),
        findsOneWidget,
      );
      expect(
        tester.getSize(_songCell(0)).width,
        tester.getSize(find.byKey(const ValueKey('album-album-0'))).width,
      );

      // One sideways shelf per kind, with arrows for the mouse.
      for (final kind in ['artist', 'album', 'playlist']) {
        final shelf = find.byKey(ValueKey('search-shelf-$kind'));
        expect(shelf, findsOneWidget);
        expect(
          find.descendant(
            of: shelf,
            matching: find.byKey(ValueKey('$kind-$kind-0')),
          ),
          findsOneWidget,
        );
      }
      expect(find.byType(DesktopScrollArrows), findsNWidgets(4));
      // Only Mornye's mixed preview cards form a grid.
      expect(find.byType(SliverGrid), mornye ? findsOneWidget : findsNothing);

      // Show all switches to that kind's filter.
      await tester.tap(find.bySemanticsLabel('Show all Albums'));
      await tester.pumpAndSettle();
      expect(results.requestedFilters.last, 'album');
      expect(find.byType(SliverGrid), findsOneWidget);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Show all Songs'));
      await tester.pumpAndSettle();
      expect(results.requestedFilters.last, 'track');
      expect(find.byType(SliverGrid), findsOneWidget);
      expect(_songCell(7), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style tablet All view shelves songs without a filter', (
      tester,
    ) async {
      final results = SearchFixtureResults(count: 2, songCount: 8);
      await pumpSearchFixture(
        tester,
        size: _tablet,
        mornye: mornye,
        settings: _grid,
        results: results,
        filters: searchFixtureCollectionFilters,
      );
      // Without a songs filter to switch to, the shelf holds every song.
      expect(find.byKey(const ValueKey('search-shelf-track')), findsOneWidget);
      expect(find.byKey(const ValueKey('search-shelf-album')), findsOneWidget);
      expect(find.bySemanticsLabel('Show all Songs'), findsNothing);
      expect(find.bySemanticsLabel('Show all Albums'), findsOneWidget);
      expect(results.requestedFilters, [null]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style song covers activate like the phone row', (
      tester,
    ) async {
      // Without a download extension, a song tap ends in this notice.
      const settings = AppSettings(
        searchProvider: 'example',
        hasSearchedBefore: true,
        askQualityBeforeDownload: false,
        deduplicateDownloads: false,
        searchViewMode: 'grid',
      );
      const notice = 'No extensions with download provider';

      await pumpSearchFixture(
        tester,
        size: const Size(820, 1400),
        mornye: mornye,
        desktop: true,
        settings: settings,
      );
      // A narrow window keeps the rows.
      expect(_songCell(0), findsNothing);
      await tester.tap(find.text('Found track 0'));
      await tester.pump();
      expect(find.text(notice), findsOneWidget);

      await pumpSearchFixture(
        tester,
        size: _desktop,
        mornye: mornye,
        desktop: true,
        settings: settings,
        filters: searchFixtureAllFilters,
      );
      await tester.tap(find.text(mornye ? 'Songs' : 'Songs filter'));
      await tester.pumpAndSettle();
      expect(find.byType(SliverGrid), findsOneWidget);
      expect(_songCell(0), findsOneWidget);
      expect(find.text(notice), findsNothing);
      await tester.tap(find.text('Found track 0'));
      await tester.pump();
      expect(find.text(notice), findsOneWidget);
      await _dismissSnackBars(tester);

      // The right-click menu is the song's track options.
      await _rightClick(tester, find.text('Found track 1'));
      expect(find.text('Download'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style wide loading skeletons match the loaded geometry', (
      tester,
    ) async {
      const albumSettings = AppSettings(
        searchProvider: 'example',
        hasSearchedBefore: true,
        defaultSearchTab: 'album',
        searchViewMode: 'grid',
      );
      await pumpSearchFixture(
        tester,
        size: _desktop,
        mornye: mornye,
        desktop: true,
        settings: albumSettings,
        filters: searchFixtureAllFilters,
        results: SearchFixtureResults(holdLoading: true),
      );
      final skeleton = find.byType(HomeSearchSkeleton);
      expect(skeleton, findsOneWidget);
      // The cover placeholders: the largest square boxes.
      double largestBox() => find
          .descendant(of: skeleton, matching: find.byType(SkeletonBox))
          .evaluate()
          .map((element) => element.size!)
          .where((size) => size.width == size.height)
          .map((size) => size.width)
          .reduce((a, b) => a > b ? a : b);
      final skeletonCover = largestBox();

      await pumpSearchFixture(
        tester,
        size: _desktop,
        mornye: mornye,
        desktop: true,
        settings: albumSettings,
        filters: searchFixtureAllFilters,
        results: SearchFixtureResults(count: 6),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('album-album-0'))).width,
        skeletonCover,
      );

      // The Songs filter loads as the same cover grid.
      const songSettings = AppSettings(
        searchProvider: 'example',
        hasSearchedBefore: true,
        defaultSearchTab: 'track',
        searchViewMode: 'grid',
      );
      await pumpSearchFixture(
        tester,
        size: _desktop,
        mornye: mornye,
        desktop: true,
        settings: songSettings,
        filters: searchFixtureAllFilters,
        results: SearchFixtureResults(holdLoading: true),
      );
      expect(largestBox(), skeletonCover);

      // The All view loads as shelves, songs included.
      await pumpSearchFixture(
        tester,
        size: _desktop,
        mornye: mornye,
        desktop: true,
        settings: _grid,
        filters: searchFixtureAllFilters,
        results: SearchFixtureResults(holdLoading: true),
      );
      expect(find.byType(TrackListSkeleton), findsNothing);
      final shelfCover = largestBox();
      if (!mornye) expect(shelfCover, searchCoverShelfExtent);
      await pumpSearchFixture(
        tester,
        size: _desktop,
        mornye: mornye,
        desktop: true,
        settings: _grid,
        filters: searchFixtureAllFilters,
        results: SearchFixtureResults(count: 3, songCount: 8),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('album-album-0'))).width,
        shelfCover,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style grid flows right to left in Arabic layouts', (
      tester,
    ) async {
      await pumpSearchFixture(
        tester,
        size: _desktop,
        mornye: mornye,
        desktop: true,
        brightness: Brightness.light,
        textDirection: TextDirection.rtl,
        settings: _grid,
        filters: searchFixtureAllFilters,
        results: SearchFixtureResults(count: 3),
      );
      await tester.tap(find.text(mornye ? 'Albums' : 'Albums filter'));
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(find.byKey(const ValueKey('album-album-0'))).dx,
        greaterThan(
          tester.getCenter(find.byKey(const ValueKey('album-album-1'))).dx,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
