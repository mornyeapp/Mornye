import 'dart:convert';

/// Root sync manifest stored at `MornyeSync/manifest.json`.
class SyncManifest {
  const SyncManifest({
    this.protocolVersion = 1,
    this.syncEpoch = 1,
    required this.epochId,
    this.app = 'Mornye',
    required this.updatedAt,
    this.devices = const [],
  });

  final int protocolVersion;
  final int syncEpoch;
  final String epochId;
  final String app;
  final int updatedAt;
  final List<SyncDeviceRegistration> devices;

  SyncManifest copyWith({
    int? protocolVersion,
    int? syncEpoch,
    String? epochId,
    String? app,
    int? updatedAt,
    List<SyncDeviceRegistration>? devices,
  }) {
    return SyncManifest(
      protocolVersion: protocolVersion ?? this.protocolVersion,
      syncEpoch: syncEpoch ?? this.syncEpoch,
      epochId: epochId ?? this.epochId,
      app: app ?? this.app,
      updatedAt: updatedAt ?? this.updatedAt,
      devices: devices ?? this.devices,
    );
  }

  Map<String, dynamic> toJson() => {
    'protocolVersion': protocolVersion,
    'syncEpoch': syncEpoch,
    'epochId': epochId,
    'app': app,
    'updatedAt': updatedAt,
    'devices': [for (final d in devices) d.toJson()],
  };

  factory SyncManifest.fromJson(Map<String, dynamic> json) {
    return SyncManifest(
      protocolVersion: json['protocolVersion'] as int? ?? 1,
      syncEpoch: json['syncEpoch'] as int? ?? 1,
      epochId: json['epochId'] as String? ?? 'epoch_default',
      app: json['app'] as String? ?? 'Mornye',
      updatedAt: json['updatedAt'] as int? ?? 0,
      devices: [
        for (final raw in (json['devices'] as List? ?? const []))
          SyncDeviceRegistration.fromJson(
            Map<String, dynamic>.from(raw as Map),
          ),
      ],
    );
  }

  String serialize() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Merges this manifest with another manifest (e.g. freshly re-read from storage),
  /// preserving all unique device registrations, retaining the latest known
  /// `lastActive` timestamp per device, resolving the highest epoch, and avoiding
  /// overwriting newer data with stale data.
  SyncManifest mergeWith(
    SyncManifest? other, {
    SyncDeviceRegistration? localDevice,
    List<SyncDeviceRegistration> recoveredDevices = const [],
    Set<String> validPartitionDeviceIds = const {},
    int? nowMs,
  }) {
    final resolvedProtocol =
        (other != null && other.protocolVersion > protocolVersion)
        ? other.protocolVersion
        : protocolVersion;
    final resolvedEpoch = (other != null && other.syncEpoch > syncEpoch)
        ? other.syncEpoch
        : syncEpoch;
    final resolvedEpochId = (other != null && other.syncEpoch > syncEpoch)
        ? other.epochId
        : epochId;

    final deviceMap = <String, SyncDeviceRegistration>{};

    // 1. Existing devices in this manifest (deduplicated by ID)
    for (final d in devices) {
      if (d.id.isNotEmpty) {
        deviceMap[d.id] = d;
      }
    }

    // 2. Merge devices from the other manifest
    if (other != null) {
      for (final d in other.devices) {
        if (d.id.isEmpty) continue;
        final existing = deviceMap[d.id];
        if (existing == null) {
          deviceMap[d.id] = d;
        } else {
          // Keep the newer lastActive
          final dTime = DateTime.tryParse(d.lastActive);
          final exTime = DateTime.tryParse(existing.lastActive);
          final useD =
              dTime != null && (exTime == null || dTime.isAfter(exTime));
          final primary = useD ? d : existing;
          final fallback = useD ? existing : d;

          // Preserve non-generic device name if available
          final bestName =
              (primary.deviceName.isNotEmpty &&
                  !primary.deviceName.endsWith('Device'))
              ? primary.deviceName
              : (fallback.deviceName.isNotEmpty
                    ? fallback.deviceName
                    : primary.deviceName);

          deviceMap[d.id] = SyncDeviceRegistration(
            id: primary.id,
            platform: primary.platform.isNotEmpty
                ? primary.platform
                : fallback.platform,
            deviceName: bestName,
            lastActive: primary.lastActive,
          );
        }
      }
    }

    // 3. Merge recovered devices (only if not already registered)
    for (final r in recoveredDevices) {
      if (r.id.isNotEmpty && !deviceMap.containsKey(r.id)) {
        deviceMap[r.id] = r;
      }
    }

    // 4. Update local device (with its fresh lastActive and resolved name)
    if (localDevice != null && localDevice.id.isNotEmpty) {
      // Prune older predecessor registrations from this exact local client installation
      final obsoleteLocalIds = <String>[];
      for (final entry in deviceMap.values) {
        if (entry.id != localDevice.id &&
            entry.platform == localDevice.platform &&
            entry.deviceName == localDevice.deviceName) {
          obsoleteLocalIds.add(entry.id);
        }
      }
      for (final oldId in obsoleteLocalIds) {
        deviceMap.remove(oldId);
      }
      deviceMap[localDevice.id] = localDevice;
    }

    // 5. Consolidate predecessor registrations across all platforms and device names:
    // If multiple registrations share the identical (platform, deviceName),
    // only the one with the latest lastActive timestamp is active.
    final byPlatformAndName = <String, List<SyncDeviceRegistration>>{};
    for (final dev in deviceMap.values) {
      final key =
          '${dev.platform.toLowerCase()}|${dev.deviceName.toLowerCase()}';
      byPlatformAndName.putIfAbsent(key, () => []).add(dev);
    }
    for (final group in byPlatformAndName.values) {
      if (group.length > 1) {
        group.sort((a, b) {
          final aTime =
              DateTime.tryParse(a.lastActive) ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final bTime =
              DateTime.tryParse(b.lastActive) ??
              DateTime.fromMillisecondsSinceEpoch(0);
          return bTime.compareTo(aTime);
        });
        for (final obsolete in group.skip(1)) {
          deviceMap.remove(obsolete.id);
        }
      }
    }

    // 6. Prune ghost peer registrations that have no valid partitions and have been superseded
    if (validPartitionDeviceIds.isNotEmpty) {
      final ghostIds = <String>[];
      for (final entry in deviceMap.values) {
        if (localDevice != null && entry.id == localDevice.id) continue;
        if (!validPartitionDeviceIds.contains(entry.id)) {
          final hasActiveReplacement = deviceMap.values.any(
            (other) =>
                other.id != entry.id &&
                other.platform == entry.platform &&
                (validPartitionDeviceIds.contains(other.id) ||
                    (DateTime.tryParse(other.lastActive)?.isAfter(
                          DateTime.tryParse(entry.lastActive) ??
                              DateTime.fromMillisecondsSinceEpoch(0),
                        ) ??
                        false)),
          );
          if (hasActiveReplacement) {
            ghostIds.add(entry.id);
          }
        }
      }
      for (final gid in ghostIds) {
        deviceMap.remove(gid);
      }
    }

    // 6. Monotonically increasing updatedAt
    final currentNow = nowMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    final maxPrior = [
      updatedAt,
      other?.updatedAt ?? 0,
    ].reduce((a, b) => a > b ? a : b);
    final resolvedUpdatedAt = currentNow > maxPrior ? currentNow : maxPrior + 1;

    // Stable sort by device ID
    final sortedDevices = deviceMap.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    return SyncManifest(
      protocolVersion: resolvedProtocol,
      syncEpoch: resolvedEpoch,
      epochId: resolvedEpochId,
      app: app,
      updatedAt: resolvedUpdatedAt,
      devices: sortedDevices,
    );
  }

  /// Calculates the number of devices active within the specified time window.
  int countActiveDevices({
    Duration activeWindow = const Duration(days: 30),
    DateTime? now,
  }) {
    final cutoff = (now ?? DateTime.now().toUtc()).subtract(activeWindow);
    return devices.where((d) {
      if (d.lastActive.isEmpty) return false;
      final dt = DateTime.tryParse(d.lastActive);
      if (dt == null) return false;
      return dt.isAfter(cutoff);
    }).length;
  }

  static SyncManifest? deserialize(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return SyncManifest.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }
}

class SyncDeviceRegistration {
  const SyncDeviceRegistration({
    required this.id,
    required this.platform,
    required this.deviceName,
    required this.lastActive,
  });

  final String id;
  final String platform;
  final String deviceName;
  final String lastActive;

  Map<String, dynamic> toJson() => {
    'id': id,
    'platform': platform,
    'deviceName': deviceName,
    'lastActive': lastActive,
  };

  factory SyncDeviceRegistration.fromJson(Map<String, dynamic> json) =>
      SyncDeviceRegistration(
        id: json['id'] as String? ?? '',
        platform: json['platform'] as String? ?? '',
        deviceName: json['deviceName'] as String? ?? '',
        lastActive: json['lastActive'] as String? ?? '',
      );
}

/// A validated monthly partition payload stored at `MornyeSync/listening/devices/{deviceId}/{YYYY-MM}.json`.
class MonthlyPartition {
  const MonthlyPartition({
    this.version = 1,
    this.syncEpoch = 1,
    required this.deviceId,
    required this.devicePlatform,
    required this.month,
    required this.generatedAt,
    required this.records,
  });

  final int version;
  final int syncEpoch;
  final String deviceId;
  final String devicePlatform;
  final String month;
  final String generatedAt;
  final List<SyncTrackRecord> records;

  Map<String, dynamic> toJson() => {
    'version': version,
    'syncEpoch': syncEpoch,
    'deviceId': deviceId,
    'devicePlatform': devicePlatform,
    'month': month,
    'generatedAt': generatedAt,
    'records': [for (final r in records) r.toJson()],
  };

  factory MonthlyPartition.fromJson(Map<String, dynamic> json) {
    final month = json['month'] as String? ?? '';
    final parsedRecords = <SyncTrackRecord>[];

    for (final raw in (json['records'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final record = SyncTrackRecord.fromJson(Map<String, dynamic>.from(raw));
      // Invariant checks:
      // 1. Must have valid non-empty day and canonical key
      if (record.day.isEmpty || record.canonicalKey.isEmpty) continue;
      // 2. Must belong to this calendar month (YYYY-MM)
      if (month.isNotEmpty && !record.day.startsWith(month)) continue;
      // 3. Must have positive duration or plays (zero-duration invariant)
      if (record.milliseconds <= 0 && record.plays <= 0) continue;

      parsedRecords.add(record);
    }

    return MonthlyPartition(
      version: json['version'] as int? ?? 1,
      syncEpoch: json['syncEpoch'] as int? ?? 1,
      deviceId: json['deviceId'] as String? ?? '',
      devicePlatform: json['devicePlatform'] as String? ?? '',
      month: month,
      generatedAt: json['generatedAt'] as String? ?? '',
      records: parsedRecords,
    );
  }

  String serialize() => const JsonEncoder.withIndent('  ').convert(toJson());

  static MonthlyPartition? deserialize(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return MonthlyPartition.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }
}

class SyncTrackRecord {
  const SyncTrackRecord({
    required this.day,
    required this.canonicalKey,
    required this.title,
    required this.artist,
    required this.album,
    this.artwork,
    this.durationMs,
    this.isrc,
    required this.milliseconds,
    required this.plays,
    required this.updatedAt,
  });

  final String day;
  final String canonicalKey;
  final String title;
  final String artist;
  final String album;
  final String? artwork;
  final int? durationMs;
  final String? isrc;
  final int milliseconds;
  final int plays;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
    'day': day,
    'canonicalKey': canonicalKey,
    'title': title,
    'artist': artist,
    'album': album,
    if (artwork != null && artwork!.isNotEmpty) 'artwork': artwork,
    if (durationMs != null && durationMs! > 0) 'durationMs': durationMs,
    if (isrc != null && isrc!.isNotEmpty) 'isrc': isrc,
    'milliseconds': milliseconds,
    'plays': plays,
    'updatedAt': updatedAt,
  };

  factory SyncTrackRecord.fromJson(Map<String, dynamic> json) =>
      SyncTrackRecord(
        day: json['day'] as String? ?? '',
        canonicalKey:
            json['canonicalKey'] as String? ??
            json['track_key'] as String? ??
            '',
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        album: json['album'] as String? ?? '',
        artwork: json['artwork'] as String?,
        durationMs: json['durationMs'] as int?,
        isrc: json['isrc'] as String?,
        milliseconds: json['milliseconds'] as int? ?? 0,
        plays: json['plays'] as int? ?? 0,
        updatedAt: json['updatedAt'] as int? ?? json['updated_at'] as int? ?? 0,
      );
}

/// Global clear history signal stored at `MornyeSync/tombstone.json`.
class SyncTombstone {
  const SyncTombstone({
    this.action = 'global_clear_history',
    required this.targetEpoch,
    required this.newEpoch,
    required this.issuedBy,
    required this.issuedAt,
    this.comment = 'User initiated clear across all devices',
  });

  final String action;
  final int targetEpoch;
  final int newEpoch;
  final String issuedBy;
  final int issuedAt;
  final String comment;

  Map<String, dynamic> toJson() => {
    'action': action,
    'targetEpoch': targetEpoch,
    'newEpoch': newEpoch,
    'issuedBy': issuedBy,
    'issuedAt': issuedAt,
    'comment': comment,
  };

  factory SyncTombstone.fromJson(Map<String, dynamic> json) => SyncTombstone(
    action: json['action'] as String? ?? 'global_clear_history',
    targetEpoch: json['targetEpoch'] as int? ?? 1,
    newEpoch: json['newEpoch'] as int? ?? 2,
    issuedBy: json['issuedBy'] as String? ?? '',
    issuedAt: json['issuedAt'] as int? ?? 0,
    comment: json['comment'] as String? ?? '',
  );

  String serialize() => const JsonEncoder.withIndent('  ').convert(toJson());

  static SyncTombstone? deserialize(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return SyncTombstone.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }
}
