import 'dart:io';
import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/services/backup_service.dart';

class _UnreadableArchiveFile extends ArchiveFile {
  _UnreadableArchiveFile(this.failure) : super('history.ndjson', 0, <int>[]);

  final FormatException failure;

  @override
  void writeContent(OutputStream output, {bool freeMemory = true}) {
    output.writeBytes([1, 2, 3]);
    throw failure;
  }
}

void main() {
  test('archive output closes when reading its payload throws', () async {
    final root = await Directory.systemTemp.createTemp('unreadable-backup-');
    addTearDown(() => root.delete(recursive: true));
    final path = p.join(root.path, 'history.ndjson');
    final output = OutputFileStream(path);
    const failure = FormatException('Invalid compressed archive payload');

    expect(
      () => BackupService.writeArchiveEntry(
        _UnreadableArchiveFile(failure),
        output,
      ),
      throwsA(same(failure)),
    );

    expect(output.isOpen, isFalse);
    expect(await File(path).readAsBytes(), [1, 2, 3]);
  });

  test(
    'ZIP backup pages history and streams cover files during restore',
    () async {
      final root = await Directory.systemTemp.createTemp('mornye-backup-test-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final output = await Directory(p.join(root.path, 'output')).create();
      final temporary = await Directory(
        p.join(root.path, 'temporary'),
      ).create();
      final cover = File(p.join(root.path, 'cover.jpg'));
      await cover.writeAsBytes([0xff, 0xd8, 0xff, 0xd9]);
      final history = List.generate(
        1203,
        (index) => <String, dynamic>{'id': 'item-$index', 'value': index},
      );
      final offsets = <int>[];

      final file = await BackupService.writeBackupArchive(
        settings: const {'theme': 'dark'},
        loadHistoryPage: (limit, offset) async {
          offsets.add(offset);
          if (offset >= history.length) {
            return const <Map<String, dynamic>>[];
          }
          final end = (offset + limit).clamp(0, history.length);
          return history.sublist(offset, end);
        },
        collections: const {
          'loved': <dynamic>[],
          'wishlist': <dynamic>[],
          'playlists': <dynamic>[],
        },
        playlistCoverFiles: {
          'playlist-1': {'ext': '.jpg', 'path': cover.path},
        },
        extensions: const {'items': <dynamic>[]},
        outputDirectory: output,
        temporaryDirectory: temporary,
      );

      expect(file.path, endsWith('.${BackupService.fileExtension}'));
      expect(offsets, [0, 500, 1000]);
      final bundle = await BackupService.parseFile(
        file.path,
        temporaryDirectory: temporary,
      );
      expect(bundle, isNotNull);
      expect(bundle!.formatVersion, 3);
      expect(bundle.historyCount, history.length);
      final restoredHistory = await bundle.streamHistory().toList();
      expect(restoredHistory, hasLength(history.length));
      expect(restoredHistory.last['id'], 'item-1202');
      final restoredCover = bundle.playlistCovers['playlist-1'];
      expect(restoredCover, isA<Map<String, dynamic>>());
      final restoredCoverPath =
          (restoredCover as Map<String, dynamic>)['path'] as String;
      expect(await File(restoredCoverPath).readAsBytes(), [
        0xff,
        0xd8,
        0xff,
        0xd9,
      ]);

      await bundle.cleanup();
      expect(await File(restoredCoverPath).exists(), isFalse);
    },
  );

  test('selective backups round trip every category combination', () async {
    final root = await Directory.systemTemp.createTemp('selective-backup-');
    addTearDown(() => root.delete(recursive: true));
    for (var mask = 1; mask < 16; mask++) {
      final settings = mask & 1 != 0;
      final history = mask & 2 != 0;
      final collections = mask & 4 != 0;
      final extensions = mask & 8 != 0;
      var historyReads = 0;
      final file = await BackupService.writeBackupArchive(
        settings: settings ? {'theme': 'dark'} : null,
        includeHistory: history,
        loadHistoryPage: (_, _) async {
          historyReads++;
          return [
            {'id': 'download-1'},
          ];
        },
        collections: collections
            ? {
                'loved': ['track-1'],
              }
            : {},
        playlistCoverFiles: {},
        extensions: extensions
            ? {
                'items': [
                  {'id': 'example-extension'},
                ],
              }
            : {},
        outputDirectory: root,
        temporaryDirectory: root,
      );
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      final metadata =
          jsonDecode(utf8.decode(archive.find('metadata.json')!.content))
              as Map<String, dynamic>;
      final data = metadata['data'] as Map<String, dynamic>;
      expect(data.containsKey('settings'), settings);
      expect(data.containsKey('collections'), collections);
      expect(data.containsKey('extensions'), extensions);
      expect(archive.find('history.ndjson') != null, history);
      expect(historyReads, history ? 1 : 0);
      final bundle = (await BackupService.parseFile(
        file.path,
        temporaryDirectory: root,
      ))!;
      expect(bundle.hasSettings, settings);
      expect(bundle.profile, isNull);
      expect(bundle.hasHistory, history);
      expect(bundle.hasCollections, collections);
      expect(bundle.hasExtensions, extensions);
      expect(
        await bundle.streamHistory().toList(),
        history
            ? [
                {'id': 'download-1'},
              ]
            : isEmpty,
      );
      await bundle.cleanup();
    }
  });

  test(
    'version 2 archives and legacy JSON retain history restore semantics',
    () async {
      final root = await Directory.systemTemp.createTemp('legacy-backup-');
      addTearDown(() => root.delete(recursive: true));
      final envelope = <String, dynamic>{
        'magic': 'mornye-backup',
        'format_version': 1,
        'data': {
          'settings': {'theme': 'light'},
          'history': <Object?>[],
        },
      };
      expect(BackupService.parse(jsonEncode(envelope))!.hasHistory, isTrue);
      envelope['magic'] = 'spotiflac-backup';
      expect(BackupService.parse(jsonEncode(envelope))!.hasHistory, isTrue);
      envelope['format_version'] = 2;
      final metadata = utf8.encode(jsonEncode(envelope));
      final archive = Archive()
        ..addFile(ArchiveFile('metadata.json', metadata.length, metadata))
        ..addFile(ArchiveFile('history.ndjson', 0, <int>[]));
      final file = File(p.join(root.path, 'old.sflb'));
      await file.writeAsBytes(ZipEncoder().encode(archive));
      final bundle = (await BackupService.parseFile(
        file.path,
        temporaryDirectory: root,
      ))!;
      expect(bundle.formatVersion, 2);
      expect(bundle.hasHistory, isTrue);
      expect(bundle.hasSettings, isTrue);
      expect(bundle.profile, isNull);
      await bundle.cleanup();
    },
  );

  test('profile archive rejects foreign paths and missing photos', () async {
    final root = await Directory.systemTemp.createTemp('profile-backup-');
    addTearDown(() => root.delete(recursive: true));
    for (final photo in ['../avatar.png', 'profile/avatar.png']) {
      final metadata = utf8.encode(
        jsonEncode({
          'magic': BackupService.magic,
          'format_version': BackupService.formatVersion,
          'data': {
            'profile': {'name': 'Listener', 'photo': photo},
          },
        }),
      );
      final archive = Archive()
        ..addFile(ArchiveFile('metadata.json', metadata.length, metadata));
      final file = File(p.join(root.path, 'invalid.sflb'));
      await file.writeAsBytes(ZipEncoder().encode(archive));
      expect(
        await BackupService.parseFile(file.path, temporaryDirectory: root),
        isNull,
      );
      expect(
        await root.list().where((entry) => entry is Directory).isEmpty,
        isTrue,
      );
    }
  });
}
