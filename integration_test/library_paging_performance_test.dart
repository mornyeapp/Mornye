import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';

import '../test/support/fixed_settings.dart';
import '../test/support/library_paging_fixture.dart';
import 'performance_probe.dart';

const _request = (
  artists: false,
  artist: null,
  search: '',
  sort: 'a-z',
  limit: 40,
  completeness: null,
);

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Local extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

/// The previous growing-prefix algorithm, scoped to this fixture. The same
/// production screen and SQL read adapter render both sides of the comparison.
class _PrefixBrowse extends LibraryBrowseNotifier {
  _PrefixBrowse(super.request, this.readPage);

  final Future<LibraryBrowsePage> Function(LibraryBrowsePageRequest) readPage;
  late int _limit;

  Future<LibraryBrowseState> _read() async {
    final page = await readPage((
      browse: (
        artists: request.artists,
        artist: request.artist,
        search: request.search,
        sort: request.sort,
        limit: _limit,
        completeness: request.completeness,
      ),
      offset: 0,
      cursor: null,
      includeLocal: true,
    ));
    return LibraryBrowseState(
      page.entries,
      hasMore: page.entries.length >= _limit,
    );
  }

  @override
  Future<LibraryBrowseState> build() {
    _limit = request.limit;
    return _read();
  }

  @override
  Future<void> loadMore() async {
    if (state.isLoading || !state.hasValue) return;
    final previous = state.requireValue;
    if (previous.isLoadingMore || !previous.hasMore) return;
    state = AsyncData(
      LibraryBrowseState(previous.entries, hasMore: true, isLoadingMore: true),
    );
    _limit += request.limit;
    state = AsyncData(await _read());
  }
}

Future<void> _cover(String path) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xff305060), BlendMode.src);
  canvas.drawCircle(
    const Offset(160, 180),
    125,
    Paint()..color = const Color(0xffc47f56),
  );
  canvas.drawRect(
    const Rect.fromLTWH(40, 245, 300, 40),
    Paint()..color = const Color(0xffc3e1dc),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(384, 384);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File(path).writeAsBytes(bytes.buffer.asUint8List());
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<Uint8List> _pixels(GlobalKey key, double ratio) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: ratio);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return Uint8List.fromList(bytes.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

void main() {
  final binding = PerformanceTestBinding.ensureInitialized();
  testWidgets('paired actual SQLite long-scroll Library paging', (
    tester,
  ) async {
    final probe = PerformanceProbe(binding, tester, suite: 'library_paging');
    final directory = await Directory.systemTemp.createTemp('library-paging-');
    final coverPath = '${directory.path}/cover.png';
    await _cover(coverPath);
    final db = await openDatabase(
      '${directory.path}/fixture.db',
      singleInstance: false,
    );
    addTearDown(() async {
      await db.close();
      await directory.delete(recursive: true);
    });
    final store = await createLibraryPagingFixture(db, cover: coverPath);
    final key = GlobalKey();
    var mountNumber = 0;
    var returnedRows = 0;
    var queryCount = 0;
    var queryMicroseconds = 0;
    final runCounters = <Map<String, Object?>>[];
    final pixelChecks = <Map<String, Object?>>[];

    Future<LibraryBrowsePage> readPage(LibraryBrowsePageRequest request) async {
      final watch = Stopwatch()..start();
      final page = await readLibraryPagingFixture(store, request);
      watch.stop();
      queryMicroseconds += watch.elapsedMicroseconds;
      returnedRows += page.entries.length;
      queryCount++;
      return page;
    }

    ProviderContainer container() => ProviderScope.containerOf(
      tester.element(find.byType(MornyeLibraryScreen)),
    );
    LibraryBrowseState? current() =>
        container().read(libraryBrowseProvider(_request)).value;
    Future<void> ready(int expected) async {
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 20)) {
        final value = current();
        if (value != null &&
            !value.isLoadingMore &&
            value.entries.length >= expected) {
          expect(value.loadMoreError, isNull);
          return;
        }
        await probe.wait(const Duration(milliseconds: 10));
      }
      fail(
        'Library did not reach $expected entries: ${current()?.entries.length}',
      );
    }

    Future<void> painted() async {
      binding.scheduleFrame();
      await binding.endOfFrame;
    }

    Future<void> mount(bool before, Brightness brightness) async {
      binding.attachRootWidget(
        binding.wrapWithDefaultView(
          RepaintBoundary(
            key: key,
            child: ProviderScope(
              key: ValueKey(mountNumber++),
              overrides: [
                settingsProvider.overrideWith(
                  () => FixedSettingsNotifier(
                    const AppSettings(localLibraryEnabled: true),
                  ),
                ),
                downloadHistoryProvider.overrideWith(_History.new),
                localLibraryProvider.overrideWith(_Local.new),
                libraryBrowsePageLoaderProvider.overrideWithValue(readPage),
                if (before)
                  libraryBrowseProvider.overrideWith2(
                    (request) => _PrefixBrowse(request, readPage),
                  ),
              ],
              child: MaterialApp(
                theme: MornyeTheme.build(brightness),
                locale: const Locale('en'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: MornyeLibraryScreen(
                    page: MornyeLibraryPage.albums,
                    onOpenSection: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await painted();
      await ready(40);
      await painted();
    }

    ScrollController scroll() => tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;

    Future<void> nextPage() async {
      final expected = current()!.entries.length + 40;
      scroll().jumpTo(scroll().position.maxScrollExtent);
      await ready(expected);
      await painted();
    }

    // First and deeper pages must remain exactly identical in both themes.
    for (final brightness in Brightness.values) {
      for (final pages in [1, 3]) {
        late Uint8List beforePixels;
        for (final before in [true, false]) {
          await tester.runAsync(() async {
            await mount(before, brightness);
            for (var page = 1; page < pages; page++) {
              await nextPage();
            }
            scroll().jumpTo(0);
            await probe.wait(const Duration(milliseconds: 700));
            binding.scheduleFrame();
            await binding.endOfFrame;
            binding.scheduleFrame();
            await binding.endOfFrame;
            final rgba = await _pixels(key, tester.view.devicePixelRatio);
            if (before) {
              beforePixels = rgba;
            } else {
              var differences = 0;
              expect(rgba.length, beforePixels.length);
              for (var channel = 0; channel < rgba.length; channel++) {
                if (rgba[channel] != beforePixels[channel]) differences++;
              }
              pixelChecks.add({
                'brightness': brightness.name,
                'pages': pages,
                'different_rgba_channels': differences,
              });
              expect(
                differences,
                0,
                reason: 'Library paging must preserve pixels',
              );
            }
          });
        }
      }
    }

    Future<void> longScroll(bool before, int pair) async {
      returnedRows = queryCount = queryMicroseconds = 0;
      await mount(before, Brightness.dark);
      for (var page = 1; page < 25; page++) {
        await nextPage();
      }
      final entries = current()!.entries;
      final expected = await readLibraryPagingFixture(store, (
        browse: (
          artists: false,
          artist: null,
          search: '',
          sort: 'a-z',
          limit: 1000,
          completeness: null,
        ),
        offset: 0,
        cursor: null,
        includeLocal: true,
      ));
      expect(
        libraryPagingIdentities(entries),
        libraryPagingIdentities(expected.entries),
      );
      expect(returnedRows, before ? 13000 : 1000);
      expect(queryCount, 25);
      runCounters.add({
        'pair': pair,
        'mode': before ? 'prefix_before' : 'pages_after',
        'returned_rows': returnedRows,
        'queries': queryCount,
        'query_and_adapter_ms': queryMicroseconds / 1000,
      });
    }

    for (var pair = 0; pair < 4; pair++) {
      for (final before in pair.isEven ? [true, false] : [false, true]) {
        await probe.measure(
          '${before ? 'prefix_before' : 'pages_after'}_pair_${pair + 1}',
          () => longScroll(before, pair + 1),
          repetitions: 1,
          warmup: () async {
            await mount(before, Brightness.dark);
            await nextPage();
          },
        );
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await probe.finish(
      metadata: {
        'fixture':
            'Isolated actual SQLite schema17, 1000 two-source albums/2000 tracks, '
            '50 mirrored tracks and one unavailable source; shared decoded 384px PNG, no network.',
        'baseline':
            'Previous growing-prefix reads through production SQL; same MornyeLibraryScreen.',
        'paging':
            'Production AsyncNotifier and bounded page adapter; same SQL/store and UI.',
        'runs': runCounters,
        'pixel_checks': pixelChecks,
        'paired_order': 'AB/BA/AB/BA',
        'known_total_fixture':
            '25 pages, stops at 1000 entries without an additional end-of-list probe',
      },
    );
  });
}
