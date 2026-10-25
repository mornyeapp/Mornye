import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/recognized_song.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/music_recognition_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/services/music_recognition.dart';
import 'package:mornye/services/music_recognition_library.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:url_launcher/url_launcher.dart';

/// Identifies a song playing nearby through the microphone.
///
/// Pops with the words to search for when the person asks to find a song
/// that is not in Mornye.
class MusicRecognitionScreen extends ConsumerStatefulWidget {
  const MusicRecognitionScreen({super.key, this.listenOnOpen = true});

  /// Starts listening as the screen opens, since opening it is the request.
  final bool listenOnOpen;

  @override
  ConsumerState<MusicRecognitionScreen> createState() =>
      _MusicRecognitionScreenState();
}

class _MusicRecognitionScreenState
    extends ConsumerState<MusicRecognitionScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.listenOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_listen());
      });
    }
  }

  Future<void> _listen() async {
    // The microphone would only hear Mornye's own song.
    if (ref.read(playbackPlayingProvider)) {
      unawaited(ref.read(musicPlayerControllerProvider).togglePlayPause(true));
    }
    await ref.read(musicRecognitionProvider.notifier).start();
  }

  Future<void> _clearHistory() async {
    final l10n = context.l10n;
    final confirmed = await showAppConfirmDialog(
      context,
      title: l10n.dialogClearHistoryTitle,
      message: l10n.recognizeClearHistoryMessage,
      confirmLabel: l10n.dialogClear,
      destructive: true,
    );
    if (confirmed) {
      await ref.read(recognitionHistoryProvider.notifier).clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(musicRecognitionProvider);
    final history = ref.watch(recognitionHistoryProvider);
    final controller = ref.read(musicRecognitionProvider.notifier);
    final l10n = context.l10n;
    final inset = 16 + wideListInset(context);
    final motion = AppMotion.effects(
      context,
      const AppMotionSpec(Duration(milliseconds: 200), Curves.easeOut),
    );

    final stage = switch (state.phase) {
      RecognitionPhase.idle => _IdleStage(onListen: _listen),
      RecognitionPhase.listening || RecognitionPhase.processing =>
        _ListeningStage(state: state, onCancel: controller.cancel),
      RecognitionPhase.result => _ResultStage(
        song: state.song!,
        onListenAgain: _listen,
      ),
      RecognitionPhase.noMatch => _MessageStage(
        icon: Icons.music_off,
        title: l10n.recognizeNoMatchTitle,
        message: l10n.recognizeNoMatchMessage,
        actionIcon: Icons.mic,
        actionLabel: l10n.recognizeTryAgain,
        onAction: _listen,
      ),
      RecognitionPhase.failed => _failureStage(state.failure),
      RecognitionPhase.permissionDenied => _MessageStage(
        icon: Icons.mic_off,
        title: l10n.recognizePermissionTitle,
        message: l10n.recognizePermissionMessage,
        actionIcon: state.canOpenSettings ? Icons.settings : Icons.mic,
        actionLabel: state.canOpenSettings
            ? l10n.setupOpenSettings
            : l10n.recognizePermissionAllow,
        onAction: state.canOpenSettings ? controller.openSettings : _listen,
      ),
    };

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: l10n.recognizeTitle,
            actions: history.isEmpty || state.isBusy
                ? null
                : [
                    AppIconButton(
                      tooltip: l10n.recognizeClearHistory,
                      icon: const AppIcon.adaptive(Icons.delete_sweep_outlined),
                      onPressed: _clearHistory,
                    ),
                  ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(inset, 8, inset, 16),
              child: AnimatedSwitcher(
                duration: motion.duration,
                switchInCurve: motion.curve,
                // Listening turns into searching in place.
                child: KeyedSubtree(
                  key: ValueKey((
                    state.phase == RecognitionPhase.processing
                        ? RecognitionPhase.listening
                        : state.phase,
                    state.song?.historyKey,
                  )),
                  child: stage,
                ),
              ),
            ),
          ),
          if (history.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: SettingsSectionHeader(title: l10n.recognizeHistory),
            ),
            SliverSettingsGroup(
              margin: EdgeInsets.symmetric(horizontal: inset),
              itemCount: history.length,
              itemBuilder: (context, index) {
                final song = history[index];
                return ListTile(
                  leading: _Cover(url: song.coverUrl, size: 48, thumb: true),
                  title: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  enabled: !state.isBusy,
                  onTap: () => controller.show(song),
                );
              },
            ),
          ],
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }

  Widget _failureStage(RecognitionFailure? failure) {
    final l10n = context.l10n;
    final (icon, title, message) = switch (failure) {
      RecognitionFailure.notEnoughAudio => (
        Icons.hearing,
        l10n.recognizeQuietTitle,
        l10n.recognizeQuietMessage,
      ),
      RecognitionFailure.network => (
        Icons.wifi_off,
        l10n.recognizeNetworkTitle,
        l10n.recognizeNetworkMessage,
      ),
      RecognitionFailure.rateLimited => (
        Icons.timer_off,
        l10n.recognizeRateLimitedTitle,
        l10n.recognizeRateLimitedMessage,
      ),
      RecognitionFailure.microphone => (
        Icons.mic_off,
        l10n.recognizeMicrophoneTitle,
        l10n.recognizeMicrophoneMessage,
      ),
      RecognitionFailure.unavailable || null => (
        Icons.error_outline,
        l10n.recognizeUnavailableTitle,
        l10n.recognizeUnavailableMessage,
      ),
    };
    return _MessageStage(
      icon: icon,
      title: title,
      message: message,
      actionIcon: Icons.mic,
      actionLabel: l10n.recognizeTryAgain,
      onAction: _listen,
    );
  }
}

/// The large round microphone control, with the listening progress around
/// it and a halo that follows the microphone level.
class _MicrophoneButton extends StatelessWidget {
  const _MicrophoneButton({
    this.onPressed,
    this.listening = false,
    this.progress,
    this.level = 0,
  });

  static const double _size = 152;
  static const double _ring = 200;

  final VoidCallback? onPressed;
  final bool listening;

  /// Determinate progress while listening; null while searching.
  final double? progress;
  final double level;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final animate = !MediaQuery.disableAnimationsOf(context);
    final fill = mornye || listening ? scheme.primary : scheme.primaryContainer;
    final glyph = mornye || listening
        ? scheme.onPrimary
        : scheme.onPrimaryContainer;
    final button = Material(
      color: fill,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox.square(
          dimension: _size,
          child: Center(
            child: AppIcon.adaptive(Icons.mic, size: 64, color: glyph),
          ),
        ),
      ),
    );
    return SizedBox.square(
      dimension: _ring,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (listening)
            // The halo grows with the level; reduced motion keeps it still.
            AnimatedScale(
              scale: animate ? 1 + 0.3 * level : 1,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: Container(
                width: _size,
                height: _size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: 0.16),
                ),
              ),
            ),
          if (listening)
            SizedBox.square(
              dimension: _ring,
              // Searching spins unless motion is reduced.
              child: AppProgressIndicator.circular(
                value: progress ?? (animate ? null : 1),
                trackColor: scheme.secondaryContainer,
              ),
            ),
          Semantics(
            button: onPressed != null,
            label: onPressed == null
                ? null
                : context.l10n.recognizeStartListening,
            excludeSemantics: true,
            child: button,
          ),
        ],
      ),
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.title, this.message});

  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (message != null) ...[
          SizedBox(height: tokens.gapSm),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _IdleStage extends StatelessWidget {
  const _IdleStage({required this.onListen});

  final VoidCallback onListen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    return Column(
      children: [
        SizedBox(height: tokens.gapXl),
        _MicrophoneButton(onPressed: onListen),
        SizedBox(height: tokens.gapXl),
        _Headline(
          title: context.l10n.recognizeIdleTitle,
          message: context.l10n.recognizeIdleMessage,
        ),
        SizedBox(height: tokens.gapLg),
        Text(
          context.l10n.recognizeServiceNote,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ListeningStage extends StatelessWidget {
  const _ListeningStage({required this.state, required this.onCancel});

  final MusicRecognitionState state;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final searching = state.phase == RecognitionPhase.processing;
    return Column(
      children: [
        SizedBox(height: tokens.gapXl),
        _MicrophoneButton(
          listening: true,
          progress: searching ? null : state.progress,
          level: state.level,
        ),
        SizedBox(height: tokens.gapXl),
        Semantics(
          liveRegion: true,
          child: _Headline(
            title: searching
                ? context.l10n.recognizeSearching
                : context.l10n.recognizeListening,
            message: searching ? null : context.l10n.recognizeListeningMessage,
          ),
        ),
        SizedBox(height: tokens.gapXl),
        AppActionButton(
          outlined: true,
          onPressed: onCancel,
          icon: const Icon(Icons.close),
          label: Text(context.l10n.dialogCancel),
        ),
      ],
    );
  }
}

class _MessageStage extends StatelessWidget {
  const _MessageStage({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionIcon,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final IconData actionIcon;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: EmptyState(
      icon: icon,
      title: title,
      message: message,
      action: AppActionButton(
        onPressed: onAction,
        icon: Icon(actionIcon),
        label: Text(actionLabel),
      ),
    ),
  );
}

class _ResultStage extends ConsumerStatefulWidget {
  const _ResultStage({required this.song, required this.onListenAgain});

  final RecognizedSong song;
  final VoidCallback onListenAgain;

  @override
  ConsumerState<_ResultStage> createState() => _ResultStageState();
}

class _ResultStageState extends ConsumerState<_ResultStage> {
  late Future<RecognitionLibraryMatch?> _match;

  @override
  void initState() {
    super.initState();
    _match = _find();
  }

  @override
  void didUpdateWidget(_ResultStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.historyKey != widget.song.historyKey) _match = _find();
  }

  Future<RecognitionLibraryMatch?> _find() async {
    try {
      return await findRecognizedSong(
        widget.song,
        ref.read(recognitionLibraryProvider),
      );
    } on Object {
      return null;
    }
  }

  Future<void> _play(RecognitionLibraryMatch match) async {
    try {
      await ref
          .read(playbackProvider.notifier)
          .playLocalPath(
            path: match.path,
            title: match.title,
            artist: match.artist,
            album: match.album,
            coverUrl: match.coverUrl.isNotEmpty
                ? match.coverUrl
                : widget.song.coverUrl ?? '',
          );
    } catch (error) {
      if (mounted) showCannotOpenFileSnackBar(context, error);
    }
  }

  Future<void> _openInShazam(String url) async {
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } on Object {
      // Reported below; the result stays on screen.
    }
    if (mounted) {
      showAppSnackBar(
        context,
        content: Text(context.l10n.announcementUnableToOpenLink),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final l10n = context.l10n;
    final webUrl =
        song.webUrl ??
        (song.key.isEmpty ? null : 'https://www.shazam.com/track/${song.key}');
    final details = [
      if (song.album case final album?) (l10n.trackAlbum, album),
      if (song.release case final release?) (l10n.trackReleaseDate, release),
      if (song.genre case final genre?) (l10n.trackGenre, genre),
      if (song.label case final label?) (l10n.trackLabel, label),
      if (song.isrc case final isrc?) (l10n.editMetadataFieldIsrc, isrc),
    ];

    final primary = FutureBuilder<RecognitionLibraryMatch?>(
      future: _match,
      builder: (context, snapshot) {
        final match = snapshot.data;
        final resolved = snapshot.connectionState == ConnectionState.done;
        return AppActionButton(
          onPressed: !resolved
              ? null
              : match != null
              ? () => _play(match)
              : () => Navigator.of(context).pop(song.searchQuery),
          icon: Icon(match != null ? Icons.play_arrow : Icons.search),
          label: Text(
            match != null ? l10n.recognizePlay : l10n.recognizeSearch,
          ),
        );
      },
    );
    final actions = [
      primary,
      if (webUrl != null)
        AppActionButton(
          tonal: true,
          outlined: true,
          onPressed: () => _openInShazam(webUrl),
          icon: const Icon(Icons.open_in_new),
          label: Text(l10n.recognizeOpenInShazam),
        ),
      AppActionButton(
        outlined: true,
        glass: false,
        onPressed: widget.onListenAgain,
        icon: const Icon(Icons.mic),
        label: Text(l10n.recognizeListenAgain),
      ),
    ];

    return Column(
      children: [
        SizedBox(height: tokens.gapLg),
        _Cover(url: song.coverUrl, size: 200),
        SizedBox(height: tokens.gapLg),
        Semantics(
          liveRegion: true,
          child: Column(
            children: [
              Text(
                song.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: tokens.gapXs),
              Text(
                song.artist,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: tokens.gapXl),
        // Apple stacks full-width actions; Material keeps a centered row
        // that wraps.
        if (context.isMornye)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: tokens.gapSm,
              children: actions,
            ),
          )
        else
          Wrap(
            alignment: WrapAlignment.center,
            spacing: tokens.gapSm,
            runSpacing: tokens.gapSm,
            children: actions,
          ),
        if (details.isNotEmpty) ...[
          SizedBox(height: tokens.gapXl),
          SettingsGroup(
            margin: EdgeInsets.zero,
            children: [
              for (final (index, (label, value)) in details.indexed)
                SettingsItem(
                  title: label,
                  subtitle: value,
                  showDivider: index < details.length - 1,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.url, required this.size, this.thumb = false});

  final String? url;
  final double size;
  final bool thumb;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final radius = BorderRadius.circular(
      thumb ? tokens.radiusThumb : tokens.radiusCover,
    );
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: radius,
      ),
      child: AppIcon.adaptive(
        Icons.music_note,
        size: size * 0.4,
        color: scheme.onSurfaceVariant,
      ),
    );
    final url = this.url;
    if (url == null) return placeholder;
    return CachedCoverImage(
      imageUrl: url,
      width: size,
      height: size,
      borderRadius: radius,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );
  }
}
