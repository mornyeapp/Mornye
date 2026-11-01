import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_smb2/dart_smb2.dart';
import 'package:synchronized/synchronized.dart';

/// The calls a [NetworkSmbClient] makes on a connected share: an [Smb2Pool]
/// in the app. Handles are what the open calls return, passed back as is.
abstract interface class NetworkSmbShare {
  Future<List<Smb2DirEntry>> listDirectory(String path);
  Future<Smb2Stat> stat(String path);
  Future<void> mkdir(String path);
  Future<bool> exists(String path);
  Future<void> deleteFile(String path);
  Future<void> rename(String from, String to);
  Future<Object> openFile(String path);
  Future<(Object, int)> openFileWithSize(String path);
  Future<Object> openFileWrite(String path);
  Future<Uint8List> readFromHandle(
    Object handle, {
    required int offset,
    required int length,
  });
  Future<void> writeToHandle(
    Object handle,
    Uint8List data, {
    required int offset,
  });
  Future<void> fsyncHandle(Object handle);
  Future<void> closeHandle(Object handle);
  Future<void> disconnect();
}

/// The server, share and account an SMB session logs on with.
typedef NetworkSmbLogin = ({
  String host,
  String share,
  String username,
  String password,
  String domain,
  Duration timeout,
});

typedef _SmbSessionKey = ({String id, NetworkSmbLogin login});

/// SMB2/3 only. Native network and crypto work runs off the UI isolate.
///
/// Serialize native calls across pools: libsmb2 maintains a process-wide
/// context list. Lock individual reads, never an entire audio stream, so cover
/// and metadata requests can run between bounded playback chunks.
class NetworkSmbClient {
  NetworkSmbClient._(this._share, this.path, this._release, [this._broken]);

  static final _native = Lock();
  final NetworkSmbShare _share;
  final String path;
  final FutureOr<void> Function() _release;
  final void Function()? _broken;
  bool _closed = false;

  static Future<NetworkSmbClient> connect(
    Uri target, {
    required String username,
    required String password,
    required String domain,
    required Duration timeout,
  }) async {
    final (:login, :path) = _target(
      target,
      username: username,
      password: password,
      domain: domain,
      timeout: timeout,
    );
    final share = await _native.synchronized(() => _connectPool(login));
    return NetworkSmbClient._(
      share,
      path,
      () => _native.synchronized(share.disconnect),
    );
  }

  static ({NetworkSmbLogin login, String path}) _target(
    Uri target, {
    required String username,
    required String password,
    required String domain,
    required Duration timeout,
  }) {
    final segments = target.pathSegments.where((s) => s.isNotEmpty).toList();
    return (
      login: (
        host: target.hasPort ? target.authority : target.host,
        share: segments.isEmpty ? 'IPC\$' : segments.first,
        username: username,
        password: password,
        domain: domain,
        timeout: timeout,
      ),
      path: segments.skip(1).join('/'),
    );
  }

  /// Runs [action] under the native lock. A failure that may come from a
  /// shared session rather than the path retires that session. Answers
  /// about a path carry it; a refused reconnect, which the pool repeats for
  /// minutes without asking the server, does not.
  Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await _native.synchronized(action);
    } catch (error) {
      if (_breaksSession(error)) _broken?.call();
      rethrow;
    }
  }

  static bool _breaksSession(Object error) =>
      error is! Smb2Exception ||
      error.path == null ||
      switch (error.type) {
        Smb2ErrorType.notFound ||
        Smb2ErrorType.accessDenied ||
        Smb2ErrorType.notADirectory ||
        Smb2ErrorType.isADirectory ||
        Smb2ErrorType.alreadyExists ||
        Smb2ErrorType.notEmpty ||
        Smb2ErrorType.inUse ||
        Smb2ErrorType.diskFull ||
        Smb2ErrorType.invalidParam ||
        Smb2ErrorType.notSupported ||
        Smb2ErrorType.cancelled => false,
        _ => true,
      };

  Future<List<Smb2DirEntry>> list() => _call(() => _share.listDirectory(path));

  static Future<List<Smb2ShareInfo>> shares(
    Uri target, {
    required String username,
    required String password,
    required String domain,
    required Duration timeout,
  }) => _native.synchronized(
    () => Smb2Pool.listSharesOn(
      host: target.hasPort ? target.authority : target.host,
      user: username,
      password: password,
      domain: domain,
      timeout: timeout,
    ),
  );

  Future<Smb2Stat> stat() => _call(() => _share.stat(path));

  Future<void> mkdir(String relative) => _call(() => _share.mkdir(relative));

  Future<bool> exists(String relative) => _call(() => _share.exists(relative));

  Future<void> delete(String relative) =>
      _call(() => _share.deleteFile(relative));

  Future<void> rename(String from, String to) =>
      _call(() => _share.rename(from, to));

  Future<void> upload(
    String relative,
    File file, {
    required void Function() checkpoint,
    required void Function(int) progress,
  }) async {
    final handle = await _call(() => _share.openFileWrite(relative));
    try {
      var offset = 0;
      await for (final chunk in file.openRead()) {
        checkpoint();
        await _call(
          () => _share.writeToHandle(
            handle,
            Uint8List.fromList(chunk),
            offset: offset,
          ),
        );
        offset += chunk.length;
        progress(offset);
      }
      checkpoint();
      await _call(() => _share.fsyncHandle(handle));
    } finally {
      await _call(() => _share.closeHandle(handle));
    }
  }

  /// Path metadata can lag behind writes on a NAS. Confirm the open file's
  /// length and bytes before accepting an upload with a different stat size.
  Future<bool> matchesFile(
    File file,
    int length, {
    required void Function() checkpoint,
  }) async {
    checkpoint();
    final (handle, remoteLength) = await _call(
      () => _share.openFileWithSize(path),
    );
    try {
      if (remoteLength != length) return false;
      var received = 0;
      final remote = await sha256
          .bind(
            _readHandle(handle, 0, length).map((chunk) {
              checkpoint();
              received += chunk.length;
              return chunk;
            }),
          )
          .first;
      final local = await sha256
          .bind(
            file.openRead().map((chunk) {
              checkpoint();
              return chunk;
            }),
          )
          .first;
      checkpoint();
      return received == length && remote == local;
    } finally {
      await _call(() => _share.closeHandle(handle));
    }
  }

  /// End is exclusive. Keep one handle and obey downstream backpressure.
  Stream<Uint8List> read(int start, int end) async* {
    final handle = await _call(() => _share.openFile(path));
    try {
      yield* _readHandle(handle, start, end);
    } finally {
      await _call(() => _share.closeHandle(handle));
    }
  }

  Stream<Uint8List> _readHandle(Object handle, int start, int end) async* {
    var offset = start;
    while (offset < end && !_closed) {
      final bytes = await _call(
        () => _share.readFromHandle(
          handle,
          offset: offset,
          length: min(256 * 1024, end - offset),
        ),
      );
      if (bytes.isEmpty) {
        throw StateError('SMB file ended before requested range');
      }
      offset += bytes.length;
      yield bytes;
    }
  }

  /// Disconnects a client of its own; a lease hands its session back.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _release();
  }
}

/// SMB read sessions shared by connection and login, so listings and byte
/// range reads stop spawning a worker and logging on for every call.
///
/// A session closes [idle] after its last lease ends, after [retire] names
/// its connection, or after a call on it fails in a way the session may have
/// caused; leases still holding it finish first. Its own worker reconnects a
/// dropped connection and repeats the call once, as a new session would.
class NetworkSmbSessions {
  NetworkSmbSessions({
    Future<NetworkSmbShare> Function(NetworkSmbLogin login)? open,
    this.idle = const Duration(seconds: 20),
  }) : _open = open ?? _connectPool;

  final Future<NetworkSmbShare> Function(NetworkSmbLogin login) _open;
  final Duration idle;
  final _current = <_SmbSessionKey, _SmbSession>{};
  final _live = <_SmbSession>{};

  /// A dedicated session for writes, using the same transport as read leases.
  Future<NetworkSmbClient> connect(
    Uri target, {
    required String username,
    required String password,
    required String domain,
    required Duration timeout,
  }) async {
    final (:login, :path) = NetworkSmbClient._target(
      target,
      username: username,
      password: password,
      domain: domain,
      timeout: timeout,
    );
    final share = await NetworkSmbClient._native.synchronized(
      () => _open(login),
    );
    return NetworkSmbClient._(
      share,
      path,
      () => NetworkSmbClient._native.synchronized(share.disconnect),
    );
  }

  /// A client for [target] on the shared session of connection [id] and
  /// this login, opened when there is none. Close it to hand it back.
  Future<NetworkSmbClient> lease(
    String id,
    Uri target, {
    required String username,
    required String password,
    required String domain,
    required Duration timeout,
  }) async {
    final (:login, :path) = NetworkSmbClient._target(
      target,
      username: username,
      password: password,
      domain: domain,
      timeout: timeout,
    );
    final key = (id: id, login: login);
    final session = _current[key] ??= _start(key);
    session.idle?.cancel();
    session.leases++;
    final NetworkSmbShare share;
    try {
      share = await session.share;
    } catch (_) {
      _retire(session);
      _release(session);
      rethrow;
    }
    return NetworkSmbClient._(
      share,
      path,
      () => _release(session),
      () => _retire(session),
    );
  }

  /// Closes the sessions of connection [id] once their leases end, so the
  /// next read logs on with what was saved.
  void retire(String id) {
    for (final session in [..._current.values]) {
      if (session.key.id == id) _retire(session);
    }
  }

  /// Closes every session now, leased or not.
  Future<void> close() async {
    final sessions = [..._live];
    _current.clear();
    for (final session in sessions) {
      session.retired = true;
      session.idle?.cancel();
    }
    await Future.wait(sessions.map(_disconnect));
  }

  _SmbSession _start(_SmbSessionKey key) {
    final session = _SmbSession(
      key,
      NetworkSmbClient._native.synchronized(() => _open(key.login)),
    );
    _live.add(session);
    return session;
  }

  void _release(_SmbSession session) {
    if (--session.leases > 0) return;
    if (session.retired) {
      unawaited(_disconnect(session));
    } else {
      session.idle = Timer(idle, () => _retire(session));
    }
  }

  void _retire(_SmbSession session) {
    session.retired = true;
    session.idle?.cancel();
    if (identical(_current[session.key], session)) {
      _current.remove(session.key);
    }
    if (session.leases == 0) unawaited(_disconnect(session));
  }

  Future<void> _disconnect(_SmbSession session) =>
      session.closing ??= () async {
        try {
          final share = await session.share;
          await NetworkSmbClient._native.synchronized(share.disconnect);
        } catch (_) {
          // A session that never opened has nothing to close.
        } finally {
          _live.remove(session);
        }
      }();
}

class _SmbSession {
  _SmbSession(this.key, this.share);

  final _SmbSessionKey key;
  final Future<NetworkSmbShare> share;
  int leases = 0;
  bool retired = false;
  Timer? idle;
  Future<void>? closing;
}

Future<NetworkSmbShare> _connectPool(NetworkSmbLogin login) async => _PoolShare(
  await Smb2Pool.connect(
    host: login.host,
    share: login.share,
    user: login.username,
    password: login.password,
    domain: login.domain,
    workers: 1,
    timeout: login.timeout,
    version: Smb2Version.any,
  ),
);

final class _PoolShare implements NetworkSmbShare {
  _PoolShare(this._pool);

  final Smb2Pool _pool;

  @override
  Future<List<Smb2DirEntry>> listDirectory(String path) =>
      _pool.listDirectory(path);

  @override
  Future<Smb2Stat> stat(String path) => _pool.stat(path);

  @override
  Future<void> mkdir(String path) => _pool.mkdir(path);

  @override
  Future<bool> exists(String path) => _pool.exists(path);

  @override
  Future<void> deleteFile(String path) => _pool.deleteFile(path);

  @override
  Future<void> rename(String from, String to) => _pool.rename(from, to);

  @override
  Future<Object> openFile(String path) => _pool.openFile(path);

  @override
  Future<(Object, int)> openFileWithSize(String path) =>
      _pool.openFileWithSize(path);

  @override
  Future<Object> openFileWrite(String path) => _pool.openFileWrite(path);

  @override
  Future<Uint8List> readFromHandle(
    Object handle, {
    required int offset,
    required int length,
  }) => _pool.readFromHandle(
    handle as Smb2PoolHandle,
    offset: offset,
    length: length,
  );

  @override
  Future<void> writeToHandle(
    Object handle,
    Uint8List data, {
    required int offset,
  }) => _pool.writeToHandle(handle as Smb2PoolHandle, data, offset: offset);

  @override
  Future<void> fsyncHandle(Object handle) =>
      _pool.fsyncHandle(handle as Smb2PoolHandle);

  @override
  Future<void> closeHandle(Object handle) =>
      _pool.closeHandle(handle as Smb2PoolHandle);

  @override
  Future<void> disconnect() => _pool.disconnect();
}
