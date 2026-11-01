import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:mornye/services/network_smb_client.dart';
import 'package:mornye/services/network_storage_service.dart';

/// The two writable NAS transports, sharing a tiny in-memory filesystem.
class NetworkEditFixture {
  NetworkEditFixture(this.protocol);

  final NetworkProtocol protocol;
  final files = <String, List<int>>{};
  final methods = <String>[];
  bool rejectWrites = false;
  bool rejectPublish = false;
  bool losePublishReply = false;
  int openHandles = 0;
  int openSessions = 0;
  HttpServer? _server;
  late final NetworkStorageService storage;
  static const source = 'network://edit-nas/song.flac';

  Future<void> start() async {
    if (protocol == NetworkProtocol.webdav) {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen(_handle);
    }
    storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
      smbSessions: NetworkSmbSessions(
        open: (login) async {
          if (login.username != 'editor' || login.password != 'secret') {
            throw StateError('Wrong NAS credentials');
          }
          openSessions++;
          return _Share(this);
        },
      ),
    );
    await storage.save(
      NetworkConnection(
        id: 'edit-nas',
        name: 'NAS',
        protocol: protocol,
        address: protocol == NetworkProtocol.smb
            ? 'smb://127.0.0.1/MUSIC/'
            : 'http://127.0.0.1:${_server!.port}/music/',
        username: 'editor',
        password: 'secret',
      ),
    );
  }

  bool _publish(String from, String to) =>
      from.startsWith('.mornye-edit-') && to == 'song.flac';

  void move(String from, String to) {
    methods.add('MOVE $from $to');
    if (rejectPublish && _publish(from, to)) {
      throw const Smb2Exception(
        'Write denied',
        type: Smb2ErrorType.accessDenied,
      );
    }
    if (files.containsKey(to)) {
      throw const Smb2Exception(
        'Already exists',
        type: Smb2ErrorType.alreadyExists,
      );
    }
    files[to] = files.remove(from) ?? (throw StateError('Missing source'));
    if (losePublishReply && _publish(from, to)) {
      losePublishReply = false;
      throw const SocketException('Lost rename response');
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final path = Uri.decodeComponent(
      request.uri.path,
    ).substring('/music/'.length);
    if (request.headers.value('authorization') !=
        'Basic ${base64Encode(utf8.encode('editor:secret'))}') {
      request.response.statusCode = 401;
      await request.response.close();
      return;
    }
    switch (request.method) {
      case 'PROPFIND':
        if (path.isNotEmpty && !files.containsKey(path)) {
          request.response.statusCode = 404;
          break;
        }
        request.response.statusCode = 207;
        request.response.write('<d:multistatus xmlns:d="DAV:">');
        for (final name in path.isEmpty ? files.keys : [path]) {
          final href = Uri(
            path: '/music/$name',
          ).toString().replaceAll('&', '&amp;');
          request.response.write(
            '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
            '<d:resourcetype/><d:getcontentlength>${files[name]!.length}</d:getcontentlength>'
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
          );
        }
        request.response.write('</d:multistatus>');
      case 'PUT':
        methods.add('PUT $path');
        if (rejectWrites) {
          request.response.statusCode = 403;
          break;
        }
        files[path] = await request.fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        request.response.statusCode = 201;
      case 'MOVE':
        final to = Uri.decodeComponent(
          Uri.parse(request.headers.value('destination')!).path,
        ).substring('/music/'.length);
        if (request.headers.value('overwrite') != 'F') {
          request.response.statusCode = 400;
          break;
        }
        try {
          move(path, to);
          request.response.statusCode = 201;
        } on Smb2Exception {
          request.response.statusCode = 403;
        } on SocketException {
          (await request.response.detachSocket(writeHeaders: false)).destroy();
          return;
        }
      case 'DELETE':
        request.response.statusCode = files.remove(path) == null ? 404 : 204;
      case 'GET':
      case 'HEAD':
        final bytes = files[path];
        if (bytes == null) {
          request.response.statusCode = 404;
          break;
        }
        request.response.contentLength = bytes.length;
        if (request.method == 'GET') request.response.add(bytes);
      default:
        request.response.statusCode = 405;
    }
    await request.response.close();
  }

  Future<void> close() async {
    await storage.dispose();
    await _server?.close(force: true);
  }
}

class _Handle {
  _Handle(this.path);
  final String path;
}

class _Share implements NetworkSmbShare {
  _Share(this.fixture);
  final NetworkEditFixture fixture;

  List<int> _file(String path) =>
      fixture.files[path] ??
      (throw Smb2Exception(
        'Not found',
        type: Smb2ErrorType.notFound,
        path: path,
      ));

  @override
  Future<List<Smb2DirEntry>> listDirectory(String path) async => [
    for (final entry in fixture.files.entries)
      Smb2DirEntry(name: entry.key, stat: await stat(entry.key)),
  ];

  @override
  Future<Smb2Stat> stat(String path) async {
    final now = DateTime.utc(2026);
    return Smb2Stat(
      type: Smb2FileType.file,
      size: _file(path).length,
      modified: now,
      created: now,
      accessed: now,
      changed: now,
    );
  }

  @override
  Future<bool> exists(String path) async => fixture.files.containsKey(path);
  @override
  Future<void> deleteFile(String path) async {
    fixture.files.remove(path);
  }

  @override
  Future<void> rename(String from, String to) async => fixture.move(from, to);
  @override
  Future<Object> openFile(String path) async {
    _file(path);
    fixture.openHandles++;
    return _Handle(path);
  }

  @override
  Future<(Object, int)> openFileWithSize(String path) async =>
      (await openFile(path), _file(path).length);
  @override
  Future<Object> openFileWrite(String path) async {
    fixture.methods.add('PUT $path');
    if (fixture.rejectWrites) {
      throw Smb2Exception(
        'Write denied',
        type: Smb2ErrorType.accessDenied,
        path: path,
      );
    }
    fixture.files[path] = [];
    fixture.openHandles++;
    return _Handle(path);
  }

  @override
  Future<Uint8List> readFromHandle(
    Object handle, {
    required int offset,
    required int length,
  }) async {
    final file = _file((handle as _Handle).path);
    return Uint8List.fromList(
      file.sublist(offset, (offset + length).clamp(0, file.length)),
    );
  }

  @override
  Future<void> writeToHandle(
    Object handle,
    Uint8List data, {
    required int offset,
  }) async {
    final path = (handle as _Handle).path;
    fixture.files[path] = [..._file(path).take(offset), ...data];
  }

  @override
  Future<void> fsyncHandle(Object handle) async {}
  @override
  Future<void> closeHandle(Object handle) async {
    fixture.openHandles--;
  }

  @override
  Future<void> disconnect() async {
    fixture.openSessions--;
  }

  @override
  Future<void> mkdir(String path) async => throw UnimplementedError();
}
