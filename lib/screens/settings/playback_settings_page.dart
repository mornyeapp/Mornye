import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/alsa_output_devices.dart';
import 'package:mornye/services/autoplay_ranker.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/music_player_service.dart'
    show resetAutoplayLearning;
import 'package:mornye/services/song_analysis.dart';
import 'package:mornye/screens/listening_statistics_screen.dart';
import 'package:mornye/screens/equalizer_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';
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
import 'package:mornye/widgets/player_volume_control.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/discord_presence_settings.dart';
import 'package:mornye/widgets/automix_settings.dart';
import 'package:mornye/widgets/music_haptics_settings.dart';
import 'package:mornye/widgets/playback_normalization_settings.dart';

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
    // Linux opens a chosen ALSA device; the other desktops use the default.
    final linuxDevice =
        settings.exclusiveOutput &&
        defaultTargetPlatform == TargetPlatform.linux;
    final colorScheme = Theme.of(context).colorScheme;
    final coverStyle = settings.playerCoverStyleFor(mornye: context.isMornye);
    // The charging rule applies to Android's background sweep only.
    final chargingOption = settings.songAnalysis && Platform.isAndroid;
    final progress = _songAnalysis.progress.value;
    final analysis =
        progress != null &&
            progress.total > 0 &&
            (settings.songAnalysis || progress.analyzed > 0)
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
                value: settings.gaplessPlayback && !settings.autoMix,
                enabled:
                    settings.playerMode == 'internal' &&
                    !settings.autoMix &&
                    !settings.usbBitPerfect &&
                    !(isDesktopPlatform && settings.exclusiveOutput),
                onChanged: (value) => ref
                    .read(settingsProvider.notifier)
                    .setGaplessPlayback(value),
              ),
              SettingsSwitchItem(
                icon: Icons.compare_arrows,
                title: 'AutoMix',
                subtitle: context.l10n.autoMixDescription,
                value: settings.autoMix,
                enabled:
                    !settings.usbBitPerfect &&
                    !(isDesktopPlatform && settings.exclusiveOutput),
                onChanged: (value) =>
                    ref.read(settingsProvider.notifier).setAutoMix(value),
                showDivider: false,
              ),
            ],
          ),
          if (settings.autoMix) ...[
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
                  subtitle: context.l10n.songAnalysisProgress(
                    analysis.analyzed,
                    analysis.total,
                  ),
                  footer:
                      settings.songAnalysis &&
                          analysis.analyzed < analysis.total
                      ? AppProgressIndicator.linear(
                          value: analysis.analyzed / analysis.total,
                          trackColor: colorScheme.surfaceContainerHighest,
                          wavy: false,
                        )
                      : null,
                  onTap: analysis.analyzed > 0 ? _confirmClearAnalysis : null,
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
                SettingsSwitchItem(
                  icon: Icons.headphones_outlined,
                  title: context.l10n.playbackOnHeadphonesConnected,
                  subtitle:
                      context.l10n.playbackOnHeadphonesConnectedDescription,
                  value: settings.playOnHeadphonesConnected,
                  enabled: settings.playerMode == 'internal',
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setPlayOnHeadphonesConnected(value),
                  showDivider: false,
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
                      showDivider: linuxDevice,
                    );
                  },
                ),
                if (linuxDevice)
                  _AlsaDeviceItem(device: settings.exclusiveOutputDevice),
              ],
            ),
          if (Platform.isAndroid)
            ...settingsSectionSlivers(
              title: context.l10n.sectionAudioOutput,
              connected: true,
              children: [
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
