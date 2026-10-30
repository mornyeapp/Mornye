import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse, AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/cover_cache_manager.dart';

/// Counts index rewrites: every save writes `<index>.tmp` and renames it.
final class _IndexWrites extends IOOverrides {
  int count = 0;

  @override
  File createFile(String path) {
    if (path.endsWith('.json.tmp')) count++;
    return super.createFile(path);
  }
}

CacheObject _cover(int i) => CacheObject(
  'https://covers.example.invalid/album-$i/cover-1400.jpg',
  relativePath: 'cover-$i.jpg',
  validTill: DateTime(2030),
  eTag: '"etag-$i"',
  length: 1,
  touched: DateTime(2026, 10, 1).add(Duration(seconds: i)),
);

Future<void> _until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  const size = 300;
  late Directory support;
  late File index;

  List<Map<String, dynamic>> rows() =>
      (jsonDecode(index.readAsStringSync()) as List<dynamic>)
          .cast<Map<String, dynamic>>();

  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('cover-manager-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => support.path,
    );
    // An index and covers left by an earlier build.
    index = File('${support.path}/null.json');
    await index.writeAsString(
      jsonEncode([
        for (var i = 1; i <= size; i++)
          _cover(i).copyWith(id: i).toMap(setTouchedToNow: false),
      ]),
    );
    final covers = await Directory('${support.path}/cover_cache').create();
    for (var i = 1; i <= size; i++) {
      await File('${covers.path}/cover-$i.jpg').writeAsBytes([i % 256]);
    }
  });

  tearDownAll(() async {
    await CoverCacheManager.instance.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await support.delete(recursive: true);
  });

  test('the cover cache works before initialize and stays one', () async {
    final logs = <String>[];
    final print = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    addTearDown(() => debugPrint = print);

    final early = CoverCacheManager.instance;
    expect(early, isNot(isA<DefaultCacheManager>()));
    final cached = await early.getFileFromCache(_cover(1).key);
    expect(cached, isNotNull);
    expect(await cached!.file.readAsBytes(), [1]);

    final first = CoverCacheManager.initialize();
    final second = CoverCacheManager.initialize();
    await first;
    expect(CoverCacheManager.instance, same(early));
    await second;
    expect(CoverCacheManager.instance, same(early));
    expect(CoverCacheManager.isInitialized, isTrue);
    expect(logs.where((line) => line.contains('Not initialized')), isEmpty);
    expect(
      logs.where((line) => line.contains('Initialized successfully')),
      hasLength(1),
    );
  });

  test('a scroll over cached covers saves the index once, on pause', () async {
    await CoverCacheManager.flush();
    final before = rows();
    final writes = _IndexWrites();
    await IOOverrides.runWithIOOverrides(() async {
      for (var i = 2; i <= 201; i++) {
        final cached = await CoverCacheManager.instance.getFileFromCache(
          _cover(i).key,
        );
        expect(cached, isNotNull);
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(writes.count, 0);

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
      }
      await _until(() => writes.count == 1, 'the pause save');
      await CoverCacheManager.flush();
      expect(writes.count, 1);
    }, writes);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      binding.handleAppLifecycleStateChanged(state);
    }

    final after = rows();
    expect(after, hasLength(size));
    for (var i = 0; i < size; i++) {
      final scrolled = i >= 1 && i <= 200;
      expect(
        after[i]['touched'],
        scrolled
            ? greaterThan(before[i]['touched'] as int)
            : before[i]['touched'],
      );
      expect(
        Map<String, dynamic>.of(after[i])..remove('touched'),
        Map<String, dynamic>.of(before[i])..remove('touched'),
      );
    }
  });

  test('an exit request saves pending index changes first', () async {
    await CoverCacheManager.flush();
    const url = 'https://covers.example.invalid/before-exit.jpg';
    final writes = _IndexWrites();
    await IOOverrides.runWithIOOverrides(() async {
      await CoverCacheManager.instance.putFile(url, Uint8List.fromList([9]));
      expect(writes.count, 0);
      expect(await binding.handleRequestAppExit(), AppExitResponse.exit);
      expect(writes.count, 1);
    }, writes);
    expect(rows().map((row) => row['key']), contains(url));
  });
}
