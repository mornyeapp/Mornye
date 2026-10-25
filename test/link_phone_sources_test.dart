import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/desktop/link_arriving_files.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/desktop/link_phone_catalogs.dart';
import 'package:mornye/services/link/desktop/link_phone_sources.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';

import 'support/link_desktop_fakes.dart';

const _phone = 'phone-1';

String _fileId(int i) => i.toRadixString(16).padLeft(32, '0');

void main() {
  late Directory root;
  late Directory received;
  late LinkPhoneCatalogs catalogs;
  late LinkArrivingFiles arriving;
  late List<({Map<String, dynamic> message, String deviceId})> sent;
  late Set<String> connected;
  late int delivered;
  late DesktopLinkCatalogIndex? index;
  late Map<String, Map<String, dynamic>> tags;
  late List<String> registered;
  final sourceId = linkPhoneSourceId(_phone);
  final coverId = _fileId(0xc0);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('link-phones-');
    received = await Directory.systemTemp.createTemp('link-received-');
    catalogs = LinkPhoneCatalogs(
      root: () async => root,
      paired: (_) async => true,
    );
    registered = [];
    arriving = LinkArrivingFiles(
      register: (path, {required url, required done}) => registered.add(path),
      poll: const Duration(milliseconds: 10),
    );
    sent = [];
    connected = {_phone};
    delivered = 1;
    index = DesktopLinkCatalogIndex(serverId: 'server-1', songs: const []);
    tags = {};
  });

  tearDown(() async {
    await arriving.close();
    await root.delete(recursive: true);
    await received.delete(recursive: true);
  });

  LinkPhoneSources sources({Duration? answerTimeout}) => LinkPhoneSources(
    catalogs: catalogs,
    index: () => index,
    receivedDir: () => received.path,
    connectedDevice: (id) =>
        id == sourceId && connected.contains(_phone) ? _phone : null,
    send: (message, deviceId) async {
      sent.add((message: message, deviceId: deviceId));
      return delivered;
    },
    arriving: () => arriving,
    readTags: (path) async =>
        tags[path] ?? (throw const FileSystemException('unreadable')),
    answerTimeout: answerTimeout ?? const Duration(seconds: 15),
  );

  Future<void> commit(List<LinkPhoneSong> songs) async {
    final router = LinkHostRouter();
    catalogs.register(router);
    await router.dispatch(
      LinkRequest(
        requestId: 'r1',
        op: LinkOps.phoneCovers,
        deviceId: _phone,
        args: {
          '_method': 'POST',
          'covers': [
            {
              'id': coverId,
              'ext': 'jpg',
              'data': base64Encode([0xff, 0xd8, 0xff]),
            },
          ],
        },
      ),
    );
    await router.dispatch(
      LinkRequest(
        requestId: 'r2',
        op: LinkOps.phoneCatalog,
        deviceId: _phone,
        args: {
          '_method': 'POST',
          'version': 'v1',
          'offset': 0,
          'total': songs.length,
          'songs': [for (final song in songs) song.toJson()],
        },
      ),
    );
  }

  LinkPhoneSong song(
    int i, {
    String? title,
    String artist = 'Artist',
    String? isrc,
    int durationMs = 200000,
    String suffix = 'flac',
    String? cover,
  }) => LinkPhoneSong(
    fileId: _fileId(i),
    suffix: suffix,
    title: title ?? 'Song $i',
    artist: artist,
    album: 'Album',
    track: 3,
    year: 2020,
    durationMs: durationMs,
    isrc: isrc,
    bitRate: 900,
    sampleRate: 44100,
    bitDepth: 16,
    size: 1000,
    coverId: cover,
    addedMs: 1700000000000,
  );

  Matcher linkError(String code) =>
      isA<LinkException>().having((error) => error.code, 'code', code);

  Map<String, dynamic> sendingMessage(String name, {int size = 6}) => {
    'type': LinkMessageTypes.filesSending,
    'name': name,
    'file': name,
    'size': size,
    'streamable': true,
  };

  group('songs', () {
    test('lists the songs the desktop does not have, with covers', () async {
      index = DesktopLinkCatalogIndex(
        serverId: 'server-1',
        songs: [
          catalogSong('l:isrc', title: 'Other', isrc: 'USAAA0000001'),
          catalogSong('l:key', title: 'Shared', artist: 'Artist'),
          catalogSong('l:far', title: 'Longer', artist: 'Artist'),
        ],
      );
      await commit([
        song(1, title: 'Unique', cover: coverId),
        song(2, title: 'Renamed', isrc: 'USAAA0000001'),
        song(3, title: 'Shared', durationMs: 201000),
        // Further than 2 s from the desktop's song: another recording.
        song(4, title: 'Longer', durationMs: 205000),
      ]);
      final listed = await sources().songs(sourceId).toList();
      expect(
        [for (final song in listed) song.path],
        ['${_fileId(1)}.flac', '${_fileId(4)}.flac'],
      );
      final first = listed.first;
      expect(first.coverPath, '${root.path}/$sourceId/covers/$coverId.jpg');
      expect(first.size, 1000);
      expect(first.modifiedTime, 1700000000000);
      expect(first.tags, {
        'title': 'Unique',
        'artist': 'Artist',
        'album': 'Album',
        'track_number': 3,
        'date': '2020',
        'duration': 200,
        'bitrate': 900,
        'sample_rate': 44100,
        'bit_depth': 16,
        'explicit': false,
        'format': 'flac',
        'cover_path': first.coverPath,
      });
      expect(listed.last.coverPath, isNull);
    });

    test('remembers sources scanned before the index was ready', () async {
      index = null;
      await commit([song(1)]);
      final phone = sources();
      expect(await phone.songs(sourceId).toList(), hasLength(1));
      expect(phone.takeUnindexed(), [sourceId]);
      expect(phone.takeUnindexed(), isEmpty);
    });

    test('owns only phone source ids', () {
      final phone = sources();
      expect(phone.owns(sourceId), isTrue);
      expect(phone.owns('nas'), isFalse);
    });
  });

  group('resolve', () {
    test('plays a whole received file without asking the phone', () async {
      final name = '${_fileId(1)}.flac';
      final file = File('${received.path}/${_fileId(1)}.m4a')
        ..writeAsBytesSync([1, 2, 3]);
      // A part file of the same song is not whole.
      File('${received.path}/.$name.123.part').writeAsBytesSync([1]);
      expect(await sources().resolve(sourceId, name), file.path);
      expect(sent, isEmpty);
    });

    test('asks the phone and streams the song as it arrives', () async {
      final phone = sources();
      final name = '${_fileId(1)}.flac';
      final first = phone.resolve(sourceId, name);
      final second = phone.resolve(sourceId, name);
      await pumpEventQueue();
      expect(sent, hasLength(1));
      expect(sent.single.deviceId, _phone);
      expect(sent.single.message, {
        'type': LinkMessageTypes.filesRequest,
        'name': name,
      });

      // Another phone's answer does not count.
      expect(phone.onMessage('phone-2', sendingMessage(name)), isTrue);
      expect(phone.onMessage(_phone, sendingMessage(name)), isTrue);
      final url = await first;
      expect(url, startsWith('http://127.0.0.1:'));
      expect(url, endsWith('/$name'));
      expect(await second, url);
      expect(registered, ['${received.path}${Platform.pathSeparator}$name']);

      // While it arrives, a later play streams it without a new request.
      expect(await phone.resolve(sourceId, name), url);
      expect(sent, hasLength(1));
    });

    test('waits for a song that plays only once whole', () async {
      final phone = sources();
      final name = '${_fileId(1)}.m4a';
      final resolved = phone.resolve(sourceId, name);
      await pumpEventQueue();
      phone.onMessage(_phone, {...sendingMessage(name), 'streamable': false});
      var done = false;
      unawaited(resolved.then((_) => done = true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(done, isFalse);
      File('${received.path}/$name').writeAsBytesSync([1, 2, 3, 4, 5, 6]);
      expect(await resolved, '${received.path}${Platform.pathSeparator}$name');
    });

    test('fails when the phone cannot send the song', () async {
      final phone = sources();
      final name = '${_fileId(1)}.flac';
      final resolved = phone.resolve(sourceId, name);
      await pumpEventQueue();
      phone.onMessage(_phone, {
        'type': LinkMessageTypes.filesFailed,
        'name': name,
        'reason': 'gone',
      });
      await expectLater(
        resolved,
        throwsA(
          isA<LinkException>().having(
            (error) => error.message,
            'message',
            contains('gone'),
          ),
        ),
      );
      // A later play asks again.
      unawaited(phone.resolve(sourceId, name).catchError((Object _) => ''));
      await pumpEventQueue();
      expect(sent, hasLength(2));
      phone.close();
    });

    test('gives up when the phone does not answer', () async {
      final phone = sources(answerTimeout: const Duration(milliseconds: 30));
      await expectLater(
        phone.resolve(sourceId, '${_fileId(1)}.flac'),
        throwsA(linkError('timeout')),
      );
    });

    test('fails at once while the phone is not connected', () async {
      connected = {};
      await expectLater(
        sources().resolve(sourceId, '${_fileId(1)}.flac'),
        throwsA(linkError('unavailable')),
      );
      expect(sent, isEmpty);

      connected = {_phone};
      delivered = 0;
      await expectLater(
        sources().resolve(sourceId, '${_fileId(1)}.flac'),
        throwsA(linkError('unavailable')),
      );
    });

    test('fails a request when its phone disconnects', () async {
      final phone = sources();
      final resolved = phone.resolve(sourceId, '${_fileId(1)}.flac');
      await pumpEventQueue();
      phone.keepConnected({'phone-2'});
      await expectLater(resolved, throwsA(linkError('unavailable')));
    });

    test('rejects names that are not phone songs', () async {
      await expectLater(
        sources().resolve(sourceId, '../secret.flac'),
        throwsFormatException,
      );
      await expectLater(
        sources().resolve(sourceId, '${_fileId(1)}.exe'),
        throwsFormatException,
      );
    });
  });

  group('metadata', () {
    test('answers the stored song while the phone has not sent it', () async {
      await commit([song(1, cover: coverId)]);
      final metadata = await sources().metadata(sourceId, '${_fileId(1)}.flac');
      expect(metadata['title'], 'Song 1');
      expect(metadata['duration'], 200);
      expect(
        metadata['cover_path'],
        '${root.path}/$sourceId/covers/$coverId.jpg',
      );
      expect(await sources().metadata(sourceId, '${_fileId(9)}.flac'), isEmpty);
      expect(await sources().metadata(sourceId, 'nonsense'), isEmpty);
    });

    test('reads the received file, else falls back', () async {
      await commit([song(1, cover: coverId)]);
      final path = '${received.path}/${_fileId(1)}.flac';
      File(path).writeAsBytesSync([1]);
      tags[path] = {
        'title': 'From the file',
        'lyrics': 'la la',
        'cover_base64': 'AAAA',
      };
      final metadata = await sources().metadata(sourceId, '${_fileId(1)}.flac');
      expect(metadata['title'], 'From the file');
      expect(metadata['lyrics'], 'la la');
      expect(metadata.containsKey('cover_base64'), isFalse);
      expect(metadata['cover_path'], endsWith('$coverId.jpg'));

      tags[path] = {'error': 'unsupported'};
      expect(
        (await sources().metadata(sourceId, '${_fileId(1)}.flac'))['title'],
        'Song 1',
      );
      tags.remove(path);
      expect(
        (await sources().metadata(sourceId, '${_fileId(1)}.flac'))['title'],
        'Song 1',
      );
    });

    test('waits for a song on its way, then reads it', () async {
      await commit([song(1)]);
      final phone = sources();
      final name = '${_fileId(1)}.flac';
      final path = '${received.path}${Platform.pathSeparator}$name';
      tags[path] = {'title': 'Arrived'};
      unawaited(phone.resolve(sourceId, name));
      await pumpEventQueue();
      final metadata = phone.metadata(sourceId, name);
      phone.onMessage(_phone, sendingMessage(name));
      var done = false;
      unawaited(metadata.then((_) => done = true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(done, isFalse);
      File(path).writeAsBytesSync([1, 2, 3, 4, 5, 6]);
      expect((await metadata)['title'], 'Arrived');
    });
  });
}
