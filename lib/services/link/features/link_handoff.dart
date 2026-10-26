import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/services/link/features/link_phone_player.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkHandoff');

/// The desktop's answer to "Play on desktop".
class LinkHandoffResult {
  const LinkHandoffResult({
    required this.queue,
    required this.resolved,
    required this.missing,
  });

  /// What the phone sent.
  final List<TrackRef> queue;

  /// How many of [queue] the desktop found.
  final int resolved;

  /// Indexes into [queue] the desktop could not find.
  final List<int> missing;

  List<TrackRef> get missingTracks => [
    for (final index in missing)
      if (index >= 0 && index < queue.length) queue[index],
  ];

  /// The desktop plays at least one track, so the phone pauses.
  bool get started => resolved > 0;
}

/// What the phone did with a queue handed to it.
class LinkContinueResult {
  const LinkContinueResult({required this.played, required this.skipped});

  /// How many items the phone queued.
  final int played;

  /// Tracks the phone has no file for and cannot stream.
  final List<TrackRef> skipped;

  bool get started => played > 0;
}

/// A queue handed between devices (`handoff/play` body, `handoff/current`
/// reply, `play_queue` command arguments).
class LinkHandoffQueue {
  const LinkHandoffQueue({
    required this.queue,
    required this.index,
    required this.positionMs,
    required this.playing,
    this.shuffle,
    this.repeat,
    this.autoplay,
    this.autoMix,
  });

  final List<TrackRef> queue;
  final int index;
  final int positionMs;
  final bool playing;
  final bool? shuffle;
  final LinkRepeatMode? repeat;
  final bool? autoplay;
  final bool? autoMix;

  Map<String, dynamic> toJson() => {
    'queue': [for (final ref in queue) ref.toJson()],
    'index': index,
    'positionMs': positionMs,
    'playing': playing,
    if (shuffle != null) 'shuffle': shuffle,
    if (repeat != null) 'repeat': repeat!.name,
    if (autoplay != null) 'autoplay': autoplay,
    if (autoMix != null) 'autoMix': autoMix,
  };

  static LinkHandoffQueue fromJson(Object? json) {
    if (json is! Map) {
      return const LinkHandoffQueue(
        queue: [],
        index: -1,
        positionMs: 0,
        playing: false,
      );
    }
    final queue = json['queue'];
    final index = json['index'];
    final position = json['positionMs'];
    return LinkHandoffQueue(
      queue: queue is List
          ? [for (final item in queue) ?TrackRef.fromJson(item)]
          : const [],
      index: index is num ? index.toInt() : 0,
      positionMs: position is num ? position.toInt() : 0,
      playing: json['playing'] != false,
      shuffle: json['shuffle'] is bool ? json['shuffle'] as bool : null,
      repeat: LinkRepeatMode.values.asNameMap()[json['repeat']],
      autoplay: json['autoplay'] is bool ? json['autoplay'] as bool : null,
      autoMix: json['autoMix'] is bool ? json['autoMix'] as bool : null,
    );
  }
}

/// How much of a [total]-byte song the desktop needs before it starts the
/// song at [fraction] of its length: the bytes up to there and a margin
/// for the header and the player's first buffer.
int linkStartBytes(int total, double fraction) {
  const margin = 512 * 1024;
  return min(total, (total * fraction.clamp(0.0, 1.0)).ceil() + margin);
}

List<int> _indexes(Object? reply, String key) {
  final value = reply is Map ? reply[key] : null;
  return value is List
      ? [
          for (final index in value)
            if (index is num) index.toInt(),
        ]
      : const [];
}

/// Whether the desktop's [track] is the queue entry [ref] the phone sent.
/// The desktop names a song it plays from the phone's file by the title and
/// artist the phone sent, and a Library song by the Library's tags.
bool _sameTrack(TrackRef ref, TrackRef track) =>
    (ref.songId != null && ref.songId == track.songId) ||
    (ref.isrc != null && ref.isrc == track.isrc) ||
    (ref.matchKey != null && ref.matchKey == track.matchKey) ||
    (ref.title == track.title && ref.artist == track.artist);

/// Where the desktop plays in a queue the phone handed it, as its
/// `player.state` pushes tell, and the songs sent that it has not reached.
class _DesktopProgress {
  _DesktopProgress(this.queue, {required this.at, required this.queued});

  final List<TrackRef> queue;

  /// The entry of [queue] the desktop plays, as last heard.
  int at;

  /// The entries of [queue] before this one are in the desktop's queue.
  int queued;

  final _sent = <({int at, int size})>[];
  TrackRef? _track;
  bool _strayed = false;
  bool _closed = false;
  Completer<bool>? _heard;

  /// Takes a pushed `player.state`.
  void hear(Map<String, dynamic> message) {
    if (message['type'] != LinkMessageTypes.playerState) return;
    final track = LinkPlayerState.fromJson(message['state'])?.track;
    final found = track == null ? null : _find(track);
    if (found != null) {
      at = found;
    } else if (track != _track) {
      _strayed = true;
    }
    _track = track;
    _wake(true);
  }

  /// The queued entry nearest [at] that is [track], looking ahead first.
  int? _find(TrackRef track) {
    for (var i = at; i < queued; i++) {
      if (_sameTrack(queue[i], track)) return i;
    }
    for (var i = min(at, queued) - 1; i >= 0; i--) {
      if (_sameTrack(queue[i], track)) return i;
    }
    return null;
  }

  /// Whether the desktop moved, since last asked, to a song that is none of
  /// the queued entries.
  bool takeStrayed() {
    final strayed = _strayed;
    _strayed = false;
    return strayed;
  }

  /// Notes the entry [at] sent, of [size] bytes.
  void sent(int at, int size) => _sent.add((at: at, size: size));

  /// Whether another song may go: the songs sent that the desktop has not
  /// reached are fewer than [songs] and under [bytes] together.
  bool room({required int songs, required int bytes}) {
    var count = 0;
    var total = 0;
    for (final sent in _sent) {
      if (sent.at <= at) continue;
      count++;
      total += sent.size;
    }
    return count < songs && total < bytes;
  }

  /// Waits for the desktop's next state; false once the session ends.
  Future<bool> heard() {
    if (_closed) return Future.value(false);
    return (_heard ??= Completer<bool>()).future;
  }

  void close() {
    _closed = true;
    _wake(false);
  }

  void _wake(bool value) {
    final heard = _heard;
    _heard = null;
    heard?.complete(value);
  }
}

/// How many bytes of songs the phone sends ahead of the one the desktop
/// plays; one song may pass it. The desktop keeps 4 GiB of received songs
/// and removes the oldest first, so a quarter of that ahead leaves room for
/// the current song and the ones just played.
const linkHandoffAheadBytes = 1 << 30;

/// How many songs the phone sends ahead of the one the desktop plays on
/// battery: each one the desktop reaches is replaced, so a few keep the
/// queue playing for a while after the phone leaves without spending its
/// battery and network on songs that may be skipped. A skip ahead refills
/// at network speed, and a song not sent yet streams as it arrives.
const linkHandoffAheadSongs = 3;

/// [linkHandoffAheadSongs] while the phone charges.
const linkHandoffAheadSongsCharging = 5;

/// Moves playback between the phone and the paired desktop.
class LinkHandoff {
  const LinkHandoff({
    required this.client,
    required this.player,
    required this.refs,
    required this.resolver,
    this.files,
    this.aheadBytes = linkHandoffAheadBytes,
    this.aheadSongs = linkHandoffAheadSongs,
    this.aheadSongsCharging = linkHandoffAheadSongsCharging,
    this.isCharging,
  });

  final LinkClientApi client;
  final LinkPhonePlayer player;
  final LinkTrackRefCache refs;
  final LinkTrackResolver resolver;

  /// Sends the phone's own song files; without it the desktop plays only
  /// what its Library has.
  final LinkPhoneFiles? files;

  /// [linkHandoffAheadBytes], [linkHandoffAheadSongs] and
  /// [linkHandoffAheadSongsCharging]; tests lower them.
  final int aheadBytes;
  final int aheadSongs;
  final int aheadSongsCharging;

  /// Whether the phone is on external power, asked before each song sent
  /// ahead; null counts as on battery.
  final Future<bool> Function()? isCharging;

  Future<int> _aheadSongs() async {
    final charging = isCharging;
    if (charging == null) return aheadSongs;
    try {
      return await charging() ? aheadSongsCharging : aheadSongs;
    } on Object {
      return aheadSongs;
    }
  }

  /// Sends the phone's queue (at most 200 items around the current one) to
  /// the desktop and pauses the phone once the desktop plays. The desktop
  /// always starts playing, as "Continue on this phone" does. Null when the
  /// phone plays nothing.
  ///
  /// Songs only the phone has are uploaded. The current one goes first and
  /// [onSending] reports its progress. Later ones follow in the background,
  /// each added to the desktop's queue in order once it arrives, a few songs
  /// ahead of the one the desktop plays; ones before the current song are
  /// not sent.
  Future<LinkHandoffResult?> playOnDesktop({
    void Function(int sent, int total)? onSending,
  }) async {
    final snapshot = player.snapshot;
    if (snapshot.current == null) return null;
    final window = linkQueueWindow(snapshot.queue.length, snapshot.index);
    return _sendQueue(
      snapshot.queue.sublist(window.start, window.end),
      current: snapshot.index - window.start,
      positionMs: () => player.snapshot.positionMs,
      onSending: onSending,
    );
  }

  /// Starts [items] on the desktop from [index], as [playOnDesktop] sends
  /// the phone's queue: what the phone picks while the desktop plays in its
  /// place.
  Future<LinkHandoffResult?> playItemsOnDesktop(
    List<MediaItem> items, {
    required int index,
    LinkPlayerState? modes,
    void Function(int sent, int total)? onSending,
  }) async {
    if (index < 0 || index >= items.length) return null;
    final window = linkQueueWindow(items.length, index);
    return _sendQueue(
      items.sublist(window.start, window.end),
      current: index - window.start,
      positionMs: () => 0,
      modes: modes,
      onSending: onSending,
    );
  }

  /// Adds [items] to the desktop's queue, after its current song when
  /// [playNext], sending the songs only the phone has first; [onSending]
  /// reports each one's progress. Reports how many the desktop queued.
  Future<int> addToDesktopQueue(
    List<MediaItem> items, {
    bool playNext = false,
    void Function(int sent, int total)? onSending,
  }) async {
    final (:queue, :phoneFiles) = await _refs(items);
    final files = this.files;
    if (files != null) {
      for (final i in await _missing(queue, phoneFiles, current: 0)) {
        await files.upload(client, phoneFiles[i]!, onProgress: onSending);
      }
    }
    final reply = await client.post(LinkOps.queueAdd, {
      'queue': [for (final ref in queue) ref.toJson()],
      'next': playNext,
    });
    final resolved = reply is Map ? reply['resolved'] : null;
    return resolved is num ? resolved.toInt() : 0;
  }

  /// The refs [items] travel as, with the phone's file behind each, if any.
  Future<({List<TrackRef> queue, List<LinkPhoneFile?> phoneFiles})> _refs(
    List<MediaItem> items,
  ) async {
    final files = this.files;
    final phoneFiles = <LinkPhoneFile?>[];
    final queue = <TrackRef>[];
    for (final item in items) {
      final file = await files?.fileFor(item);
      final ref = await refs.resolve(item);
      phoneFiles.add(file);
      queue.add(file == null ? ref : ref.withFileId(file.fileId));
    }
    return (queue: queue, phoneFiles: phoneFiles);
  }

  /// The entries of [queue] the desktop lacks and the phone can send.
  Future<Set<int>> _missing(
    List<TrackRef> queue,
    List<LinkPhoneFile?> phoneFiles, {
    required int current,
  }) async {
    if (files == null || phoneFiles.every((file) => file == null)) return {};
    final check = await client.post(LinkOps.handoffPlay, {
      ...LinkHandoffQueue(
        queue: queue,
        index: current,
        positionMs: 0,
        playing: true,
      ).toJson(),
      'check': true,
    });
    return {
      for (final i in _indexes(check, 'missing'))
        if (i >= 0 && i < queue.length && phoneFiles[i] != null) i,
    };
  }

  Future<LinkHandoffResult> _sendQueue(
    List<MediaItem> items, {
    required int current,
    required int Function() positionMs,
    LinkPlayerState? modes,
    void Function(int sent, int total)? onSending,
  }) async {
    final files = this.files;
    final run = files?.begin();
    final (:queue, :phoneFiles) = await _refs(items);

    // Songs the desktop lacks that the phone can send.
    final pending = await _missing(queue, phoneFiles, current: current);
    ({LinkUploadStart? start, Future<void> whole})? upload;
    if (pending.remove(current)) {
      final duration = items[current].duration?.inMilliseconds ?? 0;
      final position = positionMs();
      upload = await _startUpload(
        files!,
        phoneFiles[current]!,
        fraction: position <= 0
            ? 0
            : duration > 0
            ? position / duration
            : 1,
        onSending: onSending,
      );
    }

    // The desktop starts with the songs around the current one up to the
    // nearest ones still to send.
    var first = current;
    while (first > 0 && !pending.contains(first - 1)) {
      first--;
    }
    var last = current;
    while (last < items.length - 1 && !pending.contains(last + 1)) {
      last++;
    }
    final played = queue.sublist(first, last + 1);
    final arriving = upload?.start;
    final localModes = player.snapshot;
    final reply = await client.post(LinkOps.handoffPlay, {
      ...LinkHandoffQueue(
        queue: played,
        index: current - first,
        positionMs: positionMs(),
        playing: true,
        shuffle: modes?.shuffle ?? localModes.shuffle,
        repeat: modes?.repeat ?? localModes.repeat,
        autoplay: modes?.autoplay ?? localModes.autoplay,
        autoMix: modes?.autoMix ?? localModes.autoMix,
      ).toJson(),
      if (arriving != null)
        'arriving': [
          {'name': arriving.name, 'size': arriving.size},
        ],
    });
    final resolved = reply is Map ? reply['resolved'] : null;
    final handoffId = reply is Map ? reply['handoffId'] : null;
    final result = LinkHandoffResult(
      queue: played,
      resolved: resolved is num ? resolved.toInt() : 0,
      missing: _indexes(reply, 'missing'),
    );
    if (result.started) await player.pause();
    final later = [...pending.where((i) => i > last)]..sort();
    if (files != null && handoffId is String && later.isNotEmpty) {
      unawaited(
        _sendLater(
          files,
          run!,
          handoffId,
          _DesktopProgress(queue, at: current, queued: last + 1),
          phoneFiles,
          later,
          after: upload?.whole,
        ),
      );
    }
    return result;
  }

  /// Starts uploading [file] and returns once the desktop can start it at
  /// [fraction] of its length: when the bytes up to there, and a margin, are
  /// sent, or all of them for a file that cannot start before it is whole.
  /// The rest goes on in the background ([whole]) while the desktop streams
  /// it; [onSending] reports the progress toward the start.
  Future<({LinkUploadStart? start, Future<void> whole})> _startUpload(
    LinkPhoneFiles files,
    LinkPhoneFile file, {
    required double fraction,
    void Function(int sent, int total)? onSending,
  }) async {
    final ready = Completer<void>();
    LinkUploadStart? start;
    final whole = files.upload(
      client,
      file,
      onStart: (value) => start = value,
      onProgress: (sent, total) {
        if (ready.isCompleted) return;
        final needed = start?.streamable ?? false
            ? linkStartBytes(total, fraction)
            : total;
        onSending?.call(sent, needed);
        if (sent >= needed) ready.complete();
      },
    );
    whole
        .then(
          (_) {
            if (!ready.isCompleted) ready.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!ready.isCompleted) return ready.completeError(error, stack);
            _log.w('Could not finish sending a song to the computer: $error');
          },
        )
        .ignore();
    await ready.future;
    return (start: start, whole: whole);
  }

  /// Uploads the songs at [later] (ascending) one by one, once the upload
  /// [after] (the current song's) ends, at most [aheadSongs] and about
  /// [aheadBytes] ahead of the one the desktop plays: the desktop prunes
  /// its received songs oldest first, so sending a long queue at once
  /// removed the songs it was about to play. [desktop] follows where it
  /// plays. After each upload, the desktop queues the song and the songs up
  /// to the next one to send, which it already has or cannot get. Stops
  /// when another queue is sent or the desktop plays something else.
  Future<void> _sendLater(
    LinkPhoneFiles files,
    int run,
    String handoffId,
    _DesktopProgress desktop,
    List<LinkPhoneFile?> phoneFiles,
    List<int> later, {
    Future<void>? after,
  }) async {
    final queue = desktop.queue;
    final states = client.messages.listen(desktop.hear, onDone: desktop.close);
    try {
      try {
        await after;
      } on Object {
        // Reported where it was started.
      }
      for (var k = 0; k < later.length; k++) {
        final at = later[k];
        while (!desktop.room(songs: await _aheadSongs(), bytes: aheadBytes)) {
          if (desktop.takeStrayed()) {
            // An empty append fails once another queue plays there.
            await _append(handoffId, const []);
            continue;
          }
          if (!await desktop.heard() || !files.isCurrent(run)) return;
        }
        if (!files.isCurrent(run)) return;
        int? size;
        try {
          await files.upload(
            client,
            phoneFiles[at]!,
            onStart: (start) => size = start.size,
          );
        } on Object catch (error) {
          _log.w('Could not send a song to the computer: $error');
          size = null;
        }
        if (!files.isCurrent(run)) return;
        if (size case final bytes?) desktop.sent(at, bytes);
        final end = k + 1 < later.length ? later[k + 1] : queue.length;
        final added = queue.sublist(size != null ? at : at + 1, end);
        if (added.isNotEmpty) await _append(handoffId, added);
        desktop.queued = end;
      }
    } on Object catch (error) {
      _log.w('Stopped sending songs to the computer: $error');
    } finally {
      await states.cancel();
    }
  }

  /// Adds [refs] to the end of the queue [handoffId] started on the
  /// desktop; fails once another queue plays there.
  Future<void> _append(String handoffId, List<TrackRef> refs) =>
      client.post(LinkOps.handoffAppend, {
        'handoffId': handoffId,
        'queue': [for (final ref in refs) ref.toJson()],
      });

  /// Takes over what the desktop plays (`GET handoff/current`), then pauses
  /// the desktop. The phone starts playing even when the desktop was paused:
  /// the listener asked to continue here.
  Future<LinkContinueResult> continueOnPhone() async {
    final current = LinkHandoffQueue.fromJson(
      await client.get(LinkOps.handoffCurrent),
    );
    final result = await play(
      LinkHandoffQueue(
        queue: current.queue,
        index: current.index,
        positionMs: current.positionMs,
        playing: true,
        shuffle: current.shuffle,
        repeat: current.repeat,
        autoplay: current.autoplay,
        autoMix: current.autoMix,
      ),
    );
    if (result.started) {
      await client.post(
        LinkOps.command,
        const LinkCommand(LinkActions.pause).toJson(),
      );
    }
    return result;
  }

  /// Plays [handoff] on the phone, skipping tracks it cannot resolve. When
  /// the current track is one of them, the next playable one starts from
  /// its beginning.
  Future<LinkContinueResult> play(LinkHandoffQueue handoff) async {
    final media = await resolver.resolveAll(handoff.queue);
    final items = <PlayableMedia>[];
    final skipped = <TrackRef>[];
    var start = -1;
    var currentResolved = false;
    for (var i = 0; i < media.length; i++) {
      final item = media[i];
      if (item == null) {
        skipped.add(handoff.queue[i]);
        continue;
      }
      if (start < 0 && i >= handoff.index) {
        start = items.length;
        currentResolved = i == handoff.index;
      }
      items.add(item);
    }
    if (items.isEmpty) return LinkContinueResult(played: 0, skipped: skipped);
    // Nothing playable at or after the current track: play the last one
    // before it.
    if (start < 0) start = items.length - 1;
    if (handoff.autoplay case final enabled?) await player.setAutoplay(enabled);
    if (handoff.autoMix case final enabled?) await player.setAutoMix(enabled);
    if (handoff.repeat case final mode?) await player.setRepeat(mode);
    await player.playQueue(
      items,
      index: start,
      position: Duration(
        milliseconds: currentResolved && handoff.positionMs > 0
            ? handoff.positionMs
            : 0,
      ),
      playing: handoff.playing,
      shuffle: handoff.shuffle,
    );
    return LinkContinueResult(played: items.length, skipped: skipped);
  }
}
