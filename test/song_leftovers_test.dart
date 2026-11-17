import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/song_leftovers_provider.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => const DownloadQueueState();

  void setProcessing(bool processing) =>
      state = state.copyWith(isProcessing: processing);
}

class _Library extends LocalLibraryNotifier {
  _Library(this.folders);

  final List<String> folders;

  @override
  LocalLibraryState build() => LocalLibraryState(
    sources: [
      for (final folder in folders)
        LocalLibrarySource(id: folder, path: folder, displayName: folder),
    ],
  );
}

/// An Android storage tree held in memory: folder uri to its entries.
class _Documents implements SongFolderStore {
  _Documents(this.folders);

  final Map<String, List<SongFolderEntry>> folders;
  final deleted = <String>[];

  @override
  Future<List<SongFolderEntry>?> list(String folder) async {
    final entries = folders[folder];
    return entries == null ? null : List.of(entries);
  }

  @override
  Future<bool> delete(String id, {required bool folder}) async {
    if (folder && folders[id]?.isNotEmpty == true) return false;
    deleted.add(id);
    folders.remove(id);
    for (final entries in folders.values) {
      entries.removeWhere((entry) => entry.id == id);
    }
    return true;
  }
}

/// Waits for work that includes real file IO.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late String root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('song_leftovers');
    root = p.join(temp.path, 'Music');
    await Directory(root).create();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  String file(String relative, {String? under}) {
    final path = p.join(under ?? root, relative);
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    return path;
  }

  bool exists(String relative) =>
      FileSystemEntity.typeSync(p.join(root, relative)) !=
      FileSystemEntityType.notFound;

  ({SongLeftovers leftovers, _Queue queue}) setUpLeftovers({
    bool removeEmptyFolders = true,
    bool saveFolderCover = false,
    SongFolderStore? documents,
    Future<({String name, List<({String uri, bool root})> folders})?> Function(
      String source,
    )?
    documentPlace,
    Future<bool> Function(String? source)? deleteSong,
    Future<bool> Function(String source)? orphanedNetworkSong,
    List<String> libraryFolders = const [],
  }) {
    final queue = _Queue();
    final provider = Provider<SongLeftovers>(
      (ref) => SongLeftovers(
        ref,
        home: p.join(temp.path, 'home'),
        deleteSong: deleteSong,
        orphanedNetworkSong: orphanedNetworkSong,
        documents: documents ?? const DocumentSongFolderStore(),
        documentPlace: documentPlace,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        initialSettingsProvider.overrideWithValue(
          AppSettings(
            downloadDirectory: root,
            removeEmptyFolders: removeEmptyFolders,
            saveFolderCover: saveFolderCover,
          ),
        ),
        downloadQueueProvider.overrideWith(() => queue),
        localLibraryProvider.overrideWith(() => _Library(libraryFolders)),
      ],
    );
    addTearDown(container.dispose);
    container.read(downloadQueueProvider);
    return (leftovers: container.read(provider), queue: queue);
  }

  test('deletes the lyrics files and the folders the last song leaves '
      'empty', () async {
    final song = file('Artist/Album/01 Song.flac');
    file('Artist/Album/01 Song.lrc');
    file('Artist/Album/01 Song.mlrc');
    file('Artist/Album/.DS_Store');
    file('Artist/Album/cover.mp4');
    // A lyrics file a song deleted earlier left behind.
    file('Artist/Album/02 Gone.lrc');
    final (:leftovers, queue: _) = setUpLeftovers();

    expect(await leftovers.delete(song), isTrue);
    await _until(() => !exists('Artist'));

    expect(exists('Artist'), isFalse);
    expect(Directory(root).existsSync(), isTrue);
  });

  test('keeps a folder that still holds other files', () async {
    final song = file('Artist/Album/Song.flac');
    file('Artist/Album/Song.lrc');
    file('Artist/Album/folder.jpg');
    final (:leftovers, queue: _) = setUpLeftovers();

    expect(await leftovers.delete(song), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(exists('Artist/Album/Song.lrc'), isFalse);
    expect(exists('Artist/Album/folder.jpg'), isTrue);
  });

  test('removes the album cover file while downloads save it', () async {
    final song = file('Artist/Album/Song.flac');
    file('Artist/Album/Folder.jpg');
    final (:leftovers, queue: _) = setUpLeftovers(saveFolderCover: true);

    expect(await leftovers.delete(song), isTrue);
    await _until(() => !exists('Artist'));

    expect(exists('Artist'), isFalse);
  });

  test('keeps the artist folder while another album is in it', () async {
    final song = file('Artist/First/Song.flac');
    file('Artist/Second/Other.flac');
    final (:leftovers, queue: _) = setUpLeftovers();

    await leftovers.delete(song);
    await _until(() => !exists('Artist/First'));

    expect(exists('Artist/First'), isFalse);
    expect(exists('Artist/Second/Other.flac'), isTrue);
  });

  test('keeps lyrics files a song of the same name still uses', () async {
    final song = file('Artist/Album/Song.flac');
    file('Artist/Album/Song.mp3');
    file('Artist/Album/Song.lrc');
    final (:leftovers, queue: _) = setUpLeftovers();

    await leftovers.delete(song);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(exists('Artist/Album/Song.flac'), isFalse);
    expect(exists('Artist/Album/Song.lrc'), isTrue);
  });

  test('only deletes the lyrics files while Remove Empty Folders is '
      'off', () async {
    final song = file('Artist/Album/Song.flac');
    file('Artist/Album/Song.lrc');
    final (:leftovers, queue: _) = setUpLeftovers(removeEmptyFolders: false);

    await leftovers.delete(song);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(exists('Artist/Album/Song.lrc'), isFalse);
    expect(exists('Artist/Album'), isTrue);
  });

  test('leaves folders outside the download and Local Library '
      'folders', () async {
    final elsewhere = p.join(temp.path, 'Elsewhere');
    final song = file('Album/Song.flac', under: elsewhere);
    file('Album/Song.lrc', under: elsewhere);
    final (:leftovers, queue: _) = setUpLeftovers();

    await leftovers.delete(song);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(File(p.join(elsewhere, 'Album', 'Song.lrc')).existsSync(), isFalse);
    expect(Directory(p.join(elsewhere, 'Album')).existsSync(), isTrue);
  });

  test('removes folders inside an added Local Library folder', () async {
    final library = p.join(temp.path, 'Library');
    final song = file('Artist/Album/Song.flac', under: library);
    final (:leftovers, queue: _) = setUpLeftovers(libraryFolders: [library]);

    await leftovers.delete(song);
    await _until(() => !Directory(p.join(library, 'Artist')).existsSync());

    expect(Directory(p.join(library, 'Artist')).existsSync(), isFalse);
    expect(Directory(library).existsSync(), isTrue);
  });

  test('removes folders only once the download queue is idle', () async {
    final song = file('Artist/Album/Song.flac');
    final (:leftovers, :queue) = setUpLeftovers();
    queue.setProcessing(true);

    await leftovers.delete(song);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(exists('Artist/Album'), isTrue, reason: 'A download is running');

    queue.setProcessing(false);
    await _until(() => !exists('Artist'));
    expect(exists('Artist'), isFalse);
  });

  test('does not delete the song folder when the song stays', () async {
    final song = file('Artist/Album/Song.flac');
    file('Artist/Album/Song.lrc');
    final (:leftovers, queue: _) = setUpLeftovers(
      deleteSong: (_) async => false,
    );

    expect(await leftovers.delete(song), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(exists('Artist/Album/Song.lrc'), isTrue);
  });

  test('a song of a removed network server counts as gone', () async {
    final deleted = <String?>[];
    final (:leftovers, queue: _) = setUpLeftovers(
      deleteSong: (source) async {
        deleted.add(source);
        return false;
      },
      orphanedNetworkSong: (source) async =>
          Uri.parse(source).host == 'removed',
    );

    expect(await leftovers.delete('network://removed/Album/Song.flac'), isTrue);
    expect(deleted, isEmpty);
    // A server the app still has is asked to delete the file.
    expect(await leftovers.delete('network://saved/Album/Song.flac'), isFalse);
    expect(deleted, ['network://saved/Album/Song.flac']);
  });

  test('removes document folders up to the granted folder', () async {
    SongFolderEntry entry(String id, {bool folder = false}) =>
        (name: id.split('/').last, id: id, folder: folder);
    final documents = _Documents({
      'tree': [entry('tree/Artist', folder: true)],
      'tree/Artist': [entry('tree/Artist/Album', folder: true)],
      'tree/Artist/Album': [
        entry('tree/Artist/Album/Song.lrc'),
        entry('tree/Artist/Album/cover.mp4'),
      ],
    });
    final (:leftovers, queue: _) = setUpLeftovers(
      documents: documents,
      deleteSong: (_) async => true,
      documentPlace: (_) async => (
        name: 'Song.flac',
        folders: [
          (uri: 'tree/Artist/Album', root: false),
          (uri: 'tree/Artist', root: false),
          (uri: 'tree', root: true),
        ],
      ),
    );

    expect(
      await leftovers.delete(
        'content://com.example.documents/tree/a/document/b',
      ),
      isTrue,
    );
    await _until(() => documents.deleted.contains('tree/Artist'));

    expect(documents.deleted, [
      'tree/Artist/Album/Song.lrc',
      'tree/Artist/Album/cover.mp4',
      'tree/Artist/Album',
      'tree/Artist',
    ]);
    expect(documents.folders.keys, ['tree']);
  });

  group('isSharedTopFolder', () {
    test('keeps storage, volumes and the folders right inside them', () {
      final posix = p.Context(style: p.Style.posix);
      bool shared(String path) =>
          isSharedTopFolder(path, context: posix, home: '/home/me');

      expect(shared('/storage/emulated/0'), isTrue);
      expect(shared('/storage/emulated/0/Music'), isTrue);
      expect(shared('/storage/1234-ABCD/Download'), isTrue);
      expect(shared('/Volumes/Drive/Music'), isTrue);
      expect(shared('/home/me'), isTrue);
      expect(shared('/home/me/Music'), isTrue);
      expect(shared('/storage/emulated/0/Music/Mornye'), isFalse);
      expect(shared('/home/me/Music/Mornye/Artist'), isFalse);
    });

    test('keeps a Windows drive and its top folders', () {
      final windows = p.Context(style: p.Style.windows);
      bool shared(String path) =>
          isSharedTopFolder(path, context: windows, home: r'C:\Users\me');

      expect(shared(r'D:\Music'), isTrue);
      expect(shared(r'C:\Users\me\Music'), isTrue);
      expect(shared(r'C:\Users\me\Music\Mornye\Artist'), isFalse);
    });
  });
}
