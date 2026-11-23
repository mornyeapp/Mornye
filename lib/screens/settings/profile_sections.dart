part of 'profile_settings_page.dart';

typedef _Part = ({String label, int milliseconds, Color color});

/// Shares of [total] as one bar of colored parts, then a legend row per
/// part with its time and share.
class _PartsChart extends StatelessWidget {
  const _PartsChart({
    required this.parts,
    required this.total,
    required this.label,
    this.note,
    this.footer = const [],
  });

  final List<_Part> parts;
  final int total;

  /// What the bar shows, for screen readers.
  final String label;
  final String? note;

  /// Shown under the legend.
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final figures = const [FontFeature.tabularFigures()];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: label,
          child: ExcludeSemantics(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: SizedBox(
                height: 14,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, part) in parts.indexed) ...[
                      if (index > 0) const SizedBox(width: 2),
                      Expanded(
                        flex: (part.milliseconds * 1000 / total).round().clamp(
                          1,
                          1000,
                        ),
                        child: ColoredBox(color: part.color),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        for (final part in parts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: part.color,
                    shape: const CircleBorder(),
                  ),
                  child: const SizedBox.square(dimension: 10),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    part.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _duration(context, part.milliseconds),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: figures,
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 52),
                  child: Text(
                    _percent(context, part.milliseconds / total),
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFeatures: figures,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ...footer,
        if (note != null) ...[
          const SizedBox(height: 10),
          Text(
            note!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// A bar per month of the last twelve and the best of them.
class _MonthsCard extends StatelessWidget {
  const _MonthsCard({required this.months});

  /// Oldest first, this month last.
  final List<int> months;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final locale = _locale(context);
    final today = DateTime.now();
    DateTime month(int index) =>
        DateTime(today.year, today.month - (months.length - 1 - index));
    var best = 0;
    for (var index = 1; index < months.length; index++) {
      if (months[index] > months[best]) best = index;
    }
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                label: l10n.profileMonthChart,
                child: ExcludeSemantics(
                  child: _Bars(
                    values: months,
                    height: 72,
                    gap: 6,
                    labels: [
                      for (var index = 0; index < months.length; index++)
                        DateFormat('MMMMM', locale).format(month(index)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _Fact(
                label: l10n.profileBestMonth,
                value:
                    '${DateFormat.yMMMM(locale).format(month(best))} · '
                    '${_duration(context, months[best])}',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The words the record bears out, each with its reason. Hidden while the
/// record bears none out.
class _TraitsSection extends ConsumerWidget {
  const _TraitsSection({required this.overview});

  final ProfileOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final traits = profileTraits(
      overview,
      rhythm: ref.watch(profileRhythmProvider).value,
    );
    if (traits.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(title: context.l10n.profileTraits),
        SettingsGroup(
          children: [
            for (final (index, fact) in traits.indexed)
              SettingsItem(
                icon: profileTraitIcon(fact.trait),
                title: profileTraitName(context, fact),
                subtitle: profileTraitBody(context, fact),
                showDivider: index < traits.length - 1,
              ),
          ],
        ),
      ],
    );
  }
}

/// Listening time by the decade the songs came out in, and the decade with
/// the most.
class _DecadesCard extends StatelessWidget {
  const _DecadesCard({required this.sound});

  final ProfileSound sound;

  /// The most decades the chart has room for, up to the newest.
  static const most = 8;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final era = sound.era!;
    final last = sound.decades.last.decade;
    final first = math.max(sound.decades.first.decade, last - (most - 1) * 10);
    final times = {
      for (final decade in sound.decades) decade.decade: decade.milliseconds,
    };
    final decades = [for (var d = first; d <= last; d += 10) d];
    final name = l10n.profileDecade('${era.decade}');
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (decades.length > 1) ...[
                Semantics(
                  label: l10n.profileDecadeChart(name),
                  child: ExcludeSemantics(
                    child: _Bars(
                      values: [for (final d in decades) times[d] ?? 0],
                      height: 72,
                      gap: 8,
                      labels: [
                        for (final d in decades)
                          l10n.profileDecade(
                            (d % 100).toString().padLeft(2, '0'),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              _Fact(
                label: l10n.profileEra,
                value:
                    '$name · '
                    '${_percent(context, era.milliseconds / sound.decadeMilliseconds)}',
              ),
              const SizedBox(height: 4),
              Text(
                l10n.profileDecadesNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// How the heard songs are stored: Hi-Res, lossless or lossy, and the
/// format played most.
class _SoundCard extends StatelessWidget {
  const _SoundCard({required this.sound});

  final ProfileSound sound;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final format = sound.formats.firstOrNull;
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: _PartsChart(
            total: sound.qualityMilliseconds,
            label: l10n.profileSoundChart,
            note: l10n.profileSoundNote,
            parts: [
              for (final tier in ProfileQuality.values)
                if ((sound.quality[tier] ?? 0) > 0)
                  (
                    label: profileQualityName(context, tier),
                    milliseconds: sound.quality[tier]!,
                    color: profileQualityColor(
                      theme.brightness,
                      tier,
                      lossy: theme.colorScheme.outline,
                    ),
                  ),
            ],
            footer: [
              if (format != null) ...[
                const SizedBox(height: 6),
                _Fact(
                  label: l10n.profileTopFormat,
                  value:
                      '${format.name} · '
                      '${_percent(context, format.milliseconds / sound.qualityMilliseconds)}',
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

String _daypart(BuildContext context, ProfileDaypart part) => switch (part) {
  ProfileDaypart.morning => context.l10n.profileDaypartMorning,
  ProfileDaypart.afternoon => context.l10n.profileDaypartAfternoon,
  ProfileDaypart.evening => context.l10n.profileDaypartEvening,
  ProfileDaypart.night => context.l10n.profileDaypartNight,
};

/// Songs played on at each hour, the busiest part of the day and how many
/// were not skipped, from the sessions the player learned from. Hidden
/// while it has too few.
class _TimeOfDaySection extends ConsumerWidget {
  const _TimeOfDaySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rhythm = ref.watch(profileRhythmProvider).value;
    final peak = rhythm?.peakHour;
    final part = rhythm?.daypart;
    if (rhythm == null || rhythm.isEmpty || peak == null || part == null) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final format = DateFormat.j(_locale(context));
    String hour(int value) => format.format(DateTime(2024, 1, 1, value));
    final label = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(title: l10n.profileTimeOfDay),
        SettingsGroup(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: l10n.profileHourChart(hour(peak)),
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Bars(values: rhythm.hours, height: 64, gap: 2),
                          const SizedBox(height: 6),
                          // Midnight, then every six hours to midnight again.
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              for (final value in const [0, 6, 12, 18, 0])
                                Text(hour(value), style: label),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Fact(
                    label: l10n.profileMostActive,
                    value: _daypart(context, part),
                  ),
                  _Fact(label: l10n.profilePeakHour, value: hour(peak)),
                  _Fact(
                    label: l10n.profileNotSkipped,
                    value: _percent(context, rhythm.throughShare),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.profileRhythmNote(
                      rhythm.playedThrough + rhythm.skipped,
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
