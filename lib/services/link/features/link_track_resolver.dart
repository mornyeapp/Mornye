import 'dart:convert';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:crypto/crypto.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';

/// A download or Library record the phone can play, with the identity the
/// queue item itself does not carry.
class LinkLocalTrack {
  const LinkLocalTrack(this.media, {this.isrc});

  final PlayableMedia media;
  final String? isrc;

  int? get durationMs => media.duration?.inMilliseconds;

  /// Scanned from a network source rather than stored on the phone.
  bool get isNetwork => media.isNetwork;
}

/// The phone's downloads and Library as the link features query them.
abstract interface class LinkLibraryLookup {
  /// The record of the file a queue item plays, by its [source] path, then
  /// by its media [id]; null when it has none.
  Future<LinkLocalTrack?> recordFor({
    required String id,
    required String source,
  });

  /// Records with this ISRC.
  Future<List<LinkLocalTrack>> byIsrc(String isrc);

  /// Records whose title and artist normalize to [matchKey]
  /// (`title|artist`, see [linkMatchKey]).
  Future<List<LinkLocalTrack>> byMatchKey(String matchKey);
}

/// Turns [TrackRef]s from the desktop into something the phone plays: a file
/// on the phone first (ISRC, then match key with the duration within two
/// seconds, then title and artist with the duration within two seconds),
/// else the desktop song streamed through [server]'s Subsonic connection.
class LinkTrackResolver {
  const LinkTrackResolver({required this.lookup, this.server});

  final LinkLibraryLookup lookup;

  /// The paired desktop, whose song ids the phone can stream.
  final LinkServerRecord? server;

  static const durationToleranceMs = 2000;

  static bool _durationMatches(TrackRef ref, LinkLocalTrack track) {
    final expected = ref.durationMs;
    final actual = track.durationMs;
    // Without both durations there is nothing to compare.
    if (expected == null || actual == null) return true;
    return (expected - actual).abs() <= durationToleranceMs;
  }

  /// The playable item for [ref], or null when the phone has no file and
  /// cannot stream it.
  Future<PlayableMedia?> resolve(TrackRef ref) async {
    final network = <LinkLocalTrack>[];
    PlayableMedia? pick(List<LinkLocalTrack> found, {required bool timed}) {
      for (final track in found) {
        if (timed && !_durationMatches(ref, track)) continue;
        if (!track.isNetwork) return track.media;
        network.add(track);
      }
      return null;
    }

    final isrc = ref.isrc;
    if (isrc != null) {
      final media = pick(await lookup.byIsrc(isrc), timed: false);
      if (media != null) return media;
    }
    final matchKey = ref.matchKey;
    if (matchKey != null) {
      final media = pick(await lookup.byMatchKey(matchKey), timed: true);
      if (media != null) return media;
    }
    final titleKey = linkMatchKey(ref.title, ref.artist);
    if (titleKey != null && titleKey != matchKey) {
      final media = pick(await lookup.byMatchKey(titleKey), timed: true);
      if (media != null) return media;
    }

    final server = this.server;
    final songId = ref.songId;
    if (server != null && songId != null && ref.serverId == server.serverId) {
      // A row scanned from this desktop already carries its cover and tags.
      for (final track in network) {
        if (linkDesktopSongId(track.media.source, server) == songId) {
          return track.media;
        }
      }
      final source = linkDesktopSongSource(server, songId);
      final durationMs = ref.durationMs;
      return PlayableMedia(
        id: 'network_${sha256.convert(utf8.encode(source))}',
        source: source,
        title: ref.title,
        artist: ref.artist,
        album: ref.album ?? '',
        duration: durationMs == null
            ? null
            : Duration(milliseconds: durationMs),
      );
    }
    return network.isEmpty ? null : network.first.media;
  }

  /// [resolve] for each of [refs], in order.
  Future<List<PlayableMedia?>> resolveAll(List<TrackRef> refs) async => [
    for (final ref in refs) await resolve(ref),
  ];
}

/// [TrackRef]s for queue items. A queue item has no ISRC of its own, so each
/// one is looked up once in the phone's records and remembered; until then
/// the ref built from the item alone stands in.
class LinkTrackRefCache {
  LinkTrackRefCache({required this.lookup, this.server});

  final LinkLibraryLookup lookup;
  final LinkServerRecord? server;
  final _refs = <String, TrackRef>{};

  static const _limit = 2000;

  static String _key(MediaItem item) =>
      '${item.id}\n${item.extras?['source'] ?? ''}';

  /// The remembered ref for [item], else one built from the item alone.
  TrackRef refFor(MediaItem item) =>
      _refs[_key(item)] ?? linkTrackRefFromMediaItem(item, server: server);

  /// The ref for [item] with the ISRC of its record.
  Future<TrackRef> resolve(MediaItem item) async {
    final key = _key(item);
    final known = _refs[key];
    if (known != null) return known;
    var ref = linkTrackRefFromMediaItem(item, server: server);
    // A desktop song id already names the track on the desktop.
    if (ref.songId == null) {
      try {
        final record = await lookup.recordFor(
          id: item.id,
          source: item.extras?['source']?.toString() ?? '',
        );
        if (record?.isrc case final isrc?) {
          ref = linkTrackRefFromMediaItem(item, server: server, isrc: isrc);
        }
      } on Object {
        // A failed lookup leaves the ref without an ISRC.
      }
    }
    if (_refs.length >= _limit) _refs.remove(_refs.keys.first);
    return _refs[key] = ref;
  }

  /// Looks up every item not yet remembered; true when any ref changed.
  Future<bool> resolveAll(Iterable<MediaItem> items) async {
    var changed = false;
    for (final item in items.toList()) {
      if (_refs.containsKey(_key(item))) continue;
      final before = linkTrackRefFromMediaItem(item, server: server);
      if (await resolve(item) != before) changed = true;
    }
    return changed;
  }
}
