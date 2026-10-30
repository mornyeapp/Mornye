import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/listening_statistics_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/listening_rewind_screen.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/sync/sync_orchestration_service.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/animation_utils.dart' show SkeletonBox;
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_refresh_indicator.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/settings_group.dart';

export 'package:mornye/providers/listening_statistics_provider.dart';

class ListeningStatisticsScreen extends ConsumerStatefulWidget {
  const ListeningStatisticsScreen({super.key});

  @override
  ConsumerState<ListeningStatisticsScreen> createState() =>
      _ListeningStatisticsScreenState();
}

class _ListeningStatisticsScreenState
    extends ConsumerState<ListeningStatisticsScreen> {
  int _days = 7;
  int _year = DateTime.now().year;
  bool _clearing = false;
  bool _syncing = false;
  bool _syncEnabled = false;
  DateTime? _lastSyncTime;
  StreamSubscription<SyncStatus>? _statusSub;

  @override
  void initState() {
    super.initState();
    _initSyncState();
    final current = SyncOrchestrationService.instance.currentStatus;
    _lastSyncTime = current.lastSyncTime;
    _syncing = current.state == SyncStatusState.syncing;
    _statusSub = SyncOrchestrationService.instance.statusStream.listen((
      status,
    ) {
      if (mounted) {
        setState(() {
          _syncing = status.state == SyncStatusState.syncing;
          if (status.lastSyncTime != null) {
            _lastSyncTime = status.lastSyncTime;
          }
        });
        if (status.state == SyncStatusState.success) {
          final period = (days: _days, year: _year);
          ref.invalidate(listeningSummaryProvider(period));
          ref.invalidate(listeningRewindProvider);
          ref.invalidate(listeningRewindSpotlightProvider);
        }
      }
    });
  }

  Future<void> _initSyncState() async {
    final enabled = await SyncOrchestrationService.instance.isSyncEnabled();
    if (mounted) {
      setState(() => _syncEnabled = enabled);
    }
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _handleManualSync() async {
    if (_syncing || _clearing || !_syncEnabled) return;
    setState(() => _syncing = true);
    final period = (days: _days, year: _year);
    try {
      await listeningRecorder.flush();
      final status = await SyncOrchestrationService.instance.synchronize();
      ref.invalidate(listeningSummaryProvider(period));
      ref.invalidate(listeningRewindProvider);
      ref.invalidate(listeningRewindSpotlightProvider);
      if (!mounted) return;
      final activeCount = status.activeDeviceCount;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Synchronized • $activeCount active device${activeCount == 1 ? '' : 's'} in sync',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sync failed: $e'),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
      }
    }
  }

  Future<void> _clear() async {
    if (!_syncEnabled) {
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppAlertDialog(
          title: Text(context.l10n.listeningStatsClear),
          content: Text(context.l10n.listeningStatsClearDescription),
          actions: [
            AppDialogAction(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.dialogCancel),
            ),
            AppDialogAction(
              isDestructive: true,
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.listeningStatsClear),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _clearing = true);
      try {
        await listeningRecorder.clear(
          ListeningStatisticsStore.instance.clearThisDeviceHistory,
        );
        ref.invalidate(listeningSummaryProvider);
        ref.invalidate(listeningRewindProvider);
        ref.invalidate(listeningRewindSpotlightProvider);
      } finally {
        if (mounted) setState(() => _clearing = false);
      }
      return;
    }

    final choice = await showAppDialog<int>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(context.l10n.listeningStatsClear),
        content: const Text(
          'Choose how you want to clear your listening history:\n\n'
          '• This Device Only: Removes history recorded by this device, keeps imported peer data, and empties this device\'s sync partition.\n\n'
          '• Across All Synced Devices: Permanently purges history on all synced phones and PCs, advancing the sync epoch.',
        ),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(context, 0),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            onPressed: () => Navigator.pop(context, 1),
            child: const Text('This Device Only'),
          ),
          AppDialogAction(
            isDestructive: true,
            onPressed: () => Navigator.pop(context, 2),
            child: const Text('All Synced Devices'),
          ),
        ],
      ),
    );
    if (choice == null || choice == 0 || !mounted) return;
    setState(() => _clearing = true);
    try {
      if (choice == 1) {
        await listeningRecorder.clear(
          ListeningStatisticsStore.instance.clearThisDeviceHistory,
        );
      } else if (choice == 2) {
        final confirmed = await showAppDialog<bool>(
          context: context,
          builder: (context) => AppAlertDialog(
            title: const Text('Confirm Global Clear'),
            content: const Text(
              'Are you sure you want to delete listening history across ALL your devices? This action cannot be undone.',
            ),
            actions: [
              AppDialogAction(
                onPressed: () => Navigator.pop(context, false),
                child: Text(context.l10n.dialogCancel),
              ),
              AppDialogAction(
                isDestructive: true,
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete Everywhere'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await SyncOrchestrationService.instance.clearAcrossAllDevices();
        }
      }
      ref.invalidate(listeningSummaryProvider);
      ref.invalidate(listeningRewindProvider);
      ref.invalidate(listeningRewindSpotlightProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.listeningStatsClearError)),
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final period = (days: _days, year: _year);
    final summary = ref.watch(listeningSummaryProvider(period));
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: AppRefreshIndicator(
        onRefresh: () => ref.refresh(listeningSummaryProvider(period).future),
        child: CustomScrollView(
          slivers: [
            AppSliverHeader.page(
              title: context.l10n.listeningStats,
              actions: [
                if (_syncEnabled)
                  AppIconButton(
                    icon: _syncing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync),
                    tooltip: _syncing
                        ? 'Syncing...'
                        : (_lastSyncTime != null
                              ? 'Last synced: ${DateFormat.jm().format(_lastSyncTime!.toLocal())}'
                              : 'Sync Listening Statistics'),
                    onPressed: _syncing || _clearing ? null : _handleManualSync,
                  ),
              ],
            ),
            // Centered at the reading width on tablets, under the title.
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: SettingsGroup(
                      children: [
                        SettingsSwitchItem(
                          icon: Icons.insights_outlined,
                          title: context.l10n.listeningStatsRecord,
                          subtitle: context.l10n.listeningStatsDescription,
                          value: ref
                              .watch(settingsProvider)
                              .listeningStatisticsEnabled,
                          enabled: !_clearing,
                          onChanged: (value) => ref
                              .read(settingsProvider.notifier)
                              .setListeningStatisticsEnabled(value),
                          showDivider: false,
                        ),
                      ],
                    ),
                  ),
                  const SliverToBoxAdapter(child: ListeningRewindEntry()),
                  SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: SliverToBoxAdapter(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final days in [7, 30, 0])
                            AppChoiceChip(
                              label: Text(
                                days == 0
                                    ? '$_year'
                                    : context.l10n.listeningStatsDays(days),
                              ),
                              selected: _days == days,
                              onSelected: (_) => setState(() => _days = days),
                            ),
                          if (_days == 0)
                            AppIconButton(
                              tooltip: context.l10n.listeningStatsPreviousYear,
                              onPressed: () => setState(() => _year--),
                              icon: const Icon(Icons.chevron_left),
                            ),
                          if (_days == 0)
                            AppIconButton(
                              tooltip: context.l10n.listeningStatsNextYear,
                              onPressed: _year >= DateTime.now().year
                                  ? null
                                  : () => setState(() => _year++),
                              icon: const Icon(Icons.chevron_right),
                            ),
                        ],
                      ),
                    ),
                  ),
                  ...summary.when(
                    loading: () => [
                      SliverToBoxAdapter(child: _summarySkeleton(context)),
                    ],
                    error: (error, _) => [
                      SliverToBoxAdapter(
                        child: ListTile(
                          title: Text(context.l10n.listeningStatsLoadError),
                          trailing: AppIconButton(
                            icon: const Icon(Icons.refresh),
                            onPressed: () => ref.invalidate(
                              listeningSummaryProvider(period),
                            ),
                          ),
                        ),
                      ),
                    ],
                    data: (data) => _summarySlivers(context, data),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 48),
                      child: ExpressiveButton(
                        text: true,
                        onPressed: _clearing ? null : _clear,
                        icon: Icon(Icons.delete_outline, color: colors.error),
                        child: Text(
                          context.l10n.listeningStatsClear,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Material rows form an expressive connected list; Mornye keeps plain rows.
  Widget _connectedRow(
    BuildContext context, {
    required int index,
    required int count,
    required Widget child,
  }) {
    if (context.isMornye) return child;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, index == 0 ? 0 : 2, 16, 0),
      child: Material(
        color: settingsGroupColor(context),
        clipBehavior: Clip.antiAlias,
        borderRadius: connectedRowRadius(
          context,
          first: index == 0,
          last: index == count - 1,
        ),
        child: child,
      ),
    );
  }

  Widget _summarySkeleton(BuildContext context) {
    final mornye = context.isMornye;
    return ExcludeSemantics(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: AppContentCard(
              mornyeSurface: false,
              color: mornye
                  ? null
                  : Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: EdgeInsets.all(mornye ? 20 : 24),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(width: 180, height: 44),
                    SizedBox(height: 8),
                    SkeletonBox(width: double.infinity, height: 20),
                  ],
                ),
              ),
            ),
          ),
          SettingsSectionHeader(title: context.l10n.listeningStatsActivity),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                for (var index = 0; index < 7; index++)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        SkeletonBox(width: 68, height: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: SkeletonBox(
                            width: double.infinity,
                            height: 12,
                          ),
                        ),
                        SizedBox(width: 12),
                        SkeletonBox(width: 24, height: 16),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          for (final artists in [true, false]) ...[
            SettingsSectionHeader(
              title: artists
                  ? context.l10n.listeningStatsTopArtists
                  : context.l10n.listeningStatsTopTracks,
            ),
            for (var index = 0; index < 3; index++)
              _connectedRow(
                context,
                index: index,
                count: 3,
                child: ListTile(
                  leading: artists
                      ? const AppShapeClip(
                          kind: AppShapes.artist,
                          child: SkeletonBox(
                            width: 48,
                            height: 48,
                            borderRadius: 0,
                          ),
                        )
                      : const SkeletonBox(width: 48, height: 48),
                  title: const Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SkeletonBox(width: 160, height: 16),
                  ),
                  subtitle: const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: SkeletonBox(width: 88, height: 12),
                    ),
                  ),
                  trailing: artists
                      ? null
                      : const SkeletonBox(width: 40, height: 12),
                ),
              ),
          ],
        ],
      ),
    );
  }

  List<Widget> _summarySlivers(BuildContext context, ListeningSummary data) {
    final colors = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final artists = data.artists.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topArtists = artists.take(10).toList();
    final topTracks = data.tracks.take(20).toList();
    final artistArtwork = data.artistArtwork;
    final days = data.days.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final recentDays = days
        .skip((days.length - 7).clamp(0, days.length))
        .toList();
    final peakDay = days.isEmpty
        ? 0
        : days.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    final textTheme = Theme.of(context).textTheme;
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: AppContentCard(
            mornyeSurface: false,
            // Material leads with the total as an emphasized hero figure.
            color: mornye ? null : colors.primaryContainer,
            child: Padding(
              padding: EdgeInsets.all(mornye ? 20 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.listeningStatsMinutes(
                      (data.milliseconds / 60000).round(),
                    ),
                    style: mornye
                        ? textTheme.headlineMedium
                        : textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: colors.onPrimaryContainer,
                          ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.listeningStatsTotals(
                      data.plays,
                      data.tracks.length,
                      data.days.length,
                    ),
                    style: mornye
                        ? null
                        : textTheme.bodyLarge?.copyWith(
                            color: colors.onPrimaryContainer,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      if (data.tracks.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(context.l10n.listeningStatsEmpty),
          ),
        ),
      if (days.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: SettingsSectionHeader(
            title: context.l10n.listeningStatsActivity,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                for (final day in recentDays)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 68,
                          child: Text(
                            DateFormat.MMMd(
                              Localizations.localeOf(context).toLanguageTag(),
                            ).format(DateTime.parse(day.key)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: materialExpressiveEnabled(context)
                              ? _ActivityBar(
                                  fraction: day.value / peakDay,
                                  peak: day.value == peakDay,
                                )
                              : LinearProgressIndicator(
                                  value: day.value / peakDay,
                                  minHeight: 8,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                        ),
                        const SizedBox(width: 12),
                        Text('${(day.value / 60000).round()}'),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
      SliverToBoxAdapter(
        child: SettingsSectionHeader(
          title: context.l10n.listeningStatsTopArtists,
        ),
      ),
      SliverList.list(
        children: [
          for (final (index, artist) in topArtists.indexed)
            _connectedRow(
              context,
              index: index,
              count: topArtists.length,
              child: ListTile(
                leading: ExcludeSemantics(
                  child: AppShapeClip(
                    kind: AppShapes.artist,
                    child: SizedBox.square(
                      dimension: 48,
                      child: artistArtwork[artist.key] == null
                          ? ColoredBox(
                              color: colors.surfaceContainerHighest,
                              child: const Icon(Icons.person_outline),
                            )
                          : PlayerArtwork(
                              artUri: artistArtwork[artist.key],
                              colorScheme: colors,
                              cacheWidth:
                                  (48 * MediaQuery.devicePixelRatioOf(context))
                                      .ceil(),
                              iconSize: 24,
                            ),
                    ),
                  ),
                ),
                title: Text(artist.key),
                subtitle: Text(
                  context.l10n.listeningStatsMinutes(
                    (artist.value / 60000).round(),
                  ),
                ),
              ),
            ),
        ],
      ),
      SliverToBoxAdapter(
        child: SettingsSectionHeader(
          title: context.l10n.listeningStatsTopTracks,
        ),
      ),
      SliverList.list(
        children: [
          for (final (index, total) in topTracks.indexed)
            _connectedRow(
              context,
              index: index,
              count: topTracks.length,
              child: ListTile(
                leading: ExcludeSemantics(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox.square(
                      dimension: 48,
                      child: PlayerArtwork(
                        artUri: total.track.artwork,
                        colorScheme: Theme.of(context).colorScheme,
                        cacheWidth:
                            (48 * MediaQuery.devicePixelRatioOf(context))
                                .ceil(),
                        iconSize: 24,
                      ),
                    ),
                  ),
                ),
                title: Text(
                  total.track.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  total.track.artist.trim().isEmpty
                      ? context.l10n.unknownArtist
                      : total.track.artist,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Text(
                  context.l10n.listeningStatsMinutes(
                    (total.milliseconds / 60000).round(),
                  ),
                ),
              ),
            ),
        ],
      ),
    ];
  }
}

/// One day of listening activity. The bar grows in on a spatial spring and the
/// busiest day takes the primary color.
class _ActivityBar extends StatelessWidget {
  const _ActivityBar({required this.fraction, required this.peak});

  final double fraction;
  final bool peak;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final motion = AppMotion.spatial(
      context,
      const AppMotionSpec(Duration.zero, Curves.linear),
    );
    return Container(
      height: 12,
      decoration: ShapeDecoration(
        color: colors.surfaceContainerHighest,
        shape: const StadiumBorder(),
      ),
      alignment: AlignmentDirectional.centerStart,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: fraction.clamp(0.0, 1.0)),
        duration: motion.duration,
        curve: motion.curve,
        builder: (context, value, _) => FractionallySizedBox(
          // The spring may overshoot; keep the fill inside its track.
          widthFactor: value.clamp(0.0, 1.0),
          heightFactor: 1,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: peak ? colors.primary : colors.secondary,
              shape: const StadiumBorder(),
            ),
          ),
        ),
      ),
    );
  }
}
