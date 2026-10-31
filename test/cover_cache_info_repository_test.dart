import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/cover_cache_info_repository.dart';

/// Counts index rewrites: every save writes `<index>.tmp` and renames it.
final class _IndexWrites extends IOOverrides {
  int count = 0;

  @override
  File createFile(String path) {
    if (path.endsWith('.json.tmp')) count++;
    return super.createFile(path);
  }
}

CacheObject _cover(int i, {DateTime? touched, String? eTag}) => CacheObject(
  'https://covers.example.invalid/album-$i/cover-1400.jpg',
  relativePath: 'cover-$i.jpg',
  validTill: DateTime(2030).add(Duration(minutes: i)),
  eTag: eTag ?? '"etag-$i"',
  length: 250000 + i,
  touched: touched ?? DateTime(2026, 10, 1).add(Duration(seconds: i)),
);

/// An index file exactly as [JsonCacheInfoRepository] writes it.
Future<void> _writeIndex(File file, int count) => file.writeAsString(
  jsonEncode([
    for (var i = 1; i <= count; i++)
      _cover(i).copyWith(id: i).toMap(setTouchedToNow: false),
  ]),
);

List<Map<String, dynamic>> _rows(File file) =>
    (jsonDecode(file.readAsStringSync()) as List<dynamic>)
        .cast<Map<String, dynamic>>();

Map<String, Map<String, dynamic>> _maps(Iterable<CacheObject> objects) => {
  for (final object in objects)
    object.key: object.toMap(setTouchedToNow: false),
};

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
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cover-index-');
    file = File('${directory.path}/null.json');
  });

  tearDown(() => directory.delete(recursive: true));

  test('reads and writes the package JSON index both ways', () async {
    final package = JsonCacheInfoRepository.withFile(file);
    await package.open();
    final inserted = <CacheObject>[];
    for (var i = 1; i <= 4; i++) {
      inserted.add(await package.insert(_cover(i), setTouchedToNow: false));
    }
    inserted.add(
      await package.insert(
        CacheObject(
          'https://covers.example.invalid/redirected.jpg',
          key: 'cover-key',
          relativePath: 'keyed.png',
          validTill: DateTime(2031),
        ),
        setTouchedToNow: false,
      ),
    );
    await package.delete(inserted[1].id!);
    await package.close();
    final written = file.readAsBytesSync();

    final writes = _IndexWrites();
    await IOOverrides.runWithIOOverrides(() async {
      final repository = CoverCacheInfoRepository(() async => file);
      await repository.open();
      final reread = JsonCacheInfoRepository.withFile(file);
      await reread.open();
      expect(
        _maps(await repository.getAllObjects()),
        _maps(await reread.getAllObjects()),
      );
      await reread.close();
      expect((await repository.get('cover-key'))?.relativePath, 'keyed.png');
      expect(await repository.get(inserted[1].key), isNull);
      await repository.close();
      expect(writes.count, 0);
      expect(file.readAsBytesSync(), written);

      await repository.open();
      final added = await repository.insert(_cover(9));
      expect(added.id, 6);
      expect(added.key, _cover(9).key);
      await repository.update(inserted[0]);
      await repository.update(
        inserted[2].copyWith(eTag: '"changed"', length: 7),
      );
      expect(await repository.delete(inserted[3].id!), 1);
      await repository.close();
      expect(writes.count, 1);
    }, writes);
    final mine = file.readAsBytesSync();

    final package2 = JsonCacheInfoRepository.withFile(file);
    await package2.open();
    final objects = {
      for (final object in await package2.getAllObjects()) object.key: object,
    };
    expect(objects.keys.toSet(), {
      inserted[0].key,
      inserted[2].key,
      'cover-key',
      _cover(9).key,
    });
    expect(objects[_cover(9).key]!.id, 6);
    expect(objects[inserted[2].key]!.eTag, '"changed"');
    expect(objects[inserted[2].key]!.length, 7);
    expect(
      objects[inserted[0].key]!.touched!.isAfter(inserted[0].touched!),
      isTrue,
    );
    // Rewritten by the package without changes: the same bytes.
    await package2.update(objects[inserted[0].key]!, setTouchedToNow: false);
    await package2.close();
    expect(file.readAsBytesSync(), mine);
  });

  test('saves a burst of changes once and waits longer for touches', () async {
    await _writeIndex(file, 20);
    final writes = _IndexWrites();
    var encoded = 0;
    await IOOverrides.runWithIOOverrides(() async {
      final repository = CoverCacheInfoRepository(
        () async => file,
        saveDelay: const Duration(milliseconds: 100),
        touchSaveDelay: const Duration(hours: 1),
        encodeRow: (row) {
          encoded++;
          return jsonEncode(row);
        },
      );
      await repository.open();
      final objects = await repository.getAllObjects();

      for (var i = 21; i <= 40; i++) {
        await repository.insert(_cover(i));
      }
      expect(writes.count, 0);
      await _until(() => writes.count == 1, 'the insert save');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(writes.count, 1);
      expect(encoded, 20);
      expect(_rows(file), hasLength(40));

      for (final object in objects.take(10)) {
        await repository.update(object);
      }
      await repository.update(objects[15], setTouchedToNow: false);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(writes.count, 1);
      expect(encoded, 20);

      await repository.update(objects[12].copyWith(eTag: '"new"'));
      await _until(() => writes.count == 2, 'the update save');
      expect(encoded, 31);
      final touchedRows = {
        for (final row in _rows(file)) row['_id'] as int: row['touched'],
      };
      for (final object in objects.take(10)) {
        expect(
          touchedRows[object.id],
          greaterThan(object.touched!.millisecondsSinceEpoch),
        );
      }

      await repository.delete(objects[19].id!);
      await repository.close();
      expect(writes.count, 3);
      expect(encoded, 31);
    }, writes);
    expect(_rows(file), hasLength(39));
  });

  test('a scroll over an old index writes once, at flush', () async {
    const size = 600;
    await _writeIndex(file, size);
    final before = _rows(file);
    final covers = Directory('${directory.path}/cover_cache');
    await covers.create();
    for (var i = 1; i <= size; i++) {
      await File('${covers.path}/cover-$i.jpg').writeAsBytes([i % 256]);
    }
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final writes = _IndexWrites();
    var encoded = 0;
    await IOOverrides.runWithIOOverrides(() async {
      final repository = CoverCacheInfoRepository(
        () async => file,
        encodeRow: (row) {
          encoded++;
          return jsonEncode(row);
        },
      );
      final manager = CacheManager(
        Config(
          'coverScrollTest',
          repo: repository,
          fileSystem: IOFileSystem(covers.path),
          maxNrOfCacheObjects: 1000,
          stalePeriod: const Duration(days: 365),
        ),
      );
      for (var i = 1; i <= 200; i++) {
        final cached = await manager.getFileFromCache(_cover(i).key);
        expect(cached, isNotNull);
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(writes.count, 0);
      expect(encoded, 0);

      await repository.flush();
      expect(writes.count, 1);
      expect(encoded, 200);
      await manager.dispose();
      expect(writes.count, 1);
    }, writes);

    final after = _rows(file);
    expect(after, hasLength(size));
    for (var i = 0; i < size; i++) {
      final changed = Map<String, dynamic>.of(after[i])..remove('touched');
      final original = Map<String, dynamic>.of(before[i])..remove('touched');
      expect(changed, original);
      if (i < 200) {
        expect(after[i]['touched'], greaterThan(before[i]['touched'] as int));
      } else {
        expect(after[i]['touched'], before[i]['touched']);
      }
    }
  });

  test('get does not slow down as the index grows', () async {
    Future<int> microsecondsPerThousandGets(int size) async {
      await _writeIndex(file, size);
      final repository = CoverCacheInfoRepository(() async => file);
      await repository.open();
      final key = _cover(size).key;
      for (var i = 0; i < 2000; i++) {
        await repository.get(key);
      }
      final watch = Stopwatch()..start();
      for (var i = 0; i < 20000; i++) {
        await repository.get(key);
      }
      final elapsed = watch.elapsedMicroseconds ~/ 20;
      await repository.close();
      return elapsed;
    }

    final small = await microsecondsPerThousandGets(20);
    final large = await microsecondsPerThousandGets(20000);
    // A scan of 20,000 entries per lookup is about 100 times slower.
    expect(large, lessThan(small * 10 + 1000));
  });

  test('an index it cannot locate stays in memory', () async {
    await _writeIndex(file, 3);
    final written = file.readAsBytesSync();
    final repository = CoverCacheInfoRepository(
      () async => throw const FileSystemException('no support directory'),
    );
    expect(await repository.open(), isTrue);
    final added = await repository.insert(_cover(1));
    expect(await repository.get(added.key), isNotNull);
    await repository.close();
    expect(file.readAsBytesSync(), written);
  });

  test('reads the index in place when no worker can start', () async {
    await _writeIndex(file, 3);
    final repository = CoverCacheInfoRepository(
      () async => file,
      runInWorker: <T>(_) =>
          Future<T>.error(IsolateSpawnException('no worker')),
    );
    await repository.open();
    expect(await repository.getAllObjects(), hasLength(3));
    expect(await repository.get(_cover(2).key), isNotNull);
    await repository.insert(_cover(4));
    await repository.close();
    expect(_rows(file).map((row) => row['key']), [
      for (var i = 1; i <= 4; i++) _cover(i).key,
    ]);
  });

  test('an index it cannot read is reported and never replaced', () async {
    await _writeIndex(file, 3);
    final written = file.readAsBytesSync();
    await Process.run('chmod', ['000', file.path]);
    addTearDown(() => Process.run('chmod', ['644', file.path]));
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);
    final repository = CoverCacheInfoRepository(() async => file);
    await repository.open();
    expect(errors.single.exception, isA<FileSystemException>());
    final added = await repository.insert(_cover(9));
    expect(await repository.get(added.key), isNotNull);
    await repository.close();
    await Process.run('chmod', ['644', file.path]);
    expect(file.readAsBytesSync(), written);
  }, skip: Platform.isWindows ? 'needs POSIX permissions' : null);

  test('a corrupt index is reported and replaced', () async {
    await file.writeAsString('[{"_id": 1, "url": ');
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);
    final repository = CoverCacheInfoRepository(() async => file);
    await repository.open();
    expect(errors, hasLength(1));
    expect(errors.single.exception, isA<FormatException>());
    expect(await repository.getAllObjects(), isEmpty);
    await repository.insert(_cover(1));
    await repository.close();
    expect(_rows(file), hasLength(1));
  });
}
