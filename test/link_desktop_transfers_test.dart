import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/desktop/link_desktop_transfers.dart';
import 'package:mornye/services/link/desktop/link_transfer_songs.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';

import 'support/link_desktop_fakes.dart';

const _phone = 'phone-1';

String _fileId(int i) => i.toRadixString(16).padLeft(32, '0');

String _transferId(int i) => i.toRadixString(16).padLeft(32, 'a');

typedef _Fetch =
    Future<String> Function(
      String name,
      void Function(int received, int size)? onProgress,
    );

void main() {
  late Directory received;
  late Directory music;
  late ProviderContainer container;
  late FakeTransferDownloads downloads;
  late LinkTransferDownloads Function() downloadsOf;
  late List<({Map<String, dynamic> message, String deviceId})> sent;
  late Set<String> connected;
  late int delivered;
  late DesktopLinkCatalogIndex? index;
  late List<String> fetched;
  late _Fetch fetch;
  late List<String> savedFrom;
  late List<LinkTransfer> offered;
  late DateTime clock;
  final coverId = _fileId(0xc0);

  /// Writes the phone song [name] into the received folder, as an upload.
  String receivedFile(String name) {
    final file = File('${received.path}/$name')..writeAsBytesSync([1, 2, 3]);
    return file.path;
  }

  setUp(() async {
    received = await Directory.systemTemp.createTemp('link-received-');
    music = await Directory.systemTemp.createTemp('link-music-');
    container = ProviderContainer();
    downloads = FakeTransferDownloads(music);
    downloadsOf = () => downloads;
    sent = [];
    connected = {_phone};
    delivered = 1;
    index = DesktopLinkCatalogIndex(serverId: 'server-1', songs: const []);
    fetched = [];
    fetch = (name, onProgress) async {
      onProgress?.call(1, 3);
      return receivedFile(name);
    };
    savedFrom = [];
    offered = [];
    clock = DateTime(2026, 10, 25, 12);
  });

  final engines = <LinkDesktopTransfers>[];

  tearDown(() async {
    for (final engine in engines) {
      engine.close();
    }
    engines.clear();
    container.dispose();
    await received.delete(recursive: true);
    await music.delete(recursive: true);
  });

  LinkTransfers store() => container.read(linkTransfersProvider.notifier);

  LinkDesktopTransfers transfers() {
    var ids = 0;
    final engine = LinkDesktopTransfers(
      store: store,
      send: (message, deviceId) async {
        sent.add((message: message, deviceId: deviceId));
        return delivered;
      },
      fetch: (deviceId, name, {onProgress}) {
        fetched.add(name);
        return fetch(name, onProgress);
      },
      index: () => index,
      downloads: () => downloadsOf(),
      connected: connected.contains,
      deviceName: (deviceId) => deviceId == _phone ? 'Pixel' : deviceId,
      isPhone: (deviceId) async => deviceId.startsWith('phone-'),
      covers: (_) async => {coverId: '/covers/$coverId.jpg'},
      onSaved: savedFrom.add,
      onOffer: offered.add,
      now: () => clock,
      newId: () => _transferId(++ids),
    );
    engines.add(engine);
    return engine;
  }

  LinkPhoneSong song(
    int i, {
    String? title,
    String? isrc,
    String? cover,
    String suffix = 'flac',
  }) => LinkPhoneSong(
    fileId: _fileId(i),
    suffix: suffix,
    title: title ?? 'Song $i',
    artist: 'Artist',
    album: 'Album',
    albumArtist: 'Band',
    track: i,
    year: 2020,
    durationMs: 200000,
    isrc: isrc,
    bitRate: 900,
    sampleRate: 44100,
    bitDepth: 16,
    size: 3,
    coverId: cover,
  );

  Future<Object?> offer(
    LinkDesktopTransfers engine,
    List<Object?> songs, {
    Object? transferId,
    String deviceId = _phone,
  }) {
    final router = LinkHostRouter();
    engine.register(router);
    return router.dispatch(
      LinkRequest(
        requestId: 'r1',
        op: LinkOps.transfersOffer,
        deviceId: deviceId,
        args: {
          '_method': 'POST',
          'transferId': transferId ?? _transferId(0x51),
          'songs': songs,
        },
      ),
    );
  }

  List<Map<String, dynamic>> statuses([String? transferId]) => [
    for (final entry in sent)
      if (entry.message['type'] == LinkMessageTypes.transfersStatus &&
          (transferId == null || entry.message['transferId'] == transferId))
        entry.message,
  ];

  String steps(List<Map<String, dynamic>> messages) => [
    for (final message in messages) '${message['state']}:${message['index']}',
  ].join(' ');

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(done(), isTrue, reason: 'timed out');
  }

  bool finished(String id) => store().byId(id)?.active == false;

  Matcher linkError(String code) =>
      isA<LinkException>().having((error) => error.code, 'code', code);

  group('incoming', () {
    test('saves offered songs as downloads, skipping ones it has', () async {
      index = DesktopLinkCatalogIndex(
        serverId: 'server-1',
        songs: [catalogSong('l:same', title: 'Other', isrc: 'USAAA0000001')],
      );
      final engine = transfers();
      final id = _transferId(0x51);
      final reply = await offer(engine, [
        song(1, cover: coverId).toJson(),
        song(2, isrc: 'USAAA0000001').toJson(),
        {'fileId': 'not-a-file', 'suffix': 'flac', 'title': 'Bad'},
      ]);
      expect(reply, {'accepted': 2});
      expect(offered, hasLength(1));
      final transfer = offered.single;
      expect(transfer.direction, LinkTransferDirection.incoming);
      expect(transfer.peerId, _phone);
      expect(transfer.peerName, 'Pixel');
      expect(
        [for (final entry in transfer.entries) entry.title],
        ['Song 1', 'Song 2'],
      );
      expect(transfer.entries.first.coverPath, '/covers/$coverId.jpg');
      expect(transfer.entries.last.coverPath, isNull);

      await until(() => finished(id));
      expect(fetched, ['${_fileId(1)}.flac']);
      final record = downloads.records.single;
      expect(record.id, linkTransferHistoryId(_phone, '${_fileId(1)}.flac'));
      expect(record.id, startsWith('link_'));
      expect(record.service, 'Mornye Link');
      expect(record.trackName, 'Song 1');
      expect(record.albumName, 'Album');
      expect(record.albumArtist, 'Band');
      expect(record.trackNumber, 1);
      expect(record.duration, 200);
      expect(record.releaseDate, '2020');
      expect(record.format, 'flac');
      expect(record.storageMode, 'app');
      expect(record.downloadedAt, clock);
      final sep = Platform.pathSeparator;
      expect(
        record.filePath,
        '${music.path}${sep}Band${sep}Album${sep}Song 1 - Artist.flac',
      );
      expect(File(record.filePath).existsSync(), isTrue);
      // The received file stays for playback until the folder is pruned.
      expect(File('${received.path}/${_fileId(1)}.flac').existsSync(), isTrue);

      expect(steps(statuses(id)), 'queued:0 running:0 running:1 done:2');
      expect(statuses(id).last['skipped'], [1]);
      expect(sent.every((entry) => entry.deviceId == _phone), isTrue);
      final status = store().byId(id)!.status;
      expect(status.state, LinkTransferState.done);
      expect(status.saved, 1);
      expect(status.skipped, [1]);
      expect(savedFrom, [_phone]);
    });

    test('answers an offer sent again and refuses bad ones', () async {
      final engine = transfers();
      expect(await offer(engine, [song(1).toJson()]), {'accepted': 1});
      expect(await offer(engine, [song(2).toJson()]), {'accepted': 1});
      expect(offered, hasLength(1));
      await expectLater(
        offer(engine, [song(1).toJson()], transferId: 'nope'),
        throwsA(linkError('invalid')),
      );
      await expectLater(
        offer(engine, [
          {'title': 'No file'},
        ], transferId: _transferId(0x52)),
        throwsA(linkError('invalid')),
      );
      await expectLater(
        offer(
          engine,
          [song(1).toJson()],
          transferId: _transferId(0x53),
          deviceId: 'subsonic-app',
        ),
        throwsA(linkError('invalid')),
      );
      // Another phone cannot take over a transfer id.
      await expectLater(
        offer(engine, [song(1).toJson()], deviceId: 'phone-2'),
        throwsA(linkError('invalid')),
      );
    });

    test('fails a song the phone cannot send and goes on', () async {
      fetch = (name, _) async {
        if (name.startsWith(_fileId(1))) {
          throw const LinkException('unavailable', 'not_found');
        }
        return receivedFile(name);
      };
      final engine = transfers();
      final id = _transferId(0x51);
      await offer(engine, [song(1).toJson(), song(2).toJson()]);
      await until(() => finished(id));
      final status = store().byId(id)!.status;
      expect(status.state, LinkTransferState.done);
      expect(status.failed, [0]);
      expect(status.saved, 1);
      expect(downloads.records.single.trackName, 'Song 2');
    });

    test('a record that fails leaves no copy behind', () async {
      downloads.recordError = StateError('database');
      final engine = transfers();
      final id = _transferId(0x51);
      await offer(engine, [song(1).toJson()]);
      await until(() => finished(id));
      expect(store().byId(id)!.status.failed, [0]);
      expect(music.listSync(recursive: true).whereType<File>(), isEmpty);
      expect(savedFrom, isEmpty);
    });

    test('skips a song an earlier transfer saved', () async {
      downloads.held.add(linkTransferHistoryId(_phone, '${_fileId(1)}.flac'));
      final engine = transfers();
      final id = _transferId(0x51);
      await offer(engine, [song(1).toJson()]);
      await until(() => finished(id));
      expect(fetched, isEmpty);
      expect(store().byId(id)!.status.skipped, [0]);
    });

    test('fails without a download folder', () async {
      downloadsOf = () => throw StateError('no folder');
      final engine = transfers();
      final id = _transferId(0x51);
      await offer(engine, [song(1).toJson()]);
      await until(() => finished(id));
      final status = store().byId(id)!.status;
      expect(status.state, LinkTransferState.failed);
      expect(status.reason, 'no_folder');
      expect(statuses(id).last['reason'], 'no_folder');
    });

    test('runs one transfer at a time, in arrival order', () async {
      final first = Completer<String>();
      fetch = (name, _) async =>
          name.startsWith(_fileId(1)) ? await first.future : receivedFile(name);
      final engine = transfers();
      await offer(engine, [song(1).toJson()], transferId: _transferId(0x51));
      await offer(engine, [song(2).toJson()], transferId: _transferId(0x52));
      await until(() => fetched.isNotEmpty);
      await pumpEventQueue();
      expect(fetched, ['${_fileId(1)}.flac']);
      expect(
        store().byId(_transferId(0x52))!.status.state,
        LinkTransferState.queued,
      );
      first.complete(receivedFile('${_fileId(1)}.flac'));
      await until(() => finished(_transferId(0x52)));
      expect(fetched, ['${_fileId(1)}.flac', '${_fileId(2)}.flac']);
      expect(downloads.records, hasLength(2));
    });

    test('the phone cancels a running transfer', () async {
      fetch = (name, _) => Completer<String>().future;
      final engine = transfers();
      final id = _transferId(0x51);
      await offer(engine, [song(1).toJson(), song(2).toJson()]);
      await until(() => fetched.isNotEmpty);
      final cancel = {
        'type': LinkMessageTypes.transfersCancel,
        'transferId': id,
      };
      // Only the phone that offered it can.
      expect(engine.onMessage('phone-2', cancel), isTrue);
      await pumpEventQueue();
      expect(store().byId(id)!.active, isTrue);
      expect(engine.onMessage(_phone, cancel), isTrue);
      await until(() => finished(id));
      final status = store().byId(id)!.status;
      expect(status.state, LinkTransferState.cancelled);
      expect(status.index, 0);
      expect(downloads.records, isEmpty);
      expect(statuses(id).last['state'], 'cancelled');
    });

    test('the Transfers list cancels a queued transfer at once', () async {
      final first = Completer<String>();
      fetch = (name, _) => first.future;
      final engine = transfers();
      await offer(engine, [song(1).toJson()], transferId: _transferId(0x51));
      await offer(engine, [song(2).toJson()], transferId: _transferId(0x52));
      store().cancel(_transferId(0x52));
      expect(
        store().byId(_transferId(0x52))!.status.state,
        LinkTransferState.cancelled,
      );
      expect(statuses(_transferId(0x52)).last['state'], 'cancelled');
      store().cancel(_transferId(0x51));
      await until(() => finished(_transferId(0x51)));
      expect(fetched, ['${_fileId(1)}.flac']);
    });

    test('a phone that drops fails its transfers silently', () async {
      fetch = (name, _) => Completer<String>().future;
      final engine = transfers();
      await offer(engine, [song(1).toJson()], transferId: _transferId(0x51));
      await offer(engine, [song(2).toJson()], transferId: _transferId(0x52));
      await until(() => fetched.isNotEmpty);
      final before = sent.length;
      connected = {};
      engine.keepConnected(const {});
      await until(() => finished(_transferId(0x51)));
      for (final id in [_transferId(0x51), _transferId(0x52)]) {
        final status = store().byId(id)!.status;
        expect(status.state, LinkTransferState.failed);
        expect(status.reason, 'disconnected');
      }
      expect(sent, hasLength(before));
    });

    test('reports byte progress at most four times a second', () async {
      fetch = (name, onProgress) async {
        for (var i = 1; i <= 10; i++) {
          clock = clock.add(const Duration(milliseconds: 100));
          onProgress!(i * 100, 1000);
        }
        return receivedFile(name);
      };
      final engine = transfers();
      final id = _transferId(0x51);
      await offer(engine, [song(1).toJson()]);
      await until(() => finished(id));
      final progress = [
        for (final status in statuses(id))
          if ((status['received'] ?? 0) as int > 0)
            (status['received'], status['size']),
      ];
      expect(progress, [(300, 1000), (600, 1000), (900, 1000)]);
    });

    test('Save to this computer runs as an incoming transfer', () async {
      final engine = transfers();
      final started = engine.receive(_phone, [
        (song: song(1), coverPath: '/covers/one.jpg'),
      ]);
      expect(started.single.entries.single.coverPath, '/covers/one.jpg');
      expect(offered, isEmpty);
      await until(() => finished(started.single.id));
      expect(downloads.records, hasLength(1));
      expect(statuses(started.single.id).first['state'], 'queued');
    });
  });

  group('outgoing', () {
    LinkOutgoingSong outgoing(int i) => (
      song: LinkTransferSong(
        songId: 'd:$i',
        suffix: 'flac',
        title: 'Desk $i',
        artist: 'Artist',
        album: 'Album',
        size: 1000,
      ),
      coverPath: '/covers/$i.jpg',
    );

    test('offers songs and follows the phone status', () async {
      final engine = transfers();
      final started = await engine.send(_phone, [outgoing(1), outgoing(2)]);
      final transfer = started.single;
      expect(transfer.direction, LinkTransferDirection.outgoing);
      expect(transfer.peerName, 'Pixel');
      expect(transfer.entries.first.coverPath, '/covers/1.jpg');
      expect(transfer.status.state, LinkTransferState.queued);
      final message = sent.single.message;
      expect(sent.single.deviceId, _phone);
      expect(message['type'], LinkMessageTypes.transfersOffer);
      expect(message['transferId'], transfer.id);
      expect(message['songs'], [
        outgoing(1).song.toJson(),
        outgoing(2).song.toJson(),
      ]);

      Map<String, dynamic> status(LinkTransferState state, int index) => {
        'type': LinkMessageTypes.transfersStatus,
        ...LinkTransferStatus(
          transferId: transfer.id,
          state: state,
          total: 2,
          index: index,
        ).toJson(),
      };
      // Another phone's status does not count.
      expect(
        engine.onMessage('phone-2', status(LinkTransferState.running, 1)),
        isTrue,
      );
      expect(store().byId(transfer.id)!.status.state, LinkTransferState.queued);
      engine.onMessage(_phone, status(LinkTransferState.running, 1));
      expect(store().byId(transfer.id)!.status.index, 1);
      engine.onMessage(_phone, status(LinkTransferState.done, 2));
      expect(store().byId(transfer.id)!.status.state, LinkTransferState.done);
      // A finished transfer takes no more status.
      engine.onMessage(_phone, status(LinkTransferState.running, 1));
      expect(store().byId(transfer.id)!.status.state, LinkTransferState.done);
    });

    test('splits a large choice into offers of at most 1000 songs', () async {
      final engine = transfers();
      final started = await engine.send(_phone, [
        for (var i = 0; i < linkTransferOfferLimit + 1; i++) outgoing(i),
      ]);
      expect(
        [for (final transfer in started) transfer.status.total],
        [linkTransferOfferLimit, 1],
      );
      expect(sent, hasLength(2));
    });

    test('cancel asks the phone, or ends at once without it', () async {
      final engine = transfers();
      final first = (await engine.send(_phone, [outgoing(1)])).single;
      store().cancel(first.id);
      await pumpEventQueue();
      expect(sent.last.message, {
        'type': LinkMessageTypes.transfersCancel,
        'transferId': first.id,
      });
      expect(store().byId(first.id)!.active, isTrue);
      engine.onMessage(_phone, {
        'type': LinkMessageTypes.transfersStatus,
        ...LinkTransferStatus(
          transferId: first.id,
          state: LinkTransferState.cancelled,
          total: 1,
        ).toJson(),
      });
      expect(store().byId(first.id)!.status.state, LinkTransferState.cancelled);

      final second = (await engine.send(_phone, [outgoing(2)])).single;
      delivered = 0;
      store().cancel(second.id);
      await pumpEventQueue();
      expect(
        store().byId(second.id)!.status.state,
        LinkTransferState.cancelled,
      );
    });

    test('fails when the phone is gone', () async {
      final engine = transfers();
      delivered = 0;
      final undelivered = (await engine.send(_phone, [outgoing(1)])).single;
      expect(store().byId(undelivered.id)!.status.reason, 'disconnected');

      delivered = 1;
      final active = (await engine.send(_phone, [outgoing(2)])).single;
      engine.keepConnected({'phone-2'});
      final status = store().byId(active.id)!.status;
      expect(status.state, LinkTransferState.failed);
      expect(status.reason, 'disconnected');
    });
  });
}
