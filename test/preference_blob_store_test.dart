import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:mornye/services/preference_blob_store.dart';

class _RemovalFailure extends InMemorySharedPreferencesStore {
  _RemovalFailure() : super.withData({'flutter.blob': 'legacy'});
  bool fail = true;

  @override
  Future<bool> remove(String key) async => fail ? false : super.remove(key);
}

class _CountingPreferences extends InMemorySharedPreferencesStore {
  _CountingPreferences(super.data) : super.withData();

  int writes = 0;
  int removals = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    writes++;
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) {
    removals++;
    return super.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SharedPreferences prefs;
  late PreferenceBlobStore store;
  File file() => File('${root.path}/preference_blobs/test.json');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('preference-blob-');
    SharedPreferences.setMockInitialValues({
      'blob': 'Musik 🎵 日本語',
      'timestamp': 123,
      'user_setting': true,
    });
    prefs = await SharedPreferences.getInstance();
    store = PreferenceBlobStore('test', const {
      'blob': String,
      'timestamp': int,
    }, directory: () async => root);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'migrates exact values, removes owned keys and reads file size',
    () async {
      final snapshot = await store.read(prefs);
      expect(snapshot.values, {'blob': 'Musik 🎵 日本語', 'timestamp': 123});
      expect(snapshot.sizeBytes, await file().length());
      expect(prefs.getKeys(), {'user_setting'});
      expect((await store.read(prefs)).values, snapshot.values);
      expect(jsonDecode(await file().readAsString()), snapshot.values);
    },
  );

  test('a committed file wins over leftover preferences', () async {
    await store.write(prefs, {'blob': 'current'});
    await prefs.setString('blob', 'stale');
    expect((await store.read(prefs)).values, {'blob': 'current'});
    expect(prefs.containsKey('blob'), isFalse);
  });

  test(
    'malformed JSON and wrong value types fall back to legacy data',
    () async {
      for (final contents in [
        '{broken',
        '[]',
        '{"blob":42}',
        '{"unknown":"x"}',
      ]) {
        await prefs.setString('blob', 'legacy');
        await file().parent.create(recursive: true);
        await file().writeAsString(contents);
        expect((await store.read(prefs)).values['blob'], 'legacy');
        expect(prefs.containsKey('blob'), isFalse);
      }
    },
  );

  test(
    'migration retains preferences until the durable save finishes',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      final held = PreferenceBlobStore(
        'test',
        store.keys,
        directory: store.directory,
        persist: (file, data) async {
          started.complete();
          await gate.future;
          await store.persist(file, data);
        },
      );
      final reading = held.read(prefs);
      await started.future;
      expect(prefs.getString('blob'), 'Musik 🎵 日本語');
      expect(await file().exists(), isFalse);
      gate.complete();
      await reading;
      expect(prefs.containsKey('blob'), isFalse);
    },
  );

  test('failed migration keeps legacy values and retries later', () async {
    final failing = PreferenceBlobStore(
      'test',
      store.keys,
      directory: store.directory,
      persist: (_, _) async => throw const FileSystemException('Disk full'),
    );
    expect((await failing.read(prefs)).values['blob'], 'Musik 🎵 日本語');
    expect(prefs.containsKey('blob'), isTrue);
    expect(await file().exists(), isFalse);
    expect((await store.read(prefs)).values['blob'], 'Musik 🎵 日本語');
    expect(prefs.containsKey('blob'), isFalse);
  });

  test(
    'failed replacement keeps the old file and leaves later writes usable',
    () async {
      await store.write(prefs, {'blob': 'old'});
      await prefs.setString('blob', 'legacy');
      final failing = PreferenceBlobStore(
        'test',
        store.keys,
        directory: store.directory,
        persist: (_, _) async => throw const FileSystemException('Disk full'),
      );
      await expectLater(
        failing.write(prefs, {'blob': 'lost'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(jsonDecode(await file().readAsString()), {'blob': 'old'});
      expect(prefs.getString('blob'), 'legacy');
      await store.write(prefs, {'blob': 'new'});
      expect((await store.read(prefs)).values, {'blob': 'new'});
    },
  );

  test(
    'real rename failure cleans staging and preserves preferences',
    () async {
      await Directory(file().path).create(recursive: true);
      await expectLater(
        store.write(prefs, {'blob': 'new'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(prefs.containsKey('blob'), isTrue);
      expect(
        await file().parent.list().where((entry) => entry is File).toList(),
        isEmpty,
      );
    },
  );

  test(
    'overlapping migration, write and clear remain ordered across instances',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      final held = PreferenceBlobStore(
        'test',
        store.keys,
        directory: store.directory,
        persist: (file, data) async {
          started.complete();
          await gate.future;
          await store.persist(file, data);
        },
      );
      final migration = held.read(prefs);
      await started.future;
      final writing = store.write(prefs, {'blob': 'updated'});
      final clearing = store.clear(prefs);
      gate.complete();
      await migration;
      await writing;
      await clearing;
      expect(await file().exists(), isFalse);
      expect((await store.read(prefs)).values, isEmpty);
      expect(prefs.getBool('user_setting'), isTrue);
    },
  );

  test(
    'failed legacy cleanup leaves a tombstone that prevents resurrection',
    () async {
      final platform = _RemovalFailure();
      SharedPreferencesStorePlatform.instance = platform;
      await prefs.reload();
      await expectLater(store.clear(prefs), throwsStateError);
      expect(await file().readAsString(), '{}');
      expect(prefs.containsKey('blob'), isFalse);
      platform.fail = false;
      expect((await store.read(prefs)).values, isEmpty);
      await prefs.reload();
      expect(prefs.containsKey('blob'), isFalse);
      expect(await file().exists(), isFalse);
    },
  );

  test(
    'large migrated blobs and repeated saves do not rewrite preferences',
    () async {
      final values = <String, Object>{
        for (final (key, size) in [
          ('explore_home_feed_cache', 119),
          ('autoplay_learning_model_v1', 88),
          ('update_checker_releases_json', 48),
        ])
          key: jsonEncode({'data': List.filled(size * 1024, 'x').join()}),
        'user_setting': true,
      };
      SharedPreferences.setMockInitialValues(values);
      prefs = await SharedPreferences.getInstance();
      final platform = _CountingPreferences({
        for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
      });
      SharedPreferencesStorePlatform.instance = platform;
      final before = utf8.encode(jsonEncode(values)).length;
      final stores = [
        for (final key in values.keys.where((key) => key != 'user_setting'))
          PreferenceBlobStore(key, {key: String}, directory: () async => root),
      ];
      for (final store in stores) {
        await store.read(prefs);
      }
      for (var save = 0; save < 20; save++) {
        for (final store in stores) {
          final key = store.keys.keys.single;
          await store.write(prefs, {key: values[key]});
        }
      }
      expect(platform.writes, 0);
      expect(platform.removals, 3);
      expect(prefs.getKeys(), {'user_setting'});
      final after = utf8
          .encode(
            jsonEncode({
              for (final key in prefs.getKeys()) key: prefs.get(key),
            }),
          )
          .length;
      // ignore: avoid_print
      print(
        'Preference fixture bytes: $before -> $after; '
        '60 blob saves: ${platform.writes} preference writes',
      );
    },
  );

  test(
    'metadata updates do not replace a newer body with an old snapshot',
    () async {
      await store.write(prefs, {'blob': 'old', 'timestamp': 1});
      await store.write(prefs, {'blob': 'new', 'timestamp': 2});
      await store.update(prefs, (current) => {...current, 'timestamp': 3});
      expect((await store.read(prefs)).values, {'blob': 'new', 'timestamp': 3});
    },
  );
}
