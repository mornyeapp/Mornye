import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/sync/link_history_artwork.dart';
import 'package:mornye/services/link/sync/link_history_sync_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/link_sync_support.dart';

class _Peer implements LinkClientApi {
  _Peer(this.artwork);

  final LinkHistoryArtwork artwork;
  final posts = <Map<String, dynamic>>[];
  int gets = 0;

  @override
  Future<Object?> get(String op, [Map<String, String> query = const {}]) async {
    expect(op, LinkOps.historyArtwork);
    gets++;
    return linkJsonRoundTrip(
      await artwork.handle(_request({...query, '_method': 'GET'})),
    );
  }

  @override
  Future<Object?> post(String op, Map<String, dynamic> body) async {
    expect(op, LinkOps.historyArtwork);
    posts.add(body);
    final args = linkJsonRoundTrip(body)! as Map<String, dynamic>;
    return linkJsonRoundTrip(
      await artwork.handle(_request({...args, '_method': 'POST'})),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LinkRequest _request(Map<String, dynamic> args) => LinkRequest(
  requestId: 'test',
  op: LinkOps.historyArtwork,
  deviceId: 'peer',
  args: args,
);

Future<({Database db, LinkHistoryArtwork artwork, Directory directory})> _side(
  String name,
) async {
  final directory = await linkSyncTempDirectory();
  final db = await openLinkListeningDatabase(directory, name);
  return (
    db: db,
    artwork: LinkHistoryArtwork(
      LinkHistorySyncStore(() async => db),
      directory: () async => Directory('${directory.path}/received'),
    ),
    directory: directory,
  );
}

Future<void> _heard(
  Database db,
  String key,
  String title, {
  String? artwork,
  String album = 'Album',
}) => db
    .insert('listening', {
      'day': '2026-10-20',
      'track_key': key,
      'title': title,
      'artist': 'Artist',
      'album': album,
      'artwork': artwork,
      'milliseconds': 60000,
      'plays': 1,
    })
    .then((_) {});

Future<String> _image(Directory directory, String name, int color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 512, 512),
    ui.Paint()..color = ui.Color(color),
  );
  final picture = recorder.endRecording();
  final frame = await picture.toImage(512, 512);
  final data = (await frame.toByteData(format: ui.ImageByteFormat.png))!;
  frame.dispose();
  picture.dispose();
  final file = File('${directory.path}/$name.png');
  await file.writeAsBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
  return file.path;
}

Future<Map<String, String?>> _covers(Database db) async => {
  for (final row in await db.query('listening'))
    row['track_key']! as String: row['artwork'] as String?,
};

Future<List<Map<String, Object?>>> _counts(Database db) => db.rawQuery(
  'SELECT day, track_key, milliseconds, plays FROM listening ORDER BY track_key',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'old statistics repair local covers both ways, persist offline, and stop sending',
    () async {
      final phone = await _side('phone');
      final desk = await _side('desk');
      final phoneImage = await _image(phone.directory, 'phone', 0xFFCC0000);
      final deskImage = await _image(desk.directory, 'desk', 0xFF0000CC);
      await _heard(phone.db, 'phone:a', 'Phone song', artwork: phoneImage);
      await _heard(
        phone.db,
        'phone:b',
        'Desktop song',
        artwork: '/missing/foreign.jpg',
      );
      await _heard(desk.db, 'desk:a', 'Phone song');
      await _heard(desk.db, 'desk:b', 'Desktop song', artwork: deskImage);
      final phoneCounts = await _counts(phone.db);
      final deskCounts = await _counts(desk.db);
      final peer = _Peer(desk.artwork);

      expect(await phone.artwork.sync(peer), 1);
      final phoneCover = (await _covers(phone.db))['phone:b']!;
      final deskCover = (await _covers(desk.db))['desk:a']!;
      expect(phoneCover, startsWith('${phone.directory.path}/received/'));
      expect(deskCover, startsWith('${desk.directory.path}/received/'));
      expect(await File(phoneCover).exists(), isTrue);
      expect(await File(deskCover).exists(), isTrue);
      expect(await _counts(phone.db), phoneCounts);
      expect(await _counts(desk.db), deskCounts);

      peer.posts.clear();
      expect(await phone.artwork.sync(peer), 0);
      expect(peer.posts, isEmpty);

      // The cache is local and survives a closed link or a removed source image.
      await File(phoneImage).delete();
      await File(deskImage).delete();
      expect(await File(phoneCover).exists(), isTrue);
      expect(await File(deskCover).exists(), isTrue);
      final codec = await ui.instantiateImageCodec(
        await File(phoneCover).readAsBytes(),
      );
      final frame = (await codec.getNextFrame()).image;
      expect((frame.width, frame.height), (256, 256));
      frame.dispose();
      codec.dispose();
    },
  );

  test('pagination does not skip songs as earlier pages gain covers', () async {
    final phone = await _side('phone');
    final desk = await _side('desk');
    for (var i = 0; i < 105; i++) {
      await _heard(
        phone.db,
        'phone:$i',
        'Song $i',
        artwork: 'https://example.test/$i.png',
      );
      final key = i < 99
          ? 'desk:$i'
          : i == 99
          ? 'desk:\uE000'
          : i == 100
          ? 'desk:\u{1F600}'
          : 'desk:\uE001-$i';
      await _heard(desk.db, key, 'Song $i');
    }
    final peer = _Peer(desk.artwork);
    await phone.artwork.sync(peer);
    expect((await _covers(desk.db)).values.whereType<String>(), hasLength(105));
    expect(peer.gets, 2);
    for (final post in peer.posts) {
      expect(
        (post['covers'] as List).length,
        lessThanOrEqualTo(LinkHistoryArtwork.batchSize),
      );
    }
    peer.posts.clear();
    await phone.artwork.sync(peer);
    expect(peer.posts, isEmpty);
  });

  test(
    'missing album tags cannot borrow another release ambiguously',
    () async {
      final phone = await _side('phone');
      final desk = await _side('desk');
      await _heard(
        phone.db,
        'a',
        'Same song',
        album: 'Release A',
        artwork: 'https://example.test/a.png',
      );
      await _heard(
        phone.db,
        'b',
        'Same song',
        album: 'Release B',
        artwork: 'https://example.test/b.png',
      );
      await _heard(desk.db, 'x', 'Same song', album: '');
      await phone.artwork.sync(_Peer(desk.artwork));
      expect((await _covers(desk.db))['x'], isNull);
    },
  );

  test(
    'peer keys never read files and malformed images never fill covers',
    () async {
      final side = await _side('desk');
      await _heard(side.db, 'local', 'Song');
      final track = {
        'key': '/private/secret.png',
        'title': 'Song',
        'artist': 'Artist',
        'album': 'Album',
      };
      final counts = await _counts(side.db);
      final result = await side.artwork.handle(
        _request({
          '_method': 'POST',
          'covers': [
            {'track': track, 'url': 'file:///private/secret.png'},
            {
              'track': track,
              'data': base64Encode(utf8.encode('<html>not an image</html>')),
            },
            {'track': track, 'url': 'http://127.0.0.1:1234/cover'},
            {
              'track': track,
              'data': 'a' * (LinkHistoryArtwork.maxCoverBytes * 2),
            },
          ],
        }),
      );
      expect(result['applied'], 0);
      expect((await _covers(side.db))['local'], isNull);
      expect(await _counts(side.db), counts);
      expect(
        (await side.artwork.handle(
          _request({
            '_method': 'POST',
            'want': [
              {...track, 'title': 'Not in listening history'},
            ],
          }),
        ))['covers'],
        isEmpty,
      );
    },
  );
}
