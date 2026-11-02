import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/services/network_offline_saver.dart';

/// Navigation for the title/artist, separate from playback and file actions.
class MornyePlayerNavigationMenu extends StatelessWidget {
  const MornyePlayerNavigationMenu({super.key, required this.mediaItem});

  final MediaItem mediaItem;

  @override
  Widget build(BuildContext context) {
    return _MornyePlayerMenuSurface(
      mediaItem: mediaItem,
      child: MornyeContextMenu(
        inheritSurface: true,
        dense: true,
        groups: [
          [
            if ((mediaItem.artist ?? '').trim().isNotEmpty)
              MornyeMenuAction(
                icon: CupertinoIcons.mic,
                label: context.l10n.mornyeGoToArtist,
                subtitle: mediaItem.artist,
                onPressed: () => Navigator.of(context).pop('artist'),
              ),
            if ((mediaItem.album ?? '').trim().isNotEmpty)
              MornyeMenuAction(
                icon: CupertinoIcons.square_stack,
                label: context.l10n.homeGoToAlbum,
                subtitle: mediaItem.album,
                onPressed: () => Navigator.of(context).pop('album'),
              ),
          ],
        ],
      ),
    );
  }
}

/// A floating menu that inherits the player's dark appearance.
class MornyePlayerActionsSheet extends ConsumerWidget {
  const MornyePlayerActionsSheet({
    super.key,
    required this.mediaItem,
    this.sleepTimerSubtitle,
    this.volumeShown = true,
    this.sendToDesktop,
    this.saveToPhone = false,
  });

  final MediaItem mediaItem;
  final String? sleepTimerSubtitle;

  /// Whether the player shows its volume slider, which the menu toggles.
  final bool volumeShown;

  /// The paired desktop's name while this phone's song can go there.
  final String? sendToDesktop;

  /// Whether the song is the paired desktop's, which can be saved here.
  final bool saveToPhone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerCollectionTrackProvider(mediaItem)).value;
    final loved = ref.watch(
      libraryCollectionsProvider.select(
        (state) => track != null && state.isLoved(track),
      ),
    );
    return _MornyePlayerMenuSurface(
      mediaItem: mediaItem,
      child: MornyeContextMenu(
        inheritSurface: true,
        dense: true,
        quickActions: [
          _action(
            context,
            'favorite',
            loved ? context.l10n.mornyeFavorited : context.l10n.mornyeFavorite,
            CupertinoIcons.star_fill,
            selected: loved,
          ),
          _action(
            context,
            'share',
            context.l10n.trackMetadataShare,
            CupertinoIcons.share_solid,
          ),
        ],
        groups: [
          [
            _action(
              context,
              'playlist',
              context.l10n.collectionAddToPlaylist,
              CupertinoIcons.text_badge_plus,
            ),
          ],
          [
            if ((mediaItem.album ?? '').trim().isNotEmpty)
              _action(
                context,
                'album',
                context.l10n.homeGoToAlbum,
                CupertinoIcons.square_stack,
                subtitle: mediaItem.album,
              ),
            if ((mediaItem.artist ?? '').trim().isNotEmpty)
              _action(
                context,
                'artist',
                context.l10n.mornyeGoToArtist,
                CupertinoIcons.mic,
                subtitle: mediaItem.artist,
              ),
            _action(
              context,
              'details',
              context.l10n.nowPlayingDetails,
              CupertinoIcons.info,
            ),
            _action(
              context,
              'shareLyrics',
              context.l10n.lyricsShareTitle,
              CupertinoIcons.quote_bubble,
            ),
            if (sendToDesktop case final name?)
              _action(
                context,
                'linkSend',
                context.l10n.linkSendToDesktop(name),
                CupertinoIcons.desktopcomputer,
              ),
            if (saveToPhone)
              _action(
                context,
                'linkSave',
                context.l10n.linkSaveToPhone,
                CupertinoIcons.device_phone_portrait,
              ),
            if (!saveToPhone &&
                canSaveNetworkOfflineSource(
                  mediaItem.extras?['source']?.toString() ?? '',
                ))
              _action(
                context,
                'networkOffline',
                context.l10n.offlineSave,
                CupertinoIcons.arrow_down_circle,
              ),
          ],
          [
            _action(
              context,
              'equalizer',
              context.l10n.equalizerTitle,
              CupertinoIcons.slider_horizontal_3,
            ),
            _action(
              context,
              'volume',
              volumeShown
                  ? context.l10n.nowPlayingHideVolume
                  : context.l10n.nowPlayingShowVolume,
              volumeShown
                  ? CupertinoIcons.speaker_slash
                  : CupertinoIcons.speaker_2,
            ),
            _action(
              context,
              'sleepTimer',
              context.l10n.nowPlayingSleepTimer,
              CupertinoIcons.moon_zzz,
              subtitle: sleepTimerSubtitle,
            ),
            _action(
              context,
              'external',
              context.l10n.nowPlayingOpenInExternalPlayer,
              CupertinoIcons.arrow_up_right_square,
            ),
          ],
        ],
      ),
    );
  }

  MornyeMenuAction _action(
    BuildContext context,
    String value,
    String label,
    IconData icon, {
    String? subtitle,
    bool selected = false,
  }) => MornyeMenuAction(
    icon: icon,
    label: label,
    subtitle: subtitle,
    selected: selected,
    onPressed: () => Navigator.of(context).pop(value),
  );
}

/// Reuse the cached cover palette; no per-frame background capture is needed.
class _MornyePlayerMenuSurface extends StatelessWidget {
  const _MornyePlayerMenuSurface({
    required this.mediaItem,
    required this.child,
  });

  final MediaItem mediaItem;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CoverSourceColorBuilder(
      imageSource: mediaItem.artUri?.toString(),
      builder: (context, sourceColor) {
        final dominant = HSLColor.fromColor(sourceColor ?? Colors.grey);
        final surface = dominant
            .withSaturation(dominant.saturation.clamp(0.0, 0.34))
            .withLightness(0.28)
            .toColor();
        return Theme(
          data: MornyeTheme.fromContext(
            context,
            brightness: Brightness.dark,
            chromeSurface: surface,
          ),
          child: child,
        );
      },
    );
  }
}
