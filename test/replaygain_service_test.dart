import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/replaygain_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late String tempPath;
  late List<String> calls;
  late Map<String, dynamic> metadata;
  late Map<String, String> editedFields;
  var method = 'native_ogg';
  var applyEdits = true;
  var saveSaf = true;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('replaygain-test-');
    tempPath = '${directory.path}/saf_song.opus';
    calls = [];
    editedFields = {};
    metadata = {
      'audio_codec': 'opus',
      'replaygain_track_gain': '-4.00 dB',
      'replaygain_album_gain': '-3.00 dB',
    };
    method = 'native_ogg';
    applyEdits = true;
    saveSaf = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'safCopyToTemp':
          await File(tempPath).writeAsString('original audio');
          return tempPath;
        case 'editFileMetadata':
          editedFields = Map<String, String>.from(
            jsonDecode(args['metadata_json'] as String) as Map,
          );
          if (applyEdits) {
            metadata.addAll(editedFields);
            if (metadata['audio_codec'] == 'opus') {
              metadata.removeWhere((key, _) => key.endsWith('_peak'));
            }
          }
          return jsonEncode({'success': true, 'method': method});
        case 'readFileMetadata':
          return jsonEncode(metadata);
        case 'writeTempToSaf':
          expect(args['temp_path'], tempPath);
          expect(await File(tempPath).exists(), isTrue);
          return jsonEncode({'success': saveSaf});
        default:
          fail('Unexpected method: ${call.method}');
      }
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test(
    'manual SAF scan writes and verifies Opus before copying back',
    () async {
      final result = await ReplayGainService.applyToFile(
        'content://music/document/42',
        scan: (path) async {
          expect(path, tempPath);
          expect(await File(path).exists(), isTrue);
          calls.add('scan');
          return ReplayGainResult(
            trackGain: '-12.20 dB',
            trackPeak: '1.258925',
            integratedLufs: -5.8,
            truePeakLinear: 1.258925,
          );
        },
      );
      expect(result, isTrue);
      expect(calls, [
        'safCopyToTemp',
        'scan',
        'editFileMetadata',
        'readFileMetadata',
        'writeTempToSaf',
      ]);
      expect(editedFields['replaygain_track_gain'], '-12.20 dB');
      expect(await File(tempPath).exists(), isFalse);
    },
  );

  test(
    'album gain on an extensionless SAF URI uses the native writer',
    () async {
      expect(
        await ReplayGainService.writeAlbumTags(
          'content://music/document/42',
          '-10.00 dB',
          '1.300000',
        ),
        isTrue,
      );
      expect(editedFields, {
        'replaygain_album_gain': '-10.00 dB',
        'replaygain_album_peak': '1.300000',
      });
      expect(metadata['replaygain_track_gain'], '-4.00 dB');
      expect(calls.last, 'writeTempToSaf');
      expect(await File(tempPath).exists(), isFalse);
    },
  );

  test('native fallback instruction is not a successful Opus write', () async {
    method = 'ffmpeg';
    applyEdits = false;
    expect(
      await ReplayGainService.writeTrackTags(
        'content://music/document/42',
        '-12.20 dB',
        '1.258925',
      ),
      isFalse,
    );
    expect(calls, ['safCopyToTemp', 'editFileMetadata']);
    expect(await File(tempPath).exists(), isFalse);
  });

  test('unchanged gain fails verification and never overwrites SAF', () async {
    applyEdits = false;
    expect(
      await ReplayGainService.writeTrackTags(
        'content://music/document/42',
        '-12.20 dB',
        '1.258925',
      ),
      isFalse,
    );
    expect(calls, ['safCopyToTemp', 'editFileMetadata', 'readFileMetadata']);
    expect(await File(tempPath).exists(), isFalse);
  });

  test(
    'SAF save failure is reported and the temporary copy is removed',
    () async {
      saveSaf = false;
      expect(
        await ReplayGainService.writeTrackTags(
          'content://music/document/42',
          '-12.20 dB',
          '1.258925',
        ),
        isFalse,
      );
      expect(calls.last, 'writeTempToSaf');
      expect(await File(tempPath).exists(), isFalse);
    },
  );

  test(
    'scan failure leaves SAF untouched and removes its temporary copy',
    () async {
      expect(
        await ReplayGainService.applyToFile(
          'content://music/document/42',
          scan: (_) async => null,
        ),
        isFalse,
      );
      expect(calls, ['safCopyToTemp']);
      expect(await File(tempPath).exists(), isFalse);
    },
  );

  test('FLAC native method and peak verification remain supported', () async {
    method = 'native';
    metadata['audio_codec'] = 'flac';
    expect(
      await ReplayGainService.writeTrackTags(
        '${directory.path}/song.flac',
        '-12.20 dB',
        '1.258925',
      ),
      isTrue,
    );
    expect(metadata['replaygain_track_peak'], '1.258925');
    expect(calls, ['editFileMetadata', 'readFileMetadata']);
  });

  test('removal clears both scopes and verifies before saving SAF', () async {
    metadata['title'] = 'Preserved title';
    expect(
      await ReplayGainService.removeFromFile('content://music/document/42'),
      isTrue,
    );
    expect(editedFields, {
      'replaygain_track_gain': '',
      'replaygain_track_peak': '',
      'replaygain_album_gain': '',
      'replaygain_album_peak': '',
    });
    expect(metadata['title'], 'Preserved title');
    expect(calls, [
      'safCopyToTemp',
      'editFileMetadata',
      'readFileMetadata',
      'writeTempToSaf',
    ]);
    expect(await File(tempPath).exists(), isFalse);
  });

  test('removal refuses to save when the gain tags remain', () async {
    applyEdits = false;
    expect(
      await ReplayGainService.removeFromFile('content://music/document/42'),
      isFalse,
    );
    expect(calls, ['safCopyToTemp', 'editFileMetadata', 'readFileMetadata']);
    expect(await File(tempPath).exists(), isFalse);
  });

  test('removal does not treat a fallback instruction as success', () async {
    method = 'ffmpeg';
    expect(
      await ReplayGainService.removeFromFile('content://music/document/42'),
      isFalse,
    );
    expect(calls, ['safCopyToTemp', 'editFileMetadata']);
    expect(await File(tempPath).exists(), isFalse);
  });

  test(
    'removal reports SAF save failure and cleans its temporary copy',
    () async {
      saveSaf = false;
      expect(
        await ReplayGainService.removeFromFile('content://music/document/42'),
        isFalse,
      );
      expect(calls.last, 'writeTempToSaf');
      expect(await File(tempPath).exists(), isFalse);
    },
  );

  test('removal rejects an empty metadata response', () async {
    metadata = {};
    expect(
      await ReplayGainService.removeFromFile('content://music/document/42'),
      isFalse,
    );
    expect(calls, ['safCopyToTemp', 'editFileMetadata', 'readFileMetadata']);
  });

  test('removal is idempotent for an untagged local file', () async {
    method = 'native';
    metadata = {'audio_codec': 'flac'};
    expect(
      await ReplayGainService.removeFromFile('${directory.path}/song.flac'),
      isTrue,
    );
    expect(calls, ['editFileMetadata', 'readFileMetadata']);
  });
}
