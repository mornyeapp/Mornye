import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/collection_suggestions_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/collection_suggestions.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/collection_suggestions_section.dart';
import 'package:mornye/widgets/desktop/track_list_table.dart';

import 'support/fixed_settings.dart';

const _fresh = Track(
  id: 'fresh',
  name: 'Fresh song',
  artistName: 'Fresh artist',
  albumName: 'Album',
  duration: 180,
);

class _CountingTrack extends Track {
  _CountingTrack(int index)
    : super(
        id: '$index',
        name: 'Song $index',
        artistName: 'Artist $index',
        albumName: 'Album',
        duration: 180,
      );

  static int reads = 0;

  @override
  String get name {
    reads++;
    return super.name;
  }

  @override
  String get artistName {
    reads++;
    return super.artistName;
  }

  @override
  String? get isrc {
    reads++;
    return super.isrc;
  }
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);

  void publish(List<Track> tracks) {
    final date = DateTime.utc(2026);
    state = state.copyWith(
      playlists: [
        UserPlaylistCollection(
          id: 'example-playlist',
          name: 'Example playlist',
          createdAt: date,
          updatedAt: date,
          tracks: [
            for (final track in tracks)
              CollectionTrackEntry(key: track.id, track: track, addedAt: date),
          ],
        ),
      ],
    );
  }
}

Widget _app(
  ProviderContainer container,
  Widget child, {
  required bool mornye,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

void main() {
  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      testWidgets(
        'reuses filtering on parent builds, desktop=$desktop Mornye=$mornye',
        (tester) async {
          debugDesktopPlatformOverride = desktop;
          addTearDown(() => debugDesktopPlatformOverride = null);
          final collection = [for (var i = 0; i < 200; i++) _CountingTrack(i)];
          var suggestions = const CollectionSuggestions(
            tracks: [_fresh],
            related: true,
          );
          final snapshot = Provider<CollectionSuggestions>(
            (ref) => suggestions,
          );
          final container = ProviderContainer(
            overrides: [
              settingsProvider.overrideWith(FixedSettingsNotifier.new),
              currentMediaItemProvider.overrideWithBuild(
                (ref, notifier) => Stream.value(null),
              ),
              collectionSuggestionsProvider.overrideWith(
                (ref, request) async => ref.watch(snapshot),
              ),
            ],
          );
          addTearDown(container.dispose);
          final parent = ValueNotifier(0);
          addTearDown(parent.dispose);
          final tracks = <Track>[...collection];
          await tester.pumpWidget(
            _app(
              container,
              ValueListenableBuilder<int>(
                valueListenable: parent,
                builder: (context, value, child) => CustomScrollView(
                  slivers: [
                    CollectionSuggestionsSliver(
                      collectionKey: 'album:example',
                      tracks: [...tracks],
                    ),
                  ],
                ),
              ),
              mornye: mornye,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Fresh song'), findsOneWidget);
          final first = desktop
              ? tester
                    .widget<TrackListTable>(find.byType(TrackListTable))
                    .tracks
              : null;
          _CountingTrack.reads = 0;
          for (var build = 1; build <= 5; build++) {
            parent.value = build;
            await tester.pump();
            if (desktop) {
              expect(
                identical(
                  tester
                      .widget<TrackListTable>(find.byType(TrackListTable))
                      .tracks,
                  first,
                ),
                isTrue,
              );
            }
          }
          expect(_CountingTrack.reads, 0);
          tracks[100] = _fresh;
          parent.value++;
          await tester.pumpAndSettle();
          expect(find.text('Fresh song'), findsNothing);
          tracks[100] = collection[100];
          parent.value++;
          await tester.pumpAndSettle();
          expect(find.text('Fresh song'), findsOneWidget);
          suggestions = CollectionSuggestions(
            tracks: [_fresh.copyWith(name: 'Refreshed song')],
            related: false,
          );
          container.invalidate(snapshot);
          await tester.pumpAndSettle();
          expect(find.text('Fresh song'), findsNothing);
          expect(find.text('Refreshed song'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('playlist membership updates filter already loaded suggestions', (
    tester,
  ) async {
    final collections = _Collections();
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(FixedSettingsNotifier.new),
        libraryCollectionsProvider.overrideWith(() => collections),
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) => Stream.value(null),
        ),
        collectionSuggestionsProvider.overrideWith(
          (ref, request) async =>
              const CollectionSuggestions(tracks: [_fresh], related: true),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _app(
        container,
        const CustomScrollView(
          slivers: [
            CollectionSuggestionsSliver(
              collectionKey: 'playlist:example-playlist',
              tracks: [],
              playlistId: 'example-playlist',
            ),
          ],
        ),
        mornye: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fresh song'), findsOneWidget);
    collections.publish([_fresh]);
    await tester.pumpAndSettle();
    expect(find.text('Fresh song'), findsNothing);
    collections.publish([]);
    await tester.pumpAndSettle();
    expect(find.text('Fresh song'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
