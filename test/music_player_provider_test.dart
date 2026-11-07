import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';

PlaybackRowKey _row(String id, [String path = '']) => (id: id, path: path);

MediaItem _item(String id, String source) =>
    MediaItem(id: id, title: 'Song', extras: {'source': source});

void main() {
  group('mediaItemPlaysRow', () {
    test('compares files when both sides know one', () {
      // A playlist queues the file under its path rather than a row id.
      final fromPlaylist = _item('/music/a.flac', '/music/a.flac');
      final row = _row('row-a', '/music/a.flac');
      expect(mediaItemPlaysRow(fromPlaylist, row), isTrue);
      final fromLibrary = _item('row-a', '/music/a.flac');
      expect(mediaItemPlaysRow(fromLibrary, row), isTrue);
    });

    test('an id another source shares does not mark the row', () {
      final current = _item('42', '/music/a.flac');
      expect(mediaItemPlaysRow(current, _row('42', '/music/b.flac')), isFalse);
    });

    test('ignores the existence marker on stored paths', () {
      final current = _item('x', '/music/a.flac');
      expect(
        mediaItemPlaysRow(current, _row('', 'EXISTS:/music/a.flac')),
        isTrue,
      );
    });

    test('falls back to the media id without a path', () {
      expect(mediaItemPlaysRow(_item('row-a', ''), _row('row-a')), isTrue);
      expect(
        mediaItemPlaysRow(
          _item('/music/a.flac', ''),
          _row('', '/music/a.flac'),
        ),
        isTrue,
      );
      expect(mediaItemPlaysRow(_item('row-a', ''), _row('row-b')), isFalse);
      expect(mediaItemPlaysRow(null, _row('row-a')), isFalse);
    });
  });

  group('CurrentTrackIdentity', () {
    CatalogTrackKey key({
      String id = 'catalog-1',
      String? isrc,
      String name = 'Song',
      String artist = 'Artist',
    }) => catalogTrackKey(
      Track(
        id: id,
        name: name,
        artistName: artist,
        albumName: 'Album',
        duration: 180,
        isrc: isrc,
      ),
    );

    final identity = CurrentTrackIdentity(
      recordIds: const {'/music/a.flac', 'history-row'},
      catalogIds: const {'catalog-1'},
      matchKey: key().matchKey,
    );

    test('a record id is exact', () {
      expect(identity.matches(key(id: 'history-row', name: 'Other')), isTrue);
    });

    test('a catalog id needs the same title and artist', () {
      expect(identity.matches(key()), isTrue);
      // Another provider numbers its catalog independently.
      expect(
        identity.matches(key(name: 'Other song', artist: 'Other artist')),
        isFalse,
      );
    });

    test('a title and artist alone never match', () {
      expect(identity.matches(key(id: 'catalog-2')), isFalse);
    });

    test('two ISRCs decide', () {
      final withIsrc = CurrentTrackIdentity(
        catalogIds: const {'catalog-1'},
        isrc: 'XX0000000001',
        matchKey: key().matchKey,
      );
      expect(
        withIsrc.matches(key(id: 'catalog-9', isrc: 'xx-000-00-00001')),
        isTrue,
      );
      expect(withIsrc.matches(key(isrc: 'XX0000000002')), isFalse);
    });
  });

  test('catalog rows stay unmarked while the identity resolves', () async {
    final identity = Completer<CurrentTrackIdentity?>();
    final container = ProviderContainer(
      overrides: [
        currentTrackIdentityProvider.overrideWith((ref) => identity.future),
        playbackPlayingProvider.overrideWith((ref) => true),
        playbackLoadingProvider.overrideWith((ref) => false),
      ],
    );
    addTearDown(container.dispose);
    final row = (id: 'catalog-1', isrc: '', matchKey: 'song|artist');
    final subscription = container.listen(
      catalogTrackPlaybackUiProvider(row),
      (_, _) {},
    );
    addTearDown(subscription.close);
    expect(subscription.read().isCurrent, isFalse);

    identity.complete(
      const CurrentTrackIdentity(
        catalogIds: {'catalog-1'},
        matchKey: 'song|artist',
      ),
    );
    await container.pump();
    expect(subscription.read(), (
      isCurrent: true,
      isPlaying: true,
      isLoading: false,
    ));
  });

  test(
    'late duration updates notify mounted player consumers for the same track',
    () async {
      final mediaItems = StreamController<MediaItem?>();
      addTearDown(mediaItems.close);
      final container = ProviderContainer(
        overrides: [
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => mediaItems.stream,
          ),
        ],
      );
      addTearDown(container.dispose);
      final durations = <Duration?>[];
      final ids = <String?>[];
      container.listen(currentMediaItemProvider, (_, next) {
        if (next.hasValue) durations.add(next.value?.duration);
      });
      container.listen(
        currentMediaItemProvider.select((state) => state.value?.id),
        (_, next) => ids.add(next),
      );
      const initial = MediaItem(
        id: 'track',
        title: 'Track',
        duration: Duration.zero,
      );
      mediaItems.add(initial);
      await container.read(currentMediaItemProvider.future);
      await container.pump();
      final ready = initial.copyWith(duration: const Duration(minutes: 3));
      expect(ready, initial); // audio_service equality compares only the ID.
      mediaItems.add(ready);
      await container.pump();
      expect(durations, [Duration.zero, const Duration(minutes: 3)]);
      expect(ids, ['track']);

      mediaItems.add(ready);
      await container.pump();
      expect(durations, hasLength(2));
      mediaItems.add(const MediaItem(id: 'next', title: 'Next'));
      await container.pump();
      expect(durations.last, isNull);
      expect(ids, ['track', 'next']);
      mediaItems.add(null);
      await container.pump();
      expect(container.read(currentMediaItemProvider).value, isNull);
      expect(ids, ['track', 'next', null]);
    },
  );

  test('Library playback state follows only the current media item', () async {
    final container = ProviderContainer(
      overrides: [
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) =>
              Stream.value(const MediaItem(id: 'track-1', title: 'Track 1')),
        ),
        playbackPlayingProvider.overrideWith((ref) => true),
        playbackLoadingProvider.overrideWith((ref) => false),
      ],
    );
    addTearDown(container.dispose);
    final currentMediaSubscription = container.listen(
      currentMediaItemProvider,
      (_, _) {},
    );
    addTearDown(currentMediaSubscription.close);

    await container.read(currentMediaItemProvider.future);

    expect(container.read(mediaItemPlaybackUiProvider(_row('track-1'))), (
      isCurrent: true,
      isPlaying: true,
      isLoading: false,
    ));
    expect(container.read(mediaItemPlaybackUiProvider(_row('track-2'))), (
      isCurrent: false,
      isPlaying: false,
      isLoading: false,
    ));
  });

  test(
    'Library releases playback state for cells that leave the viewport',
    () async {
      final mediaItems = StreamController<MediaItem?>();
      addTearDown(mediaItems.close);
      final container = ProviderContainer(
        overrides: [
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => mediaItems.stream,
          ),
          playbackPlayingProvider.overrideWith((ref) => true),
          playbackLoadingProvider.overrideWith((ref) => false),
        ],
      );
      addTearDown(container.dispose);
      final visibleProvider = mediaItemPlaybackUiProvider(
        _row('visible-track'),
      );
      final visibleSubscription = container.listen(visibleProvider, (_, _) {});
      addTearDown(visibleSubscription.close);
      mediaItems.add(
        const MediaItem(id: 'visible-track', title: 'Visible track'),
      );
      await container.read(currentMediaItemProvider.future);

      for (var index = 0; index < 200; index++) {
        final provider = mediaItemPlaybackUiProvider(
          _row('scrolled-track-$index'),
        );
        final subscription = container.listen(provider, (_, _) {});
        expect(container.read(provider.exists), isTrue);
        subscription.close();
      }
      await container.pump();

      for (var index = 0; index < 200; index++) {
        expect(
          container.read(
            mediaItemPlaybackUiProvider(_row('scrolled-track-$index')).exists,
          ),
          isFalse,
        );
      }
      expect(container.read(visibleProvider.exists), isTrue);
      expect(visibleSubscription.read(), (
        isCurrent: true,
        isPlaying: true,
        isLoading: false,
      ));

      mediaItems.add(
        const MediaItem(id: 'scrolled-track-0', title: 'Scrolled track'),
      );
      await container.pump();
      final returningSubscription = container.listen(
        mediaItemPlaybackUiProvider(_row('scrolled-track-0')),
        (_, _) {},
      );
      addTearDown(returningSubscription.close);
      expect(returningSubscription.read(), (
        isCurrent: true,
        isPlaying: true,
        isLoading: false,
      ));
      expect(visibleSubscription.read(), (
        isCurrent: false,
        isPlaying: false,
        isLoading: false,
      ));
    },
  );
}
