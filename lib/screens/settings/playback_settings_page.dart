import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart'
    show headphoneResumeModes, loudVolumeLevels;
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/alsa_output_devices.dart';
import 'package:mornye/services/autoplay_ranker.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/music_player_service.dart'
    show resetAutoplayLearning;
import 'package:mornye/services/song_analysis.dart';
import 'package:mornye/services/spatial_audio.dart';
import 'package:mornye/screens/listening_statistics_screen.dart';
import 'package:mornye/screens/equalizer_screen.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/exclusive_output_labels.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/utils/usb_output_status_label.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/beta_badge.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/player_volume_control.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/discord_presence_settings.dart';
import 'package:mornye/widgets/lastfm_settings.dart';
import 'package:mornye/widgets/scrobble_settings.dart';
import 'package:mornye/widgets/automix_settings.dart';
import 'package:mornye/widgets/autoplay_randomness_slider.dart';
import 'package:mornye/widgets/music_haptics_settings.dart';
import 'package:mornye/widgets/playback_normalization_settings.dart';
import 'package:mornye/widgets/playback_tempo_sheet.dart';

/// Shows the Android audio output section on any host, for tests.
@visibleForTesting
bool? debugAndroidAudioSettingsOverride;

class PlaybackSettingsPage extends ConsumerStatefulWidget {
  const PlaybackSettingsPage({super.key});

  @override
  ConsumerState<PlaybackSettingsPage> createState() =>
      _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends ConsumerState<PlaybackSettingsPage>
    with WidgetsBindingObserver {
  void _refreshOutputStatus() {
    ref.read(musicPlayerRuntimeProvider).handler?.refreshOutputStatus();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshOutputStatus();
  }

  late final SongAnalysis _songAnalysis = ref
      .read(musicPlayerRuntimeProvider)
      .songAnalysis;
  late final ValueListenable<AutoplayRankEvaluation?> _rankEvaluation = ref
      .read(musicPlayerRuntimeProvider)
      .ranker
      .evaluation;

  Future<bool> _confirmAudioVolume(String message) => showAppConfirmDialog(
    context,
    title: context.l10n.usbVolumeWarningTitle,
    message: message,
    confirmLabel: context.l10n.usbVolumeAccept,
    filled: false,
  );

  /// Learning cannot be restored once cleared, so a stray tap must not wipe it.
  Future<void> _confirmResetLearning() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: context.l10n.autoplayResetLearningConfirmTitle,
      message: context.l10n.autoplayResetLearningConfirmMessage,
      confirmLabel: context.l10n.autoplayResetLearningConfirm,
      destructive: true,
      filled: false,
    );
    if (confirmed) await resetAutoplayLearning();
  }

  /// Analysis cannot be restored without analyzing every song again.
  Future<void> _confirmClearAnalysis() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: context.l10n.songAnalysisClearConfirmTitle,
      message: context.l10n.songAnalysisClearConfirmMessage,
      confirmLabel: context.l10n.songAnalysisClearConfirm,
      destructive: true,
      filled: false,
    );
    if (confirmed) await _songAnalysis.clear();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshOutputStatus();
    _songAnalysis.progress.addListener(_onAnalysisProgress);
    _rankEvaluation.addListener(_onAnalysisProgress);
    unawaited(_songAnalysis.refreshProgress());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _songAnalysis.progress.removeListener(_onAnalysisProgress);
    _rankEvaluation.removeListener(_onAnalysisProgress);
    super.dispose();
  }

  void _onAnalysisProgress() {
    if (mounted) setState(() {});
  }

  /// How far ranking has learned the listener, and whether that ranks their
  /// latest songs better than the standard ranking.
  String? _learningSummary() {
    final evaluation = _rankEvaluation.value;
    if (evaluation == null) return null;
    final starting = evaluation.starting, learned = evaluation.learned;
    if (evaluation.tested == 0) {
      return context.l10n.autoplayLearningProgress(
        evaluation.outcomes,
        autoplayRankerMinimum,
      );
    }
    if (starting == null || learned == null) {
      return context.l10n.autoplayLearningWaiting;
    }
    final learnedPercent = (learned * 100).round();
    final startingPercent = (starting * 100).round();
    return evaluation.learnedWins
        ? context.l10n.autoplayLearningTuned(learnedPercent, startingPercent)
        : context.l10n.autoplayLearningStandard(
            learnedPercent,
            startingPercent,
          );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final accessibleNavigation = MediaQuery.accessibleNavigationOf(context);
    final autoMixActive =
        settings.autoMix && !(isDesktopPlatform && settings.exclusiveOutput);
    // Linux opens a chosen ALSA device; the other desktops use the default.
    final linuxDevice =
        settings.exclusiveOutput &&
        defaultTargetPlatform == TargetPlatform.linux;
    final macSpatialAudio = spatialAudioPlatform == SpatialAudioPlatform.macos;
    final colorScheme = Theme.of(context).colorScheme;
    final coverStyle = settings.playerCoverStyleFor(mornye: context.isMornye);
    // The charging rule applies to Android's background sweep only.
    final chargingOption = settings.songAnalysis && Platform.isAndroid;
    final androidAudio =
        debugAndroidAudioSettingsOverride ?? Platform.isAndroid;
    final progress = _songAnalysis.progress.value;
    final analysis =
        progress != null &&
            progress.total > 0 &&
            (settings.songAnalysis || progress.completed > 0)
        ? progress
        : null;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: context.l10n.libraryPlayback),
          ...settingsSectionSlivers(
            title: context.l10n.sectionPlayer,
            children: [
              SettingsItem(
                icon: Icons.open_in_new,
                title: context.l10n.libraryExternalPlayer,
                subtitle: context.l10n.libraryExternalPlayerSubtitle,
                selected: settings.playerMode == 'external',
                trailing: settings.playerMode == 'external'
                    ? AppIcon(Icons.check, color: colorScheme.primary)
                    : null,
                onTap: () => ref
                    .read(settingsProvider.notifier)
                    .setPlayerMode('external'),
              ),
              SettingsItem(
                icon: Icons.play_circle_outline,
                title: context.l10n.libraryBuiltInPreviewPlayer,
                subtitle: context.l10n.libraryBuiltInPreviewPlayerSubtitle,
                selected: settings.playerMode == 'internal',
                trailing: settings.playerMode == 'internal'
                    ? AppIcon(Icons.check, color: colorScheme.primary)
                    : null,
                onTap: () => ref
                    .read(settingsProvider.notifier)
                    .setPlayerMode('internal'),
                showDivider: false,
              ),
            ],
          ),
          ...settingsSectionSlivers(
            title: context.l10n.sectionVolumeAndTransitions,
            children: [
              SettingsItem(
                icon: Icons.equalizer,
                title: context.l10n.equalizerTitle,
                titleTrailing: const BetaBadge(),
                subtitle: context.l10n.equalizerDescription,
                onTap: () =>
                    pushPage<void>(context, (_) => const EqualizerScreen()),
              ),
              SettingsItem(
                icon: Icons.speed,
                title: context.l10n.playbackTempoTitle,
                subtitle:
                    playbackTempoSettingsSummary(context.l10n, settings) ??
                    context.l10n.playbackTempoDescription,
                onTap: () => showPlaybackTempoSheet(context),
              ),
              SettingsSwitchItem(
                icon: Icons.graphic_eq,
                title: context.l10n.libraryPlaybackNormalization,
                subtitle: context.l10n.libraryPlaybackNormalizationSubtitle,
                value: settings.playbackNormalization,
                enabled: !settings.usbBitPerfect,
                onChanged: (value) => ref
                    .read(settingsProvider.notifier)
                    .setPlaybackNormalization(value),
              ),
              if (settings.playbackNormalization)
                PlaybackNormalizationSettings(enabled: !settings.usbBitPerfect),
              SettingsSwitchItem(
                icon: Icons.volume_up_outlined,
                title: context.l10n.confirmLoudVolume,
                subtitle: context.l10n.confirmLoudVolumeDescription,
                value: settings.confirmLoudVolume,
                onChanged: (value) => ref
                    .read(settingsProvider.notifier)
                    .setConfirmLoudVolume(value),
              ),
              if (settings.confirmLoudVolume)
                _LoudVolumeLevelChoice(
                  level: settings.loudVolumeLevel,
                  onChanged: ref
                      .read(settingsProvider.notifier)
                      .setLoudVolumeLevel,
                ),
              if (!isDesktopPlatform) ...[
                SettingsSwitchItem(
                  icon: Icons.vibration,
                  title: context.l10n.musicHaptics,
                  subtitle: context.l10n.musicHapticsDescription,
                  value: settings.musicHaptics,
                  enabled: settings.playerMode == 'internal',
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setMusicHaptics(value),
                ),
                if (settings.musicHaptics)
                  MusicHapticsSettings(
                    enabled: settings.playerMode == 'internal',
                  ),
              ],
              SettingsSwitchItem(
                icon: Icons.linear_scale,
                title: context.l10n.gaplessPlayback,
                subtitle: context.l10n.gaplessPlaybackDescription,
                value: settings.gaplessPlayback && !autoMixActive,
                enabled:
                    settings.playerMode == 'internal' &&
                    !autoMixActive &&
                    !settings.usbBitPerfect,
                onChanged: (value) => ref
                    .read(settingsProvider.notifier)
                    .setGaplessPlayback(value),
              ),
              SettingsSwitchItem(
                icon: Icons.compare_arrows,
                title: 'AutoMix',
                subtitle: context.l10n.autoMixDescription,
                value: autoMixActive,
                enabled:
                    !settings.usbBitPerfect &&
                    !(isDesktopPlatform && settings.exclusiveOutput),
                onChanged: (value) =>
                    ref.read(settingsProvider.notifier).setAutoMix(value),
                showDivider: false,
              ),
            ],
          ),
          if (autoMixActive) ...[
            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.autoMixSettingsTitle,
              ),
            ),
            const SliverToBoxAdapter(child: AutoMixSettings()),
          ],
          ...settingsSectionSlivers(
            title: context.l10n.autoplayFromLibrary,
            children: [
              SettingsSwitchItem(
                icon: Icons.playlist_play_rounded,
                title: context.l10n.autoplayFromLibrary,
                subtitle: context.l10n.autoplayDescription,
                value: settings.autoplay,
                enabled: settings.playerMode == 'internal',
                onChanged: (value) =>
                    ref.read(settingsProvider.notifier).setAutoplay(value),
              ),
              const AutoplayRandomnessSlider(),
              SettingsSwitchItem(
                icon: Icons.auto_awesome_outlined,
                title: context.l10n.autoplayPersonalization,
                subtitle: context.l10n.autoplayPersonalizationDescription,
                value: settings.autoplayPersonalization,
                enabled: settings.playerMode == 'internal',
                onChanged: (value) => ref
                    .read(settingsProvider.notifier)
                    .setAutoplayPersonalization(value),
              ),
              if (settings.autoplayPersonalization)
                SettingsItem(
                  icon: Icons.restart_alt,
                  title: context.l10n.autoplayResetLearning,
                  subtitle: _learningSummary(),
                  onTap: _confirmResetLearning,
                ),
              SettingsSwitchItem(
                icon: Icons.multitrack_audio,
                title: context.l10n.songAnalysis,
                subtitle: context.l10n.songAnalysisDescription,
                value: settings.songAnalysis,
                enabled: settings.playerMode == 'internal',
                onChanged: (value) =>
                    ref.read(settingsProvider.notifier).setSongAnalysis(value),
                showDivider: chargingOption || analysis != null,
              ),
              if (chargingOption)
                SettingsSwitchItem(
                  icon: Icons.battery_charging_full,
                  title: context.l10n.songAnalysisOnlyWhileCharging,
                  subtitle:
                      context.l10n.songAnalysisOnlyWhileChargingDescription,
                  value: settings.songAnalysisOnlyWhileCharging,
                  enabled: settings.playerMode == 'internal',
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setSongAnalysisOnlyWhileCharging(value),
                  showDivider: analysis != null,
                ),
              if (analysis != null)
                SettingsItem(
                  icon: Icons.delete_outline,
                  title: context.l10n.songAnalysisClear,
                  subtitle: analysis.skipped > 0
                      ? context.l10n.songAnalysisProgressWithSkipped(
                          analysis.analyzed,
                          analysis.total,
                          analysis.skipped,
                        )
                      : context.l10n.songAnalysisProgress(
                          analysis.analyzed,
                          analysis.total,
                        ),
                  footer:
                      settings.songAnalysis &&
                          analysis.completed < analysis.total
                      ? AppProgressIndicator.linear(
                          value: analysis.completed / analysis.total,
                          trackColor: colorScheme.surfaceContainerHighest,
                          wavy: false,
                        )
                      : null,
                  onTap: analysis.completed > 0 ? _confirmClearAnalysis : null,
                  showDivider: false,
                ),
            ],
          ),
          ...settingsSectionSlivers(
            title: context.l10n.sectionPlaybackQueue,
            children: [
              SettingsSwitchItem(
                icon: Icons.playlist_remove,
                title: context.l10n.queueNoDuplicates,
                subtitle: context.l10n.queueNoDuplicatesDescription,
                value: settings.queueNoDuplicates,
                enabled: settings.playerMode == 'internal',
                onChanged: (value) => ref
                    .read(settingsProvider.notifier)
                    .setQueueNoDuplicates(value),
              ),
              SettingsSwitchItem(
                icon: Icons.lock_outline,
                title: context.l10n.queueLock,
                subtitle: context.l10n.queueLockDescription,
                value: settings.queueLocked,
                onChanged: (value) =>
                    ref.read(settingsProvider.notifier).setQueueLocked(value),
                showDivider: false,
              ),
            ],
          ),
          // Mute and headphone routes come from mobile system audio.
          if (!isDesktopPlatform)
            ...settingsSectionSlivers(
              title: context.l10n.playbackAutomation,
              children: [
                SettingsSwitchItem(
                  icon: Icons.volume_off_outlined,
                  title: context.l10n.playbackPauseOnMute,
                  subtitle: context.l10n.playbackPauseOnMuteDescription,
                  value: settings.pauseOnMute,
                  enabled:
                      settings.playerMode == 'internal' &&
                      !settings.usbBitPerfect,
                  onChanged: (value) =>
                      ref.read(settingsProvider.notifier).setPauseOnMute(value),
                ),
                _HeadphoneResumeChoice(
                  mode: settings.headphoneResume,
                  enabled: settings.playerMode == 'internal',
                  onChanged: (mode) => ref
                      .read(settingsProvider.notifier)
                      .setHeadphoneResume(mode),
                ),
              ],
            ),
          ...settingsSectionSlivers(
            title: context.l10n.playerCoverStyle,
            children: [
              for (final (style, icon, title, subtitle) in [
                (
                  'default',
                  Icons.crop_square,
                  context.l10n.playerCoverStyleCard,
                  context.l10n.playerCoverStyleDefaultDescription,
                ),
                (
                  'fullscreen',
                  Icons.fullscreen,
                  context.l10n.playerCoverStyleFullScreen,
                  context.l10n.playerCoverStyleFullScreenDescription,
                ),
              ])
                SettingsItem(
                  icon: icon,
                  title: title,
                  subtitle: subtitle,
                  selected: coverStyle == style,
                  trailing: coverStyle == style
                      ? AppIcon(Icons.check, color: colorScheme.primary)
                      : null,
                  onTap: () => ref
                      .read(settingsProvider.notifier)
                      .setPlayerCoverStyle(style),
                  showDivider: true,
                ),
              SettingsSwitchItem(
                icon: Icons.splitscreen_outlined,
                title: context.l10n.landscapeLyricsArtwork,
                subtitle: context.l10n.landscapeLyricsArtworkDescription,
                value: settings.landscapeLyricsArtwork,
                enabled: !context.isMornye,
                onChanged: (value) => ref
                    .read(settingsProvider.notifier)
                    .setLandscapeLyricsArtwork(value),
              ),
              if (!isDesktopPlatform)
                SettingsSwitchItem(
                  key: const ValueKey('auto-hide-lyrics-controls'),
                  icon: Icons.fullscreen,
                  title: context.l10n.autoHideLyricsControls,
                  subtitle: accessibleNavigation
                      ? context
                            .l10n
                            .autoHideLyricsControlsAccessibilityDescription
                      : context.l10n.autoHideLyricsControlsDescription,
                  value: settings.shouldAutoHideLyricsControls(
                    accessibleNavigation: accessibleNavigation,
                  ),
                  onChanged: ref
                      .read(settingsProvider.notifier)
                      .setAutoHideLyricsControls,
                ),
              SettingsSwitchItem(
                icon: Icons.short_text,
                title: context.l10n.compactPlayer,
                subtitle: context.l10n.compactPlayerDescription,
                value: settings.compactPlayer,
                enabled: !context.isMornye,
                onChanged: (value) =>
                    ref.read(settingsProvider.notifier).setCompactPlayer(value),
                showDivider: false,
              ),
            ],
          ),
          ...settingsSectionSlivers(
            title: context.l10n.motionArtwork,
            children: [
              SettingsSwitchItem(
                icon: Icons.motion_photos_on_outlined,
                title: context.l10n.motionArtwork,
                subtitle: context.l10n.motionArtworkDescription,
                value: settings.motionArtworkEnabled,
                onChanged: (value) => ref
                    .read(settingsProvider.notifier)
                    .setMotionArtworkEnabled(value),
                showDivider: false,
              ),
            ],
          ),
          if (Platform.isAndroid || Platform.isIOS || isDesktopPlatform) ...[
            const SliverToBoxAdapter(
              child: SettingsSectionHeader(title: 'Discord'),
            ),
            const SliverToBoxAdapter(child: DiscordPresenceSettings()),
          ],
          const SliverToBoxAdapter(
            child: SettingsSectionHeader(title: 'Last.fm'),
          ),
          SliverToBoxAdapter(
            child: LastfmSettings(
              service: ref.read(musicPlayerRuntimeProvider).lastfm,
            ),
          ),
          const SliverToBoxAdapter(
            child: SettingsSectionHeader(title: 'Libre.fm'),
          ),
          SliverToBoxAdapter(
            child: LastfmSettings(
              service: ref.read(musicPlayerRuntimeProvider).librefm,
              serviceName: 'Libre.fm',
            ),
          ),
          const SliverToBoxAdapter(
            child: SettingsSectionHeader(title: 'ListenBrainz'),
          ),
          SliverToBoxAdapter(
            child: ListenBrainzSettings(
              service: ref.read(musicPlayerRuntimeProvider).listenBrainz,
            ),
          ),
          if (isDesktopPlatform)
            ...settingsSectionSlivers(
              title: context.l10n.sectionAudioOutput,
              children: [
                ValueListenableBuilder<ExclusiveOutputStatus>(
                  valueListenable: playbackExclusiveStatus,
                  builder: (context, status, _) {
                    final labels = exclusiveOutputLabels(context.l10n);
                    return SettingsSwitchItem(
                      icon: Icons.speaker_outlined,
                      title: labels.title,
                      subtitle: [
                        labels.description,
                        if (settings.exclusiveOutput)
                          switch (status) {
                            ExclusiveOutputStatus.pending =>
                              context.l10n.exclusiveOutputPending,
                            ExclusiveOutputStatus.active =>
                              context.l10n.exclusiveOutputActive,
                            ExclusiveOutputStatus.unavailable =>
                              labels.unavailable,
                          },
                      ].join('\n\n'),
                      value: settings.exclusiveOutput,
                      onChanged: (value) => ref
                          .read(settingsProvider.notifier)
                          .setExclusiveOutput(value),
                      showDivider: linuxDevice || macSpatialAudio,
                    );
                  },
                ),
                if (linuxDevice)
                  _AlsaDeviceItem(device: settings.exclusiveOutputDevice),
                if (macSpatialAudio)
                  const _SpatialAudioItem(
                    platform: SpatialAudioPlatform.macos,
                    showDivider: false,
                  ),
              ],
            ),
          // iOS has no other audio output setting.
          if (spatialAudioPlatform == SpatialAudioPlatform.ios)
            ...settingsSectionSlivers(
              title: context.l10n.sectionAudioOutput,
              children: const [
                _SpatialAudioItem(
                  platform: SpatialAudioPlatform.ios,
                  showDivider: false,
                ),
              ],
            ),
          if (androidAudio)
            ...settingsSectionSlivers(
              title: context.l10n.sectionAudioOutput,
              connected: true,
              children: [
                SettingsSwitchItem(
                  icon: Icons.play_circle_outline,
                  title: context.l10n.newPlaybackEngine,
                  titleTrailing: const BetaBadge(),
                  subtitle: context.l10n.newPlaybackEngineDescription,
                  value: settings.media3Engine,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setMedia3Engine(value),
                ),
                // Phones and tablets only; media3 does the skipping.
                if (!isAndroidTv)
                  SettingsSwitchItem(
                    icon: Icons.fast_forward_outlined,
                    title: context.l10n.skipSilence,
                    subtitle: [
                      context.l10n.skipSilenceDescription,
                      if (!settings.media3Engine)
                        context.l10n.skipSilenceNeedsEngine
                      else if (settings.autoMix)
                        context.l10n.skipSilenceAutoMix,
                    ].join('\n\n'),
                    value: settings.skipSilence,
                    enabled: settings.media3Engine,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setSkipSilence(value),
                  ),
                // TV output is HDMI or a soundbar, outside the spatializer.
                if (!isAndroidTv)
                  const _SpatialAudioItem(
                    platform: SpatialAudioPlatform.android,
                  ),
                ValueListenableBuilder<UsbAudioStatus>(
                  valueListenable: usbAudioStatus,
                  builder: (context, status, _) => SettingsSwitchItem(
                    icon: Icons.usb,
                    title: context.l10n.usbBitPerfect,
                    titleTrailing: const BetaBadge(),
                    subtitle: [
                      context.l10n.usbBitPerfectDescription,
                      if (settings.usbBitPerfect)
                        usbOutputStatusLabel(context.l10n, status),
                    ].join('\n\n'),
                    value: settings.usbBitPerfect,
                    onChanged: (value) async {
                      if (value &&
                          !await _confirmAudioVolume(
                            context.l10n.usbVolumeWarning,
                          )) {
                        return;
                      }
                      if (mounted) {
                        ref
                            .read(settingsProvider.notifier)
                            .setUsbBitPerfect(value);
                      }
                    },
                    showDivider: settings.usbBitPerfect,
                  ),
                ),
                if (settings.usbBitPerfect) ...[
                  SettingsSwitchItem(
                    icon: Icons.usb,
                    title: context.l10n.usbDirect,
                    subtitle: context.l10n.usbDirectDescription,
                    value: settings.usbDirect,
                    onChanged: (value) async {
                      if (value &&
                          !await _confirmAudioVolume(
                            context.l10n.usbVolumeWarning,
                          )) {
                        return;
                      }
                      if (mounted) {
                        ref.read(settingsProvider.notifier).setUsbDirect(value);
                      }
                    },
                  ),
                  if (settings.usbDirect) ...[
                    SettingsSwitchItem(
                      icon: Icons.graphic_eq,
                      title: context.l10n.usbDsdOverPcm,
                      subtitle: context.l10n.usbDsdOverPcmDescription,
                      value: settings.usbDsdOverPcm,
                      onChanged: (value) => ref
                          .read(settingsProvider.notifier)
                          .setUsbDsdOverPcm(value),
                    ),
                    SettingsSwitchItem(
                      icon: Icons.volume_up_outlined,
                      title: context.l10n.usbFixedVolume,
                      subtitle: context.l10n.usbFixedVolumeDescription,
                      value: settings.usbAllowFixedVolume,
                      onChanged: (value) async {
                        if (value &&
                            !await _confirmAudioVolume(
                              context.l10n.usbFixedVolumeWarning,
                            )) {
                          return;
                        }
                        if (mounted) {
                          ref
                              .read(settingsProvider.notifier)
                              .setUsbAllowFixedVolume(value);
                        }
                      },
                    ),
                    ValueListenableBuilder<UsbVolumeState?>(
                      valueListenable: usbHardwareVolume,
                      builder: (context, volume, _) => Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.l10n.usbHardwareVolume,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text(
                              volume == null
                                  ? context.l10n.usbBitPerfectPending
                                  : volume.available
                                  ? '${volume.currentDb.toStringAsFixed(1)} dB'
                                  : context.l10n.usbVolumeUnavailable,
                            ),
                            if (volume?.available == true)
                              PlayerVolumeControl(
                                foreground: colorScheme.onSurface,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  SettingsSwitchItem(
                    icon: Icons.headphones,
                    title: context.l10n.dapExclusive,
                    titleTrailing: const BetaBadge(),
                    subtitle: context.l10n.dapExclusiveDescription,
                    value: settings.dapExclusive,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setDapExclusive(value),
                    showDivider: false,
                  ),
                ],
              ],
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ...settingsSectionSlivers(
            title: context.l10n.listeningStats,
            children: [
              SettingsItem(
                icon: Icons.insights_outlined,
                title: context.l10n.listeningStats,
                subtitle: context.l10n.listeningStatsDescription,
                onTap: () => Navigator.of(context).push(
                  slidePageRoute<void>(page: const ListeningStatisticsScreen()),
                ),
                showDivider: false,
              ),
            ],
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }
}

/// The level, one of [loudVolumeLevels], above which the volume bar asks
/// first; shown under the Confirm loud volume switch.
class _LoudVolumeLevelChoice extends StatelessWidget {
  const _LoudVolumeLevelChoice({required this.level, required this.onChanged});

  final int level;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final title = context.l10n.confirmLoudVolumeLevel;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.tokens.rowPaddingH,
        vertical: context.tokens.rowPaddingVCompact,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 12),
          if (context.isMornye)
            MornyeSegmentedControl(
              labels: [for (final level in loudVolumeLevels) '$level%'],
              selectedIndex: loudVolumeLevels.indexOf(level),
              onChanged: (index) => onChanged(loudVolumeLevels[index]),
              samplesBackdrop: false,
            )
          else
            SettingsSegmentedChoice<int>(
              selected: level,
              onChanged: onChanged,
              semanticLabel: title,
              options: [
                for (final level in loudVolumeLevels)
                  SettingsSegmentOption(value: level, label: '$level%'),
              ],
            ),
        ],
      ),
    );
  }
}

/// When connecting headphones resumes playback: one of [headphoneResumeModes],
/// a three-way choice under its title and the current choice's description.
class _HeadphoneResumeChoice extends StatelessWidget {
  const _HeadphoneResumeChoice({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  final String mode;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final title = l10n.playbackOnHeadphonesConnected;
    final labels = {
      'off': l10n.playbackHeadphonesOff,
      'after_disconnect': l10n.playbackHeadphonesAfterDisconnect,
      'always': l10n.playbackHeadphonesAlways,
    };
    final description = switch (mode) {
      'after_disconnect' => l10n.playbackResumeOnReconnectDescription,
      'always' => l10n.playbackOnHeadphonesConnectedDescription,
      _ => l10n.playbackHeadphonesOffDescription,
    };
    final showIcon = !context.isMornye;
    final choice = context.isMornye
        ? MornyeSegmentedControl(
            labels: labels.values.toList(),
            selectedIndex: labels.keys.toList().indexOf(mode),
            onChanged: (index) => onChanged(labels.keys.elementAt(index)),
            samplesBackdrop: false,
          )
        : SettingsSegmentedChoice<String>(
            selected: mode,
            onChanged: onChanged,
            semanticLabel: title,
            options: [
              for (final MapEntry(:key, :value) in labels.entries)
                SettingsSegmentOption(value: key, label: value),
            ],
          );
    final content = Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.tokens.rowPaddingH,
          vertical: context.tokens.rowPaddingVCompact,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (showIcon) ...[
                  AppIcon(
                    Icons.headphones_outlined,
                    color: enabled
                        ? colorScheme.onSurfaceVariant
                        : colorScheme.outline,
                    size: 24,
                  ),
                  SizedBox(width: context.tokens.rowIconGap),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: textTheme.bodyLarge?.copyWith(
                          color: enabled ? null : colorScheme.outline,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: textTheme.bodyMedium?.copyWith(
                          color: enabled
                              ? colorScheme.onSurfaceVariant
                              : colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            IgnorePointer(
              ignoring: !enabled,
              child: ExcludeSemantics(excluding: !enabled, child: choice),
            ),
          ],
        ),
      ),
    );
    return SettingsSearchTarget(label: title, child: content);
  }
}

/// The ALSA device Linux exclusive output opens, chosen from the cards the
/// system lists.
class _AlsaDeviceItem extends ConsumerStatefulWidget {
  const _AlsaDeviceItem({required this.device});

  /// The saved mpv device name; empty for the first card.
  final String device;

  @override
  ConsumerState<_AlsaDeviceItem> createState() => _AlsaDeviceItemState();
}

class _AlsaDeviceItemState extends ConsumerState<_AlsaDeviceItem> {
  final _devices = listAlsaOutputDevices();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FutureBuilder<List<AlsaOutputDevice>>(
      future: _devices,
      builder: (context, snapshot) {
        final devices = snapshot.data ?? const <AlsaOutputDevice>[];
        final chosen = devices
            .where((device) => device.id == widget.device)
            .firstOrNull;
        return SettingsItem(
          icon: Icons.speaker_group_outlined,
          title: l10n.exclusiveOutputDevice,
          subtitle: devices.isEmpty && snapshot.hasData
              ? l10n.exclusiveOutputNoDevices
              : chosen?.label ??
                    (widget.device.isEmpty
                        ? l10n.exclusiveOutputDeviceFirst
                        : widget.device),
          onTap: devices.isEmpty
              ? null
              : () => showAppChoiceSheet<String>(
                  context: context,
                  title: l10n.exclusiveOutputDevice,
                  selected: widget.device,
                  choices: [
                    AppChoice(
                      '',
                      Icons.speaker_outlined,
                      l10n.exclusiveOutputDeviceFirst,
                      subtitle: devices.first.label,
                    ),
                    for (final device in devices)
                      AppChoice(
                        device.id,
                        Icons.speaker_outlined,
                        device.label,
                        subtitle: device.id.replaceFirst('alsa/', ''),
                      ),
                  ],
                  onSelected: ref
                      .read(settingsProvider.notifier)
                      .setExclusiveOutputDevice,
                ),
          showDivider: false,
        );
      },
    );
  }
}

/// Spatial audio, with a line for what the system does with songs on the
/// current output. The app renders nothing; the platform spatializes.
class _SpatialAudioItem extends ConsumerStatefulWidget {
  const _SpatialAudioItem({required this.platform, this.showDivider = true});

  final SpatialAudioPlatform platform;
  final bool showDivider;

  @override
  ConsumerState<_SpatialAudioItem> createState() => _SpatialAudioItemState();
}

class _SpatialAudioItemState extends ConsumerState<_SpatialAudioItem>
    with WidgetsBindingObserver {
  StreamSubscription<SpatialAudioState>? _states;
  SpatialAudioState? _state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listen();
  }

  /// The native side reports the current state on listen, then each change.
  void _listen() {
    unawaited(_states?.cancel());
    _states = spatialAudioStates(widget.platform).listen((state) {
      if (mounted) setState(() => _state = state);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system settings, where no listener may have fired.
    if (state == AppLifecycleState.resumed) _listen();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_states?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return ValueListenableBuilder<UsbAudioStatus>(
      valueListenable: usbAudioStatus,
      builder: (context, usb, _) {
        final status = spatialAudioStatus(
          enabled: settings.spatialAudio,
          platform: widget.platform,
          state: _state,
          usb: usb,
          exclusiveOutput: settings.exclusiveOutput,
        );
        return SettingsSwitchItem(
          icon: Icons.spatial_audio_outlined,
          title: context.l10n.spatialAudio,
          subtitle: [
            context.l10n.spatialAudioDescription,
            // MediaPlayer reads its attributes as each song loads.
            if (widget.platform == SpatialAudioPlatform.android &&
                !settings.media3Engine)
              context.l10n.spatialAudioNextSong,
            if (status != null) spatialAudioStatusLabel(context.l10n, status),
          ].join('\n\n'),
          value: settings.spatialAudio,
          onChanged: (value) =>
              ref.read(settingsProvider.notifier).setSpatialAudio(value),
          showDivider: widget.showDivider,
        );
      },
    );
  }
}
