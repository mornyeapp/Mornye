import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:mornye/models/download_item.dart';

typedef DownloadQueueSavedItem = ({DownloadItem? item, String? payload});

const _workerItemThreshold = 64;
const _workerPayloadThreshold = 64 * 1024;
const _workerChunkSize = 1024;

DownloadStatus downloadQueuePersistenceStatus(
  DownloadStatus status, {
  DownloadErrorType? errorType,
}) => switch (status) {
  DownloadStatus.failed
      when errorType == DownloadErrorType.verificationRequired =>
    DownloadStatus.queued,
  DownloadStatus.downloading ||
  DownloadStatus.finalizing => DownloadStatus.queued,
  _ => status,
};

/// True when [a] and [b] serialize to the exact same durable queue row,
/// ignoring volatile transfer metrics (progress, speed, byte counts, stage).
bool samePersistedDownloadItem(DownloadItem a, DownloadItem b) =>
    identical(a, b) ||
    (a.id == b.id &&
        identical(a.track, b.track) &&
        a.service == b.service &&
        downloadQueuePersistenceStatus(a.status, errorType: a.errorType) ==
            downloadQueuePersistenceStatus(b.status, errorType: b.errorType) &&
        a.filePath == b.filePath &&
        a.error == b.error &&
        a.errorType == b.errorType &&
        a.createdAt == b.createdAt &&
        a.qualityOverride == b.qualityOverride &&
        a.playlistName == b.playlistName &&
        a.playlistPosition == b.playlistPosition &&
        a.fromBatch == b.fromBatch &&
        a.preserveQualityVariant == b.preserveQualityVariant &&
        a.networkDownloadFolder == b.networkDownloadFolder);

/// Transfer samples are transient; only restart-relevant state reaches SQLite.
String encodeDownloadQueueItemForPersistence(DownloadItem item) => jsonEncode(
  item.toJson()
    ..['status'] = downloadQueuePersistenceStatus(
      item.status,
      errorType: item.errorType,
    ).name
    ..['progress'] = 0.0
    ..['speedMBps'] = 0.0
    ..['bytesReceived'] = 0
    ..['bytesTotal'] = 0
    ..['preparationStage'] = '',
);

class RestoredDownloadQueue {
  RestoredDownloadQueue({required this.items, required this.saved});

  final List<DownloadItem> items;
  final Map<String, DownloadQueueSavedItem> saved;
}

RestoredDownloadQueue _decodeRows(List<Map<String, dynamic>> rows) {
  final saved = <String, DownloadQueueSavedItem>{};
  final pending = <DownloadItem>[];
  for (final row in rows) {
    final id = row['id']?.toString() ?? '';
    // Retain corrupt IDs so the next successful flush deletes those rows.
    saved[id] = (item: null, payload: null);
    final payload = row['item_json'];
    if (id.isEmpty || payload is! String || payload.isEmpty) continue;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) continue;
      var item = DownloadItem.fromJson(Map<String, dynamic>.from(decoded));
      final status = downloadQueuePersistenceStatus(
        item.status,
        errorType: item.errorType,
      );
      saved[id] = (
        item: item,
        payload:
            row['status']?.toString() == status.name &&
                payload == encodeDownloadQueueItemForPersistence(item)
            ? payload
            : null,
      );
      if (item.status != status) {
        item = item.copyWith(status: status, progress: 0);
      }
      // Failed and cancelled songs come back shown, not restarted.
      if (status == DownloadStatus.queued ||
          status == DownloadStatus.skipped ||
          status == DownloadStatus.failed) {
        pending.add(item);
      }
    } catch (_) {
      continue;
    }
  }
  return RestoredDownloadQueue(items: pending, saved: saved);
}

bool _largeRows(List<Map<String, dynamic>> rows) {
  if (rows.length >= _workerItemThreshold) return true;
  var length = 0;
  for (final row in rows) {
    final payload = row['item_json'];
    if (payload is String) length += payload.length;
    if (length >= _workerPayloadThreshold) return true;
  }
  return false;
}

/// Keep ordinary queues inline. Large JSON/model work runs off the UI isolate;
/// bounded requests avoid copying an unbounded queue when starting a worker.
Future<RestoredDownloadQueue> decodeDownloadQueueRows(
  List<Map<String, dynamic>> rows,
) async {
  if (!_largeRows(rows)) return _decodeRows(rows);
  return _runQueueCodecWorker<RestoredDownloadQueue>(
    _QueueCodecMode.restore,
    rows,
  );
}

List<String> _encodeItems(List<DownloadItem> items) => [
  for (final item in items) encodeDownloadQueueItemForPersistence(item),
];

bool _largeItems(List<DownloadItem> items) {
  if (items.length >= _workerItemThreshold) return true;
  var length = 0;
  for (final item in items) {
    final track = item.track;
    // A single long comment/URL can be expensive too. Inspect existing strings
    // without invoking toJson on the UI isolate or allocating payload maps.
    length +=
        item.id.length +
        item.service.length +
        (item.filePath?.length ?? 0) +
        (item.error?.length ?? 0) +
        (item.qualityOverride?.length ?? 0) +
        (item.playlistName?.length ?? 0) +
        item.networkDownloadFolder.length +
        track.id.length +
        track.name.length +
        track.artistName.length +
        track.albumName.length +
        (track.albumArtist?.length ?? 0) +
        (track.artistId?.length ?? 0) +
        (track.albumId?.length ?? 0) +
        (track.coverUrl?.length ?? 0) +
        (track.headerVideoUrl?.length ?? 0) +
        (track.isrc?.length ?? 0) +
        (track.previewUrl?.length ?? 0) +
        (track.releaseDate?.length ?? 0) +
        (track.deezerId?.length ?? 0) +
        (track.source?.length ?? 0) +
        (track.albumType?.length ?? 0) +
        (track.composer?.length ?? 0) +
        (track.genre?.length ?? 0) +
        (track.label?.length ?? 0) +
        (track.copyright?.length ?? 0) +
        (track.comment?.length ?? 0) +
        (track.itemType?.length ?? 0) +
        (track.audioQuality?.length ?? 0) +
        (track.audioModes?.length ?? 0) +
        (track.upc?.length ?? 0) +
        (track.availability?.tidalUrl?.length ?? 0) +
        (track.availability?.qobuzUrl?.length ?? 0) +
        (track.availability?.amazonUrl?.length ?? 0) +
        (track.availability?.deezerUrl?.length ?? 0) +
        (track.availability?.deezerId?.length ?? 0);
    if (length >= _workerPayloadThreshold) return true;
  }
  return false;
}

/// Only cache misses enter this codec. A sparse progress change in a large
/// queue keeps the inexpensive inline path and leaves untouched tracks alone.
Future<List<String>> encodeDownloadQueueItems(List<DownloadItem> items) async {
  if (!_largeItems(items)) return _encodeItems(items);
  return _runQueueCodecWorker<List<String>>(_QueueCodecMode.persist, items);
}

enum _QueueCodecMode { restore, persist }

typedef _QueueWorkerRequest = ({SendPort replies, _QueueCodecMode mode});

Future<T> _runQueueCodecWorker<T>(
  _QueueCodecMode mode,
  List<Object> values,
) async {
  final replies = ReceivePort();
  final ready = Completer<SendPort>();
  final result = Completer<T>();
  Completer<void>? acknowledgement;
  result.future.ignore();
  final subscription = replies.listen((Object? message) {
    if (message is SendPort) {
      ready.complete(message);
    } else if (message == true) {
      acknowledgement?.complete();
    } else if (message is List<Object?> && message.length == 1) {
      result.complete(message.single as T);
    } else if (!result.isCompleted) {
      final error = message is List<Object?> && message.length == 2
          ? RemoteError(message[0].toString(), message[1].toString())
          : StateError('Download queue worker exited without a result');
      if (!ready.isCompleted) ready.completeError(error);
      result.completeError(error);
      if (acknowledgement case final pending? when !pending.isCompleted) {
        pending.completeError(error);
      }
    }
  });
  Isolate? worker;
  try {
    worker = await Isolate.spawn(
      _queueCodecWorker,
      (replies: replies.sendPort, mode: mode),
      onError: replies.sendPort,
      onExit: replies.sendPort,
      debugName: mode == _QueueCodecMode.restore
          ? 'download-queue-restore'
          : 'download-queue-persist',
    );
    final commands = await ready.future;
    for (var offset = 0; offset < values.length; offset += _workerChunkSize) {
      final end = (offset + _workerChunkSize).clamp(0, values.length);
      final received = Completer<void>();
      acknowledgement = received;
      commands.send(values.sublist(offset, end));
      await received.future;
    }
    commands.send(null);
    return await result.future;
  } finally {
    worker?.kill(priority: Isolate.immediate);
    await subscription.cancel();
    replies.close();
  }
}

void _queueCodecWorker(_QueueWorkerRequest request) async {
  final commands = ReceivePort();
  final items = <DownloadItem>[];
  final saved = <String, DownloadQueueSavedItem>{};
  final payloads = <String>[];
  request.replies.send(commands.sendPort);
  await for (final Object? message in commands) {
    if (message == null) {
      commands.close();
      Isolate.exit(request.replies, [
        request.mode == _QueueCodecMode.restore
            ? RestoredDownloadQueue(items: items, saved: saved)
            : payloads,
      ]);
    }
    if (request.mode == _QueueCodecMode.restore) {
      final decoded = _decodeRows(
        (message as List<Object?>).cast<Map<String, dynamic>>(),
      );
      items.addAll(decoded.items);
      saved.addAll(decoded.saved);
    } else {
      payloads.addAll(
        _encodeItems((message as List<Object?>).cast<DownloadItem>()),
      );
    }
    request.replies.send(true);
  }
}

List<Map<String, dynamic>>? _legacyRows((String, String) request) {
  final (raw, nowIso) = request;
  final decoded = jsonDecode(raw);
  if (decoded is! List) return null;
  final rows = <Map<String, dynamic>>[];
  for (final entry in decoded.whereType<Map<Object?, Object?>>()) {
    final map = Map<String, dynamic>.from(entry);
    final id = map['id'] as String?;
    if (id == null || id.isEmpty) continue;
    final status = map['status'] as String? ?? 'queued';
    if (status != 'queued' && status != 'downloading') continue;
    if (status == 'downloading') {
      map['status'] = 'queued';
      map['progress'] = 0.0;
      map['speedMBps'] = 0.0;
      map['bytesReceived'] = 0;
    }
    rows.add({
      'id': id,
      'item_json': jsonEncode(map),
      'status': 'queued',
      'created_at': map['createdAt'] as String? ?? nowIso,
      'updated_at': nowIso,
    });
  }
  return rows;
}

/// Legacy queue maps may contain fields unknown to today's model. Preserve
/// them rather than hydrating DownloadItem, while moving large JSON work off UI.
Future<List<Map<String, dynamic>>?> prepareLegacyDownloadQueueRows(
  String raw,
  String nowIso,
) async {
  final request = (raw, nowIso);
  if (raw.length < _workerPayloadThreshold) return _legacyRows(request);
  return compute(_legacyRows, request, debugLabel: 'download-queue-migration');
}
