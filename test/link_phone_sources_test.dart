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
import 'package:mornye/services/link/features/link_phone_library_sync.dart';
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:audio_service/audio_service.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/utils/file_access.dart';

import 'support/link_desktop_fakes.dart';
import 'support/link_fakes.dart'
    show FakeLinkClient, FakeLibraryRows, linkLocalRow;

class _LyricsClient extends FakeLinkClient {
  void Function(Map<String, dynamic>)? onReply;

  @override
  void send(Map<String, dynamic> message) {
    super.send(message);
    onReply?.call(message);
  }
}

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
  Future<int> Function(Map<String, dynamic>, String)? sendOverride;
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
    sendOverride = null;
  });

  tearDown(() async {
    await arriving.close();
    await root.delete(recursive: true);
    await received.delete(recursive: true);
  });

  LinkPhoneSources sources({
    Duration? answerTimeout,
    Duration lyricsTimeout = const Duration(milliseconds: 250),
    Duration deleteTimeout = const Duration(seconds: 5),
  }) => LinkPhoneSources(
    catalogs: catalogs,
    index: () => index,
    receivedDir: () => received.path,
    connectedDevice: (id) =>
        id == sourceId && connected.contains(_phone) ? _phone : null,
    connectedDevices: () => [...connected],
    send: (message, deviceId) async {
      sent.add((message: message, deviceId: deviceId));
      return sendOverride == null
          ? delivered
          : sendOverride!(message, deviceId);
    },
    arriving: () => arriving,
    readTags: (path) async =>
        tags[path] ?? (throw const FileSystemException('unreadable')),
    answerTimeout: answerTimeout ?? const Duration(seconds: 15),
    lyricsTimeout: lyricsTimeout,
    deleteTimeout: deleteTimeout,
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

  group('recover', () {
    String receivedPath(String name) =>
        '${received.path}${Platform.pathSeparator}$name';

    test('asks a connected phone again for a pruned received song', () async {
      final phone = sources();
      final name = '${_fileId(1)}.flac';
      final recovered = phone.recover(receivedPath(name));
      await pumpEventQueue();
      expect(sent.single.deviceId, _phone);
      expect(sent.single.message, {
        'type': LinkMessageTypes.filesRequest,
        'name': name,
      });

      phone.onMessage(_phone, sendingMessage(name));
      final url = await recovered;
      expect(url, startsWith('http://127.0.0.1:'));
      expect(url, endsWith('/$name'));
      // The player streams the queued path from there until it is whole.
      expect(registered, [receivedPath(name)]);
    });

    test('asks the next phone when one cannot send it', () async {
      connected = {_phone, 'phone-2'};
      final phone = sources();
      final name = '${_fileId(1)}.flac';
      final recovered = phone.recover(receivedPath(name));
      await pumpEventQueue();
      phone.onMessage(_phone, {
        'type': LinkMessageTypes.filesFailed,
        'name': name,
        'reason': 'not_found',
      });
      await pumpEventQueue();
      expect([for (final entry in sent) entry.deviceId], [_phone, 'phone-2']);

      phone.onMessage('phone-2', sendingMessage(name));
      expect(await recovered, endsWith('/$name'));
    });

    test('leaves other files and received files still there', () async {
      final name = '${_fileId(1)}.flac';
      File(receivedPath(name)).writeAsBytesSync([1, 2, 3]);
      final phone = sources();
      expect(await phone.recover(receivedPath(name)), isNull);
      expect(await phone.recover('${root.path}/$name'), isNull);
      expect(await phone.recover(receivedPath('cover.jpg')), isNull);
      expect(sent, isEmpty);
    });

    test('fails while no phone is connected', () async {
      connected = {};
      await expectLater(
        sources().recover(receivedPath('${_fileId(1)}.flac')),
        throwsA(linkError('unavailable')),
      );
      expect(sent, isEmpty);
    });
  });

  group('receive', () {
    test('waits for the whole song instead of streaming it', () async {
      final phone = sources();
      final name = '${_fileId(1)}.flac';
      final progress = <(int, int)>[];
      final whole = phone.receive(
        _phone,
        name,
        onProgress: (received, size) => progress.add((received, size)),
      );
      await pumpEventQueue();
      expect(sent.single.message, {
        'type': LinkMessageTypes.filesRequest,
        'name': name,
      });
      phone.onMessage(_phone, sendingMessage(name));
      var done = false;
      unawaited(whole.then((_) => done = true));
      // The upload's part file grows as the phone sends it.
      File('${received.path}/.$name.1.part').writeAsBytesSync([1, 2, 3]);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(done, isFalse);
      expect(progress, contains((3, 6)));
      File('${received.path}/.$name.1.part').deleteSync();
      File('${received.path}/$name').writeAsBytesSync([1, 2, 3, 4, 5, 6]);
      expect(await whole, '${received.path}${Platform.pathSeparator}$name');
      expect(progress.last, (6, 6));
    });

    test('takes a received file without asking the phone', () async {
      final file = File('${received.path}/${_fileId(1)}.flac')
        ..writeAsBytesSync([1]);
      expect(await sources().receive(_phone, '${_fileId(1)}.flac'), file.path);
      expect(sent, isEmpty);
    });

    test('shares one request with a play of the same song', () async {
      final phone = sources();
      final name = '${_fileId(1)}.flac';
      final playing = phone.resolve(sourceId, name);
      final whole = phone.receive(_phone, name);
      await pumpEventQueue();
      expect(sent, hasLength(1));
      phone.onMessage(_phone, sendingMessage(name));
      expect(await playing, startsWith('http://127.0.0.1:'));
      File('${received.path}/$name').writeAsBytesSync([1, 2, 3, 4, 5, 6]);
      expect(await whole, endsWith(name));
      expect(sent, hasLength(1));
    });

    test('fails as the phone answers', () async {
      final phone = sources();
      final name = '${_fileId(1)}.flac';
      final whole = phone.receive(_phone, name);
      await pumpEventQueue();
      phone.onMessage(_phone, {
        'type': LinkMessageTypes.filesFailed,
        'name': name,
        'reason': 'not_found',
      });
      await expectLater(whole, throwsA(linkError('unavailable')));
      await expectLater(
        phone.receive(_phone, '../secret.flac'),
        throwsFormatException,
      );
    });
  });

  group('deletion', () {
    test(
      'Library deletion reaches the phone and waits for confirmation',
      () async {
        final original = File('${root.path}/phone-song.flac')
          ..writeAsStringSync('audio');
        final rows = FakeLibraryRows([linkLocalRow(original.path)]);
        final library = rows.library();
        final shared = (await library.catalog()).songs.single;
        await commit([shared]);
        final client = _LyricsClient();
        addTearDown(client.close);
        final gate = Completer<void>();
        final started = Completer<void>();
        final phone = LinkPhoneFileRequests(
          client: client,
          library: library,
          files: LinkPhoneFiles(),
          deleteSharedFile: (path) async {
            expect(path, original.path);
            started.complete();
            await gate.future;
            if (!await deleteFile(
              path,
              deletionEvents: SourceDeletionEvents(),
            )) {
              return false;
            }
            rows.rows.clear();
            rows.bump();
            return true;
          },
        )..start();
        addTearDown(phone.dispose);
        final desktop = sources();
        addTearDown(desktop.close);
        client.onReply = (message) => desktop.onMessage(_phone, message);
        sendOverride = (message, deviceId) async {
          expect(deviceId, _phone);
          client.push(message);
          return 1;
        };
        final storage = NetworkStorageService(
          read: () async {
            fail('Virtual phone songs must not use saved NAS connections');
          },
        )..virtualSources = desktop;
        addTearDown(storage.dispose);
        final source = NetworkStorageService.source(sourceId, shared.name);
        final events = SourceDeletionEvents();
        final removed = <String>[];
        events.subscribe((source) async => removed.add(source));
        expect(await storage.canDeleteFile(source), isTrue);
        final pending = deleteFile(
          source,
          networkStorage: storage,
          deletionEvents: events,
        );
        await started.future;
        expect(await original.exists(), isTrue);
        expect(removed, isEmpty);
        expect(await desktop.songs(sourceId).toList(), hasLength(1));
        gate.complete();
        expect(await pending, isTrue);
        expect(await original.exists(), isFalse);
        expect(removed, [source]);
        expect(await desktop.songs(sourceId).toList(), isEmpty);
        expect((await library.catalog()).songs, isEmpty);
        expect(client.uploads, isEmpty);
      },
    );

    test(
      'only the matching phone, request and song can confirm deletion',
      () async {
        final shared = song(1);
        await commit([shared]);
        final desktop = sources();
        addTearDown(desktop.close);
        final asked = Completer<Map<String, dynamic>>();
        sendOverride = (message, _) async {
          asked.complete(message);
          return 1;
        };
        var completed = false;
        final pending = desktop.deleteFile(sourceId, shared.name).then((value) {
          completed = true;
          return value;
        });
        final request = await asked.future;
        final reply = {
          ...request,
          'type': LinkMessageTypes.filesDeleted,
          'deleted': true,
        };
        desktop.onMessage('another-phone', reply);
        desktop.onMessage(_phone, {...reply, 'requestId': 'another-request'});
        desktop.onMessage(_phone, {...reply, 'name': song(2).name});
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);
        expect(await catalogs.song(sourceId, shared.fileId), isNotNull);
        desktop.onMessage(_phone, reply);
        expect(await pending, isTrue);
      },
    );

    for (final outcome in [
      'timeout',
      'failed',
      'disconnect',
      'closed',
      'not_sent',
    ]) {
      test('$outcome keeps the shared song indexed', () async {
        final shared = song(1);
        await commit([shared]);
        final desktop = sources(
          deleteTimeout: const Duration(milliseconds: 20),
        );
        addTearDown(desktop.close);
        sendOverride = (message, _) async {
          switch (outcome) {
            case 'failed':
              desktop.onMessage(_phone, {
                ...message,
                'type': LinkMessageTypes.filesDeleted,
                'deleted': false,
                'error': 'delete_failed',
              });
            case 'disconnect':
              desktop.keepConnected({});
            case 'closed':
              desktop.close();
          }
          return outcome == 'not_sent' ? 0 : 1;
        };
        expect(await desktop.deleteFile(sourceId, shared.name), isFalse);
        expect(await catalogs.song(sourceId, shared.fileId), isNotNull);
      });
    }

    test(
      'offline phones, unknown songs and malformed paths are rejected',
      () async {
        final shared = song(1);
        await commit([shared]);
        final desktop = sources();
        addTearDown(desktop.close);
        final storage = NetworkStorageService()..virtualSources = desktop;
        addTearDown(storage.dispose);
        for (final path in [
          'network://$sourceId/',
          'network://$sourceId/${shared.name}?delete=true',
          'network://$sourceId/album%2F${shared.name}',
          'network://$sourceId/${shared.fileId}.mp3',
          'network://$sourceId/${song(2).name}',
        ]) {
          expect(await storage.canDeleteFile(path), isFalse);
          expect(await storage.deleteFile(path), isFalse);
        }
        connected.clear();
        expect(await desktop.deleteFile(sourceId, shared.name), isFalse);
        expect(sent, isEmpty);
      },
    );

    test(
      'stale catalogs cannot resurrect confirmed deletions after restart',
      () async {
        final shared = song(1);
        await commit([shared]);
        await catalogs.recordDeleted(_phone, shared.fileId);
        await commit([shared, song(2)]);
        catalogs = LinkPhoneCatalogs(
          root: () async => root,
          paired: (_) async => true,
        );
        expect((await catalogs.songs(sourceId).toList()).map((s) => s.fileId), [
          song(2).fileId,
        ]);
        expect(await catalogs.song(sourceId, shared.fileId), isNull);
        await commit([song(2)]);
        // A deliberate later re-import can be shown once absence was synced.
        await commit([shared, song(2)]);
        expect(await catalogs.song(sourceId, shared.fileId), isNotNull);
      },
    );
  });

  group('metadata', () {
    test(
      'phone file lyrics reach the desktop player without audio transfer',
      () async {
        final original = File('${root.path}/old-download.flac')
          ..writeAsStringSync('original audio');
        final fileId = linkFileIdFor(original.path, original.lengthSync());
        await commit([
          LinkPhoneSong(
            fileId: fileId,
            suffix: 'flac',
            title: 'Old download',
            artist: 'Fixture artist',
          ),
        ]);
        final client = _LyricsClient();
        addTearDown(client.close);
        final phone = LinkPhoneFileRequests(
          client: client,
          library: FakeLibraryRows([linkLocalRow(original.path)]).library(),
          files: LinkPhoneFiles(),
          readLyrics: (path) async {
            expect(path, original.path);
            return '[00:01.00]Embedded before Link existed';
          },
        )..start();
        addTearDown(phone.dispose);
        final desktop = sources(lyricsTimeout: const Duration(seconds: 5));
        addTearDown(desktop.close);
        client.onReply = (message) => desktop.onMessage(_phone, message);
        sendOverride = (message, _) async {
          client.push(message);
          return 1;
        };
        final controller = PlayerMetadataController(
          readMetadata: (_) => desktop.metadata(sourceId, '$fileId.flac'),
          parseLyrics: (text) async => LyricsParser.parse(text),
        );
        addTearDown(controller.dispose);
        await controller.load(
          MediaItem(
            id: fileId,
            title: 'Old download',
            extras: {'source': 'network://$sourceId/$fileId.flac'},
          ),
        );
        expect(
          controller.lyrics.lines.single.text,
          'Embedded before Link existed',
        );
        expect(client.uploads, isEmpty);
        expect(received.listSync(), isEmpty);
        expect(
          sent.single.message['type'],
          LinkMessageTypes.filesLyricsRequest,
        );
      },
    );

    test(
      'asks the phone for embedded lyrics missing from the catalog',
      () async {
        await commit([song(1)]);
        final phone = sources();
        final name = '${_fileId(1)}.flac';
        final pending = phone.metadata(sourceId, name);
        await pumpEventQueue();
        expect(sent, hasLength(1));
        final request = sent.single;
        expect(request.deviceId, _phone);
        expect(request.message['type'], 'files.lyrics.request');
        expect(request.message['name'], name);
        phone.onMessage(_phone, {
          'type': 'files.lyrics',
          'requestId': request.message['requestId'],
          'name': name,
          'lyrics': '[00:01.00]Embedded in an older download',
        });
        expect(
          (await pending)['lyrics'],
          '[00:01.00]Embedded in an older download',
        );
        expect(received.listSync(), isEmpty);
      },
    );

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

    test(
      'coalesces empty cached-file lyrics and rejects another phone reply',
      () async {
        await commit([song(1)]);
        final name = '${_fileId(1)}.flac';
        final cached = '${received.path}/$name';
        File(cached).writeAsStringSync('cached audio');
        tags[cached] = {'title': 'Cached', 'lyrics': ''};
        final phone = sources(lyricsTimeout: const Duration(seconds: 5));
        final first = phone.metadata(sourceId, name);
        final second = phone.metadata(sourceId, name);
        await pumpEventQueue();
        expect(sent, hasLength(1));
        final reply = {
          'type': LinkMessageTypes.filesLyrics,
          'requestId': sent.single.message['requestId'],
          'name': name,
          'lyrics': '[00:01]Original phone lyrics',
        };
        var complete = false;
        unawaited(first.then((_) => complete = true));
        phone.onMessage('another-phone', reply);
        phone.onMessage(_phone, {...reply, 'name': '${_fileId(2)}.flac'});
        await pumpEventQueue();
        expect(complete, isFalse);
        phone.onMessage(_phone, reply);
        for (final result in await Future.wait([first, second])) {
          expect(result['lyrics'], '[00:01]Original phone lyrics');
          expect(result['title'], 'Cached');
        }
      },
    );

    test('missing lyrics replies time out and can be tried again', () async {
      await commit([song(1)]);
      final phone = sources(lyricsTimeout: const Duration(milliseconds: 1));
      for (var attempt = 0; attempt < 2; attempt++) {
        expect(
          (await phone.metadata(sourceId, '${_fileId(1)}.flac'))['title'],
          'Song 1',
        );
      }
      expect(sent, hasLength(2));
      expect(
        sent.first.message['requestId'],
        isNot(sent.last.message['requestId']),
      );
    });

    test('oversized incoming lyrics cannot replace stored metadata', () async {
      await commit([song(1)]);
      final phone = sources(lyricsTimeout: const Duration(seconds: 5));
      final name = '${_fileId(1)}.flac';
      final pending = phone.metadata(sourceId, name);
      await pumpEventQueue();
      phone.onMessage(_phone, {
        'type': LinkMessageTypes.filesLyrics,
        'requestId': sent.single.message['requestId'],
        'name': name,
        'lyrics': 'あ' * (linkFileLyricsMaxBytes ~/ 2),
      });
      final metadata = await pending;
      expect(metadata['title'], 'Song 1');
      expect(metadata.containsKey('lyrics'), isFalse);
    });

    test('disconnect and close finish outstanding lyrics reads', () async {
      await commit([song(1)]);
      for (final close in [false, true]) {
        final phone = sources(lyricsTimeout: const Duration(seconds: 5));
        final pending = phone.metadata(sourceId, '${_fileId(1)}.flac');
        await pumpEventQueue();
        if (close) {
          phone.close();
        } else {
          phone.keepConnected({});
        }
        expect((await pending)['title'], 'Song 1');
        if (close) {
          final sentBefore = sent.length;
          await phone.metadata(sourceId, '${_fileId(1)}.flac');
          expect(sent, hasLength(sentBefore));
        }
      }
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
