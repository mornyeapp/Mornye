import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/ffmpeg_support.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ffmpeg-promotion-');
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<File> write(String name, String data) =>
      File('${directory.path}/$name').writeAsString(data);

  test('an in-place conversion stages without a leading dot', () async {
    final source = await write('song.flac', 'original');
    final plan = await FFmpegOutput.plan(
      source.path,
      '.flac',
      deleteOriginal: true,
    );
    // A dot name can become a hidden attribute that the rename keeps, and a
    // `.partial.<ext>` stage stays out of library scans.
    final name = File(plan.workingPath).uri.pathSegments.last;
    expect(name, startsWith('song.mornye-'));
    expect(name, endsWith('.partial.flac'));
    expect(plan.finalPath, source.path);
  });

  test(
    'metadata promotion publishes the complete output and removes staging',
    () async {
      final target = await write('song.opus', 'original');
      final temp = await write('temp.opus', 'tagged');
      expect(
        await FFmpegOutput.promote(
          temp.path,
          target.path,
          onError: (e) => fail('$e'),
        ),
        isTrue,
      );
      expect(await target.readAsString(), 'tagged');
      expect(await directory.list().map((file) => file.path).toList(), [
        target.path,
      ]);
    },
  );

  test('an empty successful temp output cannot replace the original', () async {
    final target = await write('song.opus', 'original');
    final temp = await write('temp.opus', '');
    expect(
      await FFmpegOutput.promote(
        temp.path,
        target.path,
        onError: (e) => fail('$e'),
      ),
      isFalse,
    );
    expect(await target.readAsString(), 'original');
    expect(await directory.list().map((file) => file.path).toList(), [
      target.path,
    ]);
  });

  test('missing temp output reports missing and keeps the original', () async {
    final target = await write('song.opus', 'original');
    var missing = false;
    expect(
      await FFmpegOutput.promote(
        '${directory.path}/missing.opus',
        target.path,
        onMissing: () => missing = true,
        onError: (e) => fail('$e'),
      ),
      isFalse,
    );
    expect(missing, isTrue);
    expect(await target.readAsString(), 'original');
  });

  test('a failed publication restores the original from its backup', () async {
    final target = await write('song.flac', 'original');
    final staging = await write('temp.flac', 'converted');
    final blocked = await Directory('${directory.path}/blocked.flac').create();
    await File('${blocked.path}/keep').writeAsString('untouched');
    Object? error;
    var restoredBeforeCallback = false;
    expect(
      await FFmpegOutput.finalize(
        plan: FFmpegOutputPlan(
          workingPath: staging.path,
          finalPath: blocked.path,
        ),
        inputPath: target.path,
        deleteOriginal: true,
        onError: (e) {
          error = e;
          restoredBeforeCallback =
              target.readAsStringSync() == 'original' && !staging.existsSync();
        },
      ),
      isNull,
    );
    expect(error, isA<FileSystemException>());
    expect(restoredBeforeCallback, isTrue);
    expect(await target.readAsString(), 'original');
    expect(await File('${blocked.path}/keep').readAsString(), 'untouched');
    expect(await staging.exists(), isFalse);
    expect(await directory.list().length, 2);
  });

  test('promotion reports publication errors after staging cleanup', () async {
    final target = await Directory('${directory.path}/blocked.opus').create();
    final original = await File(
      '${target.path}/keep',
    ).writeAsString('original');
    final temp = await write('temp.opus', 'tagged');
    Object? error;
    var stagingRemained = true;
    expect(
      await FFmpegOutput.promote(
        temp.path,
        target.path,
        onError: (e) {
          error = e;
          stagingRemained = directory.listSync().any(
            (entry) => entry.path.contains('.mornye-staging-'),
          );
        },
      ),
      isFalse,
    );
    expect(error, isA<FileSystemException>());
    expect(stagingRemained, isFalse);
    expect(await original.readAsString(), 'original');
    expect(await temp.exists(), isFalse);
    expect(await directory.list().length, 1);
  });

  test('a staging reservation failure preserves both existing files', () async {
    final parent = await write('parent', 'keep parent');
    final temp = await write('temp.opus', 'tagged');
    Object? error;
    expect(
      await FFmpegOutput.promote(
        temp.path,
        '${parent.path}/song.opus',
        onError: (e) => error = e,
      ),
      isFalse,
    );
    expect(error, isA<FileSystemException>());
    expect(await parent.readAsString(), 'keep parent');
    expect(await temp.exists(), isFalse);
    expect(await directory.list().length, 1);
  });
}
