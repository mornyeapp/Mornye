import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/playable_media.dart';

/// The queue a session write stores: its songs in play order and, while
/// shuffled, each song's place in the order before shuffling (play order
/// when null).
typedef PlaybackSessionQueue = ({
  List<PlayableMedia> media,
  List<int>? originalIndices,
});

typedef _Session = ({
  int revision,
  PlaybackSessionQueue queue,
  int index,
  int positionMs,
  bool shuffle,
  String repeatMode,
});

class _QueueWrite {
  _QueueWrite(this.session);

  _Session session;
  late final Future<void> done;
}

/// Owns ordered session writes and the revision of the persisted queue.
/// Position updates serialize the queue only when it changed or the stored
/// row disappeared; transport and queue ordering remain with the player.
/// Each song is encoded once, so a queue write encodes only the songs that
/// joined the queue since the last one.
class PlaybackSessionWriter {
  PlaybackSessionWriter({
    required AppStateDatabase database,
    required void Function(Object) onError,
    @visibleForTesting
    Future<List<Uint8List>> Function(List<PlayableMedia> songs)
        encodeInBackground =
        _encodeSongsInBackground,
  }) : _database = database,
       _onError = onError,
       _encodeInBackground = encodeInBackground;

  /// Songs new to the queue from this many on encode on another isolate.
  static const backgroundEncodeThreshold = 64;

  final AppStateDatabase _database;
  final void Function(Object) _onError;
  final Future<List<Uint8List>> Function(List<PlayableMedia>)
  _encodeInBackground;
  final Expando<Uint8List> _encodedSongs = Expando('playback session song');
  Future<void> _tail = Future<void>.value();
  _QueueWrite? _pendingWrite;
  int _queueRevision = 0;
  int _scheduledRevision = -1;
  int _persistedRevision = -1;

  int get queueRevision => _queueRevision;

  void queueChanged() => _queueRevision++;

  void queueRestored({required bool needsRewrite}) {
    queueChanged();
    _scheduledRevision = _persistedRevision = needsRewrite
        ? -1
        : _queueRevision;
  }

  Future<void> clear({Map<String, dynamic>? resumeMedia}) {
    _scheduledRevision = -1;
    // The archive keeps the write queued before it, never a later queue.
    _pendingWrite = null;
    // Position saves queued before it still update their own stored row.
    return _enqueue(() {
      _persistedRevision = -1;
      return resumeMedia == null
          ? _database.clearPlaybackSession()
          : _database.archivePlaybackSession(resumeMedia);
    });
  }

  Future<void> persist({
    required PlaybackSessionQueue Function() queue,
    required int index,
    required Duration position,
    required bool shuffle,
    required String repeatMode,
  }) {
    final revision = _queueRevision;
    final positionMs = position.inMilliseconds;
    _Session snapshot(PlaybackSessionQueue queue) => (
      revision: revision,
      queue: queue,
      index: index,
      positionMs: positionMs,
      shuffle: shuffle,
      repeatMode: repeatMode,
    );

    if (_scheduledRevision != revision) {
      // Capture before enqueueing: the live queue may change while an older
      // write is pending, but its matching index must never change with it.
      final session = snapshot(queue());
      _scheduledRevision = revision;
      // A queue write that has not started stores this newer snapshot in
      // its place, so rapid edits encode and write the queue once.
      if (_pendingWrite case final pending?) {
        pending.session = session;
        return pending.done;
      }
      final write = _pendingWrite = _QueueWrite(session);
      return write.done = _enqueue(() async {
        if (identical(_pendingWrite, write)) _pendingWrite = null;
        final session = write.session;
        try {
          await _save(session);
          _persistedRevision = session.revision;
        } catch (_) {
          if (_scheduledRevision == session.revision) {
            _scheduledRevision = _persistedRevision;
          }
          rethrow;
        }
      });
    }

    return _enqueue(() async {
      // Scalars apply only to the row of their own queue: never to an older
      // queue left by a failed write or one a newer write replaced.
      if (_persistedRevision == revision &&
          await _database.updatePlaybackSessionState(
            index: index,
            positionMs: positionMs,
            shuffle: shuffle,
            repeatMode: repeatMode,
          )) {
        return;
      }
      if (_queueRevision != revision) return;

      // Recreate a missing row only while this scalar snapshot still belongs
      // to the live queue. A newer full write owns recovery after a change.
      await _save(snapshot(queue()));
      _persistedRevision = revision;
    });
  }

  Future<void> _save(_Session session) async {
    await _database.savePlaybackSession(
      mediaJson: await _encode(session.queue),
      index: session.index,
      positionMs: session.positionMs,
      shuffle: session.shuffle,
      repeatMode: session.repeatMode,
    );
  }

  Future<Uint8List> _encode(PlaybackSessionQueue queue) async {
    final media = queue.media;
    final songs = [for (final song in media) _encodedSongs[song]];
    final missing = [
      for (var i = 0; i < songs.length; i++)
        if (songs[i] == null) i,
    ];
    if (missing.isNotEmpty) {
      final added = [for (final i in missing) media[i]];
      List<Uint8List> encoded;
      if (added.length < backgroundEncodeThreshold) {
        encoded = _encodeSongs(added);
      } else {
        try {
          encoded = await _encodeInBackground(added);
        } catch (_) {
          // An isolate that cannot start must not fail every large write.
          encoded = _encodeSongs(added);
        }
      }
      for (var i = 0; i < missing.length; i++) {
        songs[missing[i]] = _encodedSongs[added[i]] = encoded[i];
      }
    }
    return _joinSongs(songs.cast<Uint8List>(), queue.originalIndices);
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    return _tail = _tail.then((_) async {
      try {
        await operation();
      } catch (error) {
        _onError(error);
      }
    });
  }
}

Future<List<Uint8List>> _encodeSongsInBackground(List<PlayableMedia> songs) =>
    Isolate.run(() => _encodeSongs(songs));

List<Uint8List> _encodeSongs(List<PlayableMedia> songs) => [
  for (final song in songs) _encodeSong(song),
];

/// The song's JSON object without its closing brace: each write appends the
/// song's place in the unshuffled order, as `queueOriginalIndex`.
Uint8List _encodeSong(PlayableMedia song) {
  final json = utf8.encode(jsonEncode(song.toJson()));
  return Uint8List.sublistView(json, 0, json.length - 1);
}

final _originalIndexKey = utf8.encode(',"queueOriginalIndex":');

/// The UTF-8 bytes of the `jsonEncode` of each song's map with its
/// `queueOriginalIndex`, as the saved session has always stored them.
Uint8List _joinSongs(List<Uint8List> songs, List<int>? originalIndices) {
  final ranks = [
    for (var i = 0; i < songs.length; i++) '${originalIndices?[i] ?? i}',
  ];
  var length = songs.isEmpty ? 2 : songs.length + 1;
  for (var i = 0; i < songs.length; i++) {
    length += songs[i].length + _originalIndexKey.length + ranks[i].length + 1;
  }
  final bytes = Uint8List(length);
  var at = 0;
  bytes[at++] = 0x5b;
  for (var i = 0; i < songs.length; i++) {
    if (i > 0) bytes[at++] = 0x2c;
    bytes.setAll(at, songs[i]);
    at += songs[i].length;
    bytes.setAll(at, _originalIndexKey);
    at += _originalIndexKey.length;
    for (final unit in ranks[i].codeUnits) {
      bytes[at++] = unit;
    }
    bytes[at++] = 0x7d;
  }
  bytes[at] = 0x5d;
  return bytes;
}
