import 'dart:async';

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
  });

  final List<TrackRef> queue;
  final int index;
  final int positionMs;
  final bool playing;

  Map<String, dynamic> toJson() => {
    'queue': [for (final ref in queue) ref.toJson()],
    'index': index,
    'positionMs': positionMs,
    'playing': playing,
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
    );
  }
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

/// Moves playback between the phone and the paired desktop.
class LinkHandoff {
  const LinkHandoff({
    required this.client,
    required this.player,
    required this.refs,
    required this.resolver,
    this.files,
  });

  final LinkClientApi client;
  final LinkPhonePlayer player;
  final LinkTrackRefCache refs;
  final LinkTrackResolver resolver;

  /// Sends the phone's own song files; without it the desktop plays only
  /// what its Library has.
  final LinkPhoneFiles? files;

  /// Sends the phone's queue (at most 200 items around the current one) to
  /// the desktop and pauses the phone once the desktop plays. The desktop
  /// always starts playing, as "Continue on this phone" does. Null when the
  /// phone plays nothing.
  ///
  /// Songs only the phone has are uploaded. The current one goes first and
  /// [onSending] reports its progress. Later ones follow in the background,
  /// each added to the desktop's queue in order once it arrives; ones before
  /// the current song are not sent.
  Future<LinkHandoffResult?> playOnDesktop({
    void Function(int sent, int total)? onSending,
  }) async {
    final snapshot = player.snapshot;
    if (snapshot.current == null) return null;
    final window = linkQueueWindow(snapshot.queue.length, snapshot.index);
    final items = snapshot.queue.sublist(window.start, window.end);
    final current = snapshot.index - window.start;
    final files = this.files;
    final run = files?.begin();
    final phoneFiles = <LinkPhoneFile?>[];
    final queue = <TrackRef>[];
    for (final item in items) {
      final file = await files?.fileFor(item);
      final ref = await refs.resolve(item);
      phoneFiles.add(file);
      queue.add(file == null ? ref : ref.withFileId(file.fileId));
    }

    // Songs the desktop lacks that the phone can send.
    final pending = <int>{};
    if (files != null && phoneFiles.any((file) => file != null)) {
      final check = await client.post(LinkOps.handoffPlay, {
        ...LinkHandoffQueue(
          queue: queue,
          index: current,
          positionMs: 0,
          playing: true,
        ).toJson(),
        'check': true,
      });
      pending.addAll(
        _indexes(
          check,
          'missing',
        ).where((i) => i >= 0 && i < items.length && phoneFiles[i] != null),
      );
      if (pending.remove(current)) {
        await files.upload(client, phoneFiles[current]!, onProgress: onSending);
      }
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
    final reply = await client.post(
      LinkOps.handoffPlay,
      LinkHandoffQueue(
        queue: played,
        index: current - first,
        positionMs: player.snapshot.positionMs,
        playing: true,
      ).toJson(),
    );
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
      unawaited(_sendLater(files, run!, handoffId, queue, phoneFiles, later));
    }
    return result;
  }

  /// Uploads the songs at [later] (ascending) one by one. After each, the
  /// desktop queues it and the songs up to the next one to send, which it
  /// already has or cannot get. Stops when another queue is sent or the
  /// desktop plays something else.
  Future<void> _sendLater(
    LinkPhoneFiles files,
    int run,
    String handoffId,
    List<TrackRef> queue,
    List<LinkPhoneFile?> phoneFiles,
    List<int> later,
  ) async {
    try {
      for (var k = 0; k < later.length; k++) {
        final at = later[k];
        var sent = true;
        try {
          await files.upload(client, phoneFiles[at]!);
        } on Object catch (error) {
          _log.w('Could not send a song to the computer: $error');
          sent = false;
        }
        if (!files.isCurrent(run)) return;
        final end = k + 1 < later.length ? later[k + 1] : queue.length;
        final added = queue.sublist(sent ? at : at + 1, end);
        if (added.isEmpty) continue;
        await client.post(LinkOps.handoffAppend, {
          'handoffId': handoffId,
          'queue': [for (final ref in added) ref.toJson()],
        });
      }
    } on Object catch (error) {
      _log.w('Stopped sending songs to the computer: $error');
    }
  }

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
    await player.playQueue(
      items,
      index: start,
      position: Duration(
        milliseconds: currentResolved && handoff.positionMs > 0
            ? handoff.positionMs
            : 0,
      ),
      playing: handoff.playing,
    );
    return LinkContinueResult(played: items.length, skipped: skipped);
  }
}
