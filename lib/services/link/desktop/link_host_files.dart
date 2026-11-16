import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkHostFiles');

/// The Link server asks the app to lend it a song file it cannot open
/// itself: `{"uri","lease"}`, answered `{"path"}`. Only the server sends it,
/// without a device; it refuses the op from a phone.
const linkHostFileOpenOp = 'server/files/open';

/// The Link server is done with a lent file: `{"lease"}`.
const linkHostFileCloseOp = 'server/files/close';

/// A file the platform lends: a path readable while the lease lasts, and the
/// token that ends it.
typedef LinkLentFile = ({String path, String token});

/// Lends a phone host's Link server the songs only the app can open, which
/// are Android storage access documents (`content://`). Each lent file is a
/// descriptor lease, the same kind playback uses; the server names the
/// lease and closes it once its response is done, so a close can arrive
/// while the file is still being opened and closes it as soon as it is.
///
/// The platform keeps only a few leases and gives up the oldest when more
/// open. The server reads from its own copy of each descriptor, made before
/// it asks for the next file, so that never cuts a response short.
class LinkHostFiles {
  LinkHostFiles({
    Future<LinkLentFile?> Function(String uri)? open,
    Future<void> Function(String token)? close,
    this.maxOpen = 16,
  }) : _open = open ?? _openContentUri,
       _close = close ?? PlatformBridge.closeContentUriPlaybackLease;

  /// Leases held or being opened at once; the server keeps fewer, so this
  /// only stops a runaway.
  final int maxOpen;

  final Future<LinkLentFile?> Function(String uri) _open;
  final Future<void> Function(String token) _close;

  /// Platform tokens by the server's lease names.
  final _held = <String, String>{};

  /// Leases being opened, true once the server closed them meanwhile.
  final _opening = <String, bool>{};

  /// The leases held now.
  int get held => _held.length;

  static Future<LinkLentFile?> _openContentUri(String uri) async {
    final lease = await PlatformBridge.openContentUriPlaybackLease(uri);
    return lease == null ? null : (path: lease.path, token: lease.token);
  }

  void register(LinkHostRouter router) {
    router
      ..register(linkHostFileOpenOp, _onOpen)
      ..register(linkHostFileCloseOp, _onClose);
  }

  Future<Object?> _onOpen(LinkRequest request) async {
    final lease = _lease(request);
    final uri = request.args['uri'];
    if (uri is! String || !isContentUri(uri)) {
      throw const LinkException('invalid', 'Only storage access files');
    }
    if (_held.containsKey(lease) || _opening.containsKey(lease)) {
      throw const LinkException('invalid', 'The lease is already open');
    }
    if (_held.length + _opening.length >= maxOpen) {
      throw const LinkException('unavailable', 'Too many files are open');
    }
    _opening[lease] = false;
    LinkLentFile? lent;
    var closed = false;
    try {
      lent = await _open(uri);
    } finally {
      closed = _opening.remove(lease) ?? true;
    }
    if (lent == null) {
      throw const LinkException('not_found', 'The file cannot be opened');
    }
    if (closed) {
      await _release(lent.token);
      throw const LinkException('unavailable', 'The lease was closed');
    }
    _held[lease] = lent.token;
    return {'path': lent.path};
  }

  Future<Object?> _onClose(LinkRequest request) async {
    final lease = _lease(request);
    if (_opening.containsKey(lease)) {
      _opening[lease] = true;
      return null;
    }
    final token = _held.remove(lease);
    if (token != null) await _release(token);
    return null;
  }

  /// Ends every lease, once the server is gone.
  Future<void> closeAll() async {
    for (final lease in _opening.keys) {
      _opening[lease] = true;
    }
    final tokens = [..._held.values];
    _held.clear();
    for (final token in tokens) {
      await _release(token);
    }
  }

  /// The server's lease name of [request], which only the server sends.
  String _lease(LinkRequest request) {
    if (request.deviceId.isNotEmpty) {
      throw LinkException('not_found', 'No handler for ${request.op}');
    }
    final lease = request.args['lease'];
    if (lease is! String || lease.isEmpty) {
      throw const LinkException('invalid', 'lease is required');
    }
    return lease;
  }

  Future<void> _release(String token) async {
    try {
      await _close(token);
    } on Object catch (error) {
      _log.w('Could not close a lent file: $error');
    }
  }
}

/// The phone host's file lender. Tests override it with a fake lease.
final linkHostFilesProvider = Provider<LinkHostFiles>((ref) {
  final files = LinkHostFiles();
  ref.onDispose(() => unawaited(files.closeAll()));
  return files;
});
