import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/library_duplicates.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/network_storage_service.dart';

import 'support/sqlite_process_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteProcessDatabase db;

  setUp(() async {
    db = await SqliteProcessDatabase.open();
    await LibrarySchema.create(db, LibrarySchema.version);
    await db.execute("ATTACH DATABASE ':memory:' AS history_db");
    await db.execute('''CREATE TABLE history_db.history (
      id TEXT PRIMARY KEY, track_name TEXT, artist_name TEXT, album_name TEXT,
      file_path TEXT, isrc TEXT, bit_depth INTEGER, sample_rate INTEGER,
      bitrate INTEGER, format TEXT
    )''');
  });
  tearDown(() => db.close());

  Future<void> add(
    String id,
    String path, {
    bool history = false,
    String? sourceId,
  }) => db
      .insert(history ? 'history_db.history' : 'library', {
        'id': id,
        'track_name': 'Track',
        'artist_name': 'Artist',
        'album_name': 'Album',
        'file_path': path,
        'isrc': 'SAME-RECORDING',
        'bit_depth': 16,
        'sample_rate': 44100,
        if (!history) ...{
          'scanned_at': '2026-10-10',
          'source_id': sourceId ?? LocalLibraryItem.legacySourceId,
        },
      })
      .then((_) {});

  test(
    'disabled NAS history does not pair with the replacement RSAF library',
    () async {
      await db.insert('library_sources', {
        'id': 'nas',
        'path': 'network://nas/',
        'display_name': 'SMB',
        'enabled': 0,
        'available': 1,
      });
      await add(
        'old-download',
        'network://nas/Album/Track.flac',
        history: true,
      );
      await add(
        'new-scan',
        'content://rsaf/document/remote%3AAlbum%2FTrack.flac',
      );
      await add(
        'disabled-scan',
        'network://nas/Album/Track.flac',
        sourceId: 'nas',
      );
      expect(await readIsrcDuplicateGroups(db), isEmpty);
      // The historical record is retained, not purged while storage is disabled.
      expect(await db.query('history_db.history'), hasLength(1));
      await db.update(
        'library_sources',
        {'enabled': 1},
        where: 'id = ?',
        whereArgs: ['nas'],
      );
      expect((await readIsrcDuplicateGroups(db)).single.entries, hasLength(2));
      await db.update(
        'library_sources',
        {'available': 0},
        where: 'id = ?',
        whereArgs: ['nas'],
      );
      expect(await readIsrcDuplicateGroups(db), isEmpty);
    },
  );

  test(
    'rescans and alternate SAF tree URIs do not duplicate one physical file',
    () async {
      const document = 'remote%3AAlbum%2FTrack.flac';
      await add(
        'download',
        'content://rsaf/tree/root/document/$document',
        history: true,
      );
      await add('scan', 'content://rsaf/tree/album/document/$document');
      await add(
        'old-history',
        'content://rsaf/document/$document',
        history: true,
      );
      expect(await readIsrcDuplicateGroups(db), isEmpty);
    },
  );

  for (final protocol in [NetworkProtocol.smb, NetworkProtocol.webdav]) {
    test('NAS connection aliases are one physical file ($protocol)', () async {
      final scheme = protocol == NetworkProtocol.smb ? 'smb' : 'https';
      final connections = {
        for (final (id, address) in [
          ('root', '$scheme://nas.test/music/'),
          ('folder', '$scheme://nas.test/music/downloads/'),
          ('other', '$scheme://other.test/music/'),
          ('user', '$scheme://nas.test/music/'),
        ])
          id: NetworkConnection(
            id: id,
            name: 'NAS',
            protocol: protocol,
            address: address,
            username: id == 'user' ? 'other-user' : 'listener',
          ),
      };
      await add('first', 'network://root/downloads/Track.flac');
      await add('alias', 'network://folder/Track.flac');
      expect(
        await readIsrcDuplicateGroups(
          db,
          loadNetworkConnections: () async => connections.values.toList(),
        ),
        isEmpty,
      );
      // A real copy, another server, and another account remain distinct.
      await add('copy', 'network://root/processed/Track.flac');
      await add('server', 'network://other/downloads/Track.flac');
      await add('account', 'network://user/downloads/Track.flac');
      final groups = await readIsrcDuplicateGroups(
        db,
        networkConnections: connections,
      );
      expect(groups.single.entries, hasLength(4));
    });
  }

  test('actual copies and different formats remain selectable', () async {
    await add('download', '/music/Track.flac', history: true);
    await add('indexed-download', 'file:///music/Track.flac');
    await add('conversion', '/music/Track.opus');
    await add('copy', '/playlist/Track.flac');
    final group = (await readIsrcDuplicateGroups(
      db,
      loadNetworkConnections: () async => throw StateError('No NAS required'),
    )).single;
    expect(group.entries.map((entry) => entry.filePath).toSet(), {
      '/music/Track.flac',
      '/music/Track.opus',
      '/playlist/Track.flac',
    });
  });
}
