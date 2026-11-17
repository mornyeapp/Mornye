import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/library_mix_screen.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/library_view_toggle.dart';

/// A Library artist: their albums, or every song of theirs, whichever view
/// was chosen last on an artist.
class LibraryArtistScreen extends ConsumerWidget {
  const LibraryArtistScreen({super.key, required this.artist});

  final String artist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(
      settingsProvider.select((s) => s.libraryArtistShowsSongs),
    );
    final toolbar = _ArtistToolbar(artist: artist, songs: songs);
    final motion = AppMotion.effects(
      context,
      const AppMotionSpec(Duration(milliseconds: 200), Curves.easeOut),
    );
    return AnimatedSwitcher(
      duration: motion.duration,
      switchInCurve: motion.curve,
      switchOutCurve: motion.leaving,
      child: songs
          ? LibraryMixScreen.artist(
              key: const ValueKey('library-artist-songs'),
              artist: artist,
              toolbar: toolbar,
            )
          : Scaffold(
              key: const ValueKey('library-artist-albums'),
              body: MornyeLibraryScreen(
                page: MornyeLibraryPage.albums,
                artist: artist,
                toolbar: toolbar,
                onOpenSection: (_) {},
              ),
            ),
    );
  }
}

/// The Albums | Songs switch of a Library artist, with the link to the
/// artist's page.
class _ArtistToolbar extends ConsumerWidget {
  const _ArtistToolbar({required this.artist, required this.songs});

  final String artist;
  final bool songs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final inset = 16 + wideListInset(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 8, inset, 8),
      child: Row(
        children: [
          LibraryViewToggle(
            labels: [l10n.searchAlbums, l10n.searchSongs],
            selected: songs ? 1 : 0,
            onChanged: (index) => ref
                .read(settingsProvider.notifier)
                .setLibraryArtistShowsSongs(index == 1),
          ),
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: ExpressiveButton(
                text: true,
                onPressed: () => navigateToArtist(context, artistName: artist),
                child: Text(
                  l10n.libraryArtistPage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
