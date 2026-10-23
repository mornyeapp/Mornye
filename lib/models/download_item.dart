import 'package:json_annotation/json_annotation.dart';
import 'package:mornye/models/track.dart';

part 'download_item.g.dart';

const Object _downloadItemUnset = Object();

/// Tracks that share playlist naming and album-artist normalization rules.
class DownloadQueueBatch {
  final List<Track> tracks;
  final String? playlistName;
  final List<int?>? playlistPositions;

  const DownloadQueueBatch({
    required this.tracks,
    this.playlistName,
    this.playlistPositions,
  });
}

enum DownloadStatus {
  queued,
  downloading,
  finalizing,
  completed,
  failed,
  skipped,
}

enum DownloadErrorType {
  unknown,
  notFound,
  rateLimit,
  network,
  permission,
  verificationRequired,
}

@JsonSerializable()
class DownloadItem {
  final String id;
  final Track track;
  final String service;
  final DownloadStatus status;
  final double progress;
  final double speedMBps;
  final int bytesReceived;
  final int bytesTotal; // Total bytes when the server provides content length
  final String? filePath;
  final String? error;
  final DownloadErrorType? errorType;
  final String preparationStage;
  final DateTime createdAt;
  final String? qualityOverride;
  final String? playlistName;
  final int? playlistPosition; // 1-based position in the source playlist
  final bool fromBatch;
  final bool preserveQualityVariant;
  final String networkDownloadFolder;

  const DownloadItem({
    required this.id,
    required this.track,
    required this.service,
    this.status = DownloadStatus.queued,
    this.progress = 0.0,
    this.speedMBps = 0.0,
    this.bytesReceived = 0,
    this.bytesTotal = 0,
    this.filePath,
    this.error,
    this.errorType,
    this.preparationStage = '',
    required this.createdAt,
    this.qualityOverride,
    this.playlistName,
    this.playlistPosition,
    this.fromBatch = false,
    this.preserveQualityVariant = false,
    this.networkDownloadFolder = '',
  });

  DownloadItem copyWith({
    String? id,
    Track? track,
    String? service,
    DownloadStatus? status,
    double? progress,
    double? speedMBps,
    int? bytesReceived,
    int? bytesTotal,
    Object? filePath = _downloadItemUnset,
    Object? error = _downloadItemUnset,
    Object? errorType = _downloadItemUnset,
    String? preparationStage,
    DateTime? createdAt,
    String? qualityOverride,
    String? playlistName,
    int? playlistPosition,
    bool? fromBatch,
    bool? preserveQualityVariant,
    String? networkDownloadFolder,
  }) {
    return DownloadItem(
      id: id ?? this.id,
      track: track ?? this.track,
      service: service ?? this.service,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      speedMBps: speedMBps ?? this.speedMBps,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      filePath: identical(filePath, _downloadItemUnset)
          ? this.filePath
          : filePath as String?,
      error: identical(error, _downloadItemUnset)
          ? this.error
          : error as String?,
      errorType: identical(errorType, _downloadItemUnset)
          ? this.errorType
          : errorType as DownloadErrorType?,
      preparationStage: preparationStage ?? this.preparationStage,
      createdAt: createdAt ?? this.createdAt,
      qualityOverride: qualityOverride ?? this.qualityOverride,
      playlistName: playlistName ?? this.playlistName,
      playlistPosition: playlistPosition ?? this.playlistPosition,
      fromBatch: fromBatch ?? this.fromBatch,
      preserveQualityVariant:
          preserveQualityVariant ?? this.preserveQualityVariant,
      networkDownloadFolder:
          networkDownloadFolder ?? this.networkDownloadFolder,
    );
  }

  String get errorMessage {
    if (error == null) return '';

    return switch (errorType) {
      DownloadErrorType.notFound => 'Song not found on any service',
      DownloadErrorType.rateLimit =>
        'Service rate limit reached. Wait before retrying.',
      DownloadErrorType.network => 'Connection failed, check your internet',
      DownloadErrorType.permission =>
        'Cannot write to folder, check storage permission',
      DownloadErrorType.verificationRequired =>
        'Verification required. Open the extension and complete the security check.',
      _ => error ?? 'An error occurred',
    };
  }

  factory DownloadItem.fromJson(Map<String, dynamic> json) =>
      _$DownloadItemFromJson(json);
  Map<String, dynamic> toJson() => _$DownloadItemToJson(this);
}
