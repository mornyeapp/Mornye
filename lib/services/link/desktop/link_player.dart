import 'dart:async';
import 'dart:collection';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playback_metadata.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/playback_deck.dart';

/// One queue entry of the desktop player.
@immutable
class LinkPlayerItem {
  const LinkPlayerItem({
    required this.id,
    required this.path,
    required this.title,
    required this.artist,
    this.album,
    this.durationMs,
    this.artwork,
    this.metadataSource,
    this.audioMetadata = const {},
  });

  factory LinkPlayerItem.fromMediaItem(MediaItem item) => LinkPlayerItem(
    id: item.id,
    path: linkCleanPath(item.extras?['source']?.toString() ?? ''),
    title: item.title,
    artist: item.artist ?? '',
    album: item.album,
    durationMs: item.duration?.inMilliseconds,
    artwork: item.artUri?.toString(),
    metadataSource: item.extras?['resolvedSource']?.toString(),
    audioMetadata: playbackAudioMetadataFromMediaItem(item),
  );

  /// The media id: a Library or history row id, or a path.
  final String id;

  /// The file it plays.
  final String path;
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;
  final String? artwork;
  final String? metadataSource;
  final Map<String, dynamic> audioMetadata;
}

class _MappedPlayerItem {
  _MappedPlayerItem(this.source)
    : _extras = [for (final key in _extraKeys) source.extras?[key]],
      _displayMetadata = switch (source.extras?['displayMetadata']) {
        final Map<Object?, Object?> value => Map<Object?, Object?>.of(value),
        _ => const {},
      },
      item = LinkPlayerItem.fromMediaItem(source);

  static const _extraKeys = [
    'source',
    'resolvedSource',
    'bit_depth',
    'sample_rate',
    'bitrate',
    'format',
    'explicit',
  ];

  final MediaItem source;
  final List<Object?> _extras;
  final Map<Object?, Object?> _displayMetadata;
  final LinkPlayerItem item;

  bool matches(MediaItem value) {
    if (!identical(source, value)) return false;
    final extras = value.extras;
    for (var i = 0; i < _extraKeys.length; i++) {
      if (_extras[i] != extras?[_extraKeys[i]]) return false;
    }
    final displayMetadata = extras?['displayMetadata'];
    return displayMetadata is Map<Object?, Object?>
        ? mapEquals(_displayMetadata, displayMetadata)
        : _displayMetadata.isEmpty;
  }
}

class _MappedPlayerQueue extends ListBase<LinkPlayerItem> {
  _MappedPlayerQueue(this._source);

  static const _maxItems = LinkPlayerState.maxQueue * 2;
  final List<MediaItem> _source;
  final _items = <int, _MappedPlayerItem>{};

  @override
  int get length => _source.length;

  @override
  set length(int value) => throw UnsupportedError('Immutable player queue');

  @override
  LinkPlayerItem operator [](int index) {
    final source = _source[index];
    final cached = _items.remove(index);
    if (cached != null && cached.matches(source)) {
      _items[index] = cached;
      return cached.item;
    }
    final mapped = _MappedPlayerItem(source);
    if (_items.length >= _maxItems) _items.remove(_items.keys.first);
    _items[index] = mapped;
    return mapped.item;
  }

  @override
  void operator []=(int index, LinkPlayerItem value) =>
      throw UnsupportedError('Immutable player queue');
}

class _CurrentPlayerQueue extends ListBase<LinkPlayerItem> {
  _CurrentPlayerQueue(this._base, this._item, this._index)
    : _current = _MappedPlayerQueue([_item]);

  final List<LinkPlayerItem> _base;
  final MediaItem _item;
  final int _index;
  final _MappedPlayerQueue _current;

  @override
  int get length => _base.length;

  @override
  set length(int value) => throw UnsupportedError('Immutable player queue');

  @override
  LinkPlayerItem operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return index == _index ? _current[0] : _base[index];
  }

  @override
  void operator []=(int index, LinkPlayerItem value) =>
      throw UnsupportedError('Immutable player queue');
}

/// The desktop player at one moment.
@immutable
class LinkPlayerSnapshot {
  const LinkPlayerSnapshot({
    this.queue = const [],
    this.index = -1,
    this.playing = false,
    this.positionMs = 0,
    this.durationMs,
    this.shuffle = false,
    this.repeat = LinkRepeatMode.none,
    this.volume = 1,
    required this.updatedMs,
  });

  /// The queue in play order. The same list instance while the queue is
  /// unchanged.
  final List<LinkPlayerItem> queue;

  /// The current entry of [queue], or -1.
  final int index;
  final bool playing;
  final int positionMs;
  final int? durationMs;
  final bool shuffle;
  final LinkRepeatMode repeat;

  /// The app's output volume, 0 to 1.
  final double volume;

  /// When [positionMs] was read, in Unix milliseconds.
  final int updatedMs;

  LinkPlayerItem? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;
}

/// What the link host needs from the desktop player.
/// [RuntimeLinkPlayerPort] drives the app's player; tests fake it.
abstract interface class LinkPlayerPort {
  LinkPlayerSnapshot snapshot();

  /// Fires after any change of the queue, the current item, the transport
  /// state or the volume.
  Stream<void> get changes;

  Future<void> play();
  Future<void> pause();
  Future<void> next();
  Future<void> previous();
  Future<void> seek(Duration position);
  Future<void> setVolume(double value);
  Future<void> setShuffle(bool enabled);
  Future<void> setRepeat(LinkRepeatMode mode);

  /// Plays entry [index] of the current queue.
  Future<void> jumpTo(int index);

  /// Moves queue entry [from] to position [to].
  Future<void> moveQueueItem(int from, int to);

  /// Removes queue entry [index]; the current song stays.
  Future<void> removeQueueItem(int index);

  /// Replaces the queue with [items] and starts entry [index] at [position],
  /// paused unless [playing].
  Future<void> playQueue(
    List<PlayableMedia> items, {
    required int index,
    required Duration position,
    required bool playing,
    bool? shuffle,
  });

  /// Adds [items] in this order after the queued songs, or right after the
  /// current one when [playNext].
  Future<void> append(List<PlayableMedia> items, {bool playNext = false});
}

class RuntimeLinkPlayerPort implements LinkPlayerPort {
  RuntimeLinkPlayerPort(this._runtime)
    : _controller = MusicPlayerController(runtime: _runtime);

  final MusicPlayerRuntime _runtime;
  final MusicPlayerController _controller;
  List<MediaItem>? _mappedQueue;
  List<LinkPlayerItem> _mapped = const [];
  _CurrentPlayerQueue? _currentItems;
  MediaItem? _standaloneItem;
  List<LinkPlayerItem> _standalone = const [];

  @visibleForTesting
  int get debugMappedQueueItemCount => _mapped is _MappedPlayerQueue
      ? (_mapped as _MappedPlayerQueue)._items.length
      : 0;

  @override
  LinkPlayerSnapshot snapshot() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final volume = playbackOutputVolume.value;
    final handler = _runtime.handler;
    if (handler == null) {
      return LinkPlayerSnapshot(updatedMs: now, volume: volume);
    }
    final queue = handler.queue.value;
    // Map only entries read by the state window or an explicit queue request.
    if (!identical(queue, _mappedQueue)) {
      _mappedQueue = queue;
      _mapped = _MappedPlayerQueue(queue);
    }
    final current = handler.mediaItem.value;
    final state = handler.playbackState.value;
    var items = _mapped;
    var index = state.queueIndex ?? -1;
    if (current == null) {
      index = -1;
    } else if (index < 0 ||
        index >= queue.length ||
        queue[index].id != current.id) {
      index = queue.indexWhere((item) => item.id == current.id);
      if (index < 0) {
        if (!identical(current, _standaloneItem)) {
          _standaloneItem = current;
          _standalone = _MappedPlayerQueue([current]);
        }
        items = _standalone;
        index = 0;
      }
    }
    if (current != null &&
        identical(items, _mapped) &&
        index >= 0 &&
        !identical(current, queue[index])) {
      final overlay = _currentItems;
      if (overlay == null ||
          !identical(current, overlay._item) ||
          !identical(items, overlay._base) ||
          index != overlay._index) {
        _currentItems = _CurrentPlayerQueue(items, current, index);
      }
      items = _currentItems!;
    } else {
      _currentItems = null;
    }
    return LinkPlayerSnapshot(
      queue: items,
      index: index,
      playing: state.playing,
      positionMs: state.position.inMilliseconds,
      durationMs: current?.duration?.inMilliseconds,
      shuffle: state.shuffleMode != AudioServiceShuffleMode.none,
      repeat: switch (state.repeatMode) {
        AudioServiceRepeatMode.one => LinkRepeatMode.one,
        AudioServiceRepeatMode.all ||
        AudioServiceRepeatMode.group => LinkRepeatMode.all,
        AudioServiceRepeatMode.none => LinkRepeatMode.none,
      },
      volume: volume,
      updatedMs: now,
    );
  }

  @override
  Stream<void> get changes => Stream<void>.multi((listener) {
    void changed(Object? _) => listener.addSync(null);
    final subscriptions = <StreamSubscription<Object?>>[
      _runtime.mediaItemEvents().listen(changed),
      _runtime.playbackStateEvents().listen(changed),
      _runtime.queueEvents().listen(changed),
      playbackOutputVolumeChanges().listen(changed),
    ];
    listener.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
  });

  @override
  Future<void> play() async => _runtime.handler?.play();

  @override
  Future<void> pause() async => _runtime.handler?.pause();

  @override
  Future<void> next() => _controller.next();

  @override
  Future<void> previous() => _controller.previous();

  @override
  Future<void> seek(Duration position) => _controller.seek(position);

  @override
  Future<void> setVolume(double value) async {
    playbackOutputVolume.value = value.clamp(0, 1).toDouble();
  }

  @override
  Future<void> setShuffle(bool enabled) => _controller.setShuffle(enabled);

  @override
  Future<void> setRepeat(LinkRepeatMode mode) async {
    final handler = await _runtime.initialize();
    await handler.setRepeatMode(switch (mode) {
      LinkRepeatMode.none => AudioServiceRepeatMode.none,
      LinkRepeatMode.one => AudioServiceRepeatMode.one,
      LinkRepeatMode.all => AudioServiceRepeatMode.all,
    });
  }

  @override
  Future<void> jumpTo(int index) => _controller.jumpTo(index);

  @override
  Future<void> moveQueueItem(int from, int to) async =>
      _controller.moveQueueItem(from, to);

  @override
  Future<void> removeQueueItem(int index) async {
    final queue = _runtime.handler?.queue.value ?? const <MediaItem>[];
    if (index >= 0 && index < queue.length) {
      _controller.removeQueuedItem(queue[index]);
    }
  }

  @override
  Future<void> playQueue(
    List<PlayableMedia> items, {
    required int index,
    required Duration position,
    required bool playing,
    bool? shuffle,
  }) async {
    final handler = await _runtime.initialize();
    await handler.setQueueAndPlay(
      items,
      initialIndex: index,
      initialPosition: position,
      shuffle:
          shuffle ??
          (handler.playbackState.value.shuffleMode !=
              AudioServiceShuffleMode.none),
    );
    if (!playing) await handler.pause();
  }

  @override
  Future<void> append(
    List<PlayableMedia> items, {
    bool playNext = false,
  }) async =>
      (await _runtime.initialize()).enqueueAll(items, playNext: playNext);
}

/// The desktop player the link host reads and drives. Tests override it.
final linkDesktopPlayerProvider = Provider<LinkPlayerPort>(
  (ref) => RuntimeLinkPlayerPort(ref.watch(musicPlayerRuntimeProvider)),
);

/// The part of a queue of [length] entries sent around entry [index]: at
/// most [max] entries, the current one in the middle where possible.
({int start, int end}) linkQueueWindow(
  int length,
  int index, {
  int max = LinkPlayerState.maxQueue,
}) {
  if (length <= max) return (start: 0, end: length);
  final start = ((index < 0 ? 0 : index) - max ~/ 2).clamp(0, length - max);
  return (start: start, end: start + max);
}

/// [item] as other devices resolve it, with its catalog id when the index
/// knows its file.
TrackRef linkTrackRef(LinkPlayerItem item, {DesktopLinkCatalogIndex? index}) {
  final songId = index?.songIdForMedia(id: item.id, path: item.path);
  final song = songId == null ? null : index!.songById(songId);
  final matchKey = song?.matchKey ?? linkMatchKey(item.title, item.artist);
  return TrackRef(
    title: item.title,
    artist: item.artist,
    album: item.album == null || item.album!.isEmpty ? song?.album : item.album,
    durationMs: item.durationMs ?? song?.durationMs,
    isrc: song?.isrc,
    matchKey: matchKey.isEmpty ? null : matchKey,
    songId: songId,
    serverId: songId == null ? null : index!.serverId,
  );
}

/// Retains the last queue window while its entries and catalog stay current.
class LinkPlayerStateCache {
  List<LinkPlayerItem>? _source;
  DesktopLinkCatalogIndex? _index;
  int _start = -1;
  int _end = -1;
  List<LinkPlayerItem> _items = const [];
  List<TrackRef> _refs = const [];

  List<TrackRef> _window(
    List<LinkPlayerItem> source,
    ({int start, int end}) window,
    DesktopLinkCatalogIndex? index,
  ) {
    var unchanged =
        identical(source, _source) &&
        identical(index, _index) &&
        window.start == _start &&
        window.end == _end;
    if (unchanged) {
      for (var i = window.start; i < window.end; i++) {
        if (!identical(source[i], _items[i - window.start])) {
          unchanged = false;
          break;
        }
      }
    }
    if (!unchanged) {
      _source = source;
      _index = index;
      _start = window.start;
      _end = window.end;
      _items = [for (var i = window.start; i < window.end; i++) source[i]];
      _refs = List.unmodifiable([
        for (final item in _items) linkTrackRef(item, index: index),
      ]);
    }
    return _refs;
  }
}

/// The desktop player as `player.state` and `GET state` send it.
LinkPlayerState linkPlayerState(
  LinkPlayerSnapshot snapshot, {
  DesktopLinkCatalogIndex? index,
  bool? autoplay,
  bool? autoMix,
  LinkPlayerStateCache? cache,
}) {
  final window = linkQueueWindow(snapshot.queue.length, snapshot.index);
  final queue =
      cache?._window(snapshot.queue, window, index) ??
      [
        for (var i = window.start; i < window.end; i++)
          linkTrackRef(snapshot.queue[i], index: index),
      ];
  final current = snapshot.current;
  final inWindow =
      current != null &&
      snapshot.index >= window.start &&
      snapshot.index < window.end;
  return LinkPlayerState(
    track: current == null
        ? null
        : inWindow
        ? queue[snapshot.index - window.start]
        : linkTrackRef(current, index: index),
    playing: snapshot.playing,
    positionMs: snapshot.positionMs,
    durationMs: snapshot.durationMs ?? current?.durationMs,
    updatedMs: snapshot.updatedMs,
    queue: queue,
    index: inWindow ? snapshot.index - window.start : -1,
    shuffle: snapshot.shuffle,
    repeat: snapshot.repeat,
    volume: snapshot.volume.clamp(0, 1).toDouble(),
    autoplay: autoplay,
    autoMix: autoMix,
  );
}

/// Whether [next] differs from [previous] enough to send: anything but a
/// position that playback alone explains.
bool linkPlayerStateChanged(LinkPlayerState previous, LinkPlayerState next) {
  if (previous.playing != next.playing ||
      previous.index != next.index ||
      previous.shuffle != next.shuffle ||
      previous.repeat != next.repeat ||
      previous.autoplay != next.autoplay ||
      previous.autoMix != next.autoMix ||
      previous.durationMs != next.durationMs ||
      (previous.volume - next.volume).abs() > 0.005 ||
      previous.track != next.track ||
      !listEquals(previous.queue, next.queue)) {
    return true;
  }
  final expected = previous.positionAt(next.updatedMs);
  return (expected - next.positionMs).abs() > linkDurationToleranceMs;
}

/// The `handoff/play` arguments (also the `play_queue` command) that
/// continue [state] on another device.
Map<String, dynamic> linkHandoffArgs(LinkPlayerState state, {bool? playing}) =>
    {
      'queue': [for (final item in state.queue) item.toJson()],
      'index': state.index,
      'positionMs': state.positionMs,
      'playing': playing ?? state.playing,
      'shuffle': state.shuffle,
      'repeat': state.repeat.name,
      if (state.autoplay != null) 'autoplay': state.autoplay,
      if (state.autoMix != null) 'autoMix': state.autoMix,
    };
