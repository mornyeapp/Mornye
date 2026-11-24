import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/artist_concert.dart';
import 'package:mornye/screens/concert_detail_screen.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/animation_utils.dart';

class ArtistConcertsScreen extends StatefulWidget {
  const ArtistConcertsScreen({
    super.key,
    required this.artistName,
    required this.concerts,
    this.coverUrl,
    this.providerId,
  });

  final String artistName;
  final List<ArtistConcert> concerts;
  final String? coverUrl;
  final String? providerId;

  @override
  State<ArtistConcertsScreen> createState() => _ArtistConcertsScreenState();
}

class _ArtistConcertsScreenState extends State<ArtistConcertsScreen> {
  @override
  void dispose() {
    ShellNavigationService.clearChromeBrightness(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      final theme = Theme.of(context);
      final route = ModalRoute.of(context);
      if (route != null) {
        ShellNavigationService.setChromeBrightness(
          owner: this,
          route: route,
          brightness: theme.brightness,
          surface: theme.colorScheme.surface,
        );
      }
    }
    return _buildPage(context);
  }

  Widget _buildPage(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inset = wideListInset(context) + 24;
    final locale = Localizations.localeOf(context).toString();
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            surfaceTintColor: Colors.transparent,
            leadingWidth: 64,
            leading: Padding(
              padding: const EdgeInsetsDirectional.only(start: 12),
              child: HeaderCircleButton(
                icon: Icons.arrow_back,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 24, inset, 32),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  AppShapeClip(
                    kind: AppShapes.artist,
                    child: SizedBox.square(
                      dimension: 96,
                      child: widget.coverUrl == null || widget.coverUrl!.isEmpty
                          ? const Icon(Icons.person, size: 56)
                          : CachedCoverImage(
                              imageUrl: widget.coverUrl!,
                              fit: BoxFit.cover,
                              memCacheWidth: 288,
                              errorWidget: (_, _, _) =>
                                  const Icon(Icons.person, size: 56),
                            ),
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.artistUpcomingConcerts,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.artistName,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 0, inset, 12),
            sliver: SliverToBoxAdapter(
              child: Text(
                context.l10n.artistAllUpcomingConcerts,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          if (widget.concerts.isEmpty)
            SliverPadding(
              padding: EdgeInsets.all(inset),
              sliver: SliverToBoxAdapter(
                child: Text(context.l10n.artistNoUpcomingConcerts),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              sliver: SliverList.separated(
                itemCount: widget.concerts.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 60),
                itemBuilder: (context, index) {
                  final concert = widget.concerts[index];
                  final date = DateFormat.MMMEd(locale).format(concert.date);
                  final details = [
                    if (concert.venue.isNotEmpty) concert.venue,
                    DateFormat.y(locale).format(concert.date),
                    date,
                    if (concert.hasTime)
                      DateFormat.Hm(locale).format(concert.date),
                  ].join(' · ');
                  return InkWell(
                    onTap: () => _openConcert(context, concert),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          Semantics(
                            label: date,
                            excludeSemantics: true,
                            child: Container(
                              width: 48,
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(
                                  color: scheme.outlineVariant,
                                ),
                              ),
                              child: Column(
                                children: [
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      DateFormat.MMM(
                                        locale,
                                      ).format(concert.date),
                                      maxLines: 1,
                                      style: TextStyle(
                                        color: scheme.primary,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      DateFormat.d(locale).format(concert.date),
                                      style: const TextStyle(
                                        fontSize: 28,
                                        height: 1.05,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  concert.location,
                                  style: const TextStyle(fontSize: 16),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  details,
                                  maxLines:
                                      MediaQuery.textScalerOf(
                                            context,
                                          ).scale(1) >
                                          1.3
                                      ? null
                                      : 1,
                                  overflow:
                                      MediaQuery.textScalerOf(
                                            context,
                                          ).scale(1) >
                                          1.3
                                      ? null
                                      : TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }

  Future<void> _openConcert(BuildContext context, ArtistConcert concert) async {
    await Navigator.of(context).push(
      slidePageRoute<void>(
        page: ConcertDetailScreen(
          artistName: widget.artistName,
          coverUrl: widget.coverUrl,
          providerId: widget.providerId,
          concert: concert,
        ),
      ),
    );
  }
}
