import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/screens/artist_screen.dart';
import 'package:mornye/screens/weekly_releases_screen.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/settings_group.dart';

class FavoriteArtistsScreen extends ConsumerWidget {
  const FavoriteArtistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(
      libraryCollectionsProvider.select((state) => state.favoriteArtists),
    );
    final colorScheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: context.l10n.collectionFavoriteArtists),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsItem(
                  icon: Icons.new_releases_outlined,
                  showIconInMornye: true,
                  title: context.l10n.weeklyReleases,
                  subtitle: context.l10n.weeklyReleasesDescription,
                  showDivider: false,
                  onTap: () => Navigator.of(context).push(
                    slidePageRoute<void>(page: const WeeklyReleasesScreen()),
                  ),
                ),
              ],
            ),
          ),
          if (artists.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.favorite,
                title: context.l10n.collectionFavoriteArtistsEmptyTitle,
                message: context.l10n.collectionFavoriteArtistsEmptySubtitle,
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.symmetric(
                horizontal: wideListInset(context) + (mornye ? 0 : 16),
              ),
              sliver: SliverList.separated(
                itemCount: artists.length,
                separatorBuilder: (_, _) => mornye
                    ? const Divider(height: 1)
                    : const SizedBox(height: 2),
                itemBuilder: (context, index) {
                  final artist = artists[index];
                  final tile = ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    leading: _ArtistThumbnail(artist: artist),
                    title: Text(
                      artist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle:
                        artist.providerId == null || artist.providerId!.isEmpty
                        ? null
                        : Text(
                            artist.providerId!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: AppIconButton(
                      tooltip: context.l10n.artistOptionRemoveFromFavorites,
                      icon: Icon(Icons.favorite, color: colorScheme.error),
                      onPressed: () async {
                        await ref
                            .read(libraryCollectionsProvider.notifier)
                            .removeFavoriteArtist(artist.key);
                        if (!context.mounted) return;
                        showAppSnackBar(
                          context,
                          content: Text(
                            context.l10n.collectionRemovedFromFavoriteArtists(
                              artist.name,
                            ),
                          ),
                        );
                      },
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        slidePageRoute<void>(
                          page: ArtistScreen(
                            artistId: artist.artistId,
                            artistName: artist.name,
                            coverUrl: artist.imageUrl,
                            extensionId:
                                artist.providerId != null &&
                                    artist.providerId!.isNotEmpty
                                ? artist.providerId
                                : null,
                          ),
                        ),
                      );
                    },
                  );
                  if (mornye) return tile;
                  return Material(
                    color: settingsGroupColor(context),
                    clipBehavior: Clip.antiAlias,
                    borderRadius: connectedRowRadius(
                      context,
                      first: index == 0,
                      last: index == artists.length - 1,
                    ),
                    child: tile,
                  );
                },
              ),
            ),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }
}

class _ArtistThumbnail extends StatelessWidget {
  final CollectionArtistEntry artist;

  const _ArtistThumbnail({required this.artist});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final imageUrl = artist.imageUrl;
    return AppShapeClip(
      kind: AppShapes.artist,
      child: imageUrl != null && imageUrl.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: imageUrl,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              memCacheWidth: 112,
              memCacheHeight: 112,
              cacheManager: CoverCacheManager.instance,
              errorWidget: (_, _, _) => _placeholder(colorScheme),
            )
          : _placeholder(colorScheme),
    );
  }

  Widget _placeholder(ColorScheme colorScheme) {
    return Container(
      width: 56,
      height: 56,
      color: colorScheme.surfaceContainerHighest,
      child: AppIcon.adaptive(
        Icons.person,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }
}
