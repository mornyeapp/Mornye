import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/home_pin.dart';
import 'package:mornye/providers/home_pins_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';

/// The pin of a Library album, artist or genre row.
HomePin homePinOfBrowseEntry(LibraryBrowseEntry entry, HomePinKind kind) {
  final coverFile = entry.samplePath.isEmpty ? null : entry.samplePath;
  return switch (kind) {
    HomePinKind.artist => HomePin.artist(
      name: entry.artist,
      cover: entry.cover,
      coverFile: coverFile,
      source: entry.source,
    ),
    HomePinKind.genre => HomePin.genre(
      key: entry.key,
      name: entry.name,
      cover: entry.cover,
      coverFile: coverFile,
      source: entry.source,
    ),
    _ => HomePin.album(
      source: entry.source,
      albumKey: entry.key,
      name: entry.name,
      artist: entry.artist,
      cover: entry.cover,
      coverFile: coverFile,
    ),
  };
}

/// "Pin to Home", or "Unpin from Home" once [pin] is on Home, for the menus
/// of Library albums, playlists, artists, genres and folders.
ContextMenuAction homePinMenuAction(
  BuildContext context,
  WidgetRef ref,
  HomePin pin,
) {
  final l10n = context.l10n;
  final pins = ref.read(homePinsProvider.notifier);
  if (pins.isPinned(pin.key)) {
    return ContextMenuAction(
      icon: Icons.push_pin,
      label: l10n.homePinRemove,
      onSelected: () => pins.remove(pin.key),
    );
  }
  return ContextMenuAction(
    icon: Icons.push_pin_outlined,
    label: l10n.homePinAdd,
    onSelected: () {
      if (pins.add(pin) || !context.mounted) return;
      showAppSnackBar(
        context,
        content: Text(l10n.homePinLimit(HomePinsNotifier.limit)),
      );
    },
  );
}
