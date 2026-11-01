import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/library_mix_screen.dart';
import 'package:mornye/services/library_mixes.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/library_mix_cover.dart';
import 'package:mornye/widgets/library_track_selection_bar.dart';
import 'package:mornye/widgets/track_card.dart';

import 'support/fixed_settings.dart';

final _items = [
  for (var i = 0; i < 24; i++)
    UnifiedLibraryItem.fromLocalLibrary(
      LocalLibraryItem(
        id: 'song$i',
        trackName: 'Song $i',
        artistName: i.isEven ? 'Tyler, The Creator' : 'Frank Ocean',
        albumName: 'Album ${i % 5}',
        filePath: '/music/song$i.flac',
        scannedAt: DateTime(2026, 10, 27),
        duration: 180,
      ),
    ),
];

final _mix = LibraryMixView(
  mix: LibraryMix(
    kind: LibraryMixKind.genre,
    key: 'hiphop',
    label: 'Hip-Hop',
    artists: const ['Tyler, The Creator', 'Frank Ocean'],
    songIds: [for (final item in _items) item.id],
  ),
  items: _items,
);

void main() {
  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      testWidgets('Home lists the mixes and opens one '
          '(desktop: $desktop, Mornye: $mornye)', (tester) async {
        debugDesktopPlatformOverride = desktop;
        addTearDown(() => debugDesktopPlatformOverride = null);
        tester.view.physicalSize = desktop
            ? const Size(1280, 800)
            : const Size(430, 932);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await _pumpHome(tester, mornye: mornye, mixes: [_mix]);

        final title = find.text('Hip-Hop Mix');
        await tester.scrollUntilVisible(
          title,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        // Rows take taps again once the scroll comes to rest.
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Mixes for you'), findsOneWidget);
        expect(find.text('Tyler, The Creator and Frank Ocean'), findsOneWidget);
        expect(find.byType(LibraryMixCover), findsOneWidget);

        await tester.tap(title);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(LibraryMixScreen), findsOneWidget);
        expect(find.text('Hip-Hop Mix'), findsWidgets);
        expect(find.textContaining('Made from your Library'), findsOneWidget);
        expect(find.text('Song 0'), findsOneWidget);
        if (desktop) {
          expect(find.byType(SliverTrackTable), findsOneWidget);
        } else {
          expect(find.byType(TrackCard), findsWidgets);
          expect(find.byTooltip('Save as playlist'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final mornye in [false, true]) {
    testWidgets('a long press on a phone row selects songs for the Library '
        'actions (Mornye: $mornye)', (tester) async {
      debugDesktopPlatformOverride = false;
      addTearDown(() => debugDesktopPlatformOverride = null);
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pumpMix(tester, mornye: mornye);
      expect(find.byType(LibraryTrackSelectionBar), findsNothing);

      final first = find.text('Song 0');
      await tester.scrollUntilVisible(
        first,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.longPress(first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LibraryTrackSelectionBar), findsOneWidget);
      expect(find.text('1 selected'), findsOneWidget);
      final cards = tester
          .widgetList<TrackCard>(find.byType(TrackCard))
          .toList();
      expect(cards.first.isSelectionMode, isTrue);
      expect(cards.first.isSelected, isTrue);

      // In selection mode a tap adds the song instead of playing it. The
      // bar follows a frame later, from its overlay.
      await tester.tap(find.text('Song 1'));
      await tester.pump();
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.text('Song 1'));
      await tester.pump();
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Home leaves the section out without mixes', (tester) async {
    await _pumpHome(tester, mornye: false, mixes: const []);
    expect(find.text('Shortcuts'), findsOneWidget);
    expect(find.text('Mixes for you'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixes arriving later open below Shortcuts', (tester) async {
    late ProviderContainer container;
    await _pumpHome(
      tester,
      mornye: false,
      mixesProvider: (ref) async => ref.watch(_arrivingMixes),
      onContainer: (value) => container = value,
    );
    expect(find.text('Mixes for you'), findsNothing);
    final shortcutsBottom = tester.getBottomLeft(find.text('Shortcuts')).dy;

    container.read(_arrivingMixes.notifier).arrive([_mix]);
    await tester.pump();
    await tester.pump();
    final title = find.text('Mixes for you', skipOffstage: false);
    expect(title, findsOneWidget);
    final section = find.ancestor(
      of: title,
      matching: find.byType(AnimatedSize),
    );
    final opening = tester.getSize(section.first).height;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    final open = tester.getSize(section.first).height;
    // Home's sections open the space rather than letting it jump in.
    expect(opening, lessThan(open));
    expect(tester.getTopLeft(title).dy, greaterThan(shortcutsBottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixes wait until startup settles', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settled = container.listen(libraryMixesStartupProvider, (_, _) {});
    expect(settled.read(), isFalse);
    // The first frame starts the wait.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(libraryMixesStartupDelay - const Duration(seconds: 1));
    expect(settled.read(), isFalse);
    // Nothing animates, so the next idle check settles it.
    await tester.pump(const Duration(seconds: 3));
    expect(settled.read(), isTrue);
  });

  testWidgets('an endless animation delays the mixes only so long', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settled = container.listen(libraryMixesStartupProvider, (_, _) {});
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: CircularProgressIndicator())),
    );
    await tester.pump(libraryMixesStartupDelay + const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 16));
    expect(settled.read(), isFalse);
    await tester.pump(libraryMixesIdleTimeout);
    expect(settled.read(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  test('mix names follow their kind, in the app language', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    LibraryMix mix(
      LibraryMixKind kind,
      String key, {
      String label = '',
      List<String> artists = const ['A', 'B', 'C'],
    }) => LibraryMix(
      kind: kind,
      key: key,
      label: label,
      artists: artists,
      songIds: const [],
    );
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.favorites, 'favorites')),
      'Favorites Mix',
    );
    // A family takes its translated name, whatever label was cached.
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.genre, 'hiphop', label: 'x')),
      'Hip-Hop Mix',
    );
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.genre, 'indie')),
      'Indie & Alternative Mix',
    );
    // A tag outside the families keeps its own spelling.
    expect(
      libraryMixTitle(
        l10n,
        mix(LibraryMixKind.genre, 'tag:sundanese', label: 'Sundanese'),
      ),
      'Sundanese Mix',
    );
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.decade, '1990', label: '1990')),
      '1990s Mix',
    );
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.fresh, 'fresh')),
      'New Additions Mix',
    );
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.rediscover, 'rediscover')),
      'Rediscover Mix',
    );
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.discover, 'discover')),
      'Discover Mix',
    );
    expect(
      libraryMixTitle(
        l10n,
        mix(LibraryMixKind.artist, 'frank ocean', label: 'Frank Ocean'),
      ),
      'Frank Ocean Mix',
    );
    for (final family in [
      'hiphop',
      'rnb',
      'pop',
      'kpop',
      'jpop',
      'rock',
      'metal',
      'punk',
      'indie',
      'electronic',
      'chill',
      'jazz',
      'blues',
      'classical',
      'soundtrack',
      'country',
      'folk',
      'latin',
      'reggae',
      'afro',
      'gospel',
      'dangdut',
    ]) {
      expect(
        libraryGenreFamilyName(l10n, family),
        libraryGenreFamilyLabel(family),
        reason: family,
      );
    }
    expect(libraryGenreFamilyName(l10n, 'tag:sundanese'), isNull);

    String subtitle(List<String> artists) => libraryMixSubtitle(
      l10n,
      mix(LibraryMixKind.genre, 'pop', artists: artists),
    );
    expect(subtitle(const ['A']), 'A');
    expect(subtitle(const ['A', 'B']), 'A and B');
    expect(subtitle(const ['A', 'B', 'C']), 'A, B and more');
    expect(subtitle(const []), isEmpty);
  });
}

Future<void> _pumpMix(WidgetTester tester, {required bool mornye}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(const AppSettings()),
        ),
        downloadHistoryProvider.overrideWith(_History.new),
      ],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LibraryMixScreen(view: _mix),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required bool mornye,
  List<LibraryMixView> mixes = const [],
  Future<List<LibraryMixView>> Function(Ref ref)? mixesProvider,
  void Function(ProviderContainer container)? onContainer,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(
            const AppSettings(
              searchProvider: 'example',
              homeFeedProvider: AppSettings.homeFeedProviderOff,
              hasSearchedBefore: true,
            ),
          ),
        ),
        extensionProvider.overrideWith(_Extensions.new),
        exploreProvider.overrideWith(_Explore.new),
        downloadHistoryProvider.overrideWith(_History.new),
        recentAccessProvider.overrideWith(_Recent.new),
        libraryMixesProvider.overrideWith(
          mixesProvider ?? (ref) async => mixes,
        ),
      ],
      child: Consumer(
        builder: (context, ref, child) {
          onContainer?.call(ProviderScope.containerOf(context));
          return child!;
        },
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HomeTab(
            mode: mornye ? HomeTabMode.browse : HomeTabMode.combined,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Mixes that are built after Home is shown.
final _arrivingMixes = NotifierProvider<_ArrivingMixes, List<LibraryMixView>>(
  _ArrivingMixes.new,
);

class _ArrivingMixes extends Notifier<List<LibraryMixView>> {
  @override
  List<LibraryMixView> build() => const [];

  void arrive(List<LibraryMixView> mixes) => state = mixes;
}

/// Extensions still starting, so Home neither waits for a feed nor asks for
/// a search provider.
class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

class _Explore extends ExploreNotifier {
  @override
  ExploreState build() => const ExploreState();

  @override
  Future<void> fetchHomeFeed({bool forceRefresh = false}) async {}
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
}
