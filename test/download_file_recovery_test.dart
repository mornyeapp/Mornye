import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/download_file_recovery.dart';
import 'package:mornye/services/history_database.dart';

const oldTree = 'content://example/tree/xxx';
const newTree = 'content://example/tree/yyy';
const oldUri = '$oldTree/document/old-song';
const newUri = '$newTree/document/new-song';
const destination = AppSettings(storageMode: 'saf', downloadTreeUri: newTree);

class _History extends Fake implements HistoryDatabase {
  _History(String path, {bool saf = true})
    : item = DownloadHistoryItem(
        id: 'download',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: path,
        service: 'example',
        downloadedAt: DateTime.utc(2026),
        storageMode: saf ? 'saf' : 'app',
        downloadTreeUri: saf ? oldTree : null,
        safRelativeDir: saf ? 'Artist/Album' : null,
        safFileName: saf ? 'Song.flac' : null,
        hasReplayGain: true,
        hasLyrics: true,
      ).toJson();
  Map<String, dynamic>? item;
  int writes = 0;
  bool rejectWrite = false;

  @override
  Future<Map<String, dynamic>?> getById(String id) async =>
      id == item?['id'] ? Map.of(item!) : null;
  @override
  Future<Map<String, dynamic>?> findByFilePath(String path) async =>
      item?['filePath'] == path ? Map.of(item!) : null;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName != #updateFilePath) {
      return super.noSuchMethod(invocation);
    }
    final args = invocation.namedArguments;
    if (rejectWrite ||
        item == null ||
        args[#expectedFilePath] != item!['filePath'] ||
        args[#expectedDownloadedAt] != item!['downloadedAt']) {
      return Future.value(false);
    }
    writes++;
    item = {
      ...item!,
      'filePath': invocation.positionalArguments[1],
      'storageMode': args[#newStorageMode],
      'downloadTreeUri': args[#newDownloadTreeUri],
      'safRelativeDir': args[#newSafRelativeDir],
      'safFileName': args[#newSafFileName],
    };
    return Future.value(true);
  }
}

Map<String, dynamic> found({String directory = 'Artist/Album'}) => {
  'key': 'download',
  'status': 'found',
  'uri': newUri,
  'relative_dir': directory,
  'file_name': 'Song.flac',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  test(
    'changing folder alone keeps the old file; moving it repairs its URI and tree',
    () async {
      final history = _History(oldUri);
      final files = {oldUri};
      var inspections = 0;
      var notifications = 0;
      addTearDown(DownloadFileRecovery.subscribe(() => notifications++));
      final recovery = DownloadFileRecovery(
        history: history,
        preferences: () async => preferences,
        exists: (path) async => files.contains(path),
        inspect: (requests) async {
          inspections++;
          expect(requests.single, {
            'key': 'download',
            'tree_uri': newTree,
            'relative_dir': 'Artist/Album',
            'current_uri': '',
            'file_names': ['Song.flac'],
            'exact_relative_dir': true,
          });
          return [found()];
        },
      );
      expect(await recovery.recover(oldUri, settings: destination), isNull);
      expect(inspections, 0);
      files
        ..remove(oldUri)
        ..add(newUri);
      expect(await recovery.recover(oldUri, settings: destination), newUri);
      expect(history.item!['filePath'], newUri);
      expect(history.item!['downloadTreeUri'], newTree);
      expect(history.item!['hasReplayGain'], true);
      expect(history.item!['hasLyrics'], true);
      expect(history.item!['trackName'], 'Song');
      expect(history.writes, 1);
      expect(notifications, 1);
      // A second old queue or a saved session uses the repaired history ID.
      expect(
        await recovery.recover(
          oldUri,
          historyId: 'download',
          settings: destination,
        ),
        newUri,
      );
      expect(inspections, 1);
    },
  );

  test(
    'real files moved between app folders retain their relative album path',
    () async {
      final root = await Directory.systemTemp.createTemp('moved-download-');
      addTearDown(() => root.delete(recursive: true));
      final xxx = await Directory(
        '${root.path}/xxx/Artist/Album',
      ).create(recursive: true);
      final yyy = await Directory(
        '${root.path}/yyy/Artist/Album',
      ).create(recursive: true);
      final original = await File(
        '${xxx.path}/Song.flac',
      ).writeAsString('audio bytes');
      final history = _History(original.path, saf: false);
      await DownloadFileRecovery.rememberDirectories(preferences, [
        '${root.path}/xxx',
      ]);
      final moved = await original.rename('${yyy.path}/Song.flac');
      final recovery = DownloadFileRecovery(
        history: history,
        preferences: () async => preferences,
      );
      expect(
        await recovery.recover(
          original.path,
          settings: AppSettings(
            storageMode: 'app',
            downloadDirectory: '${root.path}/yyy',
          ),
        ),
        moved.path,
      );
      expect(await moved.readAsString(), 'audio bytes');
      expect(history.item!['filePath'], moved.path);
    },
  );

  test('same filename in another album is never accepted', () async {
    final history = _History(oldUri);
    final recovery = DownloadFileRecovery(
      history: history,
      preferences: () async => preferences,
      exists: (path) async => path == newUri,
      inspect: (_) async => [found(directory: 'Other album')],
    );
    expect(await recovery.recover(oldUri, settings: destination), isNull);
    expect(history.writes, 0);
  });

  test(
    'a missing candidate can be found on a later play after the user moves it',
    () async {
      final history = _History(oldUri);
      var moved = false;
      final recovery = DownloadFileRecovery(
        history: history,
        preferences: () async => preferences,
        exists: (path) async => moved && path == newUri,
        inspect: (_) async => [
          moved ? found() : {'key': 'download', 'status': 'missing'},
        ],
      );
      expect(await recovery.recover(oldUri, settings: destination), isNull);
      moved = true;
      expect(await recovery.recover(oldUri, settings: destination), newUri);
    },
  );

  test(
    'unavailable destination is inconclusive and never rewrites history',
    () async {
      final history = _History(oldUri);
      final recovery = DownloadFileRecovery(
        history: history,
        preferences: () async => preferences,
        exists: (_) async => false,
        inspect: (_) async => [
          {'key': 'download', 'status': 'unknown'},
        ],
      );
      await expectLater(
        recovery.recover(oldUri, settings: destination),
        throwsStateError,
      );
      expect(history.item!['filePath'], oldUri);
      expect(history.writes, 0);
    },
  );

  test(
    'a concurrent deletion cannot resurrect a download during recovery',
    () async {
      final history = _History(oldUri);
      final recovery = DownloadFileRecovery(
        history: history,
        preferences: () async => preferences,
        exists: (path) async => path == newUri,
        inspect: (_) async {
          history.item = null;
          return [found()];
        },
      );
      await expectLater(
        recovery.recover(oldUri, settings: destination),
        throwsStateError,
      );
      expect(history.item, isNull);
      expect(history.writes, 0);
    },
  );

  test('concurrent checks share a single provider lookup', () async {
    final history = _History(oldUri);
    final gate = Completer<List<Map<String, dynamic>>>();
    var inspections = 0;
    final recovery = DownloadFileRecovery(
      history: history,
      preferences: () async => preferences,
      exists: (path) async => path == newUri,
      inspect: (_) {
        inspections++;
        return gate.future;
      },
    );
    final first = recovery.recover(oldUri, settings: destination);
    final second = recovery.recover(oldUri, settings: destination);
    gate.complete([found()]);
    expect(await Future.wait([first, second]), [newUri, newUri]);
    expect(inspections, 1);
    expect(history.writes, 1);
  });
}
