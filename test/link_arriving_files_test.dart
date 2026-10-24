import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/desktop/link_arriving_files.dart';

const _name = '0123456789abcdef0123456789abcdef.flac';

void main() {
  late Directory dir;
  late LinkArrivingFiles arriving;
  late HttpClient http;
  final registered = <String, String>{};

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('link_arriving_');
    registered.clear();
    arriving = LinkArrivingFiles(
      register: (path, {required url, required done}) => registered[path] = url,
      poll: const Duration(milliseconds: 5),
      patience: const Duration(milliseconds: 300),
    );
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await arriving.close();
    await dir.delete(recursive: true);
  });

  /// The part file the Link server writes the upload into.
  File part() => File('${dir.path}/.$_name.1a2b3c.part');

  Future<HttpClientResponse> get(String url, {String? range}) async {
    final request = await http.getUrl(Uri.parse(url));
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close();
  }

  Future<List<int>> body(HttpClientResponse response) async => [
    for (final chunk in await response.toList()) ...chunk,
  ];

  test('streams a file while it arrives and after it is whole', () async {
    final bytes = List<int>.generate(1000, (i) => i % 251);
    await part().writeAsBytes(bytes.sublist(0, 300));
    final arrival = (await arriving.expect(dir.path, _name, bytes.length))!;
    expect(arrival.path, '${dir.path}${Platform.pathSeparator}$_name');
    expect(registered[arrival.path], arrival.url);
    expect(arrival.url, startsWith('http://127.0.0.1:'));

    final response = await get(arrival.url);
    expect(response.statusCode, HttpStatus.ok);
    expect(response.contentLength, 1000);
    final received = body(response);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await part().writeAsBytes(bytes.sublist(300, 700), mode: FileMode.append);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await part().writeAsBytes(bytes.sublist(700), mode: FileMode.append);
    await part().rename(arrival.path);
    expect(await received, bytes);
    await arrival.done;

    // The player seeks through the same URL once the file is whole.
    final slice = await get(arrival.url, range: 'bytes=900-');
    expect(slice.statusCode, HttpStatus.partialContent);
    expect(
      slice.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 900-999/1000',
    );
    expect(await body(slice), bytes.sublist(900));
  });

  test('a broken-off upload fails and cuts the stream short', () async {
    await part().writeAsBytes(List.filled(100, 7));
    final arrival = (await arriving.expect(dir.path, _name, 1000))!;
    final response = await get(arrival.url);
    final received = body(response);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await part().delete();
    await expectLater(arrival.done, throwsA(anything));
    await expectLater(
      received.then((bytes) => bytes.length),
      anyOf(throwsA(anything), completion(lessThan(1000))),
    );
  });

  test('an upload that never starts fails after a while', () async {
    final arrival = (await arriving.expect(dir.path, _name, 1000))!;
    await expectLater(arrival.done, throwsA(anything));
  });

  test('takes only upload names and sizes', () async {
    expect(await arriving.expect(dir.path, 'song.flac', 10), isNull);
    expect(
      await arriving.expect(dir.path, _name.replaceAll('.flac', '.txt'), 10),
      isNull,
    );
    expect(await arriving.expect(dir.path, _name, 0), isNull);
    expect(await arriving.expect('', _name, 10), isNull);
    expect(registered, isEmpty);
  });

  test('answers nothing without the token', () async {
    await part().writeAsBytes([1, 2, 3]);
    final arrival = (await arriving.expect(dir.path, _name, 3))!;
    final port = Uri.parse(arrival.url).port;
    final response = await get('http://127.0.0.1:$port/wrong/$_name');
    expect(response.statusCode, HttpStatus.notFound);
    await response.drain<void>();
  });
}
