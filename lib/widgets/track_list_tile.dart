import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/clickable_metadata.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:mornye/widgets/in_library_badge.dart';
import 'package:mornye/widgets/preview_button.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';

/// Track row shared by the album and playlist screens. Tap offers another
/// download when quality variants are enabled, otherwise it plays the local
/// copy when one exists and falls back to [onDownload]. Long-press opens the
/// track options sheet. Callers supply [leading] (track number, cover art,
/// ...) and choose whether the artist name links to the artist screen.
class TrackListTile extends ConsumerWidget {
  final Track track;
  final bool isInHistory;
  final void Function({bool forceQualityPicker}) onDownload;
  final Widget leading;
  final bool clickableArtist;
  final bool showQualityBadges;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onToggleSelection;
  final VoidCallback? onEnterSelectionMode;

  /// [leading] is cover art. See [TrackCard.leadingArtwork].
  final bool leadingArtwork;

  const TrackListTile({
    super.key,
    required this.track,
    required this.isInHistory,
    required this.onDownload,
    required this.leading,
    this.clickableArtist = false,
    this.showQualityBadges = true,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onToggleSelection,
    this.onEnterSelectionMode,
    this.leadingArtwork = false,
  }) : assert(!isSelectionMode || onToggleSelection != null);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    // Material rows mark the current track; Mornye rows show no
    // current-track state.
    final playback = context.isMornye
        ? null
        : ref.watch(catalogTrackPlaybackUiProvider(catalogTrackKey(track)));

    final isQueued = ref.watch(
      downloadQueueLookupProvider.select(
        (lookup) => lookup.byTrackId.containsKey(track.id),
      ),
    );

    final showLocalLibraryIndicator = ref.watch(
      settingsProvider.select(
        (s) => s.localLibraryEnabled && s.localLibraryShowDuplicates,
      ),
    );
    final isInLocalLibrary = showLocalLibraryIndicator
        ? ref.watch(
            localLibraryProvider.select(
              (state) => state.existsInLibrary(
                isrc: track.isrc,
                trackName: track.name,
                artistName: track.artistName,
              ),
            ),
          )
        : false;

    return TrackCard(
      style: TrackCardStyle.flat,
      isSelectionMode: isSelectionMode,
      isSelected: isSelected,
      isCurrent: playback?.isCurrent ?? false,
      isPlaying: playback?.isPlaying ?? false,
      leadingArtwork: leadingArtwork,
      leading: leading,
      title: track.name,
      subtitle: TrackMetadataBadgesLine(
        primary: clickableArtist && !isSelectionMode
            ? ClickableArtistName(
                artistName: track.artistName,
                artistId: track.artistId,
                coverUrl: track.coverUrl,
                extensionId: track.source,
              )
            : Text(
                track.artistName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        badges: [
          ...buildQualityBadges(
            audioQuality: showQualityBadges ? track.audioQuality : null,
            audioModes: showQualityBadges ? track.audioModes : null,
            colorScheme: colorScheme,
            explicit: track.isExplicit,
          ),
          if (isInLocalLibrary || isInHistory) const InLibraryBadge(),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PreviewButton(track: track),
          TrackCollectionQuickActions(
            track: track,
            hasLocalPlaybackCandidate: isInHistory || isInLocalLibrary,
          ),
        ],
      ),
      onTap: isSelectionMode
          ? onToggleSelection
          : () => _handleTap(
              context,
              ref,
              isQueued: isQueued,
              isInLocalLibrary: isInLocalLibrary,
            ),
      onLongPress: isSelectionMode
          ? null
          : onEnterSelectionMode ??
                () => TrackCollectionQuickActions.showTrackOptionsSheet(
                  context,
                  ref,
                  track,
                  hasLocalPlaybackCandidate: isInHistory || isInLocalLibrary,
                ),
    );
  }

  void _handleTap(
    BuildContext context,
    WidgetRef ref, {
    required bool isQueued,
    required bool isInLocalLibrary,
  }) async {
    if (isQueued) return;

    final settings = ref.read(settingsProvider);
    if (settings.allowQualityVariants && (isInHistory || isInLocalLibrary)) {
      onDownload(forceQualityPicker: true);
      return;
    }

    final playedLocal = await playLocalIfAvailable(context, ref, track);
    if (playedLocal) {
      return;
    }

    onDownload();
  }

  /// What a tap on the row does, for the desktop song table: offers another
  /// quality, plays the local copy, or downloads [track].
  static Future<void> activate(
    BuildContext context,
    WidgetRef ref,
    Track track, {
    required bool isInHistory,
    required void Function({bool forceQualityPicker}) onDownload,
  }) async {
    if (ref.read(downloadQueueLookupProvider).byTrackId.containsKey(track.id)) {
      return;
    }
    final settings = ref.read(settingsProvider);
    final isInLocalLibrary =
        settings.localLibraryEnabled &&
        settings.localLibraryShowDuplicates &&
        ref
            .read(localLibraryProvider)
            .existsInLibrary(
              isrc: track.isrc,
              trackName: track.name,
              artistName: track.artistName,
            );
    if (settings.allowQualityVariants && (isInHistory || isInLocalLibrary)) {
      onDownload(forceQualityPicker: true);
      return;
    }
    if (await playLocalIfAvailable(context, ref, track)) return;
    onDownload();
  }
}

/// Explicit, Dolby Atmos and In Library badges of a [TrackListTile], for the
/// title cell of the desktop song table. Quality has its own column there.
class TrackListTileBadges extends ConsumerWidget {
  const TrackListTileBadges({
    super.key,
    required this.track,
    required this.isInHistory,
  });

  final Track track;
  final bool isInHistory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final showLocalLibraryIndicator = ref.watch(
      settingsProvider.select(
        (s) => s.localLibraryEnabled && s.localLibraryShowDuplicates,
      ),
    );
    final isInLocalLibrary =
        showLocalLibraryIndicator &&
        ref.watch(
          localLibraryProvider.select(
            (state) => state.existsInLibrary(
              isrc: track.isrc,
              trackName: track.name,
              artistName: track.artistName,
            ),
          ),
        );
    final badges = [
      ...buildQualityBadges(
        audioQuality: null,
        audioModes: track.audioModes,
        colorScheme: colorScheme,
        explicit: track.isExplicit,
      ),
      if (isInLocalLibrary || isInHistory) const InLibraryBadge(),
    ];
    if (badges.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (index, badge) in badges.indexed) ...[
          if (index > 0) const SizedBox(width: 4),
          badge,
        ],
      ],
    );
  }
}
