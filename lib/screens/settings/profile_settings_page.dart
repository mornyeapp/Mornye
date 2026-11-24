import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_counts_provider.dart';
import 'package:mornye/providers/library_genres_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/profile_overview_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/screens/listening_statistics_screen.dart';
import 'package:mornye/screens/settings/profile_edit_page.dart';
import 'package:mornye/services/listening_rewind.dart';
import 'package:mornye/services/user_profile_store.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/animation_utils.dart' show slidePageRoute;
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/profile_avatar.dart';
import 'package:mornye/widgets/settings_group.dart';

/// The listener's profile: who they are, what is playing, and what the
/// listening record and the Library say about their taste. The name and
/// photo are changed on [ProfileEditPage].
class ProfileSettingsPage extends ConsumerWidget {
  const ProfileSettingsPage({super.key, required this.profile});

  /// Shown until the stored profile has loaded.
  final UserProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final profile = ref.watch(userProfileProvider).value ?? this.profile;
    final recording = ref.watch(
      settingsProvider.select((s) => s.listeningStatisticsEnabled),
    );
    final overview = recording ? ref.watch(profileOverviewProvider) : null;
    final data = overview?.value;
    final heard = data != null && !data.allTime.isEmpty;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.profileTitle),
          SliverList.list(
            children: [
              _Header(profile: profile, overview: heard ? data : null),
              const _NowPlaying(),
              if (!recording)
                SettingsInfoCard(
                  message: l10n.profileListeningOff,
                  icon: Icons.insights_outlined,
                )
              else if (data == null)
                overview!.hasError
                    ? SettingsInfoCard(message: l10n.listeningStatsLoadError)
                    : const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: AppLoadingIndicator()),
                      )
              else if (!heard)
                SettingsInfoCard(
                  message: l10n.listeningStatsEmpty,
                  icon: Icons.insights_outlined,
                )
              else
                ..._listening(context, data),
              SettingsSectionHeader(title: l10n.profileCollection),
              const _Collection(),
              const SizedBox(height: 16),
              SettingsGroup(
                children: [
                  SettingsItem(
                    icon: Icons.insights_outlined,
                    title: l10n.listeningStats,
                    trailing: const AppIcon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      slidePageRoute<void>(
                        page: const ListeningStatisticsScreen(),
                      ),
                    ),
                    showDivider: false,
                  ),
                ],
              ),
              SizedBox(height: 32 + MediaQuery.paddingOf(context).bottom),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _listening(BuildContext context, ProfileOverview data) {
    final l10n = context.l10n;
    final all = data.allTime;
    final summary = data.summary;
    return [
      SettingsSectionHeader(title: l10n.profileAllTime),
      _StatGrid(
        stats: [
          (_duration(context, summary.milliseconds), l10n.profileStatListening),
          (_count(context, summary.tracks.length), l10n.profileStatSongs),
          (_count(context, all.topArtists.length), l10n.profileStatArtists),
          (l10n.profileDays(all.activeDays), l10n.profileStatActiveDays),
          (l10n.profileDays(data.habits.currentStreak), l10n.profileStatStreak),
          (l10n.profileDays(all.longestStreak), l10n.listeningRewindStreak),
        ],
      ),
      SettingsSectionHeader(title: l10n.profileLast30Days),
      _RecentCard(month: data.month, days: data.habits.recent),
      SettingsSectionHeader(title: l10n.profileTaste),
      _TasteCard(overview: data),
      SettingsSectionHeader(title: l10n.profileHabits),
      _HabitsCard(overview: data),
      if (all.topArtists.isNotEmpty) ...[
        SettingsSectionHeader(title: l10n.listeningStatsTopArtists),
        _Shelf(
          round: true,
          tiles: [
            for (final artist in all.topArtists.take(_Shelf.most))
              (
                artwork: summary.artistArtwork[artist.key],
                title: artist.key,
                detail: _duration(context, artist.value),
              ),
          ],
        ),
      ],
      if (all.topAlbums.isNotEmpty) ...[
        SettingsSectionHeader(title: l10n.profileTopAlbums),
        _Shelf(
          tiles: [
            for (final album in all.topAlbums.take(_Shelf.most))
              (
                artwork: album.artwork,
                title: album.album,
                detail: album.artist.trim().isEmpty
                    ? _duration(context, album.milliseconds)
                    : album.artist,
              ),
          ],
        ),
      ],
      SettingsSectionHeader(title: l10n.listeningStatsTopTracks),
      SettingsGroup(
        children: [
          for (final total in summary.tracks.take(5))
            ListTile(
              leading: _Cover(artwork: total.track.artwork, size: 48),
              title: Text(
                total.track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                total.track.artist.trim().isEmpty
                    ? l10n.unknownArtist
                    : total.track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(_duration(context, total.milliseconds)),
            ),
        ],
      ),
    ];
  }
}

String _locale(BuildContext context) =>
    Localizations.localeOf(context).toLanguageTag();

String _count(BuildContext context, int value) =>
    NumberFormat.decimalPattern(_locale(context)).format(value);

/// Minutes under an hour, hours above: one decimal under ten hours.
String _duration(BuildContext context, int milliseconds) {
  final minutes = (milliseconds / 60000).round();
  if (minutes < 60) return context.l10n.listeningStatsMinutes(minutes);
  final hours = milliseconds / 3600000;
  return context.l10n.profileHours(
    NumberFormat.decimalPatternDigits(
      locale: _locale(context),
      decimalDigits: hours < 10 ? 1 : 0,
    ).format(hours),
  );
}

/// The side inset [SettingsGroup] gives itself, for content outside one.
class _Inset extends StatelessWidget {
  const _Inset({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Padding(
      padding: EdgeInsets.symmetric(
        horizontal: settingsHorizontalInset(context, constraints.maxWidth),
      ),
      child: child,
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.profile, required this.overview});

  final UserProfile profile;

  /// Null while nothing was heard or the record is not shown.
  final ProfileOverview? overview;

  /// One line for the taste: the leading genre when it takes half of the
  /// listening, a mix otherwise.
  String? _taste(BuildContext context) {
    final overview = this.overview;
    if (overview == null || overview.genres.isEmpty) return null;
    final l10n = context.l10n;
    final names = [for (final genre in overview.genres.take(3)) genre.name];
    final leads =
        overview.genres.first.milliseconds * 2 >= overview.genreMilliseconds;
    if (names.length == 1) return l10n.profileTasteMostly(names.first);
    return leads
        ? l10n.profileTasteMostlyWith(names.first, names.skip(1).join(', '))
        : l10n.profileTasteMix(names.join(', '));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final name = profile.name.trim();
    final taste = _taste(context);
    final since = overview?.since;
    return _Inset(
      child: Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Column(
          children: [
            ProfileAvatar(
              name: profile.name,
              photoPath: profile.photoPath,
              size: 112,
            ),
            const SizedBox(height: 16),
            Text(
              name.isEmpty ? l10n.profileSetUp : name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (taste != null) ...[
              const SizedBox(height: 4),
              Text(taste, textAlign: TextAlign.center, style: muted),
            ],
            if (since != null) ...[
              const SizedBox(height: 2),
              Text(
                l10n.profileListeningSince(
                  DateFormat.yMMMM(_locale(context)).format(since),
                ),
                textAlign: TextAlign.center,
                style: muted,
              ),
            ],
            const SizedBox(height: 16),
            AppActionButton(
              onPressed: () => Navigator.of(context).push(
                slidePageRoute<void>(
                  page: MornyeSettingsTheme(
                    child: ProfileEditPage(profile: profile),
                  ),
                ),
              ),
              icon: const AppIcon(Icons.edit_outlined),
              label: Text(l10n.profileEditAction),
              outlined: true,
              tonal: true,
            ),
          ],
        ),
      ),
    );
  }
}

/// The song in the player, when there is one.
class _NowPlaying extends ConsumerWidget {
  const _NowPlaying();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(currentMediaItemProvider).value;
    if (item == null) return const SizedBox.shrink();
    final artist = item.artist?.trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(title: context.l10n.profileNowPlaying),
        SettingsGroup(
          children: [
            ListTile(
              leading: _Cover(artwork: item.artUri?.toString(), size: 48),
              title: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                artist.isEmpty ? context.l10n.unknownArtist : artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.artwork, required this.size, this.round = false});

  final String? artwork;
  final double size;

  /// The artist shape instead of a cover's rounded square.
  final bool round;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final image = SizedBox.square(
      dimension: size,
      child: round && artwork == null
          ? ColoredBox(
              color: colors.surfaceContainerHighest,
              child: Icon(Icons.person_outline, size: size * 0.45),
            )
          : PlayerArtwork(
              artUri: artwork,
              colorScheme: colors,
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                  .ceil(),
              iconSize: size * 0.45,
            ),
    );
    return ExcludeSemantics(
      child: round
          ? AppShapeClip(kind: AppShapes.artist, child: image)
          : ClipRRect(
              borderRadius: BorderRadius.circular(size >= 64 ? 12 : 8),
              child: image,
            ),
    );
  }
}

/// Figures with a label each, on one surface: three to a row where there is
/// room, two on a phone.
class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.stats});

  final List<(String, String)> stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell((String, String) stat) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          stat.$1,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          stat.$2,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 460 ? 3 : 2;
              return Column(
                children: [
                  for (var row = 0; row < stats.length; row += columns) ...[
                    if (row > 0) const SizedBox(height: 20),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = row; i < row + columns; i++) ...[
                          if (i > row) const SizedBox(width: 16),
                          Expanded(
                            child: i < stats.length
                                ? cell(stats[i])
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Bars that share one scale, the tallest at full height. A value of zero
/// keeps a stub, so every position on the axis shows.
class _Bars extends StatelessWidget {
  const _Bars({
    required this.values,
    required this.height,
    required this.gap,
    this.labels,
  });

  final List<int> values;
  final double height;
  final double gap;

  /// One label under each bar.
  final List<String>? labels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final peak = values.fold(0, math.max);
    final radius = Radius.circular(gap >= 6 ? 4 : 2);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final (index, value) in values.indexed) ...[
          if (index > 0) SizedBox(width: gap),
          Expanded(
            child: Column(
              children: [
                SizedBox(
                  height: height,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      widthFactor: 1,
                      heightFactor: value <= 0 || peak <= 0
                          ? 2 / height
                          : math.max(value / peak, 3 / height),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          // The busiest stands out, as on the statistics
                          // page.
                          color: value <= 0
                              ? colors.surfaceContainerHighest
                              : value == peak
                              ? colors.primary
                              : colors.secondary,
                          borderRadius: BorderRadius.vertical(top: radius),
                        ),
                      ),
                    ),
                  ),
                ),
                if (labels != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    labels![index],
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// A label with its value at the trailing end.
class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The last thirty days: the time, how it compares with the thirty before,
/// a bar per day, and the artists first heard in them.
class _RecentCard extends StatelessWidget {
  const _RecentCard({required this.month, required this.days});

  final ListeningRewind month;
  final List<int> days;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final change = month.changePercent;
    final format = DateFormat.MMMd(_locale(context));
    final today = DateTime.now();
    final first = DateTime(
      today.year,
      today.month,
      today.day - days.length + 1,
    );
    final found = month.newArtists;
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _duration(context, month.summary.milliseconds),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (change != null) ...[
                const SizedBox(height: 2),
                Text(
                  change > 0
                      ? l10n.listeningRewindMore(change)
                      : change < 0
                      ? l10n.listeningRewindLess(-change)
                      : l10n.listeningRewindSame,
                  style: muted,
                ),
              ],
              const SizedBox(height: 16),
              Semantics(
                label: l10n.profileRecentChart,
                child: ExcludeSemantics(
                  child: _Bars(values: days, height: 56, gap: 3),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final day in [first, today])
                    Text(
                      format.format(day),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              if (found.isNotEmpty) ...[
                const SizedBox(height: 10),
                _Fact(
                  label: l10n.listeningRewindNewArtistsTitle,
                  value: [
                    ...found.take(3),
                    if (found.length > 3) '+${found.length - 3}',
                  ].join(', '),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The genres the listening time goes to, as shares of the time whose genre
/// is known.
class _TasteCard extends StatelessWidget {
  const _TasteCard({required this.overview});

  final ProfileOverview overview;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final genres = overview.genres.take(5).toList();
    final percent = NumberFormat.percentPattern(_locale(context));
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: genres.isEmpty
              ? Text(l10n.profileTasteEmpty, style: muted)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final genre in genres) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              genre.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyLarge,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            percent.format(
                              genre.milliseconds / overview.genreMilliseconds,
                            ),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // One hue: the bars measure, they do not name.
                      Container(
                        height: 8,
                        decoration: ShapeDecoration(
                          color: colors.surfaceContainerHighest,
                          shape: const StadiumBorder(),
                        ),
                        alignment: AlignmentDirectional.centerStart,
                        child: FractionallySizedBox(
                          widthFactor:
                              (genre.milliseconds / overview.genreMilliseconds)
                                  .clamp(0.0, 1.0),
                          heightFactor: 1,
                          child: DecoratedBox(
                            decoration: ShapeDecoration(
                              color: colors.primary,
                              shape: const StadiumBorder(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    Text(l10n.profileTasteNote, style: muted),
                  ],
                ),
        ),
      ],
    );
  }
}

/// When the listening happens: time by weekday, the favorite and the
/// biggest day, an ordinary day, and the song replayed most in one day.
class _HabitsCard extends StatelessWidget {
  const _HabitsCard({required this.overview});

  final ProfileOverview overview;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final locale = _locale(context);
    final all = overview.allTime;
    final habits = overview.habits;
    // 1 January 2024 is a Monday.
    DateTime weekday(int index) => DateTime(2024, 1, 1 + index);
    final favorite = all.favoriteWeekday;
    final peak = all.peakDay;
    final replay = all.replay;
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                label: favorite == null
                    ? null
                    : l10n.profileWeekdayChart(
                        DateFormat.EEEE(locale).format(weekday(favorite - 1)),
                      ),
                child: ExcludeSemantics(
                  child: _Bars(
                    values: habits.weekdays,
                    height: 72,
                    gap: 8,
                    labels: [
                      for (var day = 0; day < 7; day++)
                        DateFormat.E(locale).format(weekday(day)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (favorite != null)
                _Fact(
                  label: l10n.listeningRewindFavoriteDay,
                  value: DateFormat.EEEE(locale).format(weekday(favorite - 1)),
                ),
              if (peak != null)
                _Fact(
                  label: l10n.listeningRewindPeakDay,
                  value:
                      '${DateFormat.yMMMd(locale).format(peak)} · '
                      '${_duration(context, all.peakDayMilliseconds)}',
                ),
              _Fact(
                label: l10n.profileAverageDay,
                value: _duration(context, habits.averageMilliseconds),
              ),
              if (replay != null) ...[
                _Fact(
                  label: l10n.listeningRewindReplayTitle,
                  value: replay.track.title,
                ),
                Text(
                  l10n.listeningRewindReplayBody(
                    replay.plays,
                    DateFormat.yMMMd(locale).format(replay.day),
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

typedef _ShelfTile = ({String? artwork, String title, String detail});

/// Covers side by side with a name and a detail under each: as many of
/// [tiles] as the width holds, three on a phone.
class _Shelf extends StatelessWidget {
  const _Shelf({required this.tiles, this.round = false});

  /// The most a shelf shows, on the widest page.
  static const most = 6;

  final List<_ShelfTile> tiles;
  final bool round;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const gap = 12.0;
    return _Inset(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final columns = width >= 760
              ? most
              : width >= 560
              ? 5
              : width >= 420
              ? 4
              : 3;
          final size = math.min((width - gap * (columns - 1)) / columns, 168.0);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (index, tile) in tiles.take(columns).indexed) ...[
                if (index > 0) const SizedBox(width: gap),
                SizedBox(
                  width: size,
                  child: Column(
                    crossAxisAlignment: round
                        ? CrossAxisAlignment.center
                        : CrossAxisAlignment.start,
                    children: [
                      _Cover(artwork: tile.artwork, size: size, round: round),
                      const SizedBox(height: 8),
                      Text(
                        tile.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: round ? TextAlign.center : TextAlign.start,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        tile.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: round ? TextAlign.center : TextAlign.start,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// What the listener keeps: the Library and their own collections.
class _Collection extends ConsumerWidget {
  const _Collection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final counts = ref
        .watch(
          libraryCountsProvider(
            LibraryCountsRequest.all(
              localLibraryEnabled: ref.watch(
                settingsProvider.select((s) => s.localLibraryEnabled),
              ),
            ),
          ),
        )
        .value;
    final genres = ref.watch(libraryGenresProvider).value;
    final collections = ref.watch(libraryCollectionsProvider);
    String count(int? value) => value == null ? '' : _count(context, value);
    return _StatGrid(
      stats: [
        (count(counts?.allTrackCount), l10n.listeningRewindSongsLabel),
        (count(counts?.albumCount), l10n.listeningRewindAlbumsLabel),
        (count(genres?.length), l10n.libraryGenres),
        (count(collections.lovedCount), l10n.collectionLoved),
        (count(collections.playlistCount), l10n.searchPlaylists),
        (
          count(collections.favoriteArtistCount),
          l10n.collectionFavoriteArtists,
        ),
      ],
    );
  }
}
