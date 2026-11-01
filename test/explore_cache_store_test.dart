import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/explore_cache_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  File cacheFile() => File('${root.path}/preference_blobs/explore_feed.json');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('explore-blob-');
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    await root.delete(recursive: true);
  });

  test('missing cache has an empty snapshot', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final snapshot = await ExploreCacheStore(prefs).read();

    expect(snapshot.payload, isNull);
    expect(snapshot.timestampMs, isNull);
    expect(snapshot.sizeBytes, 0);
  });

  test('round trip preserves Unicode payload and records timestamp', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = ExploreCacheStore(prefs);
    const payload = '{"title":"Musik 🎵 日本語"}';
    final beforeWrite = DateTime.now().millisecondsSinceEpoch;

    await store.write(payload);
    final afterWrite = DateTime.now().millisecondsSinceEpoch;
    final snapshot = await store.read();

    expect(snapshot.payload, payload);
    expect(snapshot.timestampMs, inInclusiveRange(beforeWrite, afterWrite));
    expect(snapshot.sizeBytes, await cacheFile().length());
    expect(prefs.getString('explore_home_feed_cache'), isNull);
    expect(prefs.getInt('explore_home_feed_ts'), isNull);
  });

  test(
    'saves go directly to a file without retaining preference blobs',
    () async {
      SharedPreferences.setMockInitialValues({'unrelated_setting': true});
      final prefs = await SharedPreferences.getInstance();
      await ExploreCacheStore(prefs).write('{"sections":[]}');
      expect(prefs.getKeys(), {'unrelated_setting'});
      expect(await cacheFile().exists(), isTrue);
    },
  );

  test('timestamp-only cache migrates and reports its file length', () async {
    SharedPreferences.setMockInitialValues({'explore_home_feed_ts': 123});
    final prefs = await SharedPreferences.getInstance();

    final snapshot = await ExploreCacheStore(prefs).read();

    expect(snapshot.payload, isNull);
    expect(snapshot.timestampMs, 123);
    expect(snapshot.sizeBytes, await cacheFile().length());
  });

  test('empty payload without a timestamp is preserved in the file', () async {
    SharedPreferences.setMockInitialValues({'explore_home_feed_cache': ''});
    final prefs = await SharedPreferences.getInstance();

    final snapshot = await ExploreCacheStore(prefs).read();

    expect(snapshot.payload, '');
    expect(snapshot.timestampMs, isNull);
    expect(snapshot.sizeBytes, await cacheFile().length());
  });

  test(
    'clear removes both cache keys and preserves other preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        'explore_home_feed_cache': '{"sections":[]}',
        'explore_home_feed_ts': 123,
        'unrelated_setting': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = ExploreCacheStore(prefs);

      await store.clear();

      final snapshot = await store.read();
      expect(snapshot.payload, isNull);
      expect(snapshot.timestampMs, isNull);
      expect(snapshot.sizeBytes, 0);
      expect(prefs.getKeys(), {'unrelated_setting'});
      expect(prefs.getBool('unrelated_setting'), isTrue);
    },
  );
}
