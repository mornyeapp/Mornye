import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/player_lyrics.dart';
import 'package:mornye/widgets/lyrics_text_scale.dart';

class PlayerLyricsSection extends ConsumerWidget {
  const PlayerLyricsSection({
    super.key,
    required this.metadata,
    required this.seekPreview,
    required this.colorScheme,
    required this.isActive,
    this.animateWords = true,
    this.options,
    this.onShareLyrics,
  });

  final PlayerMetadataController metadata;
  final PlaybackSeekPreview seekPreview;
  final ColorScheme colorScheme;
  final bool isActive;
  final bool animateWords;
  final Widget? options;

  /// Long-pressing lyrics opens sharing, preselecting a timed line.
  final ValueChanged<LyricLine?>? onShareLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visibility = ref.watch(
      settingsProvider.select(
        (settings) =>
            (settings.playerShowPronunciation, settings.playerShowTranslation),
      ),
    );
    // The AI translation is keyed by these; a change picks another one.
    ref.watch(
      settingsProvider.select(
        (settings) => (
          settings.lyricsAiProvider,
          settings.lyricsAiModel,
          settings.lyricsAiBaseUrl,
          settings.lyricsTranslationLanguage,
          settings.locale,
          settings.lyricsAutoTranslate,
        ),
      ),
    );
    ref.watch(lyricsTranslationProvider.select((state) => state.results));
    final translation = ref.read(lyricsTranslationProvider.notifier);
    return ListenableBuilder(
      listenable: metadata,
      builder: (context, _) => _buildLyricsSection(
        context,
        visibility,
        translation.display(metadata.lyrics),
      ),
    );
  }

  Widget _buildLyricsSection(
    BuildContext context,
    (bool, bool) visibility,
    ParsedLyrics lyrics,
  ) {
    // Center in the part the player's controls leave visible. Only these
    // states depend on it, so a lyric list does not rebuild as they fade.
    if (metadata.loading || metadata.searchingOnline) {
      return Builder(
        builder: (context) => Padding(
          padding: EdgeInsets.only(bottom: LyricsCoveredBottom.of(context)),
          child: const Center(child: AppLoadingIndicator()),
        ),
      );
    }
    if (metadata.lyrics.isEmpty) {
      // Scrolls when a short screen leaves too little room above the
      // controls, so the search button stays reachable.
      return LayoutBuilder(
        builder: (_, constraints) {
          final covered = LyricsCoveredBottom.of(context);
          return SingleChildScrollView(
            padding: EdgeInsets.only(bottom: covered),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: constraints.maxWidth,
                minHeight: constraints.hasBoundedHeight
                    ? (constraints.maxHeight - covered).clamp(
                        0.0,
                        double.infinity,
                      )
                    : 0,
              ),
              child: Center(child: _noLyrics(context)),
            ),
          );
        },
      );
    }
    return _lyricsContent(context, visibility, lyrics);
  }

  Widget _noLyrics(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIcon(
          Icons.lyrics_outlined,
          size: 40,
          color: colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(
          metadata.onlineSearchMissed
              ? context.l10n.nowPlayingNoLyricsOnline
              : context.l10n.nowPlayingNoLyrics,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
        if (metadata.canSearchOnline) ...[
          const SizedBox(height: 16),
          ExpressiveButton(
            tonal: true,
            onPressed: () async {
              await metadata.searchOnline();
              if (context.mounted && metadata.onlineLyricsSaveFailed) {
                showAppSnackBar(
                  context,
                  content: Text(context.l10n.snackbarFailedToEmbedLyrics),
                );
              }
            },
            icon: const Icon(Icons.manage_search),
            child: Text(context.l10n.nowPlayingSearchLyricsOnline),
          ),
        ],
      ],
    ),
  );

  Widget _lyricsContent(
    BuildContext context,
    (bool, bool) visibility,
    ParsedLyrics lyrics,
  ) {
    if (metadata.lyrics.synced) {
      return Stack(
        fit: StackFit.expand,
        children: [
          SyncedLyricsView(
            lyrics: lyrics,
            seekPreview: seekPreview,
            credits: _lyricsCredits(),
            colorScheme: colorScheme,
            isActive: isActive,
            animateWords: animateWords,
            showPronunciation: visibility.$1,
            showTranslation: visibility.$2,
            onLongPressLine: onShareLyrics,
          ),
          if (options != null)
            PositionedDirectional(
              start: context.isMornye ? mornyeLyricsContentInset : 24,
              bottom: 8,
              child: options!,
            ),
        ],
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onLongPress: onShareLyrics == null
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    onShareLyrics!(null);
                  },
            child: LyricsTextScale(
              child: Text(
                metadata.lyrics.plainText,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  height: 1.6,
                  color: colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          ?_lyricsCredits(),
        ],
      ),
    );
  }

  LyricsCredits? _lyricsCredits() {
    final (:writers, :provider) = metadata.credits;
    if (writers == null && provider == null) return null;
    return LyricsCredits(writers: writers, provider: provider);
  }
}
