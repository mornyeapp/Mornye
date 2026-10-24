import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_directory_index.dart';

LibraryDirectoryEntry _entry(
  String id,
  String path, {
  String source = 'downloaded',
  String? cover,
  int? disc,
  int? track,
}) => LibraryDirectoryEntry(
  source: source,
  id: id,
  path: path,
  cover: cover,
  discNumber: disc,
  trackNumber: track,
);

List<String> _names(LibraryDirectory folder) => [
  for (final child in folder.folders) child.name,
];

List<String> _songs(LibraryDirectory folder) => [
  for (final track in folder.tracks) track.id,
];

void main() {
  group('libraryFileLocation', () {
    test('reads plain paths on every platform', () {
      final unix = libraryFileLocation('/home/me/Music/Album/01 Song.flac')!;
      expect(unix.root, '/');
      expect(unix.folders, ['home', 'me', 'Music', 'Album']);
      expect(unix.fileName, '01 Song.flac');

      final drive = libraryFileLocation(r'c:\Users\me\Music\Album\01.flac')!;
      expect(drive.root, 'C:');
      expect(drive.rootLabel, r'C:\');
      expect(drive.separator, r'\');
      expect(drive.folders, ['Users', 'me', 'Music', 'Album']);

      final share = libraryFileLocation(r'\\server\share\Music\a.flac')!;
      expect(share.root, '//');
      expect(share.rootLabel, r'\\');
      expect(share.folders, ['server', 'share', 'Music']);

      final uri = libraryFileLocation('file:///home/me/Music/a%20b.flac')!;
      expect(uri.folders, ['home', 'me', 'Music']);
      expect(uri.fileName, 'a b.flac');
    });

    test('places a CUE track at its sheet', () {
      final cue = libraryFileLocation('/music/Album/album.cue#track3')!;
      expect(cue.folders, ['music', 'Album']);
      expect(cue.fileName, 'album.cue');
    });

    test('maps SAF documents to the storage path they name', () {
      final primary = libraryFileLocation(
        'content://com.android.externalstorage.documents/tree/primary%3AMusic'
        '/document/primary%3AMusic%2FArtist%2FAlbum%2F01%20Song.flac',
      )!;
      expect(primary.root, '/');
      expect(primary.folders, [
        'storage',
        'emulated',
        '0',
        'Music',
        'Artist',
        'Album',
      ]);
      expect(primary.fileName, '01 Song.flac');

      final card = libraryFileLocation(
        'content://com.android.externalstorage.documents/tree/1A2B-3C4D%3AMusic'
        '/document/1A2B-3C4D%3AMusic%2FAlbum%2Fsong.flac',
      )!;
      expect(card.rootLabel, 'SD Card');
      expect(card.folders, ['Music', 'Album']);
    });

    test('names an opaque download by the tree it was saved into', () {
      final saved = libraryFileLocation(
        'content://com.android.externalstorage.documents/tree/primary%3AMusic'
        '/document/msf%3A42',
        safTreeUri:
            'content://com.android.externalstorage.documents/tree/primary%3AMusic',
        safRelativeDir: 'Artist/Album',
        safFileName: 'song.flac',
      )!;
      expect(saved.folders, [
        'storage',
        'emulated',
        '0',
        'Music',
        'Artist',
        'Album',
      ]);
      expect(saved.fileName, 'song.flac');

      final opaque = libraryFileLocation(
        'content://com.android.providers.downloads.documents/tree/downloads'
        '/document/msf%3A1234',
      )!;
      expect(opaque.rootLabel, 'downloads');
      expect(opaque.folders, isEmpty);
      expect(opaque.fileName, 'msf:1234');
    });

    test('roots network files at their connection', () {
      final file = libraryFileLocation(
        'network://nas-1/Music/Album/01%20Song.flac',
        networkNames: const {'nas-1': 'Home NAS'},
      )!;
      expect(file.root, 'network://nas-1');
      expect(file.rootLabel, 'Home NAS');
      expect(file.folders, ['Music', 'Album']);
      expect(file.fileName, '01 Song.flac');
      expect(
        libraryFileLocation('network://nas-2/song.flac')!.rootLabel,
        'nas-2',
      );
    });

    test('rejects paths that name no file', () {
      expect(libraryFileLocation(''), isNull);
      expect(libraryFileLocation('song.flac'), isNull);
      expect(libraryFileLocation('/'), isNull);
      expect(libraryFileLocation('network://nas-1/'), isNull);
    });
  });

  test('compareNaturally orders digit runs by value', () {
    final names = ['Track 10', 'track 2', 'Disc 10', 'Track 1', 'Disc 2']
      ..sort(compareNaturally);
    expect(names, ['Disc 2', 'Disc 10', 'Track 1', 'track 2', 'Track 10']);
    expect(compareNaturally('01 Intro', '1 Intro'), isNot(0));
    expect(compareNaturally('a', 'a'), 0);
  });

  group('LibraryDirectoryIndex', () {
    test('opens where the music starts on one volume', () {
      final index = LibraryDirectoryIndex.build([
        _entry('a1', '/storage/emulated/0/Music/B/Album/1.flac', cover: 'b'),
        _entry('a2', '/storage/emulated/0/Music/a/Album/1.flac'),
        _entry(
          'l1',
          '/storage/emulated/0/Music/Mornye/Single.flac',
          source: 'local',
        ),
      ]);
      final root = index.root;
      expect(root.path, '/storage/emulated/0/Music');
      expect(_names(root), ['a', 'B', 'Mornye']);
      expect(root.tracks, isEmpty);
      expect(root.trackCount, 3);
      expect(root.cover, isNull);

      final b = root.folders[1];
      expect(b.path, '/storage/emulated/0/Music/B');
      expect(b.trackCount, 1);
      expect(_names(b), ['Album']);
      expect(b.folders.single.cover, 'b');
      expect(identical(index[b.key], b), isTrue);
      expect(root.folders[2].tracks.single.itemId, 'local_l1');
    });

    test('opens on the folder itself when every song shares it', () {
      final index = LibraryDirectoryIndex.build([
        _entry('a', r'C:\Music\Downloads\b.flac'),
        _entry('b', r'C:\Music\Downloads\a.flac'),
      ]);
      expect(index.root.path, r'C:\Music\Downloads');
      expect(index.root.folders, isEmpty);
      expect(_songs(index.root), ['b', 'a']);
    });

    test('lists each volume and connection by its path', () {
      final index = LibraryDirectoryIndex.build(
        [
          _entry('phone', '/storage/emulated/0/Music/Album/1.flac'),
          _entry('phone2', '/storage/emulated/0/Music/Other/1.flac'),
          _entry('card', 'SD Card/Music/Album/1.flac'),
          _entry('nas', 'network://nas-1/Music/Album/1.flac'),
        ],
        networkNames: const {'nas-1': 'Home NAS'},
      );
      final root = index.root;
      expect(root.key, isEmpty);
      expect(_names(root), [
        '/storage/emulated/0/Music',
        'Home NAS/Music/Album',
        'SD Card/Music/Album',
      ]);
      expect(_names(root.folders.first), ['Album', 'Other']);
      expect(root.trackCount, 4);
    });

    test('orders songs by file name, then disc and track number', () {
      final index = LibraryDirectoryIndex.build([
        _entry('ten', '/m/Album/10 Ten.flac'),
        _entry('cue2', '/m/Album/album.cue#track2', disc: 1, track: 2),
        _entry('two', '/m/Album/2 Two.flac'),
        _entry('cue1', '/m/Album/album.cue#track1', disc: 1, track: 1),
      ]);
      expect(_songs(index.root), ['two', 'ten', 'cue1', 'cue2']);
    });

    test('plays a folder before the folders inside it', () {
      final index = LibraryDirectoryIndex.build([
        _entry('inner', '/m/Box/CD 2/1.flac'),
        _entry('outer', '/m/Box/Bonus.flac'),
        _entry('first', '/m/Box/CD 1/1.flac'),
        _entry('other', '/m/Loose/1.flac'),
      ]);
      final box = index.root.folders.first;
      expect(box.name, 'Box');
      expect(
        [for (final track in box.allTracks) track.id],
        ['outer', 'first', 'inner'],
      );
    });

    test('an empty Library has nothing to open', () {
      final index = LibraryDirectoryIndex.build(const []);
      expect(index.root.key, isEmpty);
      expect(index.root.folders, isEmpty);
      expect(index.root.trackCount, 0);
      expect(index['missing'], isNull);
    });
  });
}
