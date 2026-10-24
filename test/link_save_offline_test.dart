import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:path/path.dart' as p;

import 'support/link_fakes.dart';

LocalLibraryItem _row(
  String songId, {
  String title = 'Song',
  String artist = 'Artist',
  String album = 'Album',
  String? format = 'flac',
  String? source,
}) => LocalLibraryItem(
  id: 'network_$songId',
  trackName: title,
  artistName: artist,
  albumName: album,
  filePath:
      source ??
      linkDesktopSongSource(linkTestServer, songId, format: format ?? 'raw'),
  scannedAt: DateTime(2026),
  isrc: 'USABC24000$songId',
  trackNumber: 3,
  duration: 200,
  format: format,
  bitDepth: 24,
  sampleRate: 96000,
);

class _FakeTransport implements LinkOfflineTransport {
  _FakeTransport({this.failing = const {}, this.onChunk});

  final Set<String> failing;
  final void Function(String songId)? onChunk;
  final requested = <String>[];
  int closed = 0;

  @override
  Future<void> download(
    String songId,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  }) async {
    requested.add(songId);
    final sink = output.openWrite();
    try {
      for (var chunk = 1; chunk <= 2; chunk++) {
        sink.add(List.filled(5, chunk));
        progress(chunk * 5, 10);
        onChunk?.call(songId);
        checkpoint();
        if (failing.contains(songId)) {
          throw const HttpException('Server returned 500');
        }
      }
    } finally {
      await sink.close();
    }
  }

  @override
  void close() => closed++;
}

class _FakeDestination implements LinkOfflineDestination {
  _FakeDestination(this.root, {this.saf = false});

  final Directory root;
  final bool saf;
  final stored = <({String relativeDir, String fileName, String mimeType})>[];

  @override
  Future<LinkOfflineStored> store(
    File file, {
    required String relativeDir,
    required String fileName,
    required String mimeType,
  }) async {
    stored.add((
      relativeDir: relativeDir,
      fileName: fileName,
      mimeType: mimeType,
    ));
    final target = File(p.join(root.path, relativeDir, fileName));
    await target.parent.create(recursive: true);
    await file.copy(target.path);
    if (saf) {
      return LinkOfflineStored(
        filePath: 'content://tree/doc/$fileName',
        storageMode: 'saf',
        treeUri: 'content://tree',
        relativeDir: relativeDir,
        fileName: fileName,
      );
    }
    return LinkOfflineStored(filePath: target.path, storageMode: 'app');
  }
}

void main() {
  late Directory temp;
  late Directory root;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('link_offline_temp');
    root = await Directory.systemTemp.createTemp('link_offline_root');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
    await root.delete(recursive: true);
  });

  LinkOfflineSaver saver(
    _FakeTransport transport,
    _FakeDestination destination,
    List<DownloadHistoryItem> records,
  ) => LinkOfflineSaver(
    connectionId: linkTestServer.connectionId,
    openTransport: () => transport,
    destination: destination,
    record: (item) async => records.add(item),
    temporaryDirectory: () async => temp,
    now: () => DateTime(2026, 10, 25),
  );

  test('only rows streamed from the paired desktop can be saved', () {
    final songs = linkOfflineSongs([
      _row('1'),
      _row('2', source: '/music/local.flac'),
      _row('3', source: 'network://conn-9/subsonic/song/Mw.flac'),
    ], linkTestServer);
    expect(songs.map((song) => song.songId), ['1']);
  });

  test('saves originals as Library downloads with their tags', () async {
    final transport = _FakeTransport(failing: {'2'});
    final destination = _FakeDestination(root);
    final records = <DownloadHistoryItem>[];
    final progress = <double>[];
    final result = await saver(transport, destination, records).save(
      linkOfflineSongs([
        _row('1', title: 'First: Part/One'),
        _row('2', title: 'Second'),
        _row('3', title: 'Third', album: '', format: null),
      ], linkTestServer),
      onProgress: (value) => progress.add(value.fraction),
    );

    expect(result.saved, 2);
    expect(result.failed, 1);
    expect(result.cancelled, isFalse);
    expect(transport.requested, ['1', '2', '3']);
    expect(transport.closed, 1);
    expect(progress.last, 1.0);
    expect(progress, orderedEquals([...progress]..sort()));

    expect(destination.stored.first.relativeDir, 'Artist/Album');
    expect(destination.stored.first.fileName, 'First Part One - Artist.flac');
    expect(destination.stored.first.mimeType, 'audio/flac');
    expect(destination.stored.last.relativeDir, 'Artist');
    expect(destination.stored.last.fileName, 'Third - Artist.audio');

    final first = records.first;
    expect(first.service, LinkOfflineSaver.service);
    expect(first.storageMode, 'app');
    expect(File(first.filePath).lengthSync(), 10);
    expect(first.trackName, 'First: Part/One');
    expect(first.isrc, 'USABC240001');
    expect(first.trackNumber, 3);
    expect(first.bitDepth, 24);
    expect(first.sampleRate, 96000);
    expect(first.downloadedAt, DateTime(2026, 10, 25));
    expect(first.id, saver(transport, destination, records).historyId('1'));
    expect(first.id, isNot(records.last.id));
    // Temporary downloads are gone, saved or not.
    expect(temp.listSync(), isEmpty);
  });

  test('records the storage access location in saf mode', () async {
    final records = <DownloadHistoryItem>[];
    await saver(
      _FakeTransport(),
      _FakeDestination(root, saf: true),
      records,
    ).save(linkOfflineSongs([_row('1')], linkTestServer));
    final item = records.single;
    expect(item.storageMode, 'saf');
    expect(item.filePath, startsWith('content://'));
    expect(item.downloadTreeUri, 'content://tree');
    expect(item.safRelativeDir, 'Artist/Album');
    expect(item.safFileName, 'Song - Artist.flac');
  });

  test('cancel stops the run and discards the song in flight', () async {
    final cancel = LinkOfflineCancel();
    final transport = _FakeTransport(
      onChunk: (songId) {
        if (songId == '2') cancel.cancel();
      },
    );
    final destination = _FakeDestination(root);
    final records = <DownloadHistoryItem>[];
    final result = await saver(transport, destination, records).save(
      linkOfflineSongs([_row('1'), _row('2'), _row('3')], linkTestServer),
      cancel: cancel,
    );
    expect(result.cancelled, isTrue);
    expect(result.saved, 1);
    expect(result.failed, 0);
    expect(transport.requested, ['1', '2']);
    expect(records, hasLength(1));
    // Cancelling closes the connection at once, and the run closes it again.
    expect(transport.closed, 2);
    expect(temp.listSync(), isEmpty);
  });
}
