import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/local_track_batch_actions.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/widgets/app_snack_bar.dart';

typedef LibraryTrackPageReader =
    Future<QueueLibraryDbPage> Function(QueueLibraryDbQuery query);

/// Every Library song whose file this device can write tags to, in Library
/// order: downloads and the songs of enabled Library folders. Songs served
/// by a network connection (Navidrome/Subsonic, SMB, WebDAV, Mornye Link)
/// are left out, as they are for a single song's Re-enrich.
Future<List<UnifiedLibraryItem>> loadReEnrichableLibraryItems({
  required bool includeLocal,
  LibraryTrackPageReader? readPage,
  int pageSize = 1000,
}) async {
  final read = readPage ?? LibraryDatabase.instance.getQueueTrackPageResult;
  final items = <UnifiedLibraryItem>[];
  final seen = <String>{};
  QueueLibraryDbCursor? cursor;
  for (var offset = 0; ; offset += pageSize) {
    final page = await read(
      QueueLibraryDbQuery(
        includeLocal: includeLocal,
        limit: pageSize,
        offset: offset,
        cursor: cursor,
      ),
    );
    for (final row in page.rows) {
      final json = Map<String, dynamic>.from(row['item'] as Map);
      final item = switch (row['source']) {
        'local' => UnifiedLibraryItem.fromLocalLibrary(
          LocalLibraryItem.fromJson(json),
        ),
        'downloaded' => UnifiedLibraryItem.fromDownloadHistory(
          DownloadHistoryItem.fromJson(json),
        ),
        _ => null,
      };
      if (item == null || !isReEnrichableLibraryPath(item.filePath)) continue;
      if (seen.add(item.id)) items.add(item);
    }
    if (page.rows.length < pageSize || page.nextCursor == null) break;
    cursor = page.nextCursor;
  }
  return items;
}

/// Whether Re-enrich can write to the file at [path] from this device.
bool isReEnrichableLibraryPath(String path) {
  final trimmed = path.trim();
  return trimmed.isNotEmpty && !trimmed.startsWith('network://');
}

/// Re-enriches the whole Library: the field sheet, the lookup, the review
/// and the write are the same as for a selection.
Future<void> reEnrichWholeLibrary(
  BuildContext context,
  WidgetRef ref, {
  required bool Function() isActive,
}) async {
  if (ref.read(localLibraryProvider).isScanning) {
    showAppSnackBar(
      context,
      content: Text(context.l10n.libraryReEnrichAllBusy),
    );
    return;
  }
  final List<UnifiedLibraryItem> items;
  try {
    items = await loadReEnrichableLibraryItems(
      includeLocal: ref.read(settingsProvider).localLibraryEnabled,
    );
  } catch (error) {
    if (context.mounted && isActive()) {
      showAppSnackBar(
        context,
        content: Text(context.l10n.snackbarError(context.friendlyError(error))),
      );
    }
    return;
  }
  if (!context.mounted || !isActive()) return;
  if (items.isEmpty) {
    showAppSnackBar(
      context,
      content: Text(context.l10n.libraryReEnrichAllEmpty),
    );
    return;
  }
  await reEnrichLibraryTracks(
    context,
    ref,
    items,
    isActive: isActive,
    onSelectionHide: () async {},
    onSelectionRestore: () {},
    onComplete: () {},
  );
}
