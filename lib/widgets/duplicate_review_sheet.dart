import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/utils/duplicate_cleanup_policy.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/settings_group.dart';

final duplicateReviewGroupsLoaderProvider =
    Provider<Future<List<IsrcDuplicateGroup>> Function()>(
      (ref) => LibraryDatabase.instance.findIsrcDuplicateGroups,
    );

final _log = AppLogger('DuplicateReview');

/// Bottom sheet listing tracks that exist more than once (same ISRC) across
/// download history and the local library, with keep-best and per-copy
/// delete actions.
class DuplicateReviewSheet extends ConsumerStatefulWidget {
  const DuplicateReviewSheet({super.key});

  static Future<void> show(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return showAppBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      title: context.l10n.duplicatesTitle,
      maxHeightFactor: 0.85,
      builder: (_) => const DuplicateReviewSheet(),
    );
  }

  @override
  ConsumerState<DuplicateReviewSheet> createState() =>
      _DuplicateReviewSheetState();
}

class _DuplicateReviewSheetState extends ConsumerState<DuplicateReviewSheet> {
  late final LocalLibraryNotifier _localLibraryNotifier;
  late Future<List<IsrcDuplicateGroup>> _groupsFuture;
  bool _deletedLocalRows = false;
  bool _deleteActionInProgress = false;

  @override
  void initState() {
    super.initState();
    _localLibraryNotifier = ref.read(localLibraryProvider.notifier);
    _groupsFuture = _loadGroups();
  }

  @override
  void dispose() {
    if (_deletedLocalRows) {
      unawaited(_localLibraryNotifier.reloadFromStorage());
    }
    super.dispose();
  }

  void _reload() {
    setState(() {
      _groupsFuture = _loadGroups();
    });
  }

  Future<List<IsrcDuplicateGroup>> _loadGroups() async {
    try {
      return await ref.read(duplicateReviewGroupsLoaderProvider)();
    } catch (error, stack) {
      _log.e('Could not load duplicate copies', error, stack);
      rethrow;
    }
  }

  String _qualityLabel(IsrcDuplicateEntry entry) {
    var format = entry.format?.trim().toUpperCase() ?? '';
    if (format.isEmpty) {
      format = p
          .extension(
            DownloadedEmbeddedCoverResolver.cleanFilePath(entry.filePath),
          )
          .replaceFirst('.', '')
          .toUpperCase();
    }
    final bitDepth = entry.bitDepth ?? 0;
    final sampleRate = entry.sampleRate ?? 0;
    if (bitDepth > 0 && sampleRate > 0) {
      final khz = sampleRate / 1000;
      final khzText = khz % 1 == 0 ? khz.toInt().toString() : khz.toString();
      return format.isEmpty
          ? '$bitDepth/$khzText'
          : '$bitDepth/$khzText $format';
    }
    final bitrate = entry.bitrate ?? 0;
    if (bitrate > 0) {
      return '${(bitrate / 1000).round()}k${format.isEmpty ? '' : ' $format'}';
    }
    return format;
  }

  String _displayPath(String path) {
    final cleaned = DownloadedEmbeddedCoverResolver.cleanFilePath(path);
    try {
      return Uri.decodeFull(cleaned);
    } on FormatException {
      return cleaned;
    } on ArgumentError {
      return cleaned;
    }
  }

  Future<bool> _confirmDelete(String message) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: context.l10n.dialogDeleteSelectedTitle,
      message: message,
      confirmLabel: context.l10n.dialogDelete,
      destructive: true,
      errorConfirm: true,
    );
    return confirmed && mounted;
  }

  Future<void> _deleteEntries(
    List<IsrcDuplicateEntry> entries, {
    required List<IsrcDuplicateEntry> retainedEntries,
  }) async {
    final historyNotifier = ref.read(downloadHistoryProvider.notifier);
    final deleted = await deleteReviewedDuplicateCopies(
      entries: entries,
      retainedEntries: retainedEntries,
      deleteFile: deleteFile,
      removePhysicalFile: (path) async {
        // A download may also be indexed by a scan. Clear both references so
        // playlist resolution by ISRC finds the surviving file, not a ghost.
        await historyNotifier.removePhysicalFiles([path]);
        await _localLibraryNotifier.removePhysicalFiles([path]);
      },
      removeIndexEntry: (entry) async {
        if (entry.source == 'downloaded') {
          await historyNotifier.removeFromHistory(entry.id);
        } else {
          await LibraryDatabase.instance.deleteByPath(entry.filePath);
          _deletedLocalRows = true;
        }
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.snackbarDeletedTracks(deleted))),
    );
    _reload();
  }

  Future<void> _confirmAndDelete({
    required String message,
    required List<IsrcDuplicateEntry> entries,
    required List<IsrcDuplicateEntry> retainedEntries,
  }) async {
    if (_deleteActionInProgress || entries.isEmpty) return;
    setState(() => _deleteActionInProgress = true);
    try {
      final confirmed = await _confirmDelete(message);
      if (confirmed) {
        await _deleteEntries(entries, retainedEntries: retainedEntries);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.friendlyError(error))));
        _reload();
      }
    } finally {
      if (mounted) {
        setState(() => _deleteActionInProgress = false);
      }
    }
  }

  Future<void> _keepBest(IsrcDuplicateGroup group) async {
    final toDelete = group.entries.sublist(1);
    await _confirmAndDelete(
      message: context.l10n.duplicatesKeepBestMessage(
        toDelete.length,
        group.entries.first.trackName,
      ),
      entries: toDelete,
      retainedEntries: [group.entries.first],
    );
  }

  Future<void> _keepBestAll(List<IsrcDuplicateGroup> groups) async {
    final plan = buildKeepBestAllDuplicatePlan(groups);
    await _confirmAndDelete(
      message: context.l10n.duplicatesKeepBestAllMessage(
        plan.entriesToDelete.length,
        plan.groupCount,
      ),
      entries: plan.entriesToDelete,
      retainedEntries: plan.retainedEntries,
    );
  }

  Future<void> _deleteSingle(
    IsrcDuplicateGroup group,
    IsrcDuplicateEntry entry,
  ) async {
    await _confirmAndDelete(
      message: context.l10n.duplicatesDeleteCopyMessage(entry.trackName),
      entries: [entry],
      retainedEntries: group.entries
          .where(
            (candidate) =>
                candidate.source != entry.source || candidate.id != entry.id,
          )
          .toList(growable: false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<IsrcDuplicateGroup>>(
      future: _groupsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: AppLoadingIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.friendlyError(snapshot.error!),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                ExpressiveButton(
                  onPressed: _reload,
                  child: Text(context.l10n.dialogRetry),
                ),
              ],
            ),
          );
        }
        final groups = snapshot.data ?? const [];
        if (groups.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: Text(
              context.l10n.duplicatesEmpty,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        // shrinkWrap keeps a small sheet compact but builds every
        // group eagerly; past a screenful, switch to a lazy
        // full-height list so a large duplicate set can't jank the
        // opening frame.
        final compact = groups.length <= 12;
        return ListView.builder(
          shrinkWrap: compact,
          itemCount: groups.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return _buildKeepBestAllAction(context, colorScheme, groups);
            }
            return _buildGroup(context, colorScheme, groups[index - 1]);
          },
        );
      },
    );
  }

  Widget _buildKeepBestAllAction(
    BuildContext context,
    ColorScheme colorScheme,
    List<IsrcDuplicateGroup> groups,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SizedBox(
        width: double.infinity,
        child: ExpressiveButton(
          onPressed: _deleteActionInProgress
              ? null
              : () => _keepBestAll(groups),
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.error,
            foregroundColor: colorScheme.onError,
          ),
          icon: _deleteActionInProgress
              ? AppLoadingIndicator(
                  size: 18,
                  strokeWidth: 2,
                  color: colorScheme.onError,
                )
              : const Icon(Icons.delete_sweep_outlined),
          child: Text(context.l10n.duplicatesKeepBestAll),
        ),
      ),
    );
  }

  Widget _buildGroup(
    BuildContext context,
    ColorScheme colorScheme,
    IsrcDuplicateGroup group,
  ) {
    final first = group.entries.first;
    return SettingsGroup(
      connected: true,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      first.trackName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${first.artistName} • ${group.isrc}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              ExpressiveButton(
                text: true,
                onPressed: _deleteActionInProgress
                    ? null
                    : () => _keepBest(group),
                child: Text(context.l10n.duplicatesKeepBest),
              ),
            ],
          ),
        ),
        for (var i = 0; i < group.entries.length; i++)
          ListTile(
            dense: true,
            title: Row(
              children: [
                AudioQualityBadge(
                  label: _qualityLabel(group.entries[i]),
                  colorScheme: colorScheme,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _displayPath(group.entries[i].filePath),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            trailing: AppIconButton(
              tooltip: context.l10n.dialogDelete,
              icon: Icon(Icons.delete_outline, color: colorScheme.error),
              onPressed: _deleteActionInProgress
                  ? null
                  : () => _deleteSingle(group, group.entries[i]),
            ),
          ),
      ],
    );
  }
}
