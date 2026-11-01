import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/link/link_protocol.dart';

/// A request the desktop server forwarded to the app (`linkRequest`).
class LinkRequest {
  const LinkRequest({
    required this.requestId,
    required this.op,
    required this.deviceId,
    required this.args,
  });

  final String requestId;

  /// A `/mornye/v1` path such as `handoff/play`, or `subsonic/<method>`.
  final String op;
  final String deviceId;

  /// The JSON body or query. Ops shared by GET and POST carry `_method`.
  final Map<String, dynamic> args;

  String get method => args['_method'] as String? ?? 'POST';
}

/// Answers one forwarded request with a JSON value, or throws
/// [LinkException].
typedef LinkRequestHandler = Future<Object?> Function(LinkRequest request);

/// Routes forwarded requests on the desktop by op. Each feature registers
/// its ops once at startup; unknown ops answer `not_found`.
class LinkHostRouter {
  final _handlers = <String, LinkRequestHandler>{};

  /// Registers [handler] for [op], replacing an earlier one.
  void register(String op, LinkRequestHandler handler) {
    _handlers[op] = handler;
  }

  void unregister(String op) => _handlers.remove(op);

  bool handles(String op) => _handlers.containsKey(op);

  /// Runs the handler for [request]. Errors other than [LinkException]
  /// become `unavailable` so a feature bug never hangs the phone.
  Future<Object?> dispatch(LinkRequest request) async {
    final handler = _handlers[request.op];
    if (handler == null) {
      throw LinkException('not_found', 'No handler for ${request.op}');
    }
    try {
      return await handler(request);
    } on LinkException {
      rethrow;
    } on Object catch (error) {
      throw LinkException('unavailable', error.toString());
    }
  }
}

/// One song of the last catalog export (contract section 5).
class LinkCatalogSong {
  const LinkCatalogSong({
    required this.id,
    required this.title,
    required this.artist,
    required this.path,
    this.album,
    this.albumArtist,
    this.durationMs,
    this.isrc,
    this.matchKey,
  });

  /// `l:<library id>` or `d:<history id>`.
  final String id;
  final String title;
  final String artist;
  final String path;
  final String? album;
  final String? albumArtist;
  final int? durationMs;
  final String? isrc;
  final String? matchKey;
}

/// The desktop's identity index over the last catalog export, so features
/// can turn app tracks into catalog song ids and back.
abstract interface class LinkCatalogIndex {
  /// The catalog song for [id], or null.
  LinkCatalogSong? songById(String id);

  /// The best catalog match for [ref] by the [TrackRef] resolution order.
  String? songIdForRef(TrackRef ref);

  /// The best catalog match for an app [track] (collections, search).
  String? songIdForTrack(Track track);

  int get length;
}

/// The desktop's request router. The host service dispatches every
/// `linkRequest` through it; features register their ops on it.
final linkHostRouterProvider = Provider<LinkHostRouter>(
  (ref) => LinkHostRouter(),
);

/// The identity index of the last catalog export, or null before the first
/// export. The host unit sets it.
class LinkCatalogIndexState extends Notifier<LinkCatalogIndex?> {
  @override
  LinkCatalogIndex? build() => null;

  void set(LinkCatalogIndex? index) => state = index;
}

final linkCatalogIndexProvider =
    NotifierProvider<LinkCatalogIndexState, LinkCatalogIndex?>(
      LinkCatalogIndexState.new,
    );
