import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mornye/services/link/client/link_client_http.dart';
import 'package:mornye/services/link/client/link_client_pairing.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkSession');

/// Why the session last failed to connect, for the settings page.
enum LinkSessionIssue {
  unreachable,

  /// The desktop refused the API key (revoked, or the record lost its key).
  unauthorized,

  /// The desktop presented a certificate other than the pinned one.
  certificate,
  localNetworkPermission,

  /// The desktop speaks another protocol version.
  incompatible,
}

/// A [LinkClientApi] the client controller can drive.
abstract interface class LinkSession implements LinkClientApi {
  LinkSessionIssue? get issue;

  /// Connects and keeps reconnecting until [dispose].
  void start();

  /// Closes the socket and stops retrying (app in the background).
  void pause();

  /// Reconnects at once after [pause].
  void resume();

  /// Skips the remaining backoff (discovery saw the desktop again).
  void reconnectNow();

  /// Uses [server]'s new address; reconnects when it changed.
  void updateServer(LinkServerRecord server);

  Future<void> dispose();
}

/// The WebSocket as the session uses it, so tests can fake it.
abstract interface class LinkSocket {
  Stream<dynamic> get stream;
  int? get closeCode;
  void add(String data);
  Future<void> close([int? code, String? reason]);
}

typedef LinkSocketConnector =
    Future<LinkSocket> Function(
      Uri uri,
      Map<String, dynamic> headers,
      HttpClient client,
    );

typedef LinkTimerFactory = Timer Function(Duration delay, void Function() run);

class _WebSocketLinkSocket implements LinkSocket {
  _WebSocketLinkSocket(this._socket) {
    // The desktop pings every 20 s; pinging back finds a vanished desktop.
    _socket.pingInterval = const Duration(seconds: 20);
  }

  final WebSocket _socket;

  @override
  Stream<dynamic> get stream => _socket;

  @override
  int? get closeCode => _socket.closeCode;

  @override
  void add(String data) => _socket.add(data);

  @override
  Future<void> close([int? code, String? reason]) =>
      _socket.close(code, reason);
}

/// Opens the desktop's WebSocket over the session's (pinned) client.
Future<LinkSocket> linkConnectWebSocket(
  Uri uri,
  Map<String, dynamic> headers,
  HttpClient client,
) async => _WebSocketLinkSocket(
  await WebSocket.connect(
    uri.toString(),
    headers: headers,
    customClient: client,
  ),
);

/// WebSocket close code for a key that belongs to another device.
const linkCloseUnauthorized = 4401;

final _opPattern = RegExp(r'^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$');

/// Whether [op] names a path under the API: plain segments, none of them
/// `.` or `..`, which would resolve outside `/mornye/v1`.
bool _validOp(String op) =>
    _opPattern.hasMatch(op) &&
    op.split('/').every((segment) => segment != '.' && segment != '..');

/// The phone's live session with one paired desktop: Bearer JSON requests
/// and the WebSocket (`hello`, `welcome`, pushed messages), reconnecting
/// with backoff from [minBackoff] doubling to [maxBackoff].
class LinkClientSession implements LinkSession {
  LinkClientSession({
    required LinkServerRecord server,
    required String apiKey,
    required LinkDeviceIdentity device,
    HttpClient Function(LinkServerRecord server)? httpClient,
    LinkSocketConnector? connectSocket,
    Future<void> Function(Uri)? ensureAccess,
    LinkTimerFactory? timer,
    Duration requestTimeout = linkRequestTimeout,
    Duration handshakeTimeout = const Duration(seconds: 15),
  }) : _server = server,
       _apiKey = apiKey,
       _device = device,
       _createHttpClient =
           httpClient ?? ((server) => linkPinnedHttpClient(server.fingerprint)),
       _connectSocket = connectSocket ?? linkConnectWebSocket,
       _ensureAccess = ensureAccess ?? LocalNetworkAccess.instance.ensureAccess,
       _timer = timer ?? Timer.new,
       _requestTimeout = requestTimeout,
       _handshakeTimeout = handshakeTimeout;

  static const minBackoff = Duration(seconds: 1);
  static const maxBackoff = Duration(seconds: 30);

  LinkServerRecord _server;
  final String _apiKey;
  final LinkDeviceIdentity _device;
  final HttpClient Function(LinkServerRecord server) _createHttpClient;
  final LinkSocketConnector _connectSocket;
  final Future<void> Function(Uri) _ensureAccess;
  final LinkTimerFactory _timer;
  final Duration _requestTimeout;
  final Duration _handshakeTimeout;

  final _states = StreamController<LinkConnectionState>.broadcast();
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  HttpClient? _http;
  LinkSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retry;
  var _state = LinkConnectionState.disconnected;
  LinkSessionIssue? _issue;
  var _backoff = minBackoff;
  var _attempt = 0;
  var _started = false;
  var _paused = false;
  var _disposed = false;

  @override
  LinkServerRecord get server => _server;

  @override
  LinkConnectionState get connectionState => _state;

  @override
  Stream<LinkConnectionState> get connectionStates => _states.stream;

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  LinkSessionIssue? get issue => _issue;

  HttpClient get _client => _http ??= _createHttpClient(_server);

  Uri get _origin => Uri.parse(_server.address);

  Map<String, String> get _authorization => {
    HttpHeaders.authorizationHeader: 'Bearer $_apiKey',
  };

  void _setState(LinkConnectionState next) {
    if (_state == next || _disposed) return;
    _state = next;
    _states.add(next);
  }

  @override
  void start() {
    if (_disposed) return;
    _started = true;
    unawaited(_connect());
  }

  @override
  void pause() {
    if (_disposed || _paused) return;
    _paused = true;
    _dropSocket(1001);
  }

  @override
  void resume() {
    if (_disposed || !_paused) return;
    _paused = false;
    _backoff = minBackoff;
    unawaited(_connect());
  }

  @override
  void reconnectNow() {
    if (_disposed || _paused || !_started) return;
    if (_state != LinkConnectionState.disconnected) return;
    _backoff = minBackoff;
    unawaited(_connect());
  }

  @override
  void updateServer(LinkServerRecord server) {
    if (_disposed) return;
    final moved =
        server.address != _server.address ||
        server.fingerprint != _server.fingerprint;
    _server = server;
    if (!moved) return;
    _http?.close(force: true);
    _http = null;
    _dropSocket(1001);
    _backoff = minBackoff;
    if (_started && !_paused) unawaited(_connect());
  }

  /// Closes the socket and forgets pending connects and retries.
  void _dropSocket(int code) {
    _attempt++;
    _retry?.cancel();
    _retry = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    final socket = _socket;
    _socket = null;
    unawaited(socket?.close(code).catchError((Object _) {}));
    _setState(LinkConnectionState.disconnected);
  }

  Future<void> _connect() async {
    if (_disposed || _paused || !_started) return;
    if (_state != LinkConnectionState.disconnected) return;
    _retry?.cancel();
    _retry = null;
    final attempt = ++_attempt;
    _setState(LinkConnectionState.connecting);
    LinkSocket? socket;
    try {
      final origin = _origin;
      await _ensureAccess(origin);
      if (attempt != _attempt) return;
      final uri = origin.replace(
        scheme: origin.scheme == 'http' ? 'ws' : 'wss',
        path: linkSocketPath,
      );
      socket = await _connectSocket(
        uri,
        _authorization,
        _client,
      ).timeout(_handshakeTimeout);
      if (attempt != _attempt) {
        unawaited(socket.close(1001).catchError((Object _) {}));
        return;
      }
      final opened = socket;
      final welcome = Completer<Map<String, dynamic>>();
      var welcomed = false;
      _socket = opened;
      _subscription = opened.stream.listen(
        (data) {
          final message = _decode(data);
          if (message == null) return;
          if (!welcomed) {
            welcomed = true;
            if (!welcome.isCompleted) welcome.complete(message);
            return;
          }
          if (attempt == _attempt) _messages.add(message);
        },
        onError: (Object error) {
          if (!welcome.isCompleted) {
            welcome.completeError(error);
          } else {
            _closed(attempt, opened);
          }
        },
        onDone: () {
          if (!welcome.isCompleted) {
            welcome.completeError(
              opened.closeCode == linkCloseUnauthorized
                  ? const LinkException(LinkClientErrors.unauthorized)
                  : const SocketException('The computer closed the link'),
            );
          } else {
            _closed(attempt, opened);
          }
        },
        cancelOnError: true,
      );
      opened.add(
        jsonEncode({
          'type': LinkMessageTypes.hello,
          'deviceId': _device.deviceId,
          'name': _device.name,
          'platform': _device.platform,
          'appVersion': _device.appVersion,
          'protocol': linkProtocolVersion,
        }),
      );
      final reply = await welcome.future.timeout(_handshakeTimeout);
      if (attempt != _attempt) return;
      final serverId = reply['serverId'];
      if (reply['type'] != LinkMessageTypes.welcome ||
          reply['protocol'] != linkProtocolVersion ||
          (serverId is String && serverId != _server.serverId)) {
        throw const LinkException('incompatible');
      }
      _issue = null;
      _backoff = minBackoff;
      _setState(LinkConnectionState.connected);
    } catch (error) {
      if (attempt != _attempt || _disposed) {
        if (socket != null && !identical(socket, _socket)) {
          unawaited(socket.close(1001).catchError((Object _) {}));
        }
        return;
      }
      _issue = _issueFor(error);
      _log.w('Connecting to the computer failed: ${_issue!.name}');
      _dropSocket(1000);
      _scheduleRetry();
    }
  }

  void _closed(int attempt, LinkSocket socket) {
    if (attempt != _attempt || _disposed) return;
    if (socket.closeCode == linkCloseUnauthorized) {
      _issue = LinkSessionIssue.unauthorized;
    }
    _dropSocket(1000);
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_disposed || _paused || !_started) return;
    // A refused key or certificate will not fix itself quickly, and a
    // denied permission waits for the person; retry slowly or not at all.
    if (_issue == LinkSessionIssue.localNetworkPermission) return;
    if (_issue == LinkSessionIssue.unauthorized ||
        _issue == LinkSessionIssue.certificate ||
        _issue == LinkSessionIssue.incompatible) {
      _backoff = maxBackoff;
    }
    final delay = _backoff;
    _backoff = Duration(
      milliseconds: min(_backoff.inMilliseconds * 2, maxBackoff.inMilliseconds),
    );
    _retry = _timer(delay, () {
      _retry = null;
      unawaited(_connect());
    });
  }

  static LinkSessionIssue _issueFor(Object error) =>
      switch (linkTransportException(error).code) {
        LinkClientErrors.unauthorized => LinkSessionIssue.unauthorized,
        LinkClientErrors.certificate => LinkSessionIssue.certificate,
        LinkClientErrors.localNetworkPermission =>
          LinkSessionIssue.localNetworkPermission,
        'incompatible' => LinkSessionIssue.incompatible,
        _ => LinkSessionIssue.unreachable,
      };

  static Map<String, dynamic>? _decode(Object? data) {
    if (data is! String) return null;
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic> && decoded['type'] is String) {
        return decoded;
      }
    } on FormatException {
      // Ignore frames that are not JSON objects.
    }
    return null;
  }

  @override
  void send(Map<String, dynamic> message) {
    final socket = _socket;
    if (_state != LinkConnectionState.connected || socket == null) return;
    try {
      socket.add(jsonEncode(message));
    } catch (error) {
      _log.w('Sending to the computer failed: $error');
    }
  }

  @override
  Future<Object?> get(String op, [Map<String, String> query = const {}]) =>
      _request('GET', op, query: query);

  @override
  Future<Object?> post(String op, Map<String, dynamic> body) =>
      _request('POST', op, body: body);

  Future<Object?> _request(
    String method,
    String op, {
    Map<String, String> query = const {},
    Map<String, dynamic>? body,
  }) async {
    _ensureOpen();
    if (!_validOp(op)) {
      throw LinkException(LinkClientErrors.invalid, 'Invalid operation $op');
    }
    final origin = _origin;
    final uri = origin.replace(
      path: '$linkApiPath/$op',
      queryParameters: query.isEmpty ? null : query,
    );
    final LinkHttpResponse response;
    try {
      await _ensureAccess(origin);
      response = await linkHttpSend(
        _client,
        method,
        uri,
        headers: _authorization,
        json: method == 'GET' ? null : body,
        timeout: _requestTimeout,
      );
    } catch (error) {
      throw linkTransportException(error);
    }
    return _answer(response);
  }

  @override
  Future<void> upload(
    String name,
    File file, {
    void Function(int sent)? onProgress,
  }) async {
    _ensureOpen();
    final dot = name.lastIndexOf('.');
    if (dot < 0 ||
        !isLinkFileId(name.substring(0, dot)) ||
        !linkUploadExtensions.contains(name.substring(dot + 1))) {
      throw LinkException(LinkClientErrors.invalid, 'Invalid file name $name');
    }
    final origin = _origin;
    final LinkHttpResponse response;
    try {
      await _ensureAccess(origin);
      response = await linkHttpUpload(
        _client,
        origin.replace(path: '$linkFilesPath/$name'),
        file,
        headers: _authorization,
        onProgress: onProgress,
        timeout: _requestTimeout,
      );
    } catch (error) {
      throw linkTransportException(error);
    }
    _answer(response);
  }

  void _ensureOpen() {
    if (_disposed) {
      throw const LinkException(
        LinkClientErrors.unavailable,
        'The link was closed',
      );
    }
  }

  /// The body of a successful [response]; throws the failure otherwise.
  Object? _answer(LinkHttpResponse response) {
    if (response.ok) return response.body;
    final failure = linkResponseException(response);
    if (response.statusCode == 401) _issue = LinkSessionIssue.unauthorized;
    throw failure;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _dropSocket(1000);
    _disposed = true;
    _http?.close(force: true);
    _http = null;
    await _states.close();
    await _messages.close();
  }
}
