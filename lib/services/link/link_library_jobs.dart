import 'dart:convert';

import 'package:mornye/services/link/link_protocol.dart';

enum LinkLibraryAction {
  readMetadata,
  delete,
  reEnrichPreview,
  reEnrich,
  convert,
  replayGain,
  removeReplayGain,
  editMetadata,
  saveCover,
  saveLyrics,
}

bool linkLibraryActionChangesCatalog(LinkLibraryAction action) =>
    action != LinkLibraryAction.readMetadata &&
    action != LinkLibraryAction.reEnrichPreview &&
    action != LinkLibraryAction.saveCover &&
    action != LinkLibraryAction.saveLyrics;

enum LinkLibraryJobStatus { queued, running, completed, cancelled }

class LinkLibraryJob {
  const LinkLibraryJob({
    required this.id,
    required this.action,
    required this.status,
    required this.total,
    this.finished = 0,
    this.succeeded = 0,
    this.currentTitle = '',
    this.results = const [],
    this.completedMs = 0,
  });

  final String id;
  final LinkLibraryAction action;
  final LinkLibraryJobStatus status;
  final int total;
  final int finished;
  final int succeeded;
  final String currentTitle;
  final List<Map<String, dynamic>> results;
  final int completedMs;

  bool get active =>
      status == LinkLibraryJobStatus.queued ||
      status == LinkLibraryJobStatus.running;

  int get failed => results.where((result) => result['error'] != null).length;

  factory LinkLibraryJob.fromJson(Map<String, dynamic> json) => LinkLibraryJob(
    id: json['id'] as String,
    action: LinkLibraryAction.values.byName(json['action'] as String),
    status: LinkLibraryJobStatus.values.byName(json['status'] as String),
    total: json['total'] as int,
    finished: json['finished'] as int? ?? 0,
    succeeded: json['succeeded'] as int? ?? 0,
    currentTitle: json['currentTitle'] as String? ?? '',
    completedMs: json['completedMs'] as int? ?? 0,
    results: [
      for (final result in json['results'] as List? ?? const [])
        Map<String, dynamic>.from(result as Map),
    ],
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'action': action.name,
    'status': status.name,
    'total': total,
    'finished': finished,
    'succeeded': succeeded,
    'currentTitle': currentTitle,
    'results': results,
    'completedMs': completedMs,
  };
}

/// A desktop-owned operation. The phone supplies catalog IDs and options,
/// never a filesystem path. Executors resolve each ID again before writing.
class LinkLibraryWork {
  LinkLibraryWork({
    required this.id,
    required this.deviceId,
    required this.action,
    required List<String> songIds,
    required Map<String, dynamic> options,
  }) : songIds = List.unmodifiable(songIds),
       options = Map.unmodifiable(options);

  final String id;
  final String deviceId;
  final LinkLibraryAction action;
  final List<String> songIds;
  final Map<String, dynamic> options;

  String get fingerprint => jsonEncode([action.name, songIds, options]);
}

Map<String, dynamic> linkLibraryMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

Never invalidLinkLibraryRequest(String message) =>
    throw LinkException('invalid', message);
