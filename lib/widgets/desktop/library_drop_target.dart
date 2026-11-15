import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// The folders a drop adds to the Library: dropped folders, and the folders
/// that hold dropped music files. Other files are ignored, and a folder
/// inside another one in the result is left out, since the scan of the outer
/// folder covers it.
@visibleForTesting
List<String> libraryFoldersForDrop(
  Iterable<String> paths, {
  required bool Function(String path) isDirectory,
}) {
  final folders = <String>{};
  for (final raw in paths) {
    final path = _trimSeparator(raw.trim());
    if (path.isEmpty) continue;
    if (isDirectory(path)) {
      folders.add(path);
    } else if (audioFormatForPath(path) != null) {
      folders.add(File(path).parent.path);
    }
  }
  final sorted = folders.toList()..sort((a, b) => a.length.compareTo(b.length));
  final kept = <String>[];
  for (final folder in sorted) {
    final covered = kept.any(
      (outer) => folder.startsWith('$outer${Platform.pathSeparator}'),
    );
    if (!covered) kept.add(folder);
  }
  return kept;
}

String _trimSeparator(String path) {
  final separator = Platform.pathSeparator;
  // Keep a root such as "/" or "C:\".
  if (path.length > 1 && path.endsWith(separator) && !path.endsWith(':\\')) {
    return path.substring(0, path.length - 1);
  }
  return path;
}

/// On desktop, accepts music files and folders dropped onto the window and
/// adds them to the Library as scanned folders: the same path as adding a
/// folder in Library settings. A dropped file adds the folder it is in.
/// Phones and tablets get [child] unchanged.
class DesktopLibraryDropTarget extends ConsumerStatefulWidget {
  const DesktopLibraryDropTarget({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DesktopLibraryDropTarget> createState() =>
      _DesktopLibraryDropTargetState();
}

class _DesktopLibraryDropTargetState
    extends ConsumerState<DesktopLibraryDropTarget> {
  bool _dragging = false;

  Future<void> _import(List<String> paths) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final folders = libraryFoldersForDrop(
      paths,
      isDirectory: FileSystemEntity.isDirectorySync,
    );
    if (folders.isEmpty) {
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.desktopDropNothingToImport)),
      );
      return;
    }
    if (!ref.read(settingsProvider).localLibraryEnabled) {
      ref.read(settingsProvider.notifier).setLocalLibraryEnabled(true);
    }
    messenger?.showSnackBar(
      SnackBar(content: Text(l10n.desktopDropImported(folders.length))),
    );
    final library = ref.read(localLibraryProvider.notifier);
    final sources = [
      for (final folder in folders)
        await library.addSource(path: folder, displayName: folder),
    ];
    for (final source in sources) {
      if (!mounted) return;
      await library.startSourceScan(source.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform) return widget.child;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        _import([for (final file in details.files) file.path]);
      },
      child: Stack(
        children: [
          widget.child,
          if (_dragging) const Positioned.fill(child: _DropOverlay()),
        ],
      ),
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final mornye = context.isMornye;
    return IgnorePointer(
      child: ColoredBox(
        color: colorScheme.surface.withValues(alpha: 0.9),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colorScheme.primary, width: 2),
              borderRadius: BorderRadius.circular(mornye ? 16 : 28),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    mornye
                        ? mornyeIconFor(Icons.library_add_outlined)
                        : Icons.library_add_outlined,
                    size: 48,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.l10n.desktopDropToImport,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
