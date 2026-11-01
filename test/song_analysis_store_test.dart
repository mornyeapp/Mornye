import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mornye/services/song_analysis_store.dart';
import 'package:mornye/services/song_features.dart';

Float32List _features(double start) => Float32List.fromList([
  for (var i = 0; i < SongFeatures.length; i++) start + i / 4,
]);

void main() {
  late String path;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp('song-analysis-');
    addTearDown(() => directory.delete(recursive: true));
    path = '${directory.path}/song_analysis.db';
  });

  SongAnalysisStore store({int version = SongFeatures.version}) {
    Database? db;
    addTearDown(() => db?.close());
    return SongAnalysisStore(
      version: version,
      open: () async => db = await SongAnalysisStore.openWithFactory(
        databaseFactoryFfi,
        path,
      ),
    );
  }

  test('features and failed attempts round-trip by path', () async {
    final songs = store();
    await songs.save('/a.flac', (size: 10, modified: 20), _features(1));
    await songs.save('/b.flac', (size: 30, modified: 40), null);

    final features = await songs.features(['/a.flac', '/b.flac', '/c.flac']);
    expect(features.keys, ['/a.flac']);
    expect(features['/a.flac'], _features(1));

    final records = await songs.records(['/a.flac', '/b.flac', '/c.flac']);
    expect(records.keys, unorderedEquals(['/a.flac', '/b.flac']));
    expect(records['/a.flac']!.stamp, (size: 10, modified: 20));
    expect(records['/a.flac']!.failed, isFalse);
    expect(records['/a.flac']!.version, SongFeatures.version);
    expect(records['/b.flac']!.stamp, (size: 30, modified: 40));
    expect(records['/b.flac']!.failed, isTrue);
    expect((await songs.records()).length, 2);

    // A new analysis of a changed file replaces the failed attempt.
    await songs.save('/b.flac', (size: 31, modified: 41), _features(2));
    expect((await songs.records(['/b.flac']))['/b.flac']!.failed, isFalse);
    expect((await songs.features(['/b.flac']))['/b.flac'], _features(2));
  });

  test('another analysis version reads no features and shows the old '
      'version', () async {
    await store().save('/a.flac', (size: 1, modified: 2), _features(1));
    final newer = store(version: SongFeatures.version + 1);
    expect(await newer.features(['/a.flac']), isEmpty);
    expect(
      (await newer.records(['/a.flac']))['/a.flac']!.version,
      SongFeatures.version,
    );
  });

  test('rows are removed by path and cleared', () async {
    final songs = store();
    // More paths than one statement takes.
    final paths = [for (var i = 0; i < 1000; i++) '/$i.flac'];
    for (final path in paths.take(3)) {
      await songs.save(path, (size: 1, modified: 1), _features(0));
    }
    expect((await songs.features(paths)).length, 3);
    await songs.remove(['/0.flac', ...paths.skip(500)]);
    expect(
      (await songs.records()).keys,
      unorderedEquals(['/1.flac', '/2.flac']),
    );
    await songs.clear();
    expect(await songs.records(), isEmpty);
  });

  test('stored vectors keep their layout', () {
    final features = _features(-3);
    expect(SongFeatures.decode(SongFeatures.encode(features)), features);
    expect(SongFeatures.decode(Uint8List(8)), isNull);
    expect(SongFeatures.decode('features'), isNull);
    final broken = Float32List.fromList(features)..[5] = double.nan;
    expect(SongFeatures.decode(SongFeatures.encode(broken)), isNull);
  });
}
