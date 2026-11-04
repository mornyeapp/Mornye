import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:mornye/widgets/mornye_selection_pill.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/screens/settings/settings_tab.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/collection_scaffold.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';
import 'package:mornye/widgets/mornye_bottom_bar.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

void main() {
  late MornyeChromeController chrome;
  late ScrollController scroll;
  late int searches;
  final capture = GlobalKey();

  setUp(() {
    chrome = MornyeChromeController();
    scroll = ScrollController();
    searches = 0;
  });
  tearDown(() {
    chrome.dispose();
    scroll.dispose();
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    bool withPlayer = true,
    bool blur = false,
    bool liquidGlass = true,
    Brightness brightness = Brightness.light,
    Color? backdrop,
    Color? chromeSurface,
    Widget? body,
    double glassClarity = 0.75,
    ValueNotifier<int>? activeTab,
  }) async {
    tester.view.physicalSize = const Size(393, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(
              withPlayer
                  ? const MediaItem(
                      id: 'track',
                      title: 'A song',
                      artist: 'Artist',
                    )
                  : null,
            ),
          ),
          playbackStateProvider.overrideWith((ref) => const Stream.empty()),
          lowEndDeviceProvider.overrideWithValue(!blur),
          backdropBlurEnabledProvider.overrideWithValue(blur),
          mornyeLiquidGlassProvider.overrideWithValue(liquidGlass),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(
            brightness,
            chromeSurface: chromeSurface,
            glassClarity: glassClarity,
          ),
          builder: (_, child) => RepaintBoundary(key: capture, child: child),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            backgroundColor: backdrop,
            extendBody: true,
            body: NotificationListener<ScrollNotification>(
              onNotification: chrome.handleScroll,
              child:
                  body ??
                  ListView.builder(
                    controller: scroll,
                    itemExtent: 60,
                    itemCount: 50,
                    itemBuilder: (_, index) => Text('Row $index'),
                  ),
            ),
            bottomNavigationBar: ListenableBuilder(
              listenable: Listenable.merge([chrome, ?activeTab]),
              builder: (_, _) => MornyeBottomBar(
                collapsed: chrome.value,
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
                  NavigationDestination(
                    icon: Icon(Icons.music_note),
                    label: 'Library',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.grid_view),
                    label: 'Repo',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.search),
                    label: 'Search',
                  ),
                ],
                selectedIndex: activeTab?.value ?? 0,
                onSelected: (index) {
                  activeTab?.value = index;
                  chrome.expand();
                },
                onHome: () {
                  activeTab?.value = 0;
                  chrome.expand();
                },
                onSearch: () {
                  searches++;
                  activeTab?.value = 3;
                },
                blurEnabled: blur,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const albumBlue = Color(0xff464566);

  testWidgets(
    'player and navbar share a backdrop while moving capsules remain isolated',
    (tester) async {
      await pumpShell(tester, blur: true, liquidGlass: false);
      void expectSharedBackdrop({
        // The search capsule crosses the bar; the leading circle is the bar.
        int movingSurfaces = 1,
        int sharedSurfaces = 2,
      }) {
        final filters = find.descendant(
          of: find.byType(MornyeBottomBar),
          matching: find.byType(BackdropFilter),
        );
        final renderers = filters
            .evaluate()
            .map(
              (element) => element.findRenderObject()! as RenderBackdropFilter,
            )
            .toList();
        final shared = renderers
            .where((filter) => filter.backdropKey != null)
            .toList();
        expect(shared, hasLength(sharedSurfaces));
        if (sharedSurfaces == 2) {
          expect(shared[0].backdropKey, same(shared[1].backdropKey));
        }
        // Side capsules overlap the folding tabs and must not join their group.
        expect(
          renderers.where((filter) => filter.backdropKey == null),
          hasLength(movingSurfaces),
        );
      }

      // Invisible side capsules must not paint additional backdrop passes.
      expectSharedBackdrop(movingSurfaces: 0);
      chrome.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 190));
      expectSharedBackdrop();
      await tester.pumpAndSettle();
      expectSharedBackdrop(movingSurfaces: 2, sharedSurfaces: 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final withPlayer in [true, false]) {
    testWidgets(
      'liquid side capsules join the bar read only at rest (player: $withPlayer)',
      (tester) async {
        MornyeGlass.debugShaderFilterSupport = true;
        addTearDown(() => MornyeGlass.debugShaderFilterSupport = null);
        await pumpShell(tester, blur: true, withPlayer: withPlayer);
        // Every painted lens carries a batch key, so each takes the single
        // composed pass, and lenses with the same key share one read.
        List<Element> lenses() => find
            .descendant(
              of: find.byType(MornyeBottomBar),
              matching: find.byType(LiquidGlassLens),
            )
            .evaluate()
            .toList();
        List<int> keys(List<Element> lenses) => [
          for (final lens in lenses) LiquidGlassBatch.backdropIdOf(lens)!,
        ];

        final expanded = keys(lenses());
        expect(expanded, hasLength(withPlayer ? 2 : 1));
        expect(expanded.toSet(), hasLength(1));

        chrome.value = true;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 190));
        final folding = lenses();
        final foldingKeys = keys(folding);
        expect(foldingKeys, hasLength(withPlayer ? 3 : 2));
        // The search capsule crosses the tabs, so it samples on its own.
        expect(foldingKeys.toSet(), hasLength(2));
        expect(
          foldingKeys.where(expanded.contains),
          hasLength(folding.length - 1),
        );

        await tester.pumpAndSettle();
        final resting = lenses();
        expect(resting, hasLength(withPlayer ? 3 : 2));
        expect(keys(resting).toSet(), expanded.toSet());
        // Switching batches reparents the search capsule's lens instead of
        // rebuilding it. The leading circle takes over from the bar only here.
        expect(resting.where(folding.contains), hasLength(withPlayer ? 2 : 1));

        chrome.expand();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 190));
        expect(keys(lenses()).toSet(), hasLength(2));
        await tester.pumpAndSettle();
        expect(keys(lenses()), expanded);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final liquidGlass in [false, true]) {
    testWidgets(
      'navbar keeps its backdrop blurred throughout motion (liquid: $liquidGlass)',
      (tester) async {
        await pumpShell(
          tester,
          blur: true,
          liquidGlass: liquidGlass,
          brightness: Brightness.dark,
          glassClarity: 1,
          body: const SizedBox.expand(
            child: CustomPaint(painter: _StripedBackdrop()),
          ),
        );

        Future<void> expectBlur(Offset center, String phase) async {
          final variation = await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(capture),
            );
            final image = await boundary.toImage();
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final values = <int>[];
            for (var x = -9; x <= 9; x++) {
              final offset =
                  (center.dy.floor() * image.width + center.dx.floor() + x) * 4;
              values.add(bytes.getUint8(offset));
            }
            image.dispose();
            values.sort();
            return values.last - values.first;
          });
          expect(variation, lessThan(20), reason: phase);
        }

        const capsuleSample = Offset(196, 745);
        await expectBlur(capsuleSample, 'Expanded capsule');
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Home').first),
        );
        await gesture.moveBy(const Offset(100, 0));
        await tester.pump(const Duration(milliseconds: 100));
        await expectBlur(capsuleSample, 'Dragging the selected tab');
        await gesture.up();
        await tester.pumpAndSettle();

        for (final collapsed in [true, false]) {
          chrome.value = collapsed;
          await tester.pump();
          if (collapsed) {
            await tester.pump(const Duration(milliseconds: 190));
            // The bar has narrowed past the middle by now.
            await expectBlur(
              tester.getCenter(
                    find.byKey(const ValueKey('mornye-compact-leading')),
                  ) +
                  const Offset(0, 18),
              'Bar halfway to collapsed=$collapsed',
            );
          }
          // Sample below the icons once the growing circles are large enough to
          // expose their backdrop; the page stripes must stay blurred while moving.
          await tester.pump(const Duration(milliseconds: 95));
          for (final key in [
            'mornye-compact-leading',
            'mornye-compact-search',
          ]) {
            final center = tester.getCenter(find.byKey(ValueKey(key)));
            // Just under the icon: a fast circle is squashed along its travel.
            await expectBlur(
              center + const Offset(0, 14),
              '$key moving to collapsed=$collapsed',
            );
          }
          if (!collapsed) {
            await tester.pump(const Duration(milliseconds: 95));
            await expectBlur(
              capsuleSample,
              'Capsule halfway to collapsed=$collapsed',
            );
          }
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final blur in [false, true]) {
    testWidgets('active edge icons and tabs stay synchronized (glass: $blur)', (
      tester,
    ) async {
      final activeTab = ValueNotifier(0);
      addTearDown(activeTab.dispose);
      await pumpShell(
        tester,
        blur: blur,
        activeTab: activeTab,
        brightness: Brightness.dark,
      );
      final scheme = MornyeTheme.build(Brightness.dark).colorScheme;
      final primary = scheme.primary;
      Color? iconColor(String key, IconData data) {
        final icon = find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byIcon(data),
        );
        return IconTheme.of(tester.element(icon)).color;
      }

      for (final (index, label) in [
        (1, 'Library'),
        (2, 'Repo'),
        (3, 'Search'),
        (0, 'Home'),
      ]) {
        await tester.tapAt(
          tester.getCenter(
            find
                .descendant(
                  of: find.byType(MornyeTabBar),
                  matching: find.text(label),
                )
                .first,
          ),
        );
        await tester.pumpAndSettle();
        expect(activeTab.value, index);
        final tabIcons = find.descendant(
          of: find.byType(MornyeTabBar),
          matching: find.byIcon(Icons.home),
        );
        // Edge icons stay in the glass bar's selected/unselected layers at
        // rest, so the pill can reveal their red state during a held drag.
        for (final icon in tabIcons.evaluate()) {
          for (final opacity in tester.widgetList<Opacity>(
            find.ancestor(
              of: find.byElementPredicate((e) => e == icon),
              matching: find.byType(Opacity),
            ),
          )) {
            expect(opacity.opacity, 1);
          }
        }
        expect(
          iconColor('mornye-compact-leading', switch (index) {
            1 => Icons.music_note,
            2 => Icons.grid_view,
            _ => Icons.home,
          }),
          index == 3 ? scheme.onSurface : primary,
        );
        expect(
          iconColor('mornye-compact-search', Icons.search),
          index == 3 ? primary : scheme.onSurface,
        );
        final movingIcon = switch (index) {
          1 => Icons.music_note,
          2 => Icons.grid_view,
          _ => Icons.home,
        };
        final leading = find.byKey(const ValueKey('mornye-compact-leading'));
        final origin = tester.getCenter(
          find.descendant(of: leading, matching: find.byIcon(movingIcon)),
        );
        final originalTabIcon = find
            .descendant(
              of: find.byType(MornyeTabBar),
              matching: find.byIcon(movingIcon),
            )
            .first;
        expect(
          (origin - tester.getCenter(originalTabIcon)).distance,
          lessThan(0.5),
        );
        chrome.value = true;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester
              .widget<MornyeTabBar>(find.byType(MornyeTabBar))
              .hiddenIconIndices,
          {index == 3 ? 0 : index, 3},
        );
        await tester.pumpAndSettle();
        expect(
          iconColor('mornye-compact-leading', movingIcon),
          index == 3 ? scheme.onSurface : primary,
        );
        expect(
          iconColor('mornye-compact-search', Icons.search),
          index == 3 ? primary : scheme.onSurface,
        );
        expect(
          tester.widget<IconButton>(leading).tooltip,
          index == 3 ? 'Home' : label,
        );
        await tester.tap(leading);
        await tester.pumpAndSettle();
        expect(activeTab.value, index == 3 ? 0 : index);
        expect(chrome.value, isFalse);
        activeTab.value = index;
        chrome.expand();
        await tester.pumpAndSettle();
        expect(
          tester.widget<MornyeTabBar>(find.byType(MornyeTabBar)).selectedIndex,
          index,
        );
      }
    });

    testWidgets(
      'edge icons travel continuously without fading (glass: $blur)',
      (tester) async {
        await pumpShell(tester, blur: blur);
        final homeButton = find.byKey(const ValueKey('mornye-compact-leading'));
        final icon = find.descendant(
          of: homeButton,
          matching: find.byIcon(Icons.home),
        );
        final element = tester.element(icon);
        final tabIcon = find
            .descendant(
              of: find.byType(MornyeTabBar),
              matching: find.byIcon(Icons.home),
            )
            .first;
        final start = tester.getCenter(icon);
        expect((start - tester.getCenter(tabIcon)).distance, lessThan(0.5));
        chrome.value = true;
        await tester.pump();
        var previous = start;
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.element(icon), same(element));
          for (final opacity in tester.widgetList<Opacity>(
            find.ancestor(of: icon, matching: find.byType(Opacity)),
          )) {
            expect(opacity.opacity, 1);
          }
          final center = tester.getCenter(icon);
          expect((center - previous).distance, lessThan(8));
          previous = center;
        }
        expect(previous.dx, lessThan(start.dx));
        chrome.expand();
        await tester.pumpAndSettle();
        expect(tester.element(icon), same(element));
        expect((tester.getCenter(icon) - start).distance, lessThan(0.5));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Search joins full tabs and separates when compact (glass: $blur)',
      (tester) async {
        await pumpShell(tester, blur: blur);
        final tabs = find.byType(MornyeTabBar);
        final search = find.byKey(const ValueKey('mornye-compact-search'));
        final repo = find
            .descendant(of: tabs, matching: find.text('Repo'))
            .first;
        expect(tester.widget<MornyeTabBar>(tabs).destinations, hasLength(4));
        final searchLabel = find
            .descendant(of: tabs, matching: find.text('Search'))
            .first;
        expect(
          find.descendant(of: tabs, matching: find.text('Search')),
          findsWidgets,
        );
        expect(
          find.descendant(of: tabs, matching: find.text('Settings')),
          findsNothing,
        );
        expect(
          tester.getCenter(search).dx,
          greaterThan(tester.getCenter(repo).dx),
        );
        expect(
          tester.getSize(tabs).width,
          tester.getSize(find.byType(MornyeBottomBar)).width,
        );
        final searchIcon = find
            .descendant(of: tabs, matching: find.byIcon(Icons.search))
            .first;
        expect(
          (tester.getCenter(search) - tester.getCenter(searchIcon)).distance,
          lessThan(0.5),
        );
        // The glass renderer paints the labels under a gesture overlay.
        await tester.tapAt(tester.getCenter(searchLabel));
        await tester.pumpAndSettle();
        expect(searches, 1);
        chrome.value = true;
        await tester.pumpAndSettle();
        expect(tester.getSize(search), const Size(52, 52));
        await tester.tap(search);
        expect(searches, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final withPlayer in [false, true]) {
    testWidgets('compact transition has no height jump (player: $withPlayer)', (
      tester,
    ) async {
      await pumpShell(tester, withPlayer: withPlayer);
      final bar = find.byType(MornyeBottomBar);
      var previousHeight = tester.getSize(bar).height;
      final playerState = withPlayer
          ? tester.state(find.byType(MiniPlayer))
          : null;
      chrome.value = true;
      await tester.pump();
      Offset? firstHomeCenter;
      for (var frame = 0; frame < 25; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final height = tester.getSize(bar).height;
        expect(height, lessThanOrEqualTo(previousHeight + 0.01));
        previousHeight = height;
        firstHomeCenter ??= tester.getCenter(
          find.byKey(const ValueKey('mornye-compact-leading')),
        );
      }
      final homeCenter = tester.getCenter(
        find.byKey(const ValueKey('mornye-compact-leading')),
      );
      expect((homeCenter.dy - firstHomeCenter!.dy).abs(), lessThan(20));
      expect(find.byTooltip('Home').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Search').hitTestable(), findsOneWidget);
      if (withPlayer) {
        expect(tester.state(find.byType(MiniPlayer)), same(playerState));
      }
      chrome.expand();
      await tester.pump();
      for (var frame = 0; frame < 25; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final height = tester.getSize(bar).height;
        expect(height, greaterThanOrEqualTo(previousHeight - 0.01));
        previousHeight = height;
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    for (final clarity in [0.0, 0.75, 1.0]) {
      for (final backdrop in [
        Colors.white,
        Colors.black,
        if (brightness == Brightness.dark) albumBlue,
      ]) {
        testWidgets(
          'floating glass stays legible in $brightness over $backdrop (clarity: $clarity)',
          (tester) async {
            await pumpShell(
              tester,
              blur: true,
              brightness: brightness,
              glassClarity: clarity,
              backdrop: backdrop,
              chromeSurface: backdrop == albumBlue ? albumBlue : null,
            );
            final artist = find.text('Artist');
            final libraryIcon = find
                .descendant(
                  of: find.byType(MornyeTabBar),
                  matching: find.byIcon(Icons.music_note),
                )
                .first;
            final artistRect = tester.getRect(artist);
            final iconRect = tester.getRect(libraryIcon);
            final foregrounds = [
              tester.widget<Text>(artist).style!.color!,
              IconTheme.of(tester.element(libraryIcon)).color!,
            ];
            final samples = [
              Offset(artistRect.left + 8, artistRect.bottom + 2),
              Offset(iconRect.right + 8, iconRect.center.dy),
            ];
            final backgrounds = await tester.runAsync(() async {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(capture),
              );
              final image = await boundary.toImage();
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              final colors = <Color>[];
              for (final point in samples) {
                final offset =
                    (point.dy.floor() * image.width + point.dx.floor()) * 4;
                colors.add(
                  Color.fromARGB(
                    bytes.getUint8(offset + 3),
                    bytes.getUint8(offset),
                    bytes.getUint8(offset + 1),
                    bytes.getUint8(offset + 2),
                  ),
                );
              }
              image.dispose();
              return colors;
            });
            for (var index = 0; index < foregrounds.length; index++) {
              if (backdrop == albumBlue) {
                final glass = HSLColor.fromColor(backgrounds![index]);
                final page = HSLColor.fromColor(albumBlue);
                expect(glass.hue, closeTo(page.hue, 8));
                expect(glass.saturation, greaterThan(page.saturation * 0.7));
              }
              final luminances = [
                foregrounds[index].computeLuminance(),
                backgrounds![index].computeLuminance(),
              ]..sort();
              final contrast =
                  (luminances.last + 0.05) / (luminances.first + 0.05);
              expect(
                contrast,
                greaterThanOrEqualTo(index == 0 ? 4.5 : 3),
                reason: index == 0 ? 'Mini-player artist' : 'Inactive tab icon',
              );
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('downward scroll folds the tabs without replacing the player', (
    tester,
  ) async {
    await pumpShell(tester);
    final playerState = tester.state(find.byType(MiniPlayer));
    final expandedHeight = tester.getSize(find.byType(MornyeBottomBar)).height;
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(chrome.value, isTrue);
    expect(tester.state(find.byType(MiniPlayer)), same(playerState));
    expect(tester.widget<MiniPlayer>(find.byType(MiniPlayer)).compact, isTrue);
    expect(
      tester.getSize(find.byType(MornyeBottomBar)).height,
      lessThan(expandedHeight - 60),
    );
    expect(find.byTooltip('Next track'), findsNothing);
    await tester.tap(find.byTooltip('Home'));
    await tester.pumpAndSettle();
    expect(chrome.value, isFalse);
    expect(tester.getSize(find.byType(MornyeBottomBar)).height, expandedHeight);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'collapse keeps the player and tab contents out of frame rebuilds',
    (tester) async {
      await pumpShell(tester);
      var tabBuilds = 0;
      var playerBuilds = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (element.widget is MornyeTabBar) tabBuilds++;
        if (element.widget is MiniPlayer) playerBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      chrome.value = true;
      await tester.pump();
      for (var frame = 0; frame < 25; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        tabBuilds,
        lessThanOrEqualTo(2),
        reason: 'Only the wrapper geometry animates each frame',
      );
      expect(
        playerBuilds,
        lessThanOrEqualTo(2),
        reason:
            'The player rebuilds for compact mode, not for every animation tick',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('folding chrome updates the spacer without rebuilding Settings', (
    tester,
  ) async {
    await pumpShell(tester, body: const SettingsTab(), blur: true);
    var settingsBuilds = 0;
    var spacerBuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (element.widget is SettingsTab) settingsBuilds++;
      if (element.widget is NavBarSliverSpacer) spacerBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);

    for (final collapsed in [true, false]) {
      chrome.value = collapsed;
      await tester.pump();
      for (var frame = 0; frame < 25; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    expect(settingsBuilds, 0);
    expect(spacerBuilds, greaterThan(20));
    expect(tester.takeException(), isNull);
  });

  for (final artist in [true, false]) {
    testWidgets('folding chrome isolates header insets (artist: $artist)', (
      tester,
    ) async {
      var pageBuilds = 0;
      await pumpShell(
        tester,
        body: Builder(
          builder: (context) {
            pageBuilds++;
            final tracks = SliverFixedExtentList.builder(
              itemExtent: 60,
              itemCount: 50,
              itemBuilder: (_, index) => Text('Track $index'),
            );
            if (artist) {
              return CustomScrollView(
                controller: scroll,
                slivers: [
                  ...const MornyeArtistHeader(
                    name: 'Artist',
                    showTitle: false,
                    artwork: ColoredBox(color: Colors.blue),
                    actions: [],
                  ).buildSlivers(context),
                  tracks,
                  const NavBarSliverSpacer(),
                ],
              );
            }
            return CollectionScaffold(
              scrollController: scroll,
              isSelectionMode: false,
              onExitSelectionMode: () {},
              appBar: const AlbumDetailHeader(
                title: 'Album',
                expandedHeight: 400,
                immersive: true,
                showTitleInAppBar: false,
                background: ColoredBox(color: Colors.blue),
              ),
              slivers: [tracks],
            );
          },
        ),
      );
      pageBuilds = 0;
      var collectionBuilds = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (element.widget is CollectionScaffold) collectionBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      for (final collapsed in [true, false]) {
        chrome.value = collapsed;
        await tester.pump();
        for (var frame = 0; frame < 25; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      expect(pageBuilds, 0);
      expect(collectionBuilds, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'compact tabs survive upward scrolling until the page returns to the top',
    (tester) async {
      await pumpShell(tester);
      scroll.jumpTo(500);
      await tester.pumpAndSettle();
      expect(chrome.value, isFalse);
      await tester.drag(find.byType(ListView), const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(chrome.value, isFalse);
      await tester.drag(find.byType(ListView), const Offset(0, -160));
      await tester.pumpAndSettle();
      expect(chrome.value, isTrue);
      await tester.drag(find.byType(ListView), const Offset(0, 90));
      await tester.pumpAndSettle();
      expect(chrome.value, isTrue);
      await tester.drag(find.byType(ListView), const Offset(0, 900));
      await tester.pumpAndSettle();
      expect(chrome.value, isFalse);
    },
  );

  testWidgets('Library keeps compact tabs until the outer header returns', (
    tester,
  ) async {
    await pumpShell(
      tester,
      body: NestedScrollView(
        headerSliverBuilder: (_, _) => const [
          SliverAppBar(expandedHeight: 180, title: Text('Library')),
        ],
        body: PageView(
          children: [
            ListView.builder(
              itemExtent: 60,
              itemCount: 60,
              itemBuilder: (_, index) => Text('Track $index'),
            ),
          ],
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(chrome.value, isTrue);
    await tester.drag(find.byType(ListView), const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(chrome.value, isTrue);
    await tester.drag(find.byType(ListView), const Offset(0, 900));
    await tester.pumpAndSettle();
    expect(chrome.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'glass bar stays mounted and pauses its tickers while collapsed',
    (tester) async {
      await pumpShell(tester, blur: true);
      final glass = tester.element(find.byType(MornyeSelectionPill));
      final player = tester.state(find.byType(MiniPlayer));
      expect(TickerMode.valuesOf(glass).enabled, isTrue);
      chrome.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(MornyeSelectionPill), findsNothing);
      expect(
        tester.element(find.byType(MornyeSelectionPill, skipOffstage: false)),
        same(glass),
      );
      expect(TickerMode.valuesOf(glass).enabled, isFalse);
      chrome.expand();
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(MornyeSelectionPill)), same(glass));
      expect(tester.state(find.byType(MiniPlayer)), same(player));
      expect(TickerMode.valuesOf(glass).enabled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact navigation works without a playing track', (
    tester,
  ) async {
    await pumpShell(tester, withPlayer: false);
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(chrome.value, isTrue);
    await tester.tap(find.byTooltip('Search'));
    expect(searches, 1);
    await tester.tap(find.byTooltip('Home'));
    await tester.pumpAndSettle();
    expect(chrome.value, isFalse);
    expect(tester.takeException(), isNull);
  });
}

class _StripedBackdrop extends CustomPainter {
  const _StripedBackdrop();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    // Clear glass uses a small blur; fine stripes still reveal a lost backdrop
    // during transforms without requiring the old heavily frosted appearance.
    for (var x = 0.0; x < size.width; x += 2) {
      paint.color = (x / 2).round().isEven ? Colors.white : Colors.black;
      canvas.drawRect(Rect.fromLTWH(x, 0, 2, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_StripedBackdrop oldDelegate) => false;
}
