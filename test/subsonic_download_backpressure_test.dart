import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_storage_service.dart';

import 'support/subsonic_fixture.dart';

class _SlowOutput implements File {
  final started = Completer<void>();
  final release = Completer<void>();
  final bytes = <int>[];
  bool closed = false;

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding? encoding}) =>
      IOSink(_SlowConsumer(this));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SlowConsumer implements StreamConsumer<List<int>> {
  _SlowConsumer(this.output);
  final _SlowOutput output;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      if (!output.started.isCompleted) output.started.complete();
      await output.release.future;
      output.bytes.addAll(chunk);
    }
  }

  @override
  Future<void> close() async => output.closed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SubsonicFixture server;
  late NetworkStorageService storage;
  late SubsonicClient client;

  setUp(() async {
    server = await SubsonicFixture.start();
    storage = NetworkStorageService(ensureAccess: (_) async {});
    client = storage.openSubsonic(server.connection());
  });

  tearDown(() async {
    client.close();
    await storage.dispose();
    await server.close();
  });

  test('slow disk applies backpressure to the network download', () async {
    server.audio = List.generate(4 * 1024 * 1024, (index) => index % 251);
    final output = _SlowOutput();
    addTearDown(() {
      if (!output.release.isCompleted) output.release.complete();
    });
    var received = 0;
    final allReceived = Completer<void>();
    final download = client.download(
      'song',
      output,
      progress: (value, _) {
        received = value;
        if (value == server.audio!.length) allReceived.complete();
      },
    );
    await output.started.future;
    await Future.any([
      allReceived.future,
      Future<void>.delayed(const Duration(milliseconds: 100)),
    ]);
    final bufferedWhileBlocked = received;
    output.release.complete();
    await download;
    expect(bufferedWhileBlocked, lessThan(server.audio!.length));
    expect(output.bytes, server.audio);
    expect(output.closed, isTrue);
  });

  test(
    'unwritable output reports its error through the download future',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subsonic-output-error-',
      );
      addTearDown(() => directory.delete(recursive: true));
      server.audio = List.filled(1024 * 1024, 7);
      await expectLater(
        client.download('song', File(directory.path)),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
