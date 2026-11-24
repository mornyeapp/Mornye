import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';

enum _LibraryFolderLocation { documents, files }

/// App-owned music does not need a grant from the system Files picker.
Future<IosPickedDirectory?> showIosLibraryFolderSheet(
  BuildContext context,
) async {
  final location = await showAppModalBottomSheet<_LibraryFolderLocation>(
    context: context,
    useRootNavigator: true,
    builder: (context) => AppBottomSheet(
      title: context.l10n.libraryAddFolder,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppSheetOption(
              leading: const Icon(Icons.folder_special_outlined),
              title: Text(context.l10n.setupAppDocumentsFolder),
              subtitle: Text(context.l10n.setupAppDocumentsFolderSubtitle),
              onTap: () =>
                  Navigator.pop(context, _LibraryFolderLocation.documents),
            ),
            AppSheetOption(
              leading: const Icon(Icons.folder_open_outlined),
              title: Text(context.l10n.setupChooseFromFiles),
              subtitle: Text(context.l10n.setupChooseFromFilesSubtitle),
              onTap: () => Navigator.pop(context, _LibraryFolderLocation.files),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
  if (location == null || !context.mounted) return null;
  if (location == _LibraryFolderLocation.files) {
    // Keep the native picker and its bookmark for folders outside our sandbox.
    return PlatformBridge.pickIosDirectory();
  }

  // Scan Documents recursively, including the Mornye subfolder created by
  // setup and music the user copied into the app through Files. No bookmark is
  // needed: app-owned paths can be rebased when iOS relocates the container.
  final documents = await getApplicationDocumentsDirectory();
  return IosPickedDirectory(path: documents.path, bookmark: '');
}
