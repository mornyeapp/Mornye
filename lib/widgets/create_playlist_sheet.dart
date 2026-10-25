import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/playlist_sources.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';

final _log = AppLogger('CreatePlaylist');

enum _PlaylistSource { empty, folder, file }

/// Creates a playlist that starts empty, holds one Library folder, or
/// imports an M3U or CSV file matched to local files.
Future<void> showCreatePlaylistSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final l10n = context.l10n;
  final source = await showAppScrollableBottomSheet<_PlaylistSource>(
    context: context,
    title: l10n.collectionCreatePlaylist,
    builder: (sheetContext, controller) => SingleChildScrollView(
      controller: controller,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (source, icon, title, subtitle) in [
            (
              _PlaylistSource.empty,
              Icons.playlist_add,
              l10n.playlistCreateEmpty,
              l10n.playlistCreateEmptySubtitle,
            ),
            (
              _PlaylistSource.folder,
              Icons.folder_outlined,
              l10n.playlistCreateFromFolder,
              l10n.playlistCreateFromFolderSubtitle,
            ),
            (
              _PlaylistSource.file,
              Icons.file_open_outlined,
              l10n.playlistImportFile,
              l10n.playlistImportFileSubtitle,
            ),
          ])
            AppSheetOption(
              leading: AppIcon(icon),
              title: Text(title),
              subtitle: Text(subtitle),
              onTap: () => Navigator.pop(sheetContext, source),
            ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return;
  switch (source) {
    case _PlaylistSource.empty:
      await _createEmpty(context, ref);
    case _PlaylistSource.folder:
      await _createFromFolder(context, ref);
    case _PlaylistSource.file:
      await _importFile(context, ref);
  }
}

Future<String?> _promptName(BuildContext context, [String? initialName]) =>
    promptPlaylistName(
      context,
      title: context.l10n.collectionCreatePlaylist,
      confirmLabel: context.l10n.actionCreate,
      initialName: initialName,
    );

Future<void> _createEmpty(BuildContext context, WidgetRef ref) async {
  final name = await _promptName(context);
  if (name == null || name.isEmpty) return;
  await ref.read(libraryCollectionsProvider.notifier).createPlaylist(name);
}

Future<void> _createFromFolder(BuildContext context, WidgetRef ref) async {
  final library = LibraryDatabase.instance;
  // The sheet may close before the scan answers; it reports any error.
  final folders = loadLibraryFolders(library)..ignore();
  final folder = await showAppScrollableBottomSheet<LibraryFolder>(
    context: context,
    title: context.l10n.playlistFolderPickerTitle,
    builder: (sheetContext, controller) =>
        _FolderList(folders: folders, controller: controller),
  );
  if (folder == null || !context.mounted) return;
  final name = await _promptName(context, folder.name);
  if (name == null || name.isEmpty || !context.mounted) return;

  final tracks = await libraryFolderTracks(folder, library);
  final notifier = ref.read(libraryCollectionsProvider.notifier);
  final id = await notifier.createPlaylist(name);
  final result = await notifier.addTracksToPlaylist(id, tracks);
  if (!context.mounted) return;
  showAppSnackBar(
    context,
    content: Text(
      context.l10n.playlistCreatedWithTracks(name, result.addedCount),
    ),
  );
}

Future<void> _importFile(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final List<PlaylistImportEntry> entries;
  final String fileName;
  try {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['m3u', 'm3u8', 'csv'],
    );
    if (picked == null) return;
    fileName = picked.name;
    entries = await parsePlaylistImportFile(
      await picked.readAsBytes(),
      fileName,
    );
  } catch (e) {
    _log.e('Failed to read playlist file: $e');
    if (context.mounted) {
      showAppSnackBar(context, content: Text(l10n.playlistImportFailed));
    }
    return;
  }
  if (!context.mounted) return;
  if (entries.isEmpty) {
    showAppSnackBar(context, content: Text(l10n.playlistImportNoTracks));
    return;
  }
  final name = await _promptName(context, p.basenameWithoutExtension(fileName));
  if (name == null || name.isEmpty || !context.mounted) return;

  final match = await matchPlaylistImport(entries, LibraryDatabase.instance);
  final notifier = ref.read(libraryCollectionsProvider.notifier);
  final id = await notifier.createPlaylist(name);
  final result = await notifier.addTracksToPlaylist(
    id,
    match.tracks,
    preserveOccurrences: true,
  );
  if (!context.mounted) return;
  showAppSnackBar(
    context,
    content: Text(
      l10n.playlistImportResult(result.addedCount, name, match.matched),
    ),
  );
}

class _FolderList extends StatelessWidget {
  const _FolderList({required this.folders, required this.controller});

  final Future<List<LibraryFolder>> folders;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<LibraryFolder>>(
      future: folders,
      builder: (context, snapshot) {
        final folders = snapshot.hasError
            ? const <LibraryFolder>[]
            : snapshot.data;
        if (folders == null) {
          // Skeleton rows in the geometry of the folder rows below.
          return SingleChildScrollView(
            controller: controller,
            child: ShimmerLoading(
              child: Column(
                children: [
                  for (var i = 0; i < 4; i++)
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      child: Row(
                        spacing: 16,
                        children: [
                          SkeletonBox(width: 24, height: 24, borderRadius: 6),
                          Expanded(
                            child: Column(
                              spacing: 6,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SkeletonBox(width: 160, height: 14),
                                SkeletonBox(width: 220, height: 12),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        }
        if (folders.isEmpty) {
          return SingleChildScrollView(
            controller: controller,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: EmptyState(
                icon: Icons.folder_outlined,
                title: context.l10n.playlistFolderPickerEmptyTitle,
                message: context.l10n.playlistFolderPickerEmpty,
              ),
            ),
          );
        }
        return ListView.builder(
          controller: controller,
          padding: const EdgeInsets.only(bottom: 16),
          itemCount: folders.length,
          itemBuilder: (context, index) {
            final folder = folders[index];
            final count = context.l10n.tracksCount(folder.ids.length);
            return AppSheetOption(
              leading: const AppIcon(Icons.folder_outlined),
              title: Text(
                folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                folder.path.isEmpty ? count : '$count · ${folder.path}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(context, folder),
            );
          },
        );
      },
    );
  }
}
