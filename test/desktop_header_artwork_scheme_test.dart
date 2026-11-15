import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/desktop/detail_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/tooltip_finder.dart';

/// Hands out cover schemes without decoding images: [cached] answers a peek
/// at once, and any other cover waits until the test calls [complete].
class _FakePalette extends PlayerArtworkPalette {
  final cached = <String, ColorScheme>{};
  final requests = <String>[];
  final _pending = <String, Completer<ColorScheme?>>{};

  @override
  ColorScheme? peek(String source, Brightness brightness) => cached[source];

  @override
  Future<ColorScheme?> resolve(String source, Brightness brightness) {
    requests.add(source);
    final scheme = cached[source];
    if (scheme != null) return Future.value(scheme);
    return _pending.putIfAbsent(source, Completer.new).future;
  }

  void complete(String source, ColorScheme? scheme) {
    if (scheme != null) cached[source] = scheme;
    _pending.remove(source)!.complete(scheme);
  }
}

class _Player extends MusicPlayerController {
  @override
  Future<void> setShuffle(bool enabled) async {}
}

const _cover = '/covers/album.jpg';
const _toolbar = Key('toolbar');
const _details = Key('details');
const _row = Key('row');

final _tracks = [
  for (final (number, name) in [(1, 'Bravo'), (2, 'Alpha')])
    LocalLibraryItem(
      id: '$number',
      trackName: name,
      artistName: 'Artist',
      albumName: 'Album',
      filePath: '/music/$name.flac',
      coverPath: _cover,
      trackNumber: number,
      duration: 180,
      scannedAt: DateTime(2026),
    ),
];

ColorScheme _schemeAt(WidgetTester tester, Finder finder) =>
    Theme.of(tester.element(finder)).colorScheme;

/// A bare desktop album header over one row of the page.
Widget _header(ThemeData theme, String? cover, {bool reduceMotion = false}) =>
    MaterialApp(
      // A fresh app per style, so the theme does not tween in.
      key: ObjectKey(theme),
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => CustomScrollView(
            slivers: [
              ...AlbumDetailHeader(
                title: 'Album',
                expandedHeight: 300,
                showTitleInAppBar: false,
                background: const SizedBox(),
                paletteSource: cover,
                coverBuilder: (_, size) => SizedBox.square(dimension: size),
                meta: const SizedBox(key: _details, height: 20),
                leading: const SizedBox(key: _toolbar, width: 20),
              ).buildSlivers(context),
              const SliverToBoxAdapter(child: SizedBox(key: _row, height: 44)),
            ],
          ),
        ),
      ),
    );

void main() {
  late _FakePalette palette;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDesktopPlatformOverride = true;
    palette = _FakePalette();
    PlayerArtworkTheme.debugPalette = palette;
  });

  tearDown(() {
    debugDesktopPlatformOverride = null;
    PlayerArtworkTheme.debugPalette = null;
  });

  testWidgets('the Material album header takes a cached cover scheme from '
      'its first frame while the toolbar and rows keep the app scheme', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = AppTheme.light();
    final cover = ColorScheme.fromSeed(seedColor: Colors.red);
    palette.cached[_cover] = cover;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => const Stream.empty(),
          ),
          playbackPlayingProvider.overrideWith((ref) => false),
          musicPlayerControllerProvider.overrideWithValue(_Player()),
        ],
        child: MaterialApp(
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          navigatorKey: navigator,
          home: const SizedBox(),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => LocalAlbumScreen(
          albumName: 'Album',
          artistName: 'Artist',
          coverPath: _cover,
          tracks: _tracks,
        ),
      ),
    );

    void expectScoped() {
      final play = find
          .ancestor(
            of: find.text('Play'),
            matching: find.byWidgetPredicate((w) => w is FilledButton),
          )
          .first;
      expect(_schemeAt(tester, play), cover);
      final subtitle = tester.widget<Text>(find.text('Artist').first);
      expect(subtitle.style?.color, cover.primary);
      // The header title, not the toolbar's.
      final title = tester.widget<Text>(
        find.byWidgetPredicate(
          (w) => w is Text && w.data == 'Album' && w.maxLines == 3,
        ),
      );
      expect(title.style?.color, cover.onSurface);

      final back = findByTooltip(
        const DefaultMaterialLocalizations().backButtonTooltip,
      );
      expect(_schemeAt(tester, back), theme.colorScheme);
      final row = find.text('Alpha');
      expect(_schemeAt(tester, row), theme.colorScheme);
    }

    // The page's first visible frame already shows the cached scheme. A
    // pushed route sits offstage for one frame while heroes measure it.
    await tester.pump();
    await tester.pump();
    expectScoped();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expectScoped();
    expect(palette.requests, contains(_cover));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an uncached cover keeps the app scheme, then moves to its own', (
    tester,
  ) async {
    final theme = AppTheme.light();
    final cover = ColorScheme.fromSeed(seedColor: Colors.green);
    await tester.pumpWidget(_header(theme, _cover));
    expect(_schemeAt(tester, find.byKey(_details)), theme.colorScheme);

    palette.complete(_cover, cover);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final midway = _schemeAt(tester, find.byKey(_details)).primary;
    expect(midway, isNot(theme.colorScheme.primary));
    expect(midway, isNot(cover.primary));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(_schemeAt(tester, find.byKey(_details)), cover);
    expect(HeaderPalette.of(tester.element(find.byKey(_details))), cover);
    expect(_schemeAt(tester, find.byKey(_toolbar)), theme.colorScheme);
    expect(_schemeAt(tester, find.byKey(_row)), theme.colorScheme);
  });

  testWidgets('reduced motion swaps the header scheme in one step', (
    tester,
  ) async {
    final theme = AppTheme.light();
    final cover = ColorScheme.fromSeed(seedColor: Colors.green);
    await tester.pumpWidget(_header(theme, _cover, reduceMotion: true));
    palette.complete(_cover, cover);
    await tester.pump();
    await tester.pump();
    expect(_schemeAt(tester, find.byKey(_details)), cover);
  });

  testWidgets('Mornye desktop headers keep the app scheme', (tester) async {
    final theme = MornyeTheme.build(Brightness.light);
    palette.cached[_cover] = ColorScheme.fromSeed(seedColor: Colors.red);
    await tester.pumpWidget(_header(theme, _cover));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_schemeAt(tester, find.byKey(_details)), theme.colorScheme);
    expect(
      HeaderPalette.of(tester.element(find.byKey(_details))),
      theme.colorScheme,
    );
    expect(palette.requests, isEmpty);
  });

  testWidgets('the artist header scopes its image scheme to the details', (
    tester,
  ) async {
    final theme = AppTheme.dark();
    final image = ColorScheme.fromSeed(
      seedColor: Colors.orange,
      brightness: Brightness.dark,
    );
    palette.cached[_cover] = image;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (context) => CustomScrollView(
              slivers: [
                ...desktopDetailHeaderSlivers(
                  context,
                  title: 'Artist',
                  circularArtwork: true,
                  paletteSource: _cover,
                  artwork: (_, size) => SizedBox.square(dimension: size),
                  actions: const SizedBox(key: _details, height: 20),
                  leading: const SizedBox(key: _toolbar, width: 20),
                ),
                const SliverToBoxAdapter(
                  child: SizedBox(key: _row, height: 44),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(_schemeAt(tester, find.byKey(_details)), image);
    expect(_schemeAt(tester, find.byKey(_toolbar)), theme.colorScheme);
    expect(_schemeAt(tester, find.byKey(_row)), theme.colorScheme);
  });

  testWidgets('a black and white cover gives the header a neutral scheme', (
    tester,
  ) async {
    // The real palette, so the cover's grayscale check applies.
    PlayerArtworkTheme.debugPalette = null;
    late String gray;
    final cache = PaintingBinding.instance.imageCache;
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('header-gray-'),
    );
    addTearDown(() async {
      cache.clear();
      cache.clearLiveImages();
      await tester.runAsync(() => directory!.delete(recursive: true));
    });
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (final (index, color) in const [
        Color(0xff0a0a0a),
        Color(0xff8a8a8a),
        Color(0xfff2f2f2),
      ].indexed) {
        canvas.drawRect(
          Rect.fromLTWH(index * 64 / 3, 0, 64, 64),
          Paint()..color = color,
        );
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(64, 64);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final file = File('${directory!.path}/gray.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      gray = file.path;
      // Desktop hosts quantize through the native backend; the test host
      // uses the Dart quantizer that phones fall back to.
      debugDesktopPlatformOverride = null;
      await CoverPalette.resolve(gray, Brightness.light);
      debugDesktopPlatformOverride = true;
    });

    final neutral = CoverPalette.peek(
      gray,
      Brightness.light,
      neutralGrayscale: true,
    )!;
    expect(neutral, isNot(same(CoverPalette.peek(gray, Brightness.light))));
    await tester.pumpWidget(_header(AppTheme.light(), gray));
    final shown = _schemeAt(tester, find.byKey(_details));
    expect(shown, neutral);
    expect(shown.primary.r, shown.primary.g);
    expect(shown.primary.g, shown.primary.b);
  });
}
