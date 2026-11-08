import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/utils/path_match_keys.dart';

// Execute the production SQL, including bound parameters, against real SQLite.
// Python is also used by the repository's native artifact checks in CI.
class _SearchDatabase implements DatabaseExecutor {
  const _SearchDatabase({this.extraTracks = const []});

  final List<Map<String, Object?>> extraTracks;

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    final result = await Process.run('python3', [
      '-c',
      r'''
import json, sqlite3, sys
db = sqlite3.connect(':memory:')
db.row_factory = sqlite3.Row
db.execute("ATTACH DATABASE ':memory:' AS history_db")
columns = """id TEXT PRIMARY KEY, track_name TEXT, artist_name TEXT,
album_name TEXT, album_artist TEXT, album_key TEXT, sort_track TEXT,
sort_album TEXT, sort_album_artist TEXT, track_name_norm TEXT,
album_name_norm TEXT, album_artist_norm TEXT, search_text TEXT,
cover_url TEXT, cover_path TEXT, file_path TEXT, enabled INTEGER,
origin_file_path TEXT"""
db.execute('CREATE TABLE history_db.history (' + columns + ')')
db.execute('CREATE TABLE library (' + columns + ')')
db.execute('CREATE VIEW library_visible AS SELECT * FROM library WHERE enabled = 1')
for table in ['library_path_keys', 'history_db.history_path_keys']:
    db.execute('CREATE TABLE ' + table + ' (item_id TEXT, path_key TEXT)')
for table in ['history_db.history_search_fts', 'library_search_fts']:
    db.execute('CREATE VIRTUAL TABLE ' + table + " USING fts5(search_text, tokenize='trigram')")
def track(local, id, title, artist, album, path=None, enabled=1):
    table = 'library' if local else 'history_db.history'
    path = path or '/' + id + '.flac'
    fields = dict(id=id, track_name=title, artist_name=artist,
      album_name=album, album_artist=artist,
      album_key=(album+'|'+artist).lower(), sort_track=title.lower(),
      sort_album=album.lower(), sort_album_artist=artist.lower(),
      track_name_norm=title.lower(), album_name_norm=album.lower(),
      album_artist_norm=artist.lower(), search_text=(title+' '+artist+' '+album).lower(),
      file_path=path, enabled=enabled)
    cur = db.execute('INSERT INTO '+table+' ('+','.join(fields)+') VALUES ('+','.join('?' for _ in fields)+')', list(fields.values()))
    fts = 'library_search_fts' if local else 'history_db.history_search_fts'
    db.execute('INSERT INTO '+fts+' (rowid, search_text) VALUES (?, ?)', (cur.lastrowid, fields['search_text']))
    paths = 'library_path_keys' if local else 'history_db.history_path_keys'
    db.execute('INSERT INTO '+paths+' VALUES (?, ?)', (id, path))
track(False, '1', 'Lilac', 'Mrs. GREEN APPLE', 'Spring')
track(False, '2', 'Blue', 'Mrs. GREEN APPLE', 'Spring')
track(False, '3', 'Live Lilac', 'Someone Else', 'Concert')
track(True, 'local', 'Lilac acoustic', 'Mrs. GREEN APPLE', 'Acoustic')
track(True, 'duplicate', 'Lilac', 'Mrs. GREEN APPLE', 'Spring', path='/1.flac')
track(True, 'hidden', 'Lilac hidden', 'Hidden Artist', 'Hidden', enabled=0)
track(False, '4', "Don't Stop", 'Artist', 'Night')
track(True, '5', '夜の歌', '歌手', '夜空')
track(False, '6', 'OR Nothing', 'Artist', 'Night')
for i in range(85):
    track(False, 'page-'+str(i), 'Page '+str(i).zfill(3), 'Artist', 'Many')
query = json.loads(sys.argv[1])
for extra in query['extra_tracks']:
    track(extra['local'], extra['id'], extra['title'], 'Artist', extra['album'], path=extra['path'])
    keys = 'library_path_keys' if extra['local'] else 'history_db.history_path_keys'
    db.executemany('INSERT INTO '+keys+' VALUES (?, ?)', [(extra['id'], key) for key in extra['keys']])
print(json.dumps([dict(row) for row in db.execute(query['sql'], query['args'])]))
''',
      jsonEncode({'sql': sql, 'args': arguments, 'extra_tracks': extraTracks}),
    ]);
    if (result.exitCode != 0) fail('${result.stderr}\n$sql\n$arguments');
    return (jsonDecode(result.stdout as String) as List)
        .cast<Map<String, dynamic>>();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final fts in [false, true]) {
    group('Library search (FTS: $fts)', () {
      final store = LibrarySearchStore(
        _SearchDatabase(),
        historyFts: fts,
        localFts: fts,
      );
      Future<List<LibrarySearchHit>> search(
        String query, {
        LibrarySearchKind kind = LibrarySearchKind.songs,
        bool includeLocal = true,
        int limit = 40,
        int offset = 0,
      }) => store.search(
        query: query,
        kind: kind,
        includeLocal: includeLocal,
        limit: limit,
        offset: offset,
      );

      test(
        'matches unordered words across title and artist, including partial words',
        () async {
          expect((await search('green lil')).map((hit) => hit.id), [
            '1',
            'local',
          ]);
          expect((await search('mrs.   APPLE lilac')).map((hit) => hit.id), [
            '1',
            'local',
          ]);
        },
      );
      test(
        'ranks exact title first and excludes hidden sources and duplicate paths',
        () async {
          expect((await search('lilac')).map((hit) => hit.id), [
            '1',
            'local',
            '3',
          ]);
          expect(
            (await search('lilac', includeLocal: false)).map((hit) => hit.id),
            ['1', '3'],
          );
        },
      );
      test(
        'scan and download tree aliases appear as one search result',
        () async {
          const provider = 'org.example.documents';
          const documentId = 'account:Music/Album/Tree Song.flac';
          String path(String tree, String document) => Uri(
            scheme: 'content',
            host: provider,
            pathSegments: ['tree', tree, 'document', document],
          ).toString();
          Map<String, Object?> row(
            String id,
            bool local,
            String file,
            String album,
          ) => {
            'id': id,
            'local': local,
            'title': 'Tree Song',
            'album': album,
            'path': file,
            'keys': buildPathMatchKeys(file).toList(),
          };
          final treeStore = LibrarySearchStore(
            _SearchDatabase(
              extraTracks: [
                row(
                  'tree-download',
                  false,
                  path('account:Music/Album', documentId),
                  'Album',
                ),
                row(
                  'tree-scan',
                  true,
                  path('account:Music', documentId),
                  'Unknown Album',
                ),
                row(
                  'tree-other',
                  true,
                  path('account:Music', 'account:Music/Other/Tree Song.flac'),
                  'Other Album',
                ),
              ],
            ),
            historyFts: fts,
            localFts: fts,
          );
          final hits = await treeStore.search(
            query: 'Tree Song',
            kind: LibrarySearchKind.songs,
            includeLocal: true,
          );
          expect(hits.map((hit) => hit.id), ['tree-download', 'tree-other']);
        },
      );
      test(
        'handles short, non-Latin and punctuated queries as literal terms',
        () async {
          expect((await search('夜')).single.id, '5');
          expect((await search("DON’T stop")).single.id, '4');
          expect((await search('OR')).map((hit) => hit.id), contains('6'));
          expect(await search('***'), isEmpty);
        },
      );
      test(
        'album results match album fields and retain full track counts',
        () async {
          final hits = await search(
            'apple spring',
            kind: LibrarySearchKind.albums,
          );
          expect(hits.single.title, 'Spring');
          expect(hits.single.trackCount, 2);
          expect(
            await search('lilac', kind: LibrarySearchKind.albums),
            isEmpty,
          );
        },
      );
      test(
        'artists combine local and downloaded songs without counting duplicate files',
        () async {
          final hits = await search('green', kind: LibrarySearchKind.artists);
          expect(hits.single.title, 'Mrs. GREEN APPLE');
          expect(hits.single.trackCount, 3);
        },
      );
      test(
        'pagination has stable ordering without missing or repeated hits',
        () async {
          final first = await search('page', limit: 40);
          final second = await search('page', limit: 40, offset: 40);
          final third = await search('page', limit: 40, offset: 80);
          expect([first.length, second.length, third.length], [40, 40, 5]);
          expect({
            ...first.map((h) => h.id),
            ...second.map((h) => h.id),
            ...third.map((h) => h.id),
          }, hasLength(85));
        },
      );
    });
  }
}
