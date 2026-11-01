import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/client/link_client_http.dart';

class _OpeningClient implements HttpClient {
  final opening = Completer<HttpClientRequest>();

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => opening.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LateRequest implements HttpClientRequest {
  bool aborted = false;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborted = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final upload in [false, true]) {
    test(
      '${upload ? 'upload' : 'JSON'} aborts a request opened after timeout',
      () async {
        final directory = await Directory.systemTemp.createTemp('link-http-');
        addTearDown(() => directory.delete(recursive: true));
        final file = await File(
          '${directory.path}/song.flac',
        ).writeAsBytes([1]);
        final client = _OpeningClient();
        final uri = Uri.parse('https://example.test/mornye/v1/files/song.flac');
        const timeout = Duration(milliseconds: 10);
        final sending = upload
            ? linkHttpUpload(client, uri, file, timeout: timeout)
            : linkHttpSend(client, 'GET', uri, timeout: timeout);

        await expectLater(sending, throwsA(isA<TimeoutException>()));
        final request = _LateRequest();
        client.opening.complete(request);
        await pumpEventQueue();
        expect(request.aborted, isTrue);
      },
    );
  }
}
