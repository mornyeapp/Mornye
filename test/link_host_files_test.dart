import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/desktop/link_host_files.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';

const _uri =
    'content://com.example.documents/tree/a%3AMusic/document/a%3AMusic%2FSong.flac';

/// A platform lease store: hands out numbered tokens, or waits on [gate].
class _FakeLeases {
  final opened = <String>[];
  final closed = <String>[];
  Completer<void>? gate;
  bool refuse = false;
  var _next = 0;

  Future<LinkLentFile?> open(String uri) async {
    opened.add(uri);
    await gate?.future;
    if (refuse) return null;
    final number = ++_next;
    return (path: '/proc/self/fd/${40 + number}', token: 'token-$number');
  }

  Future<void> close(String token) async => closed.add(token);
}

LinkRequest _request(
  String op,
  Map<String, dynamic> args, {
  String deviceId = '',
}) => LinkRequest(requestId: '1', op: op, deviceId: deviceId, args: args);

void main() {
  late _FakeLeases leases;
  late LinkHostFiles files;
  late LinkHostRouter router;

  Future<Object?> open(String lease, {String uri = _uri}) => router.dispatch(
    _request(linkHostFileOpenOp, {'uri': uri, 'lease': lease}),
  );

  Future<Object?> close(String lease) =>
      router.dispatch(_request(linkHostFileCloseOp, {'lease': lease}));

  setUp(() {
    leases = _FakeLeases();
    files = LinkHostFiles(open: leases.open, close: leases.close, maxOpen: 2);
    router = LinkHostRouter();
    files.register(router);
  });

  test('lends a document and returns it when the server closes it', () async {
    expect(await open('1'), {'path': '/proc/self/fd/41'});
    expect(leases.opened, [_uri]);
    expect(files.held, 1);
    expect(await close('1'), isNull);
    expect(leases.closed, ['token-1']);
    expect(files.held, 0);
    // A second close, or one for a lease never lent, does nothing.
    await close('1');
    await close('9');
    expect(leases.closed, ['token-1']);
  });

  test('a close that arrives while opening ends the lease once open', () async {
    leases.gate = Completer<void>();
    final opening = open('1');
    await close('1');
    expect(leases.closed, isEmpty);
    leases.gate!.complete();
    await expectLater(
      opening,
      throwsA(
        isA<LinkException>().having((e) => e.code, 'code', 'unavailable'),
      ),
    );
    expect(leases.closed, ['token-1']);
    expect(files.held, 0);
  });

  test('a document the platform cannot open is not_found', () async {
    leases.refuse = true;
    await expectLater(
      open('1'),
      throwsA(isA<LinkException>().having((e) => e.code, 'code', 'not_found')),
    );
    expect(files.held, 0);
    // The server's close for it finds nothing to end.
    await close('1');
    expect(leases.closed, isEmpty);
  });

  test('only the server itself may ask, and only for documents', () async {
    await expectLater(
      router.dispatch(
        _request(linkHostFileOpenOp, {
          'uri': _uri,
          'lease': '1',
        }, deviceId: 'phone-1'),
      ),
      throwsA(isA<LinkException>().having((e) => e.code, 'code', 'not_found')),
    );
    await expectLater(
      open('1', uri: '/storage/emulated/0/Music/Song.flac'),
      throwsA(isA<LinkException>().having((e) => e.code, 'code', 'invalid')),
    );
    await expectLater(
      router.dispatch(_request(linkHostFileOpenOp, {'uri': _uri})),
      throwsA(isA<LinkException>().having((e) => e.code, 'code', 'invalid')),
    );
    expect(leases.opened, isEmpty);
  });

  test('bounds the leases and refuses a name already in use', () async {
    await open('1');
    await expectLater(
      open('1'),
      throwsA(isA<LinkException>().having((e) => e.code, 'code', 'invalid')),
    );
    await open('2');
    await expectLater(
      open('3'),
      throwsA(
        isA<LinkException>().having((e) => e.code, 'code', 'unavailable'),
      ),
    );
    expect(leases.opened, hasLength(2));
    await close('1');
    expect(await open('3'), {'path': '/proc/self/fd/43'});
  });

  test('closeAll ends held leases and those still opening', () async {
    await open('1');
    leases.gate = Completer<void>();
    final opening = open('2');
    await files.closeAll();
    expect(leases.closed, ['token-1']);
    leases.gate!.complete();
    await expectLater(opening, throwsA(isA<LinkException>()));
    expect(leases.closed, ['token-1', 'token-2']);
    expect(files.held, 0);
  });
}
