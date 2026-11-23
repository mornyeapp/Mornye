import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/cross_extension_share_sheet.dart';
import 'package:share_plus/share_plus.dart';

/// The text a song is shared as: its title, then its artist when it has one.
String songShareText(String title, String artist) {
  final name = title.trim();
  final by = artist.trim();
  return by.isEmpty ? name : '$name - $by';
}

/// Share for a song: its name as text, or its link on one of the person's
/// services, which are searched for it when Share link is picked.
Future<void> showSongShare(
  BuildContext context, {
  required String title,
  required String artist,
}) {
  final root = Navigator.of(context, rootNavigator: true).context;
  final text = songShareText(title, artist);
  return showAppBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    // The same surface as the link list that may follow.
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
    title: context.l10n.trackMetadataShare,
    subtitle: text,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: AppSheetOptions(
        children: [
          Builder(
            builder: (rowContext) => AppSheetOption(
              key: const ValueKey('song-share-name'),
              leading: const AppIcon(Icons.short_text_rounded),
              title: Text(rowContext.l10n.shareSongName),
              onTap: () {
                final origin = shareOriginOf(rowContext);
                Navigator.pop(sheetContext);
                SharePlus.instance.share(
                  ShareParams(text: text, sharePositionOrigin: origin),
                );
              },
            ),
          ),
          AppSheetOption(
            key: const ValueKey('song-share-link'),
            leading: const AppIcon(Icons.link_rounded),
            title: Text(sheetContext.l10n.shareSongLink),
            subtitle: Text(sheetContext.l10n.shareSongLinkSubtitle),
            onTap: () {
              Navigator.pop(sheetContext);
              // The opener's own theme, as the player has, while it lasts.
              final host = context.mounted ? context : root;
              if (!host.mounted) return;
              CrossExtensionShareSheet.show(
                host,
                name: title.trim(),
                artists: artist.trim(),
                type: 'track',
                sourceExtensionId: '',
                share: true,
              );
            },
          ),
        ],
      ),
    ),
  );
}
