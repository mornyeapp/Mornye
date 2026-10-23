import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/weekly_releases_provider.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_refresh_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/settings_group.dart';

class WeeklyReleasesScreen extends ConsumerStatefulWidget {
  const WeeklyReleasesScreen({super.key});

  @override
  ConsumerState<WeeklyReleasesScreen> createState() =>
      _WeeklyReleasesScreenState();
}

class _WeeklyReleasesScreenState extends ConsumerState<WeeklyReleasesScreen> {
  int _days = 7;
  bool _refresh = false;

  Future<void> _reload() async {
    if (_refresh) return;
    setState(() => _refresh = true);
    try {
      await ref.refresh(weeklyReleasesProvider(true).future).then((_) {});
      if (mounted) ref.invalidate(weeklyReleasesProvider(false));
    } catch (_) {
      // The provider displays the failure without leaving refresh latched on.
    } finally {
      if (mounted) setState(() => _refresh = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(weeklyReleasesProvider(_refresh));
    return Scaffold(
      body: AppRefreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            AppSliverHeader.page(title: context.l10n.weeklyReleases),
            // Centered at the reading width on tablets, under the title.
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(context.l10n.weeklyReleasesDescription),
                          const SizedBox(height: 16),
                          SettingsSegmentedChoice<int>(
                            selected: _days,
                            onChanged: (days) => setState(() => _days = days),
                            semanticLabel: context.l10n.weeklyReleases,
                            options: [
                              for (final days in [7, 30])
                                SettingsSegmentOption(
                                  value: days,
                                  label: context.l10n.listeningStatsDays(days),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  ...feed.when(
                    loading: () => [
                      const SliverToBoxAdapter(
                        child: Center(child: AppLoadingIndicator()),
                      ),
                    ],
                    error: (_, _) => [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: ErrorCard(
                            error: context.l10n.weeklyReleasesLoadError,
                            colorScheme: Theme.of(context).colorScheme,
                            onRetry: _reload,
                          ),
                        ),
                      ),
                    ],
                    data: (data) {
                      final releases = data.inPeriod(DateTime.now(), _days);
                      return [
                        if (data.unavailableArtists.isNotEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                '${context.l10n.weeklyReleasesUnavailable}\n'
                                '${data.unavailableArtists.join(', ')}',
                              ),
                            ),
                          ),
                        if (releases.isEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(context.l10n.weeklyReleasesEmpty),
                            ),
                          ),
                        SliverList.list(
                          children: [
                            for (final release in releases)
                              ListTile(
                                leading: release.coverUrl == null
                                    ? const SizedBox(
                                        width: 56,
                                        height: 56,
                                        child: Icon(Icons.album_outlined),
                                      )
                                    : CachedCoverImage(
                                        imageUrl: release.coverUrl!,
                                        width: 56,
                                        height: 56,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                title: Text(release.name),
                                subtitle: Text(
                                  '${release.artist}\n${DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(release.date)}',
                                ),
                                onTap: () => navigateToAlbum(
                                  context,
                                  albumName: release.name,
                                  albumId: release.id,
                                  artistName: release.artist,
                                  coverUrl: release.coverUrl,
                                  extensionId: release.providerId,
                                ),
                              ),
                          ],
                        ),
                      ];
                    },
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(height: context.navBarBottomInset),
            ),
          ],
        ),
      ),
    );
  }
}
