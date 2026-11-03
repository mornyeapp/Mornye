import 'dart:convert';

import 'package:mornye/models/library_scan_failure.dart';
import 'package:shared_preferences/shared_preferences.dart';

const localLibraryLastScannedAtKey = 'local_library_last_scanned_at';
const localLibraryActiveScanSourceKey = 'local_library_active_scan_source';
const localLibraryActiveScanStartedAtKey =
    'local_library_active_scan_started_at';
const localLibraryActiveScanNotifyKey = 'local_library_active_scan_notify';
const localLibraryRecoveredScanKey = 'local_library_recovered_scan';
const localLibraryScanFailuresKey = 'local_library_scan_failures';

/// The unreadable files of each source's last scan, by source ID.
Map<String, LibraryScanFailures> readLocalLibraryScanFailures(
  SharedPreferences prefs,
) {
  final value = prefs.getString(localLibraryScanFailuresKey);
  if (value == null || value.isEmpty) return const {};
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return const {};
    return {
      for (final entry in decoded.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: LibraryScanFailures.fromJson(
            (entry.value as Map).cast(),
          ),
    };
  } on FormatException {
    return const {};
  }
}

Future<void> writeLocalLibraryScanFailures(
  SharedPreferences prefs,
  Map<String, LibraryScanFailures> failures,
) {
  if (failures.isEmpty) return prefs.remove(localLibraryScanFailuresKey);
  return prefs.setString(
    localLibraryScanFailuresKey,
    jsonEncode({
      for (final entry in failures.entries) entry.key: entry.value.toJson(),
    }),
  );
}

DateTime? readLocalLibraryLastScannedAt(SharedPreferences prefs) {
  final lastScannedAtStr = prefs.getString(localLibraryLastScannedAtKey);
  if (lastScannedAtStr != null && lastScannedAtStr.isNotEmpty) {
    return DateTime.tryParse(lastScannedAtStr);
  }

  // Backward compatibility for older builds that may have stored epoch millis.
  final lastScannedAtMs = prefs.getInt(localLibraryLastScannedAtKey);
  if (lastScannedAtMs != null) {
    return DateTime.fromMillisecondsSinceEpoch(lastScannedAtMs);
  }

  return null;
}

Future<void> writeLocalLibraryLastScannedAt(
  SharedPreferences prefs,
  DateTime value,
) {
  return prefs.setString(localLibraryLastScannedAtKey, value.toIso8601String());
}

Future<void> clearLocalLibraryLastScannedAt(SharedPreferences prefs) {
  return prefs.remove(localLibraryLastScannedAtKey);
}
