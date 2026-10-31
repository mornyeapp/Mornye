import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_result.dart';
import 'package:mornye/services/download_file_finalizer.dart';
import 'package:mornye/services/download_saf_file_replacer.dart';

void main() {
  late Directory directory;
  late List<String> warnings;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('download-finalization-');
    warnings = [];
  });
  tearDown(() async => directory.delete(recursive: true));

  DownloadFileFinalizer finalizer({
    DecryptDownloadFile? decrypt,
    ConvertDownloadAudio? convert,
    ReplaceSafDownloadFile? replaceSaf,
    Future<String?> Function(String)? probe,
    Future<void> Function(String, String)? repair,
  }) => DownloadFileFinalizer(
    decryptFile:
        decrypt ??
        ({
          required inputPath,
          required descriptor,
          required deleteOriginal,
          prepareOutput,
        }) async => throw StateError('Unexpected decrypt'),
    convertAudio:
        convert ??
        ({
          required inputPath,
          required targetFormat,
          required bitrate,
          required deleteOriginal,
        }) async => throw StateError('Unexpected conversion'),
    replaceSafFile:
        replaceSaf ??
        ({
          required uri,
          required treeUri,
          required relativeDir,
          required op,
          avoidOverwrite = false,
          onPublishedFileName,
        }) async => throw StateError('Unexpected SAF access'),
    probeCodec: probe ?? (_) async => throw StateError('Unexpected probe'),
    repairAc4: repair ?? (_, _) async => throw StateError('Unexpected repair'),
    warn: warnings.add,
    info: (_) {},
  );

  DownloadResult encrypted({bool existing = false}) => DownloadResult.fromMap({
    'already_exists': existing,
    'decryption_key': 'abcd',
    'extension_context': {'provider': 'example'},
  });

  Future<DownloadDecryptionOutcome> decrypt(
    DownloadFileFinalizer stage,
    DownloadResult result,
    String path, {
    bool saf = false,
    String? treeUri = 'content://tree',
    bool repair = false,
  }) => stage.decrypt(
    result: result,
    filePath: path,
    useSaf: saf,
    treeUri: treeUri,
    relativeDir: 'Artist/Album',
    baseName: 'Song',
    extensionFallback: '.flac',
    repairContainer: repair,
  );

  test(
    'existing or unencrypted files never enter the transform stages',
    () async {
      for (final result in [
        encrypted(existing: true),
        DownloadResult.fromMap({}),
      ]) {
        final outcome = await decrypt(
          finalizer(),
          result,
          'content://source',
          saf: true,
        );
        expect(outcome.path, 'content://source');
        expect(outcome.failure, isNull);
      }
    },
  );

  test(
    'local AC-4 repair completes before source promotion and stays MP4',
    () async {
      final source = await File(
        '${directory.path}/Song.mp4',
      ).writeAsString('encrypted');
      final output = File('${directory.path}/work.mp4');
      final stage = finalizer(
        decrypt:
            ({
              required inputPath,
              required descriptor,
              required deleteOriginal,
              prepareOutput,
            }) async {
              expect(deleteOriginal, isTrue);
              await output.writeAsString('decrypted');
              await prepareOutput!(output.path);
              await source.delete();
              return (await output.rename(source.path)).path;
            },
        repair: (path, encryptedPath) async {
          expect(await File(encryptedPath).readAsString(), 'encrypted');
          await File(path).writeAsString('repaired');
        },
        probe: (_) async => 'ac4',
      );
      final outcome = await decrypt(
        stage,
        encrypted(),
        source.path,
        repair: true,
      );
      expect(outcome.path, source.path);
      expect(await source.readAsString(), 'repaired');
      expect(await directory.list().length, 1);
    },
  );

  test('normalizes audio-only MP4 without overwriting a sibling', () async {
    final output = await File(
      '${directory.path}/Song.mp4',
    ).writeAsString('audio');
    final stage = finalizer(
      decrypt:
          ({
            required inputPath,
            required descriptor,
            required deleteOriginal,
            prepareOutput,
          }) async => output.path,
      probe: (_) async => 'aac',
    );
    final outcome = await decrypt(stage, encrypted(), output.path);
    expect(outcome.path, '${directory.path}/Song.m4a');
    expect(await File(outcome.path!).readAsString(), 'audio');
    await output.writeAsString('second');
    final collision = await decrypt(stage, encrypted(), output.path);
    expect(collision.path, output.path);
    expect(await File(outcome.path!).readAsString(), 'audio');
    expect(warnings.single, contains('target already exists'));
  });

  test(
    'SAF access, decrypt and publish failures retain distinct outcomes',
    () async {
      for (final failure in DownloadDecryptionFailure.values) {
        final temp = File('${directory.path}/encrypted.flac');
        final output = File('${directory.path}/decrypted.flac');
        final replacer = DownloadSafFileReplacer(
          copyToTemp: (_) async =>
              failure == DownloadDecryptionFailure.safAccess
              ? null
              : (await temp.writeAsString('encrypted')).path,
          publish:
              ({
                required treeUri,
                required relativeDir,
                required fileName,
                required srcPath,
                required avoidOverwrite,
                required preservedSuffix,
                collisionCleanFileName,
                collisionVariantFileName,
              }) async => null,
          deleteSource: (_) async => fail('Source was deleted after failure'),
        );
        final stage = finalizer(
          replaceSaf: replacer.replace,
          decrypt:
              ({
                required inputPath,
                required descriptor,
                required deleteOriginal,
                prepareOutput,
              }) async {
                expect(deleteOriginal, isFalse);
                return failure == DownloadDecryptionFailure.decrypt
                    ? null
                    : (await output.writeAsString('decrypted')).path;
              },
        );
        final outcome = await decrypt(
          stage,
          encrypted(),
          'content://source',
          saf: true,
        );
        expect(outcome.path, isNull);
        expect(outcome.failure, failure);
        expect(await directory.list().length, 0);
      }
      final missingTree = await decrypt(
        finalizer(),
        encrypted(),
        'content://source',
        saf: true,
        treeUri: '',
      );
      expect(missingTree.failure, DownloadDecryptionFailure.safAccess);
    },
  );

  Future<DownloadConversionOutcome> convert(
    DownloadFileFinalizer stage,
    DownloadResult result, {
    String path = '/source.flac',
    String? name,
    bool saf = false,
    bool enabled = true,
    Future<void> Function(String, String)? embed,
    void Function()? start,
  }) => stage.autoConvert(
    result: result,
    filePath: path,
    fileName: name,
    quality: '24-bit/96kHz',
    enabled: enabled,
    targetFormat: 'opus',
    targetBitrate: '192k',
    useSaf: saf,
    treeUri: 'content://tree',
    embedMetadata: embed,
    onStart: start,
  );

  test(
    'disabled and already satisfied conversions leave the file alone',
    () async {
      final result = DownloadResult.fromMap({'bitrate': 192});
      for (final enabled in [false, true]) {
        final outcome = await convert(
          finalizer(),
          result,
          path: '/Song.opus',
          enabled: enabled,
          start: () => fail('Unexpected finalizing progress'),
        );
        expect(outcome.converted, isFalse);
        expect(outcome.filePath, '/Song.opus');
      }
    },
  );

  test(
    'optional conversion failure preserves source, quality and extension data',
    () async {
      final result = encrypted();
      final stage = finalizer(
        convert:
            ({
              required inputPath,
              required targetFormat,
              required bitrate,
              required deleteOriginal,
            }) async => null,
      );
      final outcome = await convert(stage, result, name: 'Song.flac');
      expect(outcome.converted, isFalse);
      expect(outcome.filePath, '/source.flac');
      expect(outcome.fileName, 'Song.flac');
      expect(outcome.quality, '24-bit/96kHz');
      expect(result['extension_context'], {'provider': 'example'});
      expect(
        result['auto_conversion_warning'],
        contains('no automatic conversion output'),
      );
      expect(result.filePath, isNull);
    },
  );

  test(
    'deferred SAF conversion retains its logical filename despite tag failure',
    () async {
      final result = DownloadResult.fromMap({
        'actual_bit_depth': 24,
        'actual_sample_rate': 96000,
        'unknown': 'kept',
      });
      final stage = finalizer(
        convert:
            ({
              required inputPath,
              required targetFormat,
              required bitrate,
              required deleteOriginal,
            }) async {
              expect(deleteOriginal, isTrue);
              expect(targetFormat, 'opus');
              expect(bitrate, '192k');
              return '/cache/native_saf_work_123.opus';
            },
      );
      final outcome = await convert(
        stage,
        result,
        path: '/cache/native_saf_work_123.flac',
        name: 'Artist - Song.flac',
        saf: true,
        embed: (_, _) async => throw StateError('Tags failed'),
      );
      expect(outcome.converted, isTrue);
      expect(outcome.fileName, 'Artist - Song.opus');
      expect(outcome.quality, 'OPUS 192kbps');
      expect(result.fileName, outcome.fileName);
      expect(result.actualBitDepth, isNull);
      expect(result.actualSampleRate, isNull);
      expect(result.audioCodec, 'opus');
      expect(result['unknown'], 'kept');
      expect(
        result['auto_conversion_metadata_warning'],
        contains('Tags failed'),
      );
    },
  );

  for (final uri in [
    'content://com.android.externalstorage.documents/tree/primary%3AMusic/document/primary%3AMusic%2FAlbum%2FSong.flac',
    'content://com.android.providers.downloads.documents/document/msf%3A1234',
  ]) {
    test(
      'SAF conversion without a file name never publishes a path as name ($uri)',
      () async {
        final output = File('${directory.path}/cache2.opus');
        String? published;
        final stage = finalizer(
          replaceSaf:
              ({
                required uri,
                required treeUri,
                required relativeDir,
                required op,
                avoidOverwrite = false,
                onPublishedFileName,
              }) async {
                final done = await op('${directory.path}/cache2.flac', (_) {});
                published = done?.$2;
                return 'content://converted';
              },
          convert:
              ({
                required inputPath,
                required targetFormat,
                required bitrate,
                required deleteOriginal,
              }) async => (await output.writeAsString('converted')).path,
        );
        await convert(stage, encrypted(), path: uri, name: null, saf: true);
        expect(published, isNotNull);
        expect(published, isNot(contains('/')));
        expect(published, isNot(contains(':')));
        expect(published, isNot(contains('%')));
        expect(published, endsWith('.opus'));
      },
    );
  }

  test('downloadSourceFileName reads the name out of SAF document ids', () {
    expect(
      downloadSourceFileName(
        'content://com.android.externalstorage.documents/tree/primary%3AMusic/document/primary%3AMusic%2FAlbum%2FSong.flac',
      ),
      'Song.flac',
    );
    expect(
      downloadSourceFileName(
        'content://com.android.providers.downloads.documents/document/msf%3A1234',
      ),
      '1234',
    );
    expect(
      downloadSourceFileName('/storage/emulated/0/Music/Song.flac'),
      'Song.flac',
    );
  });

  test(
    'SAF conversion adopts the collision-safe published name and cleans temps',
    () async {
      final temp = File('${directory.path}/cache.flac');
      final output = File('${directory.path}/cache.opus');
      final events = <String>[];
      final replacer = DownloadSafFileReplacer(
        copyToTemp: (_) async => (await temp.writeAsString('source')).path,
        publish:
            ({
              required treeUri,
              required relativeDir,
              required fileName,
              required srcPath,
              required avoidOverwrite,
              required preservedSuffix,
              collisionCleanFileName,
              collisionVariantFileName,
            }) async {
              expect(avoidOverwrite, isTrue);
              expect(fileName, 'Song.opus');
              expect(
                await File(srcPath).readAsString(),
                'converted and tagged',
              );
              events.add('published');
              return (uri: 'content://converted', fileName: 'Song (2).opus');
            },
        deleteSource: (_) async => events.add('deleted'),
      );
      final stage = finalizer(
        replaceSaf: replacer.replace,
        convert:
            ({
              required inputPath,
              required targetFormat,
              required bitrate,
              required deleteOriginal,
            }) async {
              expect(deleteOriginal, isFalse);
              return (await output.writeAsString('converted')).path;
            },
      );
      final result = encrypted();
      final outcome = await convert(
        stage,
        result,
        path: 'content://source',
        name: 'Song.flac',
        saf: true,
        embed: (path, format) async {
          expect(format, 'opus');
          await File(path).writeAsString('converted and tagged');
        },
      );
      expect(outcome.filePath, 'content://converted');
      expect(outcome.fileName, 'Song (2).opus');
      expect(result.fileName, 'Song (2).opus');
      expect(events, ['published', 'deleted']);
      expect(await directory.list().length, 0);
    },
  );
}
