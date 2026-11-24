import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/utils/file_access.dart';

class _HistoryNotifier extends DownloadHistoryNotifier {
  _HistoryNotifier(HistoryDatabase database, this._items)
    : super(database: database);

  final List<DownloadHistoryItem> _items;

  @override
  DownloadHistoryState build() =>
      DownloadHistoryState(items: _items, totalCount: _items.length);
}

class _HistoryRows implements HistoryDatabase {
  _HistoryRows(Iterable<DownloadHistoryItem> items)
    : rows = {for (final item in items) item.id: item};

  final Map<String, DownloadHistoryItem> rows;

  @override
  Future<List<Map<String, dynamic>>> getEntriesWithPathsPage({
    required int limit,
    int offset = 0,
  }) async => [
    for (final item in rows.values.skip(offset).take(limit))
      {
        'id': item.id,
        'file_path': item.filePath,
        'storage_mode': item.storageMode,
        'download_tree_uri': item.downloadTreeUri,
        'saf_relative_dir': item.safRelativeDir,
        'saf_file_name': item.safFileName,
        'downloaded_at': item.downloadedAt.toUtc().toIso8601String(),
      },
  ];

  @override
  Future<Map<String, dynamic>?> getById(String id) async => rows[id]?.toJson();

  @override
  Future<List<String>> deleteInspectedEntries(
    List<Map<String, dynamic>> entries,
  ) async => [
    for (final entry in entries)
      if (rows.remove(entry['id']) != null) entry['id'] as String,
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadHistoryItem _download(String id, String path) => DownloadHistoryItem(
  id: id,
  trackName: 'Song $id',
  artistName: 'Artist',
  albumName: 'Album',
  filePath: path,
  service: 'test',
  downloadedAt: DateTime.utc(2026),
);

/// A path on a drive that is not plugged in: nothing of it exists below the
/// filesystem root.
String _unpluggedPath(String name) => p.join(
  p.rootPrefix(Directory.systemTemp.path),
  'mornye-unplugged-$pid',
  'Album',
  name,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('mount containers', () {
    test('posix folders that hold drives, cards and shares', () {
      for (final path in [
        '/',
        '/Volumes',
        '/media',
        '/media/user',
        '/run/media/user',
        '/mnt',
        '/mnt/nas',
        '/storage',
        '/storage/emulated',
      ]) {
        expect(isStorageMountContainer(path, context: p.posix), isTrue);
      }
      for (final path in [
        '/Users/me/Music',
        '/Volumes/Drive',
        '/media/user/Drive',
        '/run/media/user/Drive',
        '/mnt/nas/Music',
        '/storage/emulated/0',
        '/storage/1234-ABCD',
        '/home/me',
      ]) {
        expect(isStorageMountContainer(path, context: p.posix), isFalse);
      }
    });

    test('windows drive and share roots', () {
      for (final path in [r'C:\', r'E:\', r'\\server\share']) {
        expect(isStorageMountContainer(path, context: p.windows), isTrue);
      }
      for (final path in [r'C:\Users', r'E:\Music', r'\\server\share\Music']) {
        expect(isStorageMountContainer(path, context: p.windows), isFalse);
      }
    });
  });

  group('stored file state', () {
    late Directory root;
    late Directory album;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('stored_file_state_');
      album = await Directory(
        p.join(root.path, 'Artist', 'Album'),
      ).create(recursive: true);
    });

    tearDown(() => root.delete(recursive: true));

    test('a file that is there, and a CUE track of it, are present', () async {
      final file = await File(p.join(album.path, '01.flac')).writeAsString('');
      expect(await storedFileState(file.path), isTrue);
      expect(await storedFileState('${file.path}#track01'), isTrue);
    });

    test('a file gone from its folder or with its folder is absent', () async {
      expect(await storedFileState(p.join(album.path, '02.flac')), isFalse);
      final goneAlbum = p.join(root.path, 'Artist', 'Gone', '01.flac');
      expect(await storedFileState(goneAlbum), isFalse);
      expect((await fileExistenceByPath([goneAlbum]))[goneAlbum], isFalse);
    });

    test('a file on storage that is not there cannot be told', () async {
      final unplugged = _unpluggedPath('01.flac');
      expect(await storedFileState(unplugged), isNull);
      expect((await fileExistenceByPath([unplugged]))[unplugged], isNull);
      expect(await storedFileState('network://share/Song.flac'), isNull);
      expect(await storedFileState(''), isNull);
    });
  });

  test(
    'orphan cleanup removes deleted downloads and keeps those on missing storage',
    () async {
      final root = await Directory.systemTemp.createTemp('orphan_storage_');
      addTearDown(() => root.delete(recursive: true));
      final album = await Directory(
        p.join(root.path, 'Artist', 'Album'),
      ).create(recursive: true);
      final kept = await File(
        p.join(album.path, '01 Kept.flac'),
      ).writeAsString('');
      final db = _HistoryRows([
        _download('kept', kept.path),
        _download('deleted', p.join(album.path, '02 Deleted.flac')),
        _download(
          'folder',
          p.join(root.path, 'Artist', 'Removed Album', '01.flac'),
        ),
        _download('unplugged', _unpluggedPath('01 Song.flac')),
      ]);
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(
            () => _HistoryNotifier(db, db.rows.values.toList()),
          ),
        ],
      );
      addTearDown(container.dispose);

      final removed = await container
          .read(downloadHistoryProvider.notifier)
          .cleanupOrphanedDownloads();

      expect(removed, 2);
      expect(db.rows.keys, unorderedEquals(['kept', 'unplugged']));
      expect(
        container.read(downloadHistoryProvider).items.map((item) => item.id),
        unorderedEquals(['kept', 'unplugged']),
      );
    },
  );
}
