import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_playback_cache.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:path/path.dart' as p;

const _a = 'network://nas/Album/01.flac';
const _b = 'network://nas/Album/02.flac';
const _c = 'network://nas/Album/03.flac';
const _d = 'network://nas/Album/04.flac';
const _wait = Duration(seconds: 5);

/// A NAS whose downloads can be held halfway until a test releases them.
class _Server {
  final files = <String, List<int>>{};
  final identities = <String, String?>{};
  final holds = <String, Completer<void>>{};
  final started = <String>[];
  final closed = <String>[];
  bool unreachable = false;

  void put(String source, String text, {String? identity = 'v1'}) {
    files[source] = utf8.encode(text);
    identities[source] = identity;
  }

  /// Holds the next download of [source] after its first half.
  Completer<void> hold(String source) => holds[source] = Completer<void>();

  Future<void> startedDownloading(String source) async {
    for (var i = 0; i < 200 && !started.contains(source); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(started, contains(source));
  }
}

class _Transfer implements NetworkPlaybackTransfer {
  _Transfer(this.server);

  final _Server server;
  final _closed = Completer<void>();
  String? _source;

  @override
  Future<String?> identity(String source) async {
    if (server.unreachable) throw const SocketException('Unreachable');
    return server.identities[source];
  }

  @override
  Future<void> download(
    String source,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  }) async {
    _source = source;
    server.started.add(source);
    final bytes = server.files[source]!;
    final half = bytes.length ~/ 2;
    final sink = output.openWrite();
    try {
      sink.add(bytes.sublist(0, half));
      await sink.flush();
      progress(half, bytes.length);
      final hold = server.holds.remove(source);
      if (hold != null) await Future.any([hold.future, _closed.future]);
      if (_closed.isCompleted) throw StateError('Transfer closed');
      checkpoint();
      sink.add(bytes.sublist(half));
      progress(bytes.length, bytes.length);
    } finally {
      await sink.close();
    }
  }

  @override
  void close() {
    if (_closed.isCompleted) return;
    _closed.complete();
    if (_source case final source?) server.closed.add(source);
  }
}

void main() {
  late Directory root;
  late _Server server;
  late DateTime now;
  late SourceDeletionEvents removals;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('network-playback-cache-');
    server = _Server()
      ..put(_a, 'first song bytes')
      ..put(_b, 'second song bytes')
      ..put(_c, 'third song bytes')
      ..put(_d, 'fourth song bytes');
    now = DateTime(2026, 11, 4, 12);
    removals = SourceDeletionEvents();
  });

  tearDown(() async {
    // An index write may still be finishing in the background.
    for (var attempt = 0; await root.exists(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        if (attempt >= 10) rethrow;
      }
    }
  });

  NetworkPlaybackCache cache({
    int maxFiles = 32,
    int maxBytes = 1 << 30,
    int maxFileBytes = 1 << 20,
  }) => NetworkPlaybackCache(
    directory: () async => Directory(p.join(root.path, 'cache')),
    transfer: () => _Transfer(server),
    connectionRemovals: removals,
    now: () => now,
    maxFiles: maxFiles,
    maxBytes: maxBytes,
    maxFileBytes: maxFileBytes,
  );

  Future<List<String>> files() async {
    final directory = Directory(p.join(root.path, 'cache'));
    if (!await directory.exists()) return [];
    return [
      await for (final entity in directory.list()) p.basename(entity.path),
    ]..sort();
  }

  test('a wanted song plays from its whole copy once downloaded', () async {
    final subject = cache()..want([_a]);

    expect(await subject.ready(_a, _wait), isTrue);
    final path = await subject.lookup(_a);

    expect(path, isNotNull);
    expect(p.extension(path!), '.flac');
    expect(subject.owns(path), isTrue);
    expect(await File(path).readAsString(), 'first song bytes');
  });

  test('a song still downloading never resolves to its partial file', () async {
    final release = server.hold(_a);
    final subject = cache()..want([_a]);
    await server.startedDownloading(_a);

    // The player falls back to the server while the copy is incomplete.
    expect(await subject.lookup(_a), isNull);
    expect(await files(), contains(endsWith('.part')));

    release.complete();
    expect(await subject.ready(_a, _wait), isTrue);
    expect(
      await File((await subject.lookup(_a))!).readAsString(),
      'first song bytes',
    );
    expect(await files(), isNot(contains(endsWith('.part'))));
  });

  test('songs download one at a time in the order wanted', () async {
    final release = server.hold(_a);
    final subject = cache()..want([_a, _b]);
    await server.startedDownloading(_a);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.started, [_a]);

    release.complete();
    expect(await subject.ready(_b, _wait), isTrue);
    expect(server.started, [_a, _b]);
  });

  test('a song no longer wanted stops downloading', () async {
    server.hold(_a);
    final subject = cache()..want([_a]);
    await server.startedDownloading(_a);
    final waiting = subject.ready(_a, _wait);

    subject.want([_b]);

    expect(await waiting, isFalse);
    expect(server.closed, contains(_a));
    expect(await subject.ready(_b, _wait), isTrue);
    expect(await subject.lookup(_a), isNull);
    expect(await files(), isNot(contains(endsWith('.part'))));
  });

  test('the least recently used copies go first, never a wanted one', () async {
    final subject = cache(maxFiles: 2)..want([_a]);
    expect(await subject.ready(_a, _wait), isTrue);
    subject.want([_a, _b]);
    expect(await subject.ready(_b, _wait), isTrue);
    subject.want([_a, _b, _c]);
    expect(await subject.ready(_c, _wait), isTrue);
    // Every copy is still wanted, so the cache stays over its bound.
    expect(
      (await files()).where((name) => name.endsWith('.flac')),
      hasLength(3),
    );

    subject.want([_c, _d]);
    expect(await subject.ready(_d, _wait), isTrue);

    expect(
      (await files()).where((name) => name.endsWith('.flac')),
      hasLength(2),
    );
    expect(await subject.lookup(_a), isNull);
    expect(await subject.lookup(_b), isNull);
    expect(await subject.lookup(_c), isNotNull);
    expect(await subject.lookup(_d), isNotNull);
  });

  test('a copy just handed to the player is not evicted', () async {
    final subject = cache(maxFiles: 1)..want([_a]);
    expect(await subject.ready(_a, _wait), isTrue);
    final playing = await subject.lookup(_a);

    subject.want([_b]);
    expect(await subject.ready(_b, _wait), isTrue);

    expect(await File(playing!).exists(), isTrue);
  });

  test('the byte bound evicts older copies', () async {
    final subject = cache(maxBytes: 40)..want([_a]);
    expect(await subject.ready(_a, _wait), isTrue);
    subject.want([_b]);
    expect(await subject.ready(_b, _wait), isTrue);
    subject.want([_c]);
    expect(await subject.ready(_c, _wait), isTrue);

    expect(await subject.lookup(_a), isNull);
    expect(await subject.lookup(_c), isNotNull);
  });

  test('a song larger than the file bound keeps streaming', () async {
    server.put(_a, 'x' * 64);
    final subject = cache(maxFileBytes: 32)..want([_a, _b]);

    expect(await subject.ready(_a, _wait), isFalse);
    expect(await subject.ready(_b, _wait), isTrue);
    expect(await subject.lookup(_a), isNull);
    expect(server.started.where((source) => source == _a), hasLength(1));
  });

  test(
    'an invalidated copy is deleted and a wanted song downloads again',
    () async {
      final subject = cache()..want([_a]);
      expect(await subject.ready(_a, _wait), isTrue);
      final old = (await subject.lookup(_a))!;
      server.put(_a, 'edited song bytes', identity: 'v2');

      await subject.invalidate(_a);

      expect(await File(old).exists(), isFalse);
      expect(await subject.ready(_a, _wait), isTrue);
      final path = (await subject.lookup(_a))!;
      expect(path, isNot(old));
      expect(await File(path).readAsString(), 'edited song bytes');
    },
  );

  test('a download finishing after invalidation is discarded', () async {
    final release = server.hold(_a);
    final subject = cache()..want([_a]);
    await server.startedDownloading(_a);
    server.put(_a, 'edited song bytes', identity: 'v2');

    await subject.invalidate(_a);
    release.complete();

    expect(await subject.ready(_a, _wait), isTrue);
    expect(
      await File((await subject.lookup(_a))!).readAsString(),
      'edited song bytes',
    );
  });

  test('a copy whose server file changed is not served', () async {
    final subject = cache()..want([_a]);
    expect(await subject.ready(_a, _wait), isTrue);
    subject.want([]);

    // Within the verified window the copy plays without asking the server.
    server.identities[_a] = 'v2';
    expect(await subject.lookup(_a), isNotNull);

    now = now.add(const Duration(minutes: 11));
    expect(await subject.lookup(_a), isNull);
    expect((await files()).where((name) => name.endsWith('.flac')), isEmpty);
  });

  test('a verified copy plays while its server is out of reach', () async {
    final subject = cache()..want([_a]);
    expect(await subject.ready(_a, _wait), isTrue);
    now = now.add(const Duration(minutes: 11));
    server.unreachable = true;

    expect(await subject.lookup(_a), isNotNull);
  });

  test(
    'a copy without identity is served only shortly after download',
    () async {
      server.identities[_a] = null;
      final subject = cache()..want([_a]);
      expect(await subject.ready(_a, _wait), isTrue);
      expect(await subject.lookup(_a), isNotNull);

      now = now.add(const Duration(minutes: 11));
      expect(await subject.lookup(_a), isNull);
    },
  );

  test('a removed connection forgets its copies', () async {
    final subject = cache()..want([_a]);
    expect(await subject.ready(_a, _wait), isTrue);
    subject.want([]);

    await removals.publish('nas');

    expect(await subject.lookup(_a), isNull);
  });

  test(
    'a restart keeps whole copies and clears stale temporary files',
    () async {
      final first = cache()..want([_a]);
      expect(await first.ready(_a, _wait), isTrue);
      first.want([]);
      final kept = p.basename((await first.lookup(_a))!);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final directory = p.join(root.path, 'cache');
      await File(p.join(directory, 'stale.part')).writeAsString('half');
      await File(p.join(directory, 'orphan.flac')).writeAsString('old');

      final second = cache();
      final path = await second.lookup(_a);
      // Let the index write finish.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(p.basename(path!), kept);
      expect(await files(), [kept, 'index.json']);
    },
  );

  test('a truncated copy from an earlier run is dropped', () async {
    final first = cache()..want([_a]);
    expect(await first.ready(_a, _wait), isTrue);
    first.want([]);
    final path = (await first.lookup(_a))!;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await File(path).writeAsString('cut');

    expect(await cache().lookup(_a), isNull);
  });

  test('only plain network songs with a file type are cached', () async {
    const untyped = 'network://nas/Album/no-extension';
    const local = '/music/song.flac';
    final subject = cache()..want([untyped, local]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(server.started, isEmpty);
    expect(await subject.ready(untyped, _wait), isFalse);
  });
}
