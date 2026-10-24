import 'package:mornye/services/link/features/link_phone_player.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';

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

/// Moves playback between the phone and the paired desktop.
class LinkHandoff {
  const LinkHandoff({
    required this.client,
    required this.player,
    required this.refs,
    required this.resolver,
  });

  final LinkClientApi client;
  final LinkPhonePlayer player;
  final LinkTrackRefCache refs;
  final LinkTrackResolver resolver;

  /// Sends the phone's queue (at most 200 items around the current one) to
  /// the desktop and pauses the phone once the desktop plays. Null when the
  /// phone plays nothing.
  Future<LinkHandoffResult?> playOnDesktop() async {
    final snapshot = player.snapshot;
    if (snapshot.current == null) return null;
    final window = linkQueueWindow(snapshot.queue.length, snapshot.index);
    final queue = [
      for (final item in snapshot.queue.sublist(window.start, window.end))
        await refs.resolve(item),
    ];
    final reply = await client.post(
      LinkOps.handoffPlay,
      LinkHandoffQueue(
        queue: queue,
        index: snapshot.index - window.start,
        positionMs: player.snapshot.positionMs,
        playing: snapshot.playing,
      ).toJson(),
    );
    final resolved = reply is Map ? reply['resolved'] : null;
    final missing = reply is Map ? reply['missing'] : null;
    final result = LinkHandoffResult(
      queue: queue,
      resolved: resolved is num ? resolved.toInt() : 0,
      missing: missing is List
          ? [
              for (final index in missing)
                if (index is num) index.toInt(),
            ]
          : const [],
    );
    if (result.started) await player.pause();
    return result;
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
