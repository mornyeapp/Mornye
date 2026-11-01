import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_library_scanner.dart';
import 'package:mornye/services/network_smb_client.dart';
import 'package:mornye/services/network_storage_service.dart';

final _date = DateTime.utc(2026);

Smb2Stat _stat(Smb2FileType type, int size) => Smb2Stat(
  type: type,
  size: size,
  modified: _date,
  created: _date,
  accessed: _date,
  changed: _date,
);

class _Handle {
  _Handle(this.path);

  final String path;
}

/// A share of generated files. It counts logons, the calls made and the
/// handles left open, logs every call in order, and records how many native
/// calls were ever in flight at once.
class _FakeServer {
  _FakeServer(this.files);

  final Map<String, List<int>> files;
  final logins = <NetworkSmbLogin>[];
  final shares = <_FakeShare>[];
  final log = <String>[];
  int active = 0;
  int maxActive = 0;
  Object? refuse;
  Smb2Exception? failNext;
  Completer<void>? gate;

  int get opened => logins.length;
  int get closed => shares.where((share) => share.disconnected).length;
  int get openHandles =>
      shares.fold(0, (count, share) => count + share.handles.length);
  int count(String call) => log.where((entry) => entry == call).length;

  Future<T> run<T>(String call, T Function() body) async {
    active++;
    if (active > maxActive) maxActive = active;
    try {
      log.add(call);
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return body();
    } finally {
      active--;
    }
  }

  Future<NetworkSmbShare> open(NetworkSmbLogin login) => run('logon', () {
    logins.add(login);
    if (refuse case final refused?) throw refused;
    final share = _FakeShare(this);
    shares.add(share);
    return share;
  });
}

class _FakeShare implements NetworkSmbShare {
  _FakeShare(this.server);

  final _FakeServer server;
  final handles = <_Handle>{};
  bool disconnected = false;

  Future<T> _run<T>(String call, T Function() body) => server.run(call, () {
    if (disconnected) {
      throw const Smb2Exception(
        'The pool is closed',
        type: Smb2ErrorType.state,
      );
    }
    if (server.failNext case final failure?) {
      server.failNext = null;
      throw failure;
    }
    return body();
  });

  List<int> _file(String path) =>
      server.files[path] ??
      (throw Smb2Exception(
        'No such file',
        type: Smb2ErrorType.notFound,
        path: path,
      ));

  @override
  Future<List<Smb2DirEntry>> listDirectory(String path) => _run('list', () {
    final prefix = path.isEmpty ? '' : '$path/';
    final children = <String, Smb2DirEntry>{};
    for (final MapEntry(key: file, value: bytes) in server.files.entries) {
      if (!file.startsWith(prefix)) continue;
      final parts = file.substring(prefix.length).split('/');
      children[parts.first] = Smb2DirEntry(
        name: parts.first,
        stat: parts.length > 1
            ? _stat(Smb2FileType.directory, 0)
            : _stat(Smb2FileType.file, bytes.length),
      );
    }
    if (children.isEmpty) {
      throw Smb2Exception(
        'No such folder',
        type: Smb2ErrorType.notFound,
        path: path,
      );
    }
    return children.values.toList();
  });

  @override
  Future<Smb2Stat> stat(String path) =>
      _run('stat', () => _stat(Smb2FileType.file, _file(path).length));

  @override
  Future<Object> openFile(String path) => _run('open', () {
    _file(path);
    final handle = _Handle(path);
    handles.add(handle);
    return handle;
  });

  @override
  Future<Uint8List> readFromHandle(
    Object handle, {
    required int offset,
    required int length,
  }) async {
    final bytes = await _run('read', () {
      final file = _file((handle as _Handle).path);
      return Uint8List.fromList(
        file.sublist(offset, (offset + length).clamp(0, file.length)),
      );
    });
    await server.gate?.future;
    return bytes;
  }

  @override
  Future<void> closeHandle(Object handle) =>
      _run('close', () => handles.remove(handle));

  @override
  Future<void> disconnect() => server.run('logoff', () {
    disconnected = true;
    handles.clear();
  });

  @override
  Future<void> mkdir(String path) => throw UnimplementedError();

  @override
  Future<bool> exists(String path) => throw UnimplementedError();

  @override
  Future<void> deleteFile(String path) => throw UnimplementedError();

  @override
  Future<void> rename(String from, String to) => throw UnimplementedError();

  @override
  Future<(Object, int)> openFileWithSize(String path) =>
      throw UnimplementedError();

  @override
  Future<Object> openFileWrite(String path) => throw UnimplementedError();

  @override
  Future<void> writeToHandle(
    Object handle,
    Uint8List data, {
    required int offset,
  }) => throw UnimplementedError();

  @override
  Future<void> fsyncHandle(Object handle) => throw UnimplementedError();
}

List<int> _bytes(int length) => List.generate(length, (i) => i % 251);

NetworkConnection _connection({String password = 'first'}) => NetworkConnection(
  id: 'nas',
  name: 'NAS',
  protocol: NetworkProtocol.smb,
  address: 'smb://192.0.2.1/Music/',
  username: 'user',
  password: password,
);

/// Gives unawaited closes time to run before checking nothing closed.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

/// Waits for [done] for up to five seconds; the caller then checks it.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late _FakeServer server;
  late NetworkSmbSessions sessions;
  late NetworkStorageService storage;
  late HttpClient http;

  void setUpStorage({Duration idle = const Duration(seconds: 20)}) {
    sessions = NetworkSmbSessions(open: server.open, idle: idle);
    storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
      ensureAccess: (_) async {},
      smbSessions: sessions,
    );
    addTearDown(storage.dispose);
  }

  setUp(() {
    server = _FakeServer({
      'A/01.flac': _bytes(4000),
      'A/02.flac': _bytes(4000),
      'B/01.flac': _bytes(4000),
      'B/C/01.flac': _bytes(4000),
      'B/C/cover.jpg': _bytes(600),
    });
    http = HttpClient();
    addTearDown(() => http.close(force: true));
  });

  Future<List<int>> get(String path, String range) async {
    final url = await storage.resolve(
      NetworkStorageService.source('nas', path),
    );
    final request = await http.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    expect(response.statusCode, HttpStatus.partialContent);
    return response.fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
  }

  test(
    'a scan, its tag reads, covers and parallel reads share one SMB logon',
    () async {
      setUpStorage();
      await storage.save(_connection());
      final directory = await Directory.systemTemp.createTemp('smb-session-');
      addTearDown(() => directory.delete(recursive: true));
      final scanner = NetworkLibraryScanner(
        storage: storage,
        supportDirectory: () async => directory,
        temporaryDirectory: () async => directory,
        readMetadata: (source) async {
          final path = Uri.parse(source).pathSegments.join('/');
          expect(await get(path, 'bytes=0-31'), _bytes(32));
          expect(await get(path, 'bytes=-16'), _bytes(4000).sublist(3984));
          return {'title': path};
        },
      );
      final result = await scanner.scan(
        NetworkStorageService.source('nas', ''),
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      );
      addTearDown(result.delete);
      expect(result.expectedCount, 4);
      expect(result.errorCount, 0);

      final cover = File('${directory.path}/cover.image');
      await Future.wait([
        for (var i = 0; i < 8; i++)
          get('A/0${i % 2 + 1}.flac', 'bytes=${i * 100}-${i * 100 + 99}').then(
            (bytes) =>
                expect(bytes, _bytes(4000).sublist(i * 100, i * 100 + 100)),
          ),
        for (final path in ['', 'A/', 'B/C/'])
          storage.list(_connection(), path),
        storage.downloadCover(
          NetworkStorageService.source('nas', 'B/C/cover.jpg'),
          cover,
        ),
      ]);
      expect(await cover.readAsBytes(), _bytes(600));

      // The code before shared sessions logged on once per listing and once
      // per byte range: here 4 + 8 scan calls, 8 reads, 3 listings, a cover.
      expect(server.count('list') + server.count('stat'), 24);
      expect(server.opened, 1);
      expect(server.closed, 0);
      expect(server.openHandles, 0);
      expect(server.maxActive, 1);
    },
  );

  test(
    'playback during a scan waits only for the readers ahead, never a logon',
    () async {
      setUpStorage();
      await storage.save(_connection());
      final long = server.files['Long.flac'] = _bytes(2 * 1024 * 1024);
      for (var i = 0; i < 12; i++) {
        server.files['Scan/${i.toString().padLeft(2, '0')}.flac'] = _bytes(
          4000,
        );
      }
      final directory = await Directory.systemTemp.createTemp('smb-session-');
      addTearDown(() => directory.delete(recursive: true));
      final scanner = NetworkLibraryScanner(
        storage: storage,
        supportDirectory: () async => directory,
        temporaryDirectory: () async => directory,
        readMetadata: (source) async {
          final path = Uri.parse(source).pathSegments.join('/');
          await get(path, 'bytes=0-31');
          await get(path, 'bytes=-16');
          return {'title': path};
        },
      );
      await storage.list(_connection());
      final scan = scanner.scan(
        NetworkStorageService.source('nas', 'Scan/'),
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final start = server.log.length;
      final player = await sessions.lease(
        'nas',
        Uri.parse('smb://192.0.2.1/Music/Long.flac'),
        username: 'user',
        password: 'first',
        domain: '',
        timeout: NetworkStorageService.timeout,
      );
      final playback = await player
          .read(0, long.length)
          .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
      await player.close();
      final calls = server.log.sublist(start);
      await (await scan).delete();
      expect(playback, long);
      final reads = [
        for (var i = 0; i < calls.length; i++)
          if (calls[i] == 'read') i,
      ];
      expect(reads.length, greaterThanOrEqualTo(8));
      expect(calls, contains('stat'));
      // Two tag readers run beside playback; each has at most the handle
      // close of its last range and its next call queued ahead of a chunk.
      for (var i = 1; i < reads.length; i++) {
        expect(reads[i] - reads[i - 1] - 1, lessThanOrEqualTo(4));
      }
      expect(calls, isNot(contains('logon')));
      expect(calls, isNot(contains('logoff')));
      expect(server.opened, 1);
      expect(server.maxActive, 1);
    },
  );

  test('an idle session closes and the next call logs on again', () async {
    const idle = Duration(milliseconds: 200);
    setUpStorage(idle: idle);
    await storage.save(_connection());
    await storage.list(_connection());
    await storage.list(_connection(), 'A/');
    final waited = Stopwatch()..start();
    expect(server.opened, 1);
    expect(server.closed, 0);
    await _until(() => server.closed == 1);
    expect(server.closed, 1);
    expect(waited.elapsed, greaterThan(idle ~/ 2));
    expect(await storage.list(_connection(), 'A/'), hasLength(2));
    expect(server.opened, 2);
    expect(server.closed, 1);
  });

  test('a held lease outlives the idle period and closes after it', () async {
    sessions = NetworkSmbSessions(
      open: server.open,
      idle: const Duration(milliseconds: 50),
    );
    addTearDown(sessions.close);
    final target = Uri.parse('smb://192.0.2.1/Music/A/01.flac');
    Future<NetworkSmbClient> lease() => sessions.lease(
      'nas',
      target,
      username: 'user',
      password: 'first',
      domain: '',
      timeout: const Duration(seconds: 20),
    );
    final first = await lease();
    final second = await lease();
    expect(server.opened, 1);
    expect(server.logins.single.share, 'Music');
    expect(first.path, 'A/01.flac');
    await first.close();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.closed, 0);
    expect(await second.read(0, 4).expand((bytes) => bytes).toList(), [
      0,
      1,
      2,
      3,
    ]);
    await second.close();
    await second.close();
    expect(server.closed, 0);
    await _until(() => server.closed == 1);
    expect(server.closed, 1);
    expect(server.openHandles, 0);
  });

  test(
    'edits, new credentials and removal close the session once reads end',
    () async {
      setUpStorage();
      server.files['Long.flac'] = _bytes(2 * 1024 * 1024);
      await storage.save(_connection());
      await storage.list(_connection());
      expect(server.logins.last.password, 'first');

      final gate = server.gate = Completer<void>();
      // A gated read holds the app-wide SMB lock; never leave it held.
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final reading = get('Long.flac', 'bytes=0-');
      while (server.count('read') == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await storage.save(_connection(password: 'second'));
      await _settle();
      expect(server.closed, 0);
      gate.complete();
      server.gate = null;
      expect(await reading, server.files['Long.flac']);
      await _until(() => server.closed == 1);
      expect(server.closed, 1);

      expect(await storage.list(_connection(password: 'second')), hasLength(3));
      expect(server.opened, 2);
      expect(server.logins.last.password, 'second');
      await storage.save(_connection(password: 'second'));
      await _until(() => server.closed == 2);
      expect(server.closed, 2);

      await storage.list(_connection(password: 'second'));
      await storage.remove('nas');
      await _until(() => server.closed == 3);
      expect(server.opened, 3);
      expect(server.closed, 3);
      expect(server.openHandles, 0);
    },
  );

  // Answers about a path carry it ('' for the share root). A reconnect the
  // pool keeps refusing carries none, whatever its type.
  for (final (type, path, retires) in [
    (Smb2ErrorType.connection, '', true),
    (Smb2ErrorType.timeout, '', true),
    (Smb2ErrorType.auth, '', true),
    (Smb2ErrorType.state, '', true),
    (Smb2ErrorType.io, '', true),
    (Smb2ErrorType.unknown, '', true),
    (Smb2ErrorType.notFound, '', false),
    (Smb2ErrorType.accessDenied, '', false),
    (Smb2ErrorType.isADirectory, '', false),
    (Smb2ErrorType.inUse, '', false),
    (Smb2ErrorType.notFound, null, true),
    (Smb2ErrorType.accessDenied, null, true),
    (Smb2ErrorType.inUse, null, true),
  ]) {
    test('a ${type.name} failure ${path == null ? 'without a path ' : ''}'
        'reaches the caller as it is and '
        '${retires ? 'replaces' : 'keeps'} the session', () async {
      setUpStorage();
      await storage.save(_connection());
      await storage.list(_connection());
      final failure = Smb2Exception('Injected', type: type, path: path);
      server.failNext = failure;
      await expectLater(storage.list(_connection()), throwsA(same(failure)));
      if (retires) {
        await _until(() => server.closed == 1);
      } else {
        await _settle();
      }
      expect(server.closed, retires ? 1 : 0);
      expect(await storage.list(_connection(), 'A/'), hasLength(2));
      expect(server.opened, retires ? 2 : 1);
    });
  }

  test(
    'a byte range that fails for the session answers 502 and is replaced',
    () async {
      setUpStorage();
      await storage.save(_connection());
      expect(await get('A/01.flac', 'bytes=0-3'), [0, 1, 2, 3]);
      server.failNext = const Smb2Exception(
        'Session expired',
        type: Smb2ErrorType.connection,
      );
      final url = await storage.resolve(
        NetworkStorageService.source('nas', 'A/01.flac'),
      );
      final request = await http.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-3');
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, HttpStatus.badGateway);
      expect(await get('A/01.flac', 'bytes=4-7'), [4, 5, 6, 7]);
      await _until(() => server.closed == 1);
      expect(server.opened, 2);
      expect(server.closed, 1);
      expect(server.openHandles, 0);
    },
  );

  test('verify logs on again instead of reusing a live session', () async {
    setUpStorage();
    await storage.save(_connection());
    await storage.list(_connection());
    expect(server.opened, 1);
    const refusal = Smb2Exception('Logon failure', type: Smb2ErrorType.auth);
    server.refuse = refusal;
    await expectLater(storage.verify(_connection()), throwsA(same(refusal)));
    expect(server.opened, 2);
    await _until(() => server.closed == 1);
    expect(server.closed, 1);
    server.refuse = null;
    expect(await storage.verify(_connection()), hasLength(2));
    expect(server.opened, 3);
  });

  test(
    'concurrent first calls share one logon and a refusal is not kept',
    () async {
      setUpStorage();
      await storage.save(_connection());
      const refusal = Smb2Exception('Logon failure', type: Smb2ErrorType.auth);
      server.refuse = refusal;
      await Future.wait([
        for (var i = 0; i < 3; i++)
          expectLater(storage.list(_connection()), throwsA(same(refusal))),
      ]);
      expect(server.opened, 1);
      server.refuse = null;
      expect(await storage.list(_connection()), hasLength(2));
      expect(server.opened, 2);
      expect(server.closed, 0);
    },
  );

  test('closing the sessions ends leased and idle ones at once', () async {
    sessions = NetworkSmbSessions(open: server.open);
    addTearDown(sessions.close);
    Future<NetworkSmbClient> lease(String id) => sessions.lease(
      id,
      Uri.parse('smb://192.0.2.1/Music/A'),
      username: 'user',
      password: 'first',
      domain: '',
      timeout: const Duration(seconds: 20),
    );
    final held = await lease('one');
    await (await lease('two')).close();
    expect(server.opened, 2);
    await sessions.close();
    expect(server.closed, 2);
    await expectLater(
      held.list(),
      throwsA(
        isA<Smb2Exception>().having((e) => e.type, 'type', Smb2ErrorType.state),
      ),
    );
    await held.close();
    await _settle();
    expect(server.count('logoff'), 2);
    expect(await (await lease('one')).list(), hasLength(2));
    expect(server.opened, 3);
    await sessions.close();
    expect(server.closed, 3);
  });
}
