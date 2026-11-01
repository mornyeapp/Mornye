import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/services/library_reorganizer.dart';

LibraryReorganizationMove _move(
  String root, {
  required String sourceDir,
  required String sourceName,
  required String targetDir,
  required String targetName,
  List<String> ids = const ['h1'],
}) => LibraryReorganizationMove(
  historyIds: ids,
  trackName: sourceName,
  sourcePath: p.joinAll([
    root,
    ...sourceDir.split('/').where((s) => s.isNotEmpty),
    sourceName,
  ]),
  sourceRelativeDir: sourceDir,
  sourceFileName: sourceName,
  targetRelativeDir: targetDir,
  targetFileName: targetName,
);

void main() {
  late Directory root;
  late Map<String, String> recorded;
  late Map<String, String> relinked;
  late bool libraryHasRow;
  late bool historyAcceptsUpdates;

  LibraryReorganizer reorganizer() => LibraryReorganizer(
    updateHistoryPath:
        (
          id,
          newFilePath, {
          newSafFileName,
          newSafRelativeDir,
          required expectedFilePath,
        }) async {
          if (!historyAcceptsUpdates) return false;
          recorded[id] = newFilePath;
          return true;
        },
    relinkLibraryPath: (oldPath, newPath) async {
      if (!libraryHasRow) return false;
      relinked[oldPath] = newPath;
      return true;
    },
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-reorganizer-');
    recorded = {};
    relinked = {};
    libraryHasRow = true;
    historyAcceptsUpdates = true;
  });
  tearDown(() => root.delete(recursive: true));

  Future<File> write(String relative, [String content = 'audio']) async {
    final file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    return file.writeAsString(content);
  }

  test('moves the track and its lyrics, updates every history row and prunes '
      'emptied folders', () async {
    await write('Old/Nested/Song - Artist.flac');
    await write('Old/Nested/Song - Artist.lrc', '[00:01.00]hi');
    final move = _move(
      root.path,
      sourceDir: 'Old/Nested',
      sourceName: 'Song - Artist.flac',
      targetDir: 'Artist/Album',
      targetName: 'Artist - Song.flac',
      ids: ['h1', 'h2'],
    );

    final result = await reorganizer().run(
      LibraryReorganizationPlan(root: root.path, safMode: false, moves: [move]),
    );

    final target = p.join(root.path, 'Artist', 'Album', 'Artist - Song.flac');
    expect(result.moved, 1);
    expect(result.failed, 0);
    expect(await File(target).readAsString(), 'audio');
    expect(
      await File(
        p.join(root.path, 'Artist', 'Album', 'Artist - Song.lrc'),
      ).readAsString(),
      '[00:01.00]hi',
    );
    expect(recorded, {'h1': target, 'h2': target});
    expect(relinked, {move.sourcePath: target});
    expect(await Directory(p.join(root.path, 'Old')).exists(), isFalse);
    expect(await root.exists(), isTrue);
  });

  test('keeps folders that still hold other files', () async {
    await write('Mixed/A.flac');
    await write('Mixed/cover.jpg');
    await reorganizer().run(
      LibraryReorganizationPlan(
        root: root.path,
        safMode: false,
        moves: [
          _move(
            root.path,
            sourceDir: 'Mixed',
            sourceName: 'A.flac',
            targetDir: 'Artist',
            targetName: 'A.flac',
          ),
        ],
      ),
    );
    expect(
      await File(p.join(root.path, 'Mixed', 'cover.jpg')).exists(),
      isTrue,
    );
  });

  test('never overwrites a file already at the target', () async {
    await write('B.flac', 'new');
    await write('Artist/B.flac', 'existing');
    await reorganizer().run(
      LibraryReorganizationPlan(
        root: root.path,
        safMode: false,
        moves: [
          _move(
            root.path,
            sourceDir: '',
            sourceName: 'B.flac',
            targetDir: 'Artist',
            targetName: 'B.flac',
          ),
        ],
      ),
    );
    expect(
      await File(p.join(root.path, 'Artist', 'B.flac')).readAsString(),
      'existing',
    );
    final numbered = p.join(root.path, 'Artist', 'B (2).flac');
    expect(await File(numbered).readAsString(), 'new');
    expect(recorded['h1'], numbered);
  });

  test('puts the file back when its history row changed meanwhile', () async {
    await write('C.flac');
    await write('C.lrc', 'lyrics');
    historyAcceptsUpdates = false;
    final result = await reorganizer().run(
      LibraryReorganizationPlan(
        root: root.path,
        safMode: false,
        moves: [
          _move(
            root.path,
            sourceDir: '',
            sourceName: 'C.flac',
            targetDir: 'Artist',
            targetName: 'C.flac',
          ),
        ],
      ),
    );
    expect(result.failed, 1);
    expect(await File(p.join(root.path, 'C.flac')).exists(), isTrue);
    expect(await File(p.join(root.path, 'C.lrc')).exists(), isTrue);
    expect(await Directory(p.join(root.path, 'Artist')).exists(), isFalse);
    expect(relinked, isEmpty);
  });

  test('reports missing files and honours cancellation', () async {
    await write('D.flac');
    var calls = 0;
    final result = await reorganizer().run(
      LibraryReorganizationPlan(
        root: root.path,
        safMode: false,
        moves: [
          _move(
            root.path,
            sourceDir: '',
            sourceName: 'Gone.flac',
            targetDir: 'X',
            targetName: 'Gone.flac',
          ),
          _move(
            root.path,
            sourceDir: '',
            sourceName: 'D.flac',
            targetDir: 'X',
            targetName: 'D.flac',
          ),
        ],
      ),
      isCancelled: () => calls++ > 0,
    );
    expect(result.missing, 1);
    expect(result.moved, 0);
    expect(result.cancelled, isTrue);
    expect(await File(p.join(root.path, 'D.flac')).exists(), isTrue);
  });

  test('planned targets never collide with each other or kept files', () {
    LibraryReorganizationMove planned(String source, String target) =>
        LibraryReorganizationMove(
          historyIds: [source],
          trackName: source,
          sourcePath: source,
          sourceRelativeDir: '',
          sourceFileName: source,
          targetRelativeDir: 'Artist',
          targetFileName: target,
        );
    final resolved = resolveLibraryReorganizationConflicts(
      [
        planned('1.flac', 'Song.flac'),
        planned('2.flac', 'song.flac'),
        planned('3.flac', 'Other.flac'),
      ],
      occupied: ['Artist/Other.flac'],
    );
    expect(resolved.map((m) => m.targetDisplayPath), [
      'Artist/Song.flac',
      'Artist/song (2).flac',
      'Artist/Other (2).flac',
    ]);
  });

  test(
    'a file known only from the library scan relinks its library row',
    () async {
      await write('Loose/Track.mp3');
      final move = _move(
        root.path,
        sourceDir: 'Loose',
        sourceName: 'Track.mp3',
        targetDir: 'Band/Record',
        targetName: '01 - Track.mp3',
        ids: const [],
      );
      final result = await reorganizer().run(
        LibraryReorganizationPlan(
          root: root.path,
          safMode: false,
          moves: [move],
        ),
      );
      final target = p.join(root.path, 'Band', 'Record', '01 - Track.mp3');
      expect(result.moved, 1);
      expect(await File(target).exists(), isTrue);
      expect(recorded, isEmpty);
      expect(relinked, {move.sourcePath: target});
    },
  );

  test('a scanned file is put back when its library row is gone', () async {
    await write('Loose/Gone.mp3');
    libraryHasRow = false;
    final result = await reorganizer().run(
      LibraryReorganizationPlan(
        root: root.path,
        safMode: false,
        moves: [
          _move(
            root.path,
            sourceDir: 'Loose',
            sourceName: 'Gone.mp3',
            targetDir: 'Band',
            targetName: 'Gone.mp3',
            ids: const [],
          ),
        ],
      ),
    );
    expect(result.failed, 1);
    expect(await File(p.join(root.path, 'Loose', 'Gone.mp3')).exists(), isTrue);
    expect(await Directory(p.join(root.path, 'Band')).exists(), isFalse);
  });

  test('Windows verbatim paths match their plain spelling', () {
    expect(
      plainWindowsPath(r'\\?\C:\Users\admin\Music\a.flac'),
      r'C:\Users\admin\Music\a.flac',
    );
    expect(
      plainWindowsPath(r'\\?\UNC\server\share\a.flac'),
      r'\\server\share\a.flac',
    );
    expect(plainWindowsPath(r'C:\Music\a.flac'), r'C:\Music\a.flac');
    expect(plainWindowsPath('/music/a.flac'), '/music/a.flac');

    // A moved file keeps the spelling its scanner used.
    expect(
      matchWindowsPathSpelling(
        r'\\?\C:\Music\old.flac',
        r'C:\Music\A\new.flac',
      ),
      r'\\?\C:\Music\A\new.flac',
    );
    expect(
      matchWindowsPathSpelling(
        r'\\?\UNC\nas\music\old.flac',
        r'\\nas\music\new.flac',
      ),
      r'\\?\UNC\nas\music\new.flac',
    );
    expect(
      matchWindowsPathSpelling(r'C:\Music\old.flac', r'C:\Music\A\new.flac'),
      r'C:\Music\A\new.flac',
    );
    expect(
      matchWindowsPathSpelling('/music/old.flac', '/music/A/new.flac'),
      '/music/A/new.flac',
    );
  });

  test('relative folder helpers', () {
    expect(normalizeRelativeLibraryDir(r'.\Artist\\Album/'), 'Artist/Album');
    expect(numberedLibraryFileName('Song.flac', 3), 'Song (3).flac');
    expect(numberedLibraryFileName('Song', 2), 'Song (2)');
    expect(lyricsSidecarName('Song.m4a'), 'Song.lrc');
  });

  test('SAF moves publish at the new folder, then delete the original and '
      'record the new name', () async {
    // In-memory document tree: "dir/name" → contents.
    final documents = <String, String>{
      'Old/Song.flac': 'audio',
      'Old/Song.lrc': 'lyrics',
    };
    String uriOf(String path) => 'content://tree/$path';
    String pathOf(String uri) => uri.substring('content://tree/'.length);
    final temp = await Directory.systemTemp.createTemp('saf-temp-');
    addTearDown(() => temp.delete(recursive: true));
    var copies = 0;
    final saf = LibraryReorganizerSafOps(
      copyToTemp: (uri) async {
        final content = documents[pathOf(uri)];
        if (content == null) return null;
        final file = File(p.join(temp.path, 'copy${copies++}'));
        await file.writeAsString(content);
        return file.path;
      },
      createUnique:
          ({
            required treeUri,
            required relativeDir,
            required fileName,
            required mimeType,
            required srcPath,
          }) async {
            final path = joinRelativeLibraryPath(relativeDir, fileName);
            documents[path] = await File(srcPath).readAsString();
            return (uri: uriOf(path), fileName: fileName);
          },
      delete: (uri) async => documents.remove(pathOf(uri)) != null,
      resolve:
          ({required treeUri, required relativeDir, required fileName}) async {
            final path = joinRelativeLibraryPath(relativeDir, fileName);
            return documents.containsKey(path) ? uriOf(path) : null;
          },
    );
    final updates = <String, List<String?>>{};
    final result =
        await LibraryReorganizer(
          saf: saf,
          updateHistoryPath:
              (
                id,
                newFilePath, {
                newSafFileName,
                newSafRelativeDir,
                required expectedFilePath,
              }) async {
                updates[id] = [
                  newFilePath,
                  newSafFileName,
                  newSafRelativeDir,
                  expectedFilePath,
                ];
                return true;
              },
          relinkLibraryPath: (_, _) async => false,
        ).run(
          LibraryReorganizationPlan(
            root: 'content://tree',
            safMode: true,
            moves: [
              LibraryReorganizationMove(
                historyIds: const ['h1'],
                trackName: 'Song',
                sourcePath: uriOf('Old/Song.flac'),
                sourceRelativeDir: 'Old',
                sourceFileName: 'Song.flac',
                targetRelativeDir: 'Artist/Album',
                targetFileName: 'Artist - Song.flac',
              ),
            ],
          ),
        );

    expect(result.moved, 1);
    expect(documents, {
      'Artist/Album/Artist - Song.flac': 'audio',
      'Artist/Album/Artist - Song.lrc': 'lyrics',
    });
    expect(updates['h1'], [
      uriOf('Artist/Album/Artist - Song.flac'),
      'Artist - Song.flac',
      'Artist/Album',
      uriOf('Old/Song.flac'),
    ]);
    expect(await temp.list().isEmpty, isTrue);
  });
}
