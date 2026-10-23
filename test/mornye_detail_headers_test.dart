import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/collection_scaffold.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';

void main() {
  testWidgets('artist logo uses a bounded aspect-preserving shared decode', (
    tester,
  ) async {
    const name = 'An artist with a name spanning several lines';
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(
            body: CustomScrollView(
              slivers: [
                MornyeArtistHeader(
                  name: name,
                  logoUrl: 'https://example.invalid/large-logo.png',
                  artwork: ColoredBox(color: Colors.orange),
                  actions: [],
                  showTitle: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    final resized = image.image as ResizeImage;
    expect(resized.width, 640);
    expect(resized.height, 192);
    expect(resized.policy, ResizeImagePolicy.fit);
    final source = resized.imageProvider as CachedNetworkImageProvider;
    expect(source.cacheManager, same(CoverCacheManager.instance));
    await tester.pumpAndSettle();
    final fallback = find.descendant(
      of: find.byType(FlexibleSpaceBar),
      matching: find.text(name),
    );
    expect(tester.getSize(fallback).height, greaterThan(96));
    expect(tester.takeException(), isNull);
  });

  testWidgets('artist actions preserve artwork and logo accents', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('artist-palette-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final neutralCover = File('${directory.path}/neutral.png');
    final coloredCover = File('${directory.path}/colored.png');
    final whiteLogo = File('${directory.path}/white-logo.png');
    final coloredLogo = File('${directory.path}/colored-logo.png');
    await tester.runAsync(() async {
      for (final (file, color, isLogo) in [
        (neutralCover, const Color(0xff9da4a9), false),
        (coloredCover, Colors.deepOrange, false),
        (whiteLogo, Colors.white, true),
        (coloredLogo, Colors.amber, true),
      ]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          isLogo
              ? const Rect.fromLTWH(20, 40, 60, 20)
              : const Rect.fromLTWH(0, 0, 100, 100),
          Paint()..color = color,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(100, 100);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        await CoverPalette.resolve(file.path, Brightness.dark);
      }
    });
    final artworkAccent = CoverPalette.peek(
      coloredCover.path,
      Brightness.dark,
    )!.primary;
    expect(artworkAccent, isNot(Colors.white));
    for (final brightness in Brightness.values) {
      for (final (cover, logo, expected) in [
        (neutralCover, null, Colors.white),
        (coloredCover, null, artworkAccent),
        (coloredCover, whiteLogo, Colors.white),
        (neutralCover, coloredLogo, Colors.amber),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: MornyeTheme.build(brightness),
            home: MornyeArtistSurface(
              imageSource: cover.path,
              logoSource: logo?.path,
              child: const Text('Artist action'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scheme = Theme.of(
          tester.element(find.text('Artist action')),
        ).colorScheme;
        expect(scheme.primary.toARGB32(), expected.toARGB32());
        final foreground = scheme.onPrimary.computeLuminance();
        final background = scheme.primary.computeLuminance();
        final contrast = foreground > background
            ? (foreground + 0.05) / (background + 0.05)
            : (background + 0.05) / (foreground + 0.05);
        expect(contrast, greaterThanOrEqualTo(4.5));
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'local and online album actions share the neutral cover surface',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('album-surface-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final cover = File('${directory.path}/cover.png');
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(Colors.white, BlendMode.src);
        canvas.drawRect(
          const Rect.fromLTWH(50, 0, 50, 100),
          Paint()..color = const Color(0xff02020f),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(100, 100);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        await cover.writeAsBytes(bytes!.buffer.asUint8List());
        await CoverPalette.resolve(cover.path, Brightness.dark);
      });
      for (final online in [false, true]) {
        final label = online ? 'Download' : 'Play';
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: MornyeTheme.build(Brightness.light),
              home: MornyeArtistSurface(
                imageSource: cover.path,
                neutralActions: true,
                child: CollectionScaffold(
                  scrollController: scrollController,
                  isSelectionMode: false,
                  onExitSelectionMode: () {},
                  bottomInset: 0,
                  appBar: AlbumDetailHeader(
                    title: 'Monochrome album',
                    expandedHeight: 400,
                    showTitleInAppBar: false,
                    immersive: true,
                    background: const ColoredBox(color: Colors.white),
                    actions: online
                        ? HeaderFilledButton(
                            icon: CupertinoIcons.arrow_down_circle_fill,
                            label: label,
                            onPressed: () {},
                          )
                        : AlbumPlayActions(
                            playLabel: label,
                            shuffleTooltip: 'Shuffle',
                            onPlay: () {},
                            onShuffle: () {},
                          ),
                  ),
                  slivers: const [],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final action = find.text(label);
        final context = tester.element(action);
        final scheme = Theme.of(context).colorScheme;
        expect(scheme.surface.r, scheme.surface.g);
        expect(scheme.surface.g, scheme.surface.b);
        expect(HeaderPalette.of(context), scheme);
        expect(tester.widget<Text>(action).style?.color, Colors.black);
        expect(
          tester
              .widget<CupertinoButton>(
                find.ancestor(
                  of: action,
                  matching: find.byType(CupertinoButton),
                ),
              )
              .color,
          Colors.white,
        );
        if (!online) {
          expect(
            tester.widget<Text>(find.text('Shuffle')).style?.color,
            Colors.white,
          );
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('album surface is tinted on its first frame from the player', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('album-tint-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cover = File('${directory.path}/cover.png');
    final source = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.teal, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(32, 32);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      await cover.writeAsBytes(bytes!.buffer.asUint8List());
      // The Mornye player resolves only the source colour, never a scheme.
      return CoverPalette.resolveSourceColor(cover.path);
    });
    expect(CoverPalette.peek(cover.path, Brightness.dark), isNull);
    final dominant = HSLColor.fromColor(source!);
    final tinted = dominant
        .withSaturation((dominant.saturation * 0.45).clamp(0.0, 0.22))
        .withLightness(0.24 + dominant.lightness * 0.20)
        .toColor();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.light),
          home: MornyeArtistSurface(
            imageSource: cover.path,
            neutralActions: true,
            child: const Text('Album action'),
          ),
        ),
      ),
    );
    final scheme = Theme.of(
      tester.element(find.text('Album action')),
    ).colorScheme;
    expect(scheme.surface.toARGB32(), tinted.toARGB32());
    expect(scheme.surface.r, isNot(scheme.surface.b));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unavailable artist logo keeps the name and actions readable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Scaffold(
            body: CustomScrollView(
              slivers: const [
                MornyeArtistHeader(
                  name: 'Example Artist',
                  logoUrl: 'https://example.invalid/unavailable-logo.png',
                  artwork: ColoredBox(color: Colors.orange),
                  actions: [Text('Artist action')],
                  showTitle: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find
          .descendant(
            of: find.byType(FlexibleSpaceBar),
            matching: find.text('Example Artist'),
          )
          .hitTestable(),
      findsOneWidget,
    );
    expect(find.text('Artist action').hitTestable(), findsOneWidget);
    final background = tester.getRect(
      find.byKey(const ValueKey('artist-artwork-fade')),
    );
    final action = tester.getRect(find.text('Artist action'));
    expect(background.contains(action.center), isTrue);
    expect(background.bottom - action.bottom, inInclusiveRange(32, 60));
    expect(action.center.dy, lessThan(480));
    expect(tester.takeException(), isNull);
  });

  testWidgets('artist artwork blurs, disappears, and returns with scroll', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(top: 59, bottom: 34);
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    const artworkKey = ValueKey('artist-artwork');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              slivers: const [
                MornyeArtistHeader(
                  name: 'Artist',
                  artwork: ColoredBox(key: artworkKey, color: Colors.orange),
                  actions: [Text('Artist action')],
                  showTitle: false,
                ),
                SliverToBoxAdapter(child: SizedBox(height: 2000)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    double fade() => tester
        .widget<ColoredBox>(find.byKey(const ValueKey('artist-artwork-fade')))
        .color
        .a;
    ImageFiltered filter() => tester.widget<ImageFiltered>(
      find.ancestor(
        of: find.byKey(artworkKey),
        matching: find.byType(ImageFiltered),
      ),
    );
    final artwork = tester.element(find.byKey(artworkKey));
    expect(fade(), 0);
    expect(filter().enabled, isFalse);

    controller.jumpTo(120);
    await tester.pumpAndSettle();
    expect(filter().enabled, isTrue);
    expect(fade(), inExclusiveRange(0, 1));
    expect(find.text('Artist action').hitTestable(), findsOneWidget);

    controller.jumpTo(340);
    await tester.pumpAndSettle();
    expect(fade(), 1);
    expect(filter().enabled, isFalse);
    expect(TickerMode.valuesOf(artwork).enabled, isFalse);
    expect(find.byTooltip('Back').hitTestable(), findsOneWidget);

    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(fade(), 0);
    expect(filter().enabled, isFalse);
    expect(TickerMode.valuesOf(artwork).enabled, isTrue);
    expect(find.text('Artist action').hitTestable(), findsOneWidget);
    expect(tester.element(find.byKey(artworkKey)), same(artwork));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pulling the artist header zooms only the artwork', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(top: 59, bottom: 34);
    addTearDown(tester.view.reset);
    const artworkKey = ValueKey('stretch-artwork');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Scaffold(
            body: CustomScrollView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: const [
                MornyeArtistHeader(
                  name: 'Artist',
                  artwork: ColoredBox(key: artworkKey, color: Colors.orange),
                  actions: [Text('Artist action')],
                  showTitle: false,
                ),
                SliverToBoxAdapter(child: Text('Album list')),
                SliverToBoxAdapter(child: SizedBox(height: 2000)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final artwork = find.byKey(artworkKey);
    final action = find.text('Artist action');
    final albums = find.text('Album list');
    final originalArt = tester.getRect(artwork);
    final originalAction = tester.getRect(action);
    final originalAlbums = tester.getRect(albums);
    final element = tester.element(artwork);
    final gesture = await tester.startGesture(const Offset(195, 350));
    await gesture.moveBy(const Offset(0, 150));
    await tester.pump();
    final stretchedArt = tester.getRect(artwork);
    expect(stretchedArt.width, greaterThan(originalArt.width));
    expect(
      stretchedArt.width / originalArt.width,
      closeTo(stretchedArt.height / originalArt.height, 0.001),
    );
    expect(stretchedArt.top, closeTo(originalArt.top, 0.01));
    expect(tester.getSize(action), originalAction.size);
    expect(tester.getRect(action).top, greaterThan(originalAction.top));
    expect(tester.getRect(albums).top, greaterThan(originalAlbums.top));
    expect(tester.element(artwork), same(element));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(artwork), originalArt);
    expect(tester.getRect(action), originalAction);
    expect(tester.takeException(), isNull);
  });

  for (final squareArtwork in [true, false]) {
    for (final reduceMotion in [false, true]) {
      testWidgets(
        'album pull preserves controls (square: $squareArtwork, reduced motion: $reduceMotion)',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = FakeViewPadding(top: 59, bottom: 34);
          addTearDown(tester.view.reset);
          final controller = ScrollController();
          addTearDown(controller.dispose);
          const artworkKey = ValueKey('stretch-album-artwork');
          var plays = 0;
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                theme: MornyeTheme.build(Brightness.dark),
                scrollBehavior: const MaterialScrollBehavior().copyWith(
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: reduceMotion),
                  child: child!,
                ),
                home: CollectionScaffold(
                  scrollController: controller,
                  isSelectionMode: false,
                  onExitSelectionMode: () {},
                  bottomInset: 0,
                  appBar: AlbumDetailHeader(
                    immersive: true,
                    squareArtwork: squareArtwork,
                    title: 'Album',
                    expandedHeight: 400,
                    showTitleInAppBar: false,
                    background: const ColoredBox(
                      key: artworkKey,
                      color: Colors.orange,
                    ),
                    actions: AlbumPlayActions(
                      playLabel: 'Play',
                      shuffleTooltip: 'Shuffle',
                      onPlay: () => plays++,
                      onShuffle: () {},
                    ),
                  ),
                  slivers: const [
                    SliverToBoxAdapter(child: Text('Track list')),
                    SliverToBoxAdapter(child: SizedBox(height: 2000)),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final artwork = find.byKey(artworkKey);
          final play = find.text('Play');
          final tracks = find.text('Track list');
          final originalArt = tester.getRect(artwork);
          final originalPlay = tester.getRect(play);
          final originalTracks = tester.getRect(tracks);
          final originalBack = tester.getRect(find.byTooltip('Back'));
          final element = tester.element(artwork);
          final gesture = await tester.startGesture(const Offset(195, 250));
          await gesture.moveBy(const Offset(0, 150));
          await tester.pump();
          final stretchedArt = tester.getRect(artwork);
          expect(controller.offset, lessThan(0));
          if (reduceMotion) {
            expect(stretchedArt.size, originalArt.size);
          } else {
            expect(stretchedArt.width, greaterThan(originalArt.width));
            expect(
              stretchedArt.width / originalArt.width,
              closeTo(stretchedArt.height / originalArt.height, 0.001),
            );
            expect(stretchedArt.top, closeTo(originalArt.top, 0.01));
          }
          expect(tester.getSize(play), originalPlay.size);
          expect(tester.getRect(play).top, greaterThan(originalPlay.top));
          expect(tester.getRect(tracks).top, greaterThan(originalTracks.top));
          expect(tester.getRect(find.byTooltip('Back')), originalBack);
          expect(play.hitTestable(), findsOneWidget);
          expect(tester.element(artwork), same(element));
          await gesture.up();
          await tester.pumpAndSettle();
          expect(tester.getRect(artwork), originalArt);
          expect(tester.getRect(play), originalPlay);
          await tester.tap(play);
          expect(plays, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'album actions and pinned navigation work in $brightness at $scale',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = FakeViewPadding(top: 59, bottom: 34);
          addTearDown(tester.view.reset);
          final controller = ScrollController();
          addTearDown(controller.dispose);
          var plays = 0;
          var shuffles = 0;
          var backs = 0;
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                theme: MornyeTheme.build(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: CollectionScaffold(
                  scrollController: controller,
                  isSelectionMode: false,
                  onExitSelectionMode: () {},
                  bottomInset: 0,
                  appBar: AlbumDetailHeader(
                    immersive: true,
                    title:
                        'A long album title that must wrap without hiding any of its controls',
                    expandedHeight: 400,
                    showTitleInAppBar: false,
                    background: const ColoredBox(
                      key: ValueKey('album-artwork'),
                      color: Colors.orange,
                    ),
                    coverBuilder: (_, _) =>
                        const ColoredBox(color: Colors.orange),
                    subtitle: const Text('Artist name'),
                    leading: HeaderCircleButton(
                      icon: Icons.arrow_back,
                      tooltip: 'Back',
                      onPressed: () => backs++,
                    ),
                    actions: AlbumPlayActions(
                      playLabel: 'Play',
                      shuffleTooltip: 'Shuffle',
                      onPlay: () => plays++,
                      onShuffle: () => shuffles++,
                    ),
                  ),
                  slivers: [
                    SliverList.builder(
                      itemCount: 40,
                      itemBuilder: (_, index) =>
                          SizedBox(height: 64, child: Text('Track $index')),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            tester.getSize(find.byKey(const ValueKey('album-artwork'))),
            const Size(390, 390),
          );
          final albumTitle = find
              .text(
                'A long album title that must wrap without hiding any of its controls',
              )
              .last;
          expect(tester.getTopLeft(albumTitle).dy, 370);
          expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
          await tester.ensureVisible(find.text('Play'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Play'));
          await tester.tap(find.text('Shuffle'));
          expect(plays, 1);
          expect(shuffles, 1);
          controller.jumpTo(1300);
          await tester.pumpAndSettle();
          expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
          await tester.tap(find.byTooltip('Back'));
          expect(backs, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('album banner extends behind the raised details and actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(top: 59, bottom: 34);
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var downloads = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: CollectionScaffold(
            scrollController: controller,
            isSelectionMode: false,
            onExitSelectionMode: () {},
            bottomInset: 0,
            appBar: AlbumDetailHeader(
              title: 'Album title',
              expandedHeight: 400,
              showTitleInAppBar: false,
              immersive: true,
              squareArtwork: false,
              background: const ColoredBox(
                key: ValueKey('album-banner'),
                color: Colors.orange,
              ),
              subtitle: const Text('Artist name'),
              meta: const Text('2026 · Lossless'),
              actions: HeaderFilledButton(
                icon: CupertinoIcons.arrow_down_circle_fill,
                label: 'Download',
                onPressed: () => downloads++,
              ),
            ),
            slivers: const [SliverToBoxAdapter(child: SizedBox(height: 2000))],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Album title').last).dy, 370);
    final banner = tester.getRect(find.byKey(const ValueKey('album-banner')));
    final action = tester.getRect(find.text('Download'));
    expect(banner.top, 0);
    expect(banner.contains(action.bottomRight), isTrue);
    expect(action.center.dy, lessThan(520));
    expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Download'));
    expect(downloads, 1);
    controller.jumpTo(1000);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('Download').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'artist identity grows with text and retains navigation after scroll',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var favorites = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: CustomScrollView(
                  controller: controller,
                  slivers: [
                    ...MornyeArtistHeader(
                      name: 'An artist with a name spanning several lines',
                      showTitle: true,
                      artwork: const ColoredBox(color: Colors.orange),
                      actions: [
                        HeaderCircleButton(
                          icon: Icons.favorite_border,
                          tooltip: 'Favorite',
                          onPressed: () => favorites++,
                        ),
                      ],
                    ).buildSlivers(context),
                    const SliverToBoxAdapter(child: SizedBox(height: 2000)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Favorite'));
      expect(favorites, 1);
      controller.jumpTo(1000);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
