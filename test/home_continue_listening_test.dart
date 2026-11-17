import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/weekly_releases_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/weekly_releases_screen.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/weekly_releases.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

const _cover = 'network://nas/Album/cover.jpg';

/// The Material Home without a feed, resuming a saved song unless
/// [saved] is false.
Widget _home({
  bool saved = true,
  bool card = true,
  List<WeeklyRelease> releases = const [],
}) => ProviderScope(
  overrides: [
    homeNewReleasesProvider.overrideWith((ref) => Stream.value(releases)),
    weeklyReleasesProvider.overrideWith(
      (ref, refresh) async => WeeklyReleaseFeed(releases),
    ),
    settingsProvider.overrideWith(
      () => FixedSettingsNotifier(
        AppSettings(
          searchProvider: 'example',
          homeFeedProvider: AppSettings.homeFeedProviderOff,
          hasSearchedBefore: true,
          homeContinueListening: card,
        ),
      ),
    ),
    extensionProvider.overrideWith(_Extensions.new),
    exploreProvider.overrideWith(_Explore.new),
    downloadHistoryProvider.overrideWith(_History.new),
    recentAccessProvider.overrideWith(_Recent.new),
    libraryMixesProvider.overrideWith((ref) async => const []),
    playerUiEnabledProvider.overrideWithValue(true),
    currentMediaItemProvider.overrideWithBuild(
      (ref, notifier) => Stream<MediaItem?>.value(null),
    ),
    playbackResumeProvider.overrideWith(
      (ref) async => saved
          ? (
              media: const PlayableMedia(
                id: 'network://nas/Album/song.flac',
                source: 'network://nas/Album/song.flac',
                title: 'Saved song',
                artist: 'Artist',
                networkArtworkSource: _cover,
              ),
              position: const Duration(seconds: 23),
            )
          : null,
    ),
  ],
  child: MaterialApp(
    theme: AppTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const HomeTab(mode: HomeTabMode.combined),
  ),
);

/// Opens [_home] in a [width] wide window, as the desktop app when
/// [desktop] is true.
Future<void> _open(
  WidgetTester tester, {
  required bool desktop,
  double width = 1280,
  bool saved = true,
  bool card = true,
  List<WeeklyRelease> releases = const [],
}) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  debugDesktopPlatformOverride = desktop;
  addTearDown(() => debugDesktopPlatformOverride = null);
  await tester.pumpWidget(_home(saved: saved, card: card, releases: releases));
  await tester.pump();
  await tester.pump();
}

/// Lets a menu, sheet or route finish opening. Home keeps an animation
/// running, so it never settles; short frames let the menu spring run.
Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('Continue listening shows a network cover not stored yet', (
    tester,
  ) async {
    const cover = _cover;
    await tester.pumpWidget(_home());
    await tester.pump();
    await tester.pump();

    final card = find.ancestor(
      of: find.text('Saved song'),
      matching: find.byType(InkWell),
    );
    final artwork = find.descendant(
      of: card.first,
      matching: find.byType(PlayerArtwork),
    );
    expect(tester.widget<PlayerArtwork>(artwork).artUri, cover);
  });

  testWidgets('desktop Home sets the shortcuts beside Continue listening', (
    tester,
  ) async {
    await _open(tester, desktop: true);
    expect(tester.takeException(), isNull);

    final continueHeader = tester.getRect(find.text('Continue listening'));
    final shortcutsHeader = tester.getRect(find.text('Shortcuts'));
    expect(shortcutsHeader.top, continueHeader.top);
    expect(shortcutsHeader.left, greaterThan(continueHeader.left + 400));

    // The shortcuts stack in one list as tall as the card beside it.
    final card = tester.getRect(
      find
          .ancestor(of: find.text('Saved song'), matching: find.byType(InkWell))
          .first,
    );
    final first = tester.getRect(
      find
          .ancestor(
            of: find.text('Shuffle library'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    final last = tester.getRect(
      find
          .ancestor(
            of: find.text('Network storage'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(first.left, last.left);
    expect(first.top, card.top);
    expect(last.bottom, card.bottom);
    expect(first.height, greaterThanOrEqualTo(48));
  });

  testWidgets('desktop Home stacks both sections in a narrow pane', (
    tester,
  ) async {
    await _open(tester, desktop: true, width: 700);
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.text('Shortcuts')).top,
      greaterThan(tester.getRect(find.text('Saved song')).bottom),
    );
    // One row of shortcuts.
    expect(
      tester.getRect(find.text('Network storage')).top,
      tester.getRect(find.text('Shuffle library')).top,
    );
  });

  testWidgets('desktop Home without a session shows the shortcuts in a row', (
    tester,
  ) async {
    await _open(tester, desktop: true, saved: false);
    expect(tester.takeException(), isNull);
    expect(find.text('Continue listening'), findsNothing);
    // Labels may wrap; the tiles share one row and one height.
    final tiles = {
      for (final label in [
        'Shuffle library',
        'Equalizer',
        'Listening statistics',
        'Network storage',
      ])
        tester.getRect(
          find
              .ancestor(of: find.text(label), matching: find.byType(InkWell))
              .first,
        ),
    };
    expect({for (final tile in tiles) (tile.top, tile.height)}, hasLength(1));
  });

  testWidgets('phones keep two columns of shortcuts under the card', (
    tester,
  ) async {
    await _open(tester, desktop: false, width: 400);
    expect(tester.takeException(), isNull);
    final shuffle = tester.getRect(find.text('Shuffle library'));
    expect(tester.getRect(find.text('Equalizer')).top, shuffle.top);
    expect(
      tester.getRect(find.text('Listening statistics')).top,
      greaterThan(shuffle.bottom),
    );
    expect(
      tester.getRect(find.text('Shortcuts')).top,
      greaterThan(tester.getRect(find.text('Saved song')).bottom),
    );
  });

  for (final desktop in [false, true]) {
    testWidgets('Continue listening can be left off Home '
        '(${desktop ? 'desktop' : 'phone'})', (tester) async {
      await _open(
        tester,
        desktop: desktop,
        width: desktop ? 1280 : 400,
        card: false,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Continue listening'), findsNothing);
      expect(find.text('Saved song'), findsNothing);
      expect(find.text('Shuffle library'), findsOneWidget);
    });
  }

  testWidgets('a long press changes a shortcut and Reset restores them', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _open(tester, desktop: false, width: 400);

    await tester.longPress(find.text('Equalizer'));
    await _settle(tester);
    await tester.tap(find.text('Change shortcut'));
    await _settle(tester);
    expect(
      find.text('A shortcut already on Home swaps places with this one'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Loved'));
    await _settle(tester);
    await tester.tap(find.text('Loved'));
    await _settle(tester);

    // Loved takes the Equalizer's place beside Shuffle.
    expect(find.text('Equalizer'), findsNothing);
    expect(
      tester.getRect(find.text('Loved')).top,
      tester.getRect(find.text('Shuffle library')).top,
    );

    await tester.longPress(find.text('Loved'));
    await _settle(tester);
    await tester.tap(find.text('Reset shortcuts'));
    await _settle(tester);
    expect(find.text('Loved'), findsNothing);
    expect(find.text('Equalizer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a right-click opens the shortcut menu on desktop', (
    tester,
  ) async {
    await _open(tester, desktop: true);
    await _settle(tester);
    final click = await tester.startGesture(
      tester.getCenter(find.text('Network storage')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await click.up();
    await _settle(tester);
    expect(find.text('Change shortcut'), findsOneWidget);
    expect(find.text('Reset shortcuts'), findsOneWidget);
  });

  testWidgets('new releases show as a shelf that opens the full list', (
    tester,
  ) async {
    await _open(
      tester,
      desktop: false,
      width: 400,
      releases: [
        WeeklyRelease(
          id: 'release-1',
          name: 'Example release',
          artist: 'Example artist',
          providerId: 'example',
          date: DateTime(2026, 10, 2),
        ),
      ],
    );
    await tester.pump();
    expect(find.text('Example release'), findsOneWidget);
    expect(find.text('Example artist'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.ensureVisible(find.text('New releases'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('New releases'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(WeeklyReleasesScreen), findsOneWidget);
  });

  testWidgets('no releases leave no heading', (tester) async {
    await _open(tester, desktop: false, width: 400);
    expect(find.text('New releases'), findsNothing);
  });
}

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
