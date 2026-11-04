import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/services/download_file_recovery.dart';
import 'package:mornye/services/history_database.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// History rows in memory. Any method not listed here, such as deleting
/// entries, fails the test.
class _History extends Fake implements HistoryDatabase {
  _History(Iterable<DownloadHistoryItem> items)
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
  Future<Map<String, dynamic>?> findByFilePath(String path) async =>
      rows.values.where((item) => item.filePath == path).firstOrNull?.toJson();

  @override
  Future<bool> updateFilePath(
    String id,
    String newFilePath, {
    String? newStorageMode,
    String? newDownloadTreeUri,
    String? newSafFileName,
    String? newSafRelativeDir,
    String? newQuality,
    int? newBitDepth,
    int? newSampleRate,
    int? newBitrate,
    String? newFormat,
    bool clearAudioSpecs = false,
    String? expectedFilePath,
    String? expectedDownloadedAt,
  }) async {
    final item = rows[id];
    if (item == null ||
        (expectedFilePath != null && item.filePath != expectedFilePath)) {
      return false;
    }
    rows[id] = item.copyWith(filePath: newFilePath);
    return true;
  }
}

class _Notifier extends DownloadHistoryNotifier {
  _Notifier(this.history) : super(database: history);

  final _History history;

  @override
  DownloadHistoryState build() => DownloadHistoryState(
    items: history.rows.values.toList(),
    totalCount: history.rows.length,
  );
}

/// [DownloadFileRecovery] follows only `/` paths and Android SAF folders, so
/// a file moved between drive-letter folders is not recovered on Windows.
final String? _movedFilesSkip = Platform.isWindows
    ? 'Moved files are only recovered on / paths and SAF folders'
    : null;

DownloadHistoryItem _download(String id, String path) => DownloadHistoryItem(
  id: id,
  trackName: 'Song $id',
  artistName: 'Artist',
  albumName: 'Album',
  filePath: path,
  service: 'example',
  downloadedAt: DateTime.utc(2026, 1, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String oldFolder;
  late String newFolder;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('moved_downloads_');
    oldFolder = p.join(root.path, 'old');
    newFolder = p.join(root.path, 'new');
    await Directory(oldFolder).create();
    await Directory(newFolder).create();
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(
        AppSettings(downloadDirectory: newFolder).toJson(),
      ),
      DownloadFileRecovery.previousDirectoriesKey: [oldFolder],
    });
  });
  tearDown(() => root.delete(recursive: true));

  Future<File> file(String path) async {
    final created = File(path);
    await created.parent.create(recursive: true);
    return created.writeAsString('audio');
  }

  Future<({int relinked, int missing})> run(_History history) async {
    final container = ProviderContainer(
      overrides: [
        downloadHistoryProvider.overrideWith(() => _Notifier(history)),
      ],
    );
    addTearDown(container.dispose);
    return container
        .read(downloadHistoryProvider.notifier)
        .findMovedDownloads();
  }

  test('relinks moved downloads and only counts the missing ones', () async {
    final movedOld = p.join(oldFolder, 'Artist', 'Album', '01 - Song.flac');
    final movedNew = p.join(newFolder, 'Artist', 'Album', '01 - Song.flac');
    final present = p.join(newFolder, 'Artist', 'Album', '02 - Kept.flac');
    final gone = p.join(oldFolder, 'Artist', 'Album', '03 - Gone.flac');
    final elsewhere = p.join(oldFolder, 'Other', '04 - Elsewhere.flac');
    await file(movedNew);
    await file(present);
    // Same file name in another folder of the new download folder: not a
    // match, as the subfolders differ.
    await file(p.join(newFolder, 'Somewhere', '04 - Elsewhere.flac'));

    final history = _History([
      _download('moved', movedOld),
      _download('present', present),
      _download('gone', gone),
      _download('elsewhere', elsewhere),
    ]);
    final result = await run(history);

    expect(result.relinked, 1);
    expect(result.missing, 2);
    expect(history.rows['moved']!.filePath, movedNew);
    expect(history.rows['present']!.filePath, present);
    // Nothing is removed from History.
    expect(history.rows.keys, {'moved', 'present', 'gone', 'elsewhere'});
    expect(history.rows['gone']!.filePath, gone);
    expect(history.rows['elsewhere']!.filePath, elsewhere);
  }, skip: _movedFilesSkip);

  test('relinks a download converted next to its old file', () async {
    final original = p.join(newFolder, 'Artist', 'Album', '01 - Song.flac');
    final converted = p.join(newFolder, 'Artist', 'Album', '01 - Song.opus');
    await file(converted);

    final history = _History([_download('converted', original)]);
    final result = await run(history);

    expect(result, (relinked: 1, missing: 0));
    expect(history.rows['converted']!.filePath, converted);
  });

  test('reports nothing when every download is in place', () async {
    final present = p.join(newFolder, 'Song.flac');
    await file(present);

    final history = _History([_download('present', present)]);
    expect(await run(history), (relinked: 0, missing: 0));
    expect(history.rows['present']!.filePath, present);
  });
}
