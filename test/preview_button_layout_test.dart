import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/preview_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/preview_button.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';

import 'support/app_icon_finder.dart';

void main() {
  const track = Track(
    id: 'track-1',
    name: 'Track',
    artistName: 'Artist',
    albumName: 'Album',
    previewUrl: 'https://example.com/preview.mp3',
    duration: 180,
  );
  const sparseSearchTrack = Track(
    id: 'search-track',
    name: 'Search Track',
    artistName: 'Artist',
    albumName: '',
    duration: 180,
    source: 'metadata-extension',
  );

  Future<void> pumpButton(
    WidgetTester tester, {
    MediaItem? currentItem,
    bool overArtwork = false,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(currentItem),
          ),
          playbackPlayingProvider.overrideWith((ref) => false),
        ],
        child: MaterialApp(
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PreviewButton(track: track, overArtwork: overArtwork),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  void expectCenteredHitbox(WidgetTester tester, IconData iconData) {
    // M3EIconButton builds an IconButton inside; measure the outer button.
    final button = find
        .byWidgetPredicate(
          (widget) => widget is IconButton || widget is M3EIconButton,
        )
        .first;
    final icon = findAppIcon(iconData);
    final hitbox = tester.getRect(button);

    expect(hitbox.width, greaterThanOrEqualTo(48));
    expect(hitbox.height, greaterThanOrEqualTo(48));
    expect(tester.getCenter(icon), hitbox.center);
  }

  for (final current in [false, true]) {
    testWidgets('Material fills the button on a cover (current: $current)', (
      tester,
    ) async {
      await pumpButton(
        tester,
        overArtwork: true,
        currentItem: current
            ? const MediaItem(id: 'current', title: 'Track', artist: 'Artist')
            : null,
      );
      await tester.pump();
      expect(findAppIcon(Icons.play_arrow), findsOneWidget);
      expect(findAppIcon(Icons.play_circle_outline_rounded), findsNothing);
      expect(findAppIcon(Icons.play_circle_fill_rounded), findsNothing);
      expectCenteredHitbox(tester, Icons.play_arrow);
    });
  }

  testWidgets('Mornye keeps its own button on a cover', (tester) async {
    await pumpButton(
      tester,
      overArtwork: true,
      theme: MornyeTheme.build(Brightness.dark),
    );
    expect(findAppIcon(Icons.play_arrow), findsNothing);
  });

  testWidgets('preview icon is centered inside its 48dp hitbox', (
    tester,
  ) async {
    await pumpButton(tester);
    expectCenteredHitbox(tester, Icons.play_circle_outline_rounded);
  });

  testWidgets('a link that did not play is not offered again', (tester) async {
    await pumpButton(tester);
    expect(findAppIcon(Icons.play_circle_outline_rounded), findsOneWidget);

    ProviderScope.containerOf(
      tester.element(find.byType(PreviewButton)),
    ).read(previewUnavailableLinksProvider.notifier).add(track.previewUrl!);
    await tester.pump();
    expect(findAppIcon(Icons.play_circle_outline_rounded), findsNothing);
  });

  testWidgets('current-track play icon uses the same centered hitbox', (
    tester,
  ) async {
    await pumpButton(
      tester,
      currentItem: const MediaItem(
        id: 'track-1',
        title: 'Track',
        artist: 'Artist',
      ),
    );
    expectCenteredHitbox(tester, Icons.play_circle_fill_rounded);
  });

  testWidgets('preview progress does not rebuild track buttons', (
    tester,
  ) async {
    final player = _TestPreviewPlayer();
    var builds = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(null),
          ),
          previewPlayerProvider.overrideWith(() => player),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: _CountingPreviewButton(track: track, onBuild: () => builds++),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    player.emit(
      PreviewPlayerState(
        activeUrl: track.previewUrl,
        status: PreviewStatus.playing,
      ),
    );
    await tester.pump();
    expect(findAppIcon(Icons.pause_circle_filled_rounded), findsOneWidget);
    final playingBuilds = builds;
    for (var second = 1; second <= 3; second++) {
      player.emit(
        PreviewPlayerState(
          activeUrl: track.previewUrl,
          status: PreviewStatus.playing,
          position: Duration(seconds: second),
          duration: const Duration(seconds: 30),
        ),
      );
      await tester.pump();
    }
    expect(builds, playingBuilds);

    player.emit(
      PreviewPlayerState(
        activeUrl: track.previewUrl,
        status: PreviewStatus.paused,
      ),
    );
    await tester.pump();
    expect(findAppIcon(Icons.play_circle_fill_rounded), findsOneWidget);
    expect(builds, playingBuilds + 1);

    player.emit(
      const PreviewPlayerState(
        activeUrl: 'https://example.com/another-preview.mp3',
        status: PreviewStatus.playing,
      ),
    );
    await tester.pump();
    expect(findAppIcon(Icons.play_circle_outline_rounded), findsOneWidget);
  });

  testWidgets('overflow menu icon is centered in its adjacent hitbox', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: TrackCollectionQuickActions(track: track)),
        ),
      ),
    );
    await tester.pump();

    expectCenteredHitbox(tester, Icons.more_vert);
  });

  testWidgets('track options expose Go to Album for album tracks', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_TestSettingsNotifier.new),
          libraryCollectionsProvider.overrideWith(
            _TestLibraryCollectionsNotifier.new,
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: TrackCollectionQuickActions(track: track)),
        ),
      ),
    );

    await tester.tap(findAppIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text('Go to Album'), findsOneWidget);
    expect(findAppIcon(Icons.album_outlined), findsOneWidget);
  });

  testWidgets(
    'search track options keep Go to Album when album data is sparse',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_TestSettingsNotifier.new),
            libraryCollectionsProvider.overrideWith(
              _TestLibraryCollectionsNotifier.new,
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: TrackCollectionQuickActions(track: sparseSearchTrack),
            ),
          ),
        ),
      );

      await tester.tap(findAppIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('Go to Album'), findsOneWidget);
      expect(findAppIcon(Icons.album_outlined), findsOneWidget);
    },
  );
}

class _TestSettingsNotifier extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _TestPreviewPlayer extends PreviewPlayerController {
  @override
  PreviewPlayerState build() => const PreviewPlayerState();

  void emit(PreviewPlayerState next) => state = next;
}

class _CountingPreviewButton extends PreviewButton {
  const _CountingPreviewButton({required super.track, required this.onBuild});

  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onBuild();
    return super.build(context, ref);
  }
}

class _TestLibraryCollectionsNotifier extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}
