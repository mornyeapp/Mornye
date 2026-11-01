import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/services/metadata_persistence_service.dart';
import 'package:mornye/utils/artist_utils.dart';

class _Covers extends MetadataCoverResources {
  bool failResize = false;
  bool extractCover = false;
  MetadataCoverPreview? resized;
  MetadataCoverPreview? extracted;

  Future<MetadataCoverPreview> create() =>
      copyPicked(extension: 'png', bytes: Uint8List.fromList([1, 2, 3]));

  @override
  Future<MetadataCoverPreview> resize(String source, int maxDimension) async {
    expect(await File(source).exists(), isTrue);
    expect(maxDimension, 500);
    if (failResize) throw StateError('Resize failed');
    return resized = await create();
  }

  @override
  Future<MetadataCoverPreview?> extract(String filePath) async =>
      extractCover ? extracted = await create() : null;
}

void main() {
  late _Covers covers;
  setUp(() => covers = _Covers());
  tearDown(() => covers.dispose());

  MetadataSaveRequest request({
    String path = 'song.mp3',
    Map<String, String> tags = const {},
    String? selectedCover,
    String? currentCover,
    int? dimension,
  }) => MetadataSaveRequest(
    filePath: path,
    metadata: tags,
    artistTagMode: artistTagModeSplitVorbis,
    selectedCoverPath: selectedCover,
    currentCoverPath: currentCover,
    coverMaxDimension: dimension,
  );

  test(
    'native writer keeps a snapshot and artwork alive after editor closes',
    () async {
      final cover = await covers.create();
      final entered = Completer<void>();
      final completed = Completer<Map<String, dynamic>>();
      final tags = {'title': 'Song', 'lyrics': ''};
      final input = request(tags: tags, selectedCover: cover.path);
      tags['title'] = 'Changed';
      final service = MetadataPersistenceService(
        covers: covers,
        edit: (path, metadata) async {
          expect(path, 'song.mp3');
          expect(metadata, {
            'title': 'Song',
            'lyrics': '',
            'artist_tag_mode': artistTagModeSplitVorbis,
            'cover_path': cover.path,
          });
          entered.complete();
          return completed.future;
        },
        read: (_) async => throw StateError('Native edit needs no fallback'),
      );
      final pending = service.save(input);
      await entered.future;
      await covers.dispose();
      expect(await File(cover.path).exists(), isTrue);
      completed.complete({'success': true, 'method': 'native'});
      expect((await pending).failure, isNull);
      expect(await Directory(cover.tempDir).exists(), isFalse);
    },
  );

  for (final extension in ['mp3', 'm4a', 'aac', 'opus', 'OGG']) {
    test(
      'lyrics-only fallback retains unspecified tags for $extension',
      () async {
        final service = MetadataPersistenceService(
          covers: covers,
          edit: (_, metadata) async {
            expect(metadata['lyrics'], '[00:01.00]Found');
            expect(metadata.containsKey('title'), isFalse);
            expect(metadata.containsKey('artist'), isFalse);
            return {'method': 'ffmpeg'};
          },
          read: (_) async => const {},
          embed: (codec, path, cover, tags, artistMode) async {
            expect(tags, {
              'LYRICS': '[00:01.00]Found',
              'UNSYNCEDLYRICS': '[00:01.00]Found',
            });
            return path;
          },
        );
        final saved = await service.save(
          MetadataSaveRequest(
            filePath: 'song.$extension',
            metadata: const {'lyrics': '[00:01.00]Found'},
            artistTagMode: artistTagModeJoined,
            preserveUnspecifiedTags: true,
          ),
        );
        expect(saved.failure, isNull);
      },
    );

    test(
      'fallback preserves edited/empty tags and artist mode for $extension',
      () async {
        final cover = await covers.create();
        final isOpus = extension == 'opus' || extension == 'OGG';
        final service = MetadataPersistenceService(
          covers: covers,
          edit: (_, metadata) async {
            expect(metadata['cover_path'], '');
            return {'method': 'ffmpeg'};
          },
          read: (path) async {
            expect(path, 'song.$extension');
            return {
              'replaygain_track_gain': '-6.20 dB',
              'replaygain_track_peak': '0.000000',
              'replaygain_album_gain': '0.00 dB',
              'replaygain_album_peak': '1.234567',
            };
          },
          embed: (codec, path, coverPath, metadata, mode) async {
            expect(
              codec,
              isOpus
                  ? MetadataSaveCodec.opus
                  : extension == 'mp3'
                  ? MetadataSaveCodec.mp3
                  : MetadataSaveCodec.m4a,
            );
            expect(
              mode,
              isOpus ? artistTagModeSplitVorbis : artistTagModeJoined,
            );
            expect(coverPath, cover.path);
            expect(metadata['ARTIST'], 'Artist One; Artist Two');
            expect(metadata['LYRICS'], 'Existing lyrics');
            expect(metadata['UNSYNCEDLYRICS'], 'Existing lyrics');
            expect(metadata['TITLE'], '');
            expect(metadata['ALBUMARTIST'], '');
            expect(metadata['TRACKNUMBER'], '3/12');
            expect(metadata['DISCNUMBER'], '');
            expect(metadata['REPLAYGAIN_TRACK_GAIN'], '-6.20 dB');
            expect(metadata['REPLAYGAIN_TRACK_PEAK'], '0.000000');
            expect(metadata['REPLAYGAIN_ALBUM_GAIN'], '0.00 dB');
            expect(metadata['REPLAYGAIN_ALBUM_PEAK'], '1.234567');
            return path;
          },
          writeBack: (_, _) async =>
              throw StateError('Local edit needs no SAF write'),
        );
        expect(
          (await service.save(
            request(
              path: 'song.$extension',
              currentCover: cover.path,
              tags: {
                'artist': 'Artist One; Artist Two',
                'lyrics': 'Existing lyrics',
                'track_number': '3',
                'track_total': '12',
                'disc_number': '0',
                'disc_total': '2',
              },
            ),
          )).failure,
          isNull,
        );
        expect(await File(cover.path).exists(), isTrue);
      },
    );
  }

  test(
    'fallback clears lyrics and handles missing/zero track and disc totals',
    () async {
      for (final pair in [
        ('', '12', ''),
        ('0', '12', ''),
        ('3', '', '3'),
        ('3', '0', '3'),
      ]) {
        final service = MetadataPersistenceService(
          covers: covers,
          edit: (_, _) async => {'method': 'ffmpeg'},
          read: (_) async => throw StateError('Reader unavailable'),
          embed: (_, path, _, metadata, _) async {
            expect(metadata['LYRICS'], '');
            expect(metadata['UNSYNCEDLYRICS'], '');
            expect(metadata['TRACKNUMBER'], pair.$3);
            expect(metadata['DISCNUMBER'], pair.$3);
            expect(metadata.keys, isNot(contains('REPLAYGAIN_TRACK_GAIN')));
            return path;
          },
        );
        expect(
          (await service.save(
            request(
              tags: {
                'track_number': pair.$1,
                'track_total': pair.$2,
                'disc_number': pair.$1,
                'disc_total': pair.$2,
              },
            ),
          )).failure,
          isNull,
        );
      }
    },
  );

  test(
    'resized artwork replaces the cover and is released after saving',
    () async {
      final original = await covers.create();
      final service = MetadataPersistenceService(
        covers: covers,
        edit: (_, metadata) async {
          expect(metadata['cover_path'], covers.resized!.path);
          expect(await File(covers.resized!.path).exists(), isTrue);
          return {'method': 'native'};
        },
      );
      expect(
        (await service.save(
          request(currentCover: original.path, dimension: 500),
        )).failure,
        isNull,
      );
      expect(await File(original.path).exists(), isTrue);
      expect(await Directory(covers.resized!.tempDir).exists(), isFalse);
    },
  );

  test(
    'missing artwork and resize failures return typed failures before editing',
    () async {
      final service = MetadataPersistenceService(
        covers: covers,
        edit: (_, _) async => throw StateError('Must not edit'),
      );
      expect(
        (await service.save(request(dimension: 500))).failure,
        MetadataSaveFailure.noCover,
      );
      covers.failResize = true;
      final original = await covers.create();
      expect(
        (await service.save(
          request(selectedCover: original.path, dimension: 500),
        )).failure,
        MetadataSaveFailure.resize,
      );
      expect(await File(original.path).exists(), isTrue);
    },
  );

  for (final failure in [
    null,
    MetadataSaveFailure.ffmpeg,
    MetadataSaveFailure.storage,
    MetadataSaveFailure.unexpected,
    MetadataSaveFailure.backend,
  ]) {
    test(
      'SAF staged file and extracted artwork are cleaned on $failure',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'metadata-save-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final staged = await File(
          '${directory.path}/staged.mp3',
        ).writeAsBytes([1, 2, 3]);
        var writes = 0;
        covers.extractCover = true;
        final service = MetadataPersistenceService(
          covers: covers,
          edit: (_, _) async => {
            'method': 'ffmpeg',
            'temp_path': staged.path,
            'saf_uri': 'content://library/song.mp3',
            if (failure == MetadataSaveFailure.backend)
              'error': 'Backend failed',
          },
          read: (_) async => {},
          embed: (_, path, coverPath, _, _) async {
            expect(path, staged.path);
            expect(coverPath, covers.extracted!.path);
            if (failure == MetadataSaveFailure.unexpected) {
              throw StateError('Writer failed');
            }
            return failure == MetadataSaveFailure.ffmpeg ? null : path;
          },
          writeBack: (path, uri) async {
            writes++;
            expect(path, staged.path);
            expect(uri, 'content://library/song.mp3');
            expect(await staged.exists(), isTrue);
            return failure != MetadataSaveFailure.storage;
          },
        );
        final result = await service.save(
          request(path: 'content://library/song.mp3'),
        );
        expect(result.failure, failure);
        expect(
          writes,
          failure == null || failure == MetadataSaveFailure.storage ? 1 : 0,
        );
        expect(await staged.exists(), isFalse);
        if (covers.extracted case final cover?) {
          expect(await Directory(cover.tempDir).exists(), isFalse);
        }
      },
    );
  }
}
