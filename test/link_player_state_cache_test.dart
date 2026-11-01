import 'dart:collection';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/desktop/link_desktop_ops.dart';
import 'package:mornye/services/link/desktop/link_player.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_playback_details.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/music_player_service.dart';

import 'support/link_desktop_fakes.dart';

class _Handler extends BaseAudioHandler implements MusicPlayerHandler {
  @override
  Future<void> stop({bool keepResume = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  Future<void> close() async {
    await queue.close();
    await mediaItem.close();
    await playbackState.close();
  }
}

class _Runtime extends MusicPlayerRuntime {
  _Runtime(this.handler);

  @override
  final MusicPlayerHandler? handler;
}

class _CountingMediaItem extends MediaItem {
  _CountingMediaItem(int index, {Map<String, dynamic>? extras, Uri? artwork})
    : super(
        id: '$index',
        title: 'Song $index',
        artist: 'Artist',
        artUri: artwork,
        extras: extras ?? {'source': '/Music/$index.flac'},
      );

  static int titleReads = 0;

  @override
  String get title {
    titleReads++;
    return super.title;
  }
}

class _CountingIndex extends DesktopLinkCatalogIndex {
  _CountingIndex({super.serverId = 'server', super.songs = const []});

  int lookups = 0;

  @override
  String? songIdForMedia({required String id, required String path}) {
    lookups++;
    return super.songIdForMedia(id: id, path: path);
  }
}

class _CountingMetadata extends MapBase<String, dynamic> {
  final _values = <String, dynamic>{'genre': 'Rock', 'lyrics': 'Words'};
  int keyReads = 0;

  @override
  int get length => _values.length;

  @override
  bool containsKey(Object? key) => _values.containsKey(key);

  @override
  Iterable<String> get keys {
    keyReads++;
    return _values.keys;
  }

  @override
  dynamic operator [](Object? key) => _values[key];

  @override
  void operator []=(String key, dynamic value) => _values[key] = value;

  @override
  void clear() => _values.clear();

  @override
  dynamic remove(Object? key) => _values.remove(key);
}

class _RecordingDetails extends LinkPlaybackDetails {
  LinkPlayerItem? item;

  @override
  Future<Map<String, dynamic>> read(LinkPlayerItem item) async {
    this.item = item;
    return {};
  }
}

void _expectMappedItem(LinkPlayerItem actual, MediaItem source) {
  final expected = LinkPlayerItem.fromMediaItem(source);
  expect(actual.id, expected.id);
  expect(actual.path, expected.path);
  expect(actual.title, expected.title);
  expect(actual.artist, expected.artist);
  expect(actual.album, expected.album);
  expect(actual.durationMs, expected.durationMs);
  expect(actual.artwork, expected.artwork);
  expect(actual.metadataSource, expected.metadataSource);
  expect(actual.audioMetadata, expected.audioMetadata);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a rich current overlay maps only its 20000-song queue window', () {
    final handler = _Handler();
    final runtime = _Runtime(handler);
    addTearDown(handler.close);
    addTearDown(runtime.dispose);
    final media = List<MediaItem>.unmodifiable([
      for (var i = 0; i < 20000; i++) _CountingMediaItem(i),
    ]);
    final tags = _CountingMetadata();
    final current = _CountingMediaItem(
      10000,
      artwork: Uri.file('/current.jpg'),
      extras: {
        'source': '/Music/10000.flac',
        'resolvedSource': '/received/current.flac',
        'sample_rate': 96000,
        'displayMetadata': tags,
      },
    );
    handler.queue.add(media);
    handler.mediaItem.add(current);
    handler.playbackState.add(PlaybackState(queueIndex: 10000));
    final port = RuntimeLinkPlayerPort(runtime);
    final cache = LinkPlayerStateCache();
    final index = _CountingIndex();
    _CountingMediaItem.titleReads = 0;
    final snapshot = port.snapshot();
    expect(_CountingMediaItem.titleReads, 0);
    final state = linkPlayerState(snapshot, index: index, cache: cache);
    expect(_CountingMediaItem.titleReads, 200);
    expect(port.debugMappedQueueItemCount, 199);
    expect(snapshot.current!.artwork, 'file:///current.jpg');
    expect(snapshot.current!.metadataSource, '/received/current.flac');
    expect(snapshot.current!.audioMetadata['sample_rate'], 96000);
    final metadata = snapshot.current!.audioMetadata;
    final keyReads = tags.keyReads;
    expect(keyReads, greaterThan(0));
    for (var tick = 0; tick < 60; tick++) {
      final next = port.snapshot();
      expect(next.queue, same(snapshot.queue));
      expect(next.current!.audioMetadata, same(metadata));
      expect(
        linkPlayerState(next, index: index, cache: cache).queue,
        same(state.queue),
      );
    }
    expect(tags.keyReads, keyReads);
    expect(_CountingMediaItem.titleReads, 200);
    expect(index.lookups, 200);
    expect(snapshot.queue[9999].metadataSource, isNull);
    for (var i = 0; i < snapshot.queue.length; i++) {
      expect(snapshot.queue[i].id, '$i');
      expect(port.debugMappedQueueItemCount, lessThanOrEqualTo(400));
    }
    expect(port.debugMappedQueueItemCount, 400);
    expect(tags.keyReads, keyReads);
    expect(() => snapshot.queue[0] = snapshot.current!, throwsUnsupportedError);
  });

  test(
    'current overlays follow duplicate indices and fallback transitions',
    () {
      final handler = _Handler();
      final runtime = _Runtime(handler);
      addTearDown(handler.close);
      addTearDown(runtime.dispose);
      const first = MediaItem(id: 'same', title: 'First');
      const second = MediaItem(id: 'same', title: 'Second');
      const current = MediaItem(id: 'same', title: 'Live');
      handler.queue.add([first, second]);
      handler.mediaItem.add(current);
      handler.playbackState.add(PlaybackState(queueIndex: 0));
      final port = RuntimeLinkPlayerPort(runtime);
      final cache = LinkPlayerStateCache();
      final atFirst = port.snapshot();
      expect(atFirst.queue.map((v) => v.title), ['Live', 'Second']);
      expect(linkPlayerState(atFirst, cache: cache).index, 0);
      handler.playbackState.add(PlaybackState(queueIndex: 1));
      final atSecond = port.snapshot();
      expect(atSecond.queue.map((v) => v.title), ['First', 'Live']);
      final movedState = linkPlayerState(atSecond, cache: cache);
      expect(movedState.index, 1);
      expect(movedState.track!.title, 'Live');
      expect(movedState.queue.first.title, 'First');
      expect(atFirst.queue.map((v) => v.title), ['Live', 'Second']);
      expect(port.snapshot().queue, same(atSecond.queue));
      handler.mediaItem.add(second);
      final canonical = port.snapshot();
      expect(canonical.queue.map((v) => v.title), ['First', 'Second']);
      handler.mediaItem.add(null);
      final emptyCurrent = port.snapshot();
      expect(emptyCurrent.queue, same(canonical.queue));
      expect(emptyCurrent.current, isNull);
      expect(emptyCurrent.index, -1);
      const foreign = MediaItem(id: 'foreign', title: 'Foreign');
      handler.mediaItem.add(foreign);
      final standalone = port.snapshot();
      expect(standalone.queue.single.title, 'Foreign');
      expect(standalone.index, 0);
      handler.queue.add([]);
      expect(port.snapshot().queue, same(standalone.queue));
      handler.mediaItem.add(null);
      expect(port.snapshot().queue, isEmpty);
      handler.queue.add([first, second]);
      handler.mediaItem.add(current);
      expect(port.snapshot().queue.map((v) => v.title), ['First', 'Live']);
    },
  );

  for (final mode in ['canonical', 'overlay', 'standalone']) {
    test('$mode mapping observes metadata edits, removal and replacement', () {
      final handler = _Handler();
      final runtime = _Runtime(handler);
      addTearDown(handler.close);
      addTearDown(runtime.dispose);
      final tags = <String, dynamic>{'genre': 'Rock', 'lyrics': 'Old words'};
      final extras = <String, dynamic>{
        'source': '/song.flac',
        'resolvedSource': '/received/song.flac',
        'bit_depth': 16,
        'sample_rate': 44100,
        'bitrate': 320,
        'format': 'flac',
        'explicit': false,
        'displayMetadata': tags,
      };
      var current = MediaItem(
        id: mode == 'standalone' ? 'foreign' : 'song',
        title: 'Song',
        artUri: Uri.file('/old.jpg'),
        extras: extras,
      );
      final queue = [
        mode == 'canonical'
            ? current
            : const MediaItem(id: 'song', title: 'Queued'),
      ];
      handler.queue.add(queue);
      handler.mediaItem.add(current);
      handler.playbackState.add(PlaybackState(queueIndex: 0));
      final port = RuntimeLinkPlayerPort(runtime);
      var previous = port.snapshot();
      var mapped = previous.current!;
      _expectMappedItem(mapped, current);
      void checkMutation() {
        final next = port.snapshot();
        expect(next.queue, same(previous.queue));
        expect(next.current, isNot(same(mapped)));
        mapped = next.current!;
        _expectMappedItem(mapped, current);
        previous = next;
      }

      for (final change in {
        'source': 'EXISTS:/updated.flac',
        'resolvedSource': '/received/updated.flac',
        'bit_depth': 24,
        'sample_rate': 96000,
        'bitrate': 2400,
        'format': 'alac',
        'explicit': true,
      }.entries) {
        extras[change.key] = change.value;
        checkMutation();
      }
      tags['genre'] = 'Jazz';
      checkMutation();
      tags.remove('genre');
      checkMutation();
      extras['displayMetadata'] = {'album_artist': 'Replacement'};
      checkMutation();
      extras.remove('displayMetadata');
      checkMutation();
      for (final key in [
        'source',
        'resolvedSource',
        'bit_depth',
        'sample_rate',
        'bitrate',
        'format',
        'explicit',
      ]) {
        extras.remove(key);
        checkMutation();
      }
      current = current.copyWith(
        artUri: Uri.file('/new.jpg'),
        extras: {
          'source': '/replacement.flac',
          'resolvedSource': '/received/replacement.flac',
          'sample_rate': 48000,
          'displayMetadata': {'genre': 'Replacement'},
        },
      );
      if (mode == 'canonical') queue[0] = current;
      handler.mediaItem.add(current);
      final replaced = port.snapshot();
      expect(replaced.current, isNot(same(mapped)));
      _expectMappedItem(replaced.current!, current);
      expect(port.snapshot().queue, same(replaced.queue));
    });
  }

  test(
    'playback details read the current overlay after metadata updates',
    () async {
      final handler = _Handler();
      final runtime = _Runtime(handler);
      addTearDown(handler.close);
      addTearDown(runtime.dispose);
      final tags = <String, dynamic>{'genre': 'Rock'};
      final extras = <String, dynamic>{
        'source': '/song.flac',
        'resolvedSource': '/received/old.flac',
        'sample_rate': 44100,
        'displayMetadata': tags,
      };
      var current = MediaItem(
        id: 'song',
        title: 'Song',
        artUri: Uri.file('/old.jpg'),
        extras: extras,
      );
      handler.queue.add([const MediaItem(id: 'song', title: 'Queued')]);
      handler.mediaItem.add(current);
      handler.playbackState.add(PlaybackState(queueIndex: 0));
      final port = RuntimeLinkPlayerPort(runtime);
      final details = _RecordingDetails();
      final ops = LinkDesktopOps(
        player: port,
        downloads: FakeLinkDownloads(),
        downloadItems: () => [],
        openUrl: (_) async {},
        index: () => null,
        desktopName: () => 'Desktop',
        playbackDetails: details,
      );
      final router = LinkHostRouter();
      ops.register(router);
      Future<void> readDetails() async {
        await router.dispatch(
          LinkRequest(
            requestId: 'details',
            op: LinkOps.playbackDetails,
            deviceId: 'phone',
            args: {'track': ops.state().track!.toJson()},
          ),
        );
        _expectMappedItem(details.item!, current);
      }

      await readDetails();
      extras['resolvedSource'] = '/received/new.flac';
      extras['sample_rate'] = 96000;
      tags['genre'] = 'Jazz';
      await readDetails();
      current = current.copyWith(artUri: Uri.file('/new.jpg'));
      handler.mediaItem.add(current);
      await readDetails();
    },
  );

  test('runtime mapping retention stays bounded through a 20000-song walk', () {
    final handler = _Handler();
    final runtime = _Runtime(handler);
    addTearDown(handler.close);
    addTearDown(runtime.dispose);
    final media = List<MediaItem>.unmodifiable([
      for (var i = 0; i < 20000; i++) _CountingMediaItem(i),
    ]);
    handler.queue.add(media);
    handler.mediaItem.add(media[10000]);
    handler.playbackState.add(PlaybackState(queueIndex: 10000));
    final port = RuntimeLinkPlayerPort(runtime);
    final snapshot = port.snapshot();
    var peak = 0;
    for (var i = 0; i < snapshot.queue.length; i++) {
      expect(snapshot.queue[i].id, '$i');
      peak = max(peak, port.debugMappedQueueItemCount);
    }
    expect(peak, 400);
    expect(port.debugMappedQueueItemCount, 400);
    expect(snapshot.current!.id, '10000');
    final state = linkPlayerState(snapshot, cache: LinkPlayerStateCache());
    expect(state.index, 100);
    expect(state.track!.title, 'Song 10000');
    expect(port.debugMappedQueueItemCount, 400);
  });

  test('cached state matches the original mapping through queue changes', () {
    final random = Random(7);
    final cache = LinkPlayerStateCache();
    var items = <LinkPlayerItem>[
      for (var i = 0; i < 500; i++)
        LinkPlayerItem(
          id: '$i',
          path: '/$i.flac',
          title: 'Song $i',
          artist: 'Artist',
        ),
    ];
    DesktopLinkCatalogIndex? catalog;
    for (var round = 0; round < 200; round++) {
      final at = random.nextInt(items.length + 2) - 1;
      switch (round % 6) {
        case 0:
          items = [...items];
        case 1:
          if (at >= 0 && at < items.length) {
            items[at] = LinkPlayerItem(
              id: 'edited-$round',
              path: '/edited-$round.flac',
              title: 'Edited $round',
              artist: 'Artist $round',
              album: 'Album $round',
              durationMs: round * 1000,
            );
          }
        case 2:
          items.add(
            LinkPlayerItem(
              id: '$round',
              path: '/$round.flac',
              title: 'Song $round',
              artist: 'Artist',
            ),
          );
        case 3:
          if (at >= 0 && at < items.length) items.removeAt(at);
        case 4:
          items.setAll(0, items.reversed.toList());
        case 5:
          catalog = catalog == null
              ? DesktopLinkCatalogIndex(
                  serverId: 'server',
                  songs: [
                    for (final item in items)
                      LinkCatalogSong(
                        id: 'l:${item.id}',
                        path: item.path,
                        title: item.title,
                        artist: item.artist,
                        album: 'Catalog album',
                        durationMs: 12345,
                        isrc: 'EXAMPLE123',
                      ),
                  ],
                )
              : null;
      }
      final snapshot = LinkPlayerSnapshot(
        queue: items,
        index: at,
        updatedMs: round * 1000,
        positionMs: round * 400,
        playing: round.isEven,
        durationMs: round.isEven ? null : 12345,
        shuffle: round % 3 == 0,
        volume: random.nextDouble() * 1.5,
      );
      expect(
        linkPlayerState(snapshot, index: catalog, cache: cache).toJson(),
        linkPlayerState(snapshot, index: catalog).toJson(),
        reason: 'round $round',
      );
    }
  });

  test(
    'a 20000-song runtime queue maps only the window across ticks',
    () async {
      final handler = _Handler();
      final runtime = _Runtime(handler);
      addTearDown(handler.close);
      addTearDown(runtime.dispose);
      final media = List<MediaItem>.unmodifiable([
        for (var i = 0; i < 20000; i++) _CountingMediaItem(i),
      ]);
      handler.queue.add(media);
      handler.mediaItem.add(media[10000]);
      handler.playbackState.add(PlaybackState(queueIndex: 10000));
      final port = RuntimeLinkPlayerPort(runtime);
      _CountingMediaItem.titleReads = 0;
      final snapshot = port.snapshot();
      expect(_CountingMediaItem.titleReads, 0);
      final cache = LinkPlayerStateCache();
      final index = _CountingIndex();
      final first = linkPlayerState(snapshot, index: index, cache: cache);
      expect(_CountingMediaItem.titleReads, 200);
      expect(index.lookups, 200);
      expect(first.queue.first.title, 'Song 9900');
      expect(first.queue.last.title, 'Song 10099');
      expect(first.index, 100);
      expect(first.track!.title, 'Song 10000');
      for (var tick = 0; tick < 60; tick++) {
        final next = port.snapshot();
        expect(identical(next.queue, snapshot.queue), isTrue);
        expect(
          identical(
            linkPlayerState(next, index: index, cache: cache).queue,
            first.queue,
          ),
          isTrue,
        );
      }
      expect(_CountingMediaItem.titleReads, 200);
      expect(index.lookups, 200);
      expect(() => snapshot.queue.clear(), throwsUnsupportedError);
      expect(() => first.queue.clear(), throwsUnsupportedError);

      final replacement = [...media];
      replacement[10005] = replacement[10005].copyWith(title: 'Edited song');
      handler.queue.add(List.unmodifiable(replacement));
      final edited = linkPlayerState(
        port.snapshot(),
        index: index,
        cache: cache,
      );
      expect(edited.queue[105].title, 'Edited song');
      expect(first.queue[105].title, 'Song 10005');
      expect(index.lookups, 400);
      expect(_CountingMediaItem.titleReads, lessThan(401));

      final before = _CountingMediaItem.titleReads;
      handler.mediaItem.add(media[10500]);
      handler.playbackState.add(PlaybackState(queueIndex: 10500));
      final moved = linkPlayerState(
        port.snapshot(),
        index: index,
        cache: cache,
      );
      expect(moved.queue.first.title, 'Song 10400');
      expect(moved.track!.title, 'Song 10500');
      expect(_CountingMediaItem.titleReads - before, 200);
    },
  );

  test('cached windows retain scalar, metadata and catalog invalidation', () {
    final items = <LinkPlayerItem>[
      for (var i = 0; i < 500; i++)
        LinkPlayerItem(
          id: '$i',
          path: '/$i.flac',
          title: 'Song $i',
          artist: 'Artist',
        ),
    ];
    final cache = LinkPlayerStateCache();
    final index = _CountingIndex();
    LinkPlayerSnapshot snapshot({
      int at = 499,
      bool playing = false,
      int position = 0,
    }) => LinkPlayerSnapshot(
      queue: items,
      index: at,
      playing: playing,
      positionMs: position,
      updatedMs: position,
    );
    final first = linkPlayerState(snapshot(), index: index, cache: cache);
    final tick = linkPlayerState(
      snapshot(playing: true, position: 5000),
      index: index,
      cache: cache,
      autoplay: true,
      autoMix: false,
    );
    expect(identical(tick.queue, first.queue), isTrue);
    expect(tick.index, 199);
    expect(tick.playing, isTrue);
    expect(tick.positionMs, 5000);
    expect(tick.autoplay, isTrue);
    expect(tick.autoMix, isFalse);
    expect(index.lookups, 200);

    items[498] = const LinkPlayerItem(
      id: '498',
      path: '/edited.flac',
      title: 'Edited',
      artist: 'Edited artist',
      album: 'Edited album',
      durationMs: 1234,
    );
    final edited = linkPlayerState(snapshot(), index: index, cache: cache);
    expect(edited.queue[198].toJson(), {
      'title': 'Edited',
      'artist': 'Edited artist',
      'album': 'Edited album',
      'durationMs': 1234,
      'matchKey': 'edited|edited artist',
    });
    final refreshedIndex = _CountingIndex(
      songs: [
        const LinkCatalogSong(
          id: 'l:edited',
          path: '/edited.flac',
          title: 'Edited',
          artist: 'Edited artist',
          album: 'Catalog album',
          durationMs: 4321,
          isrc: 'EXAMPLE123',
        ),
      ],
    );
    final refreshed = linkPlayerState(
      snapshot(),
      index: refreshedIndex,
      cache: cache,
    );
    expect(refreshed.queue[198].songId, 'l:edited');
    expect(refreshed.queue[198].serverId, 'server');
    expect(refreshed.queue[198].isrc, 'EXAMPLE123');
    expect(refreshed.queue[198].album, 'Edited album');
    expect(refreshed.queue[198].durationMs, 1234);
    expect(refreshedIndex.lookups, 200);
    final uncataloged = linkPlayerState(snapshot(), cache: cache);
    expect(uncataloged.queue[198].songId, isNull);
    expect(uncataloged.queue[198].isrc, isNull);
    expect(linkPlayerState(snapshot(at: -1), cache: cache).track, isNull);
    items.clear();
    final empty = linkPlayerState(snapshot(), cache: cache);
    expect(empty.queue, isEmpty);
    expect(empty.index, -1);
    expect(empty.track, isNull);
  });

  test(
    'runtime queue observes source edits and standalone current items',
    () async {
      final handler = _Handler();
      final runtime = _Runtime(handler);
      addTearDown(handler.close);
      addTearDown(runtime.dispose);
      final item = _CountingMediaItem(1);
      handler.queue.add([item]);
      handler.mediaItem.add(item);
      handler.playbackState.add(PlaybackState(queueIndex: 0));
      final port = RuntimeLinkPlayerPort(runtime);
      final cache = LinkPlayerStateCache();
      final first = port.snapshot();
      linkPlayerState(first, cache: cache);
      item.extras!['source'] = 'EXISTS:/edited.flac';
      final edited = port.snapshot();
      expect(identical(edited.queue, first.queue), isTrue);
      expect(edited.current!.path, '/edited.flac');
      final foreign = const MediaItem(
        id: 'foreign',
        title: 'Foreign',
        duration: Duration(seconds: 9),
      );
      handler.mediaItem.add(foreign);
      final standalone = port.snapshot();
      expect(standalone.queue.length, 1);
      expect(standalone.index, 0);
      expect(standalone.current!.title, 'Foreign');
      expect(identical(port.snapshot().queue, standalone.queue), isTrue);
      handler.mediaItem.add(foreign.copyWith(title: 'Edited foreign'));
      expect(port.snapshot().current!.title, 'Edited foreign');
      handler.mediaItem.add(null);
      expect(port.snapshot().index, -1);
      expect(RuntimeLinkPlayerPort(_Runtime(null)).snapshot().queue, isEmpty);
    },
  );
}
