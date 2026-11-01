import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:path/path.dart' as p;

void main() {
  test('stored reference lookup benchmark', () async {
    final directory = await Directory.systemTemp.createTemp('cover-lookup-');
    addTearDown(() => directory.delete(recursive: true));
    final refs = List.generate(1000, (i) => 'network://nas/cover/album-$i');
    for (final ref in refs) {
      final key = sha256.convert(utf8.encode(ref)).toString().substring(0, 32);
      File(
        p.join(directory.path, '${key}_0000000000000001.image'),
      ).writeAsBytesSync([0xff, 0xd8, 0xff]);
    }
    final store = CoverStore(directory: () async => directory);
    addTearDown(store.dispose);
    await store.warmUp();
    for (final ref in refs) {
      expect(store.indexedFile(ref), isNotNull);
    }
    final times = <int>[];
    var misses = 0;
    for (var sample = 0; sample < 5; sample++) {
      final watch = Stopwatch()..start();
      for (var pass = 0; pass < 100; pass++) {
        for (final ref in refs) {
          if (store.indexedFile(ref) == null) misses++;
        }
      }
      watch.stop();
      times.add(watch.elapsedMicroseconds);
    }
    expect(misses, 0);
    times.sort();
    debugPrint('100,000 indexed lookups, microseconds: $times');
  });
}
