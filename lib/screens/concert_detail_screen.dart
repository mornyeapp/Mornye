import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/artist_concert.dart';
import 'package:mornye/screens/playlist_screen.dart';
import 'package:mornye/services/concert_calendar_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/settings_group.dart';

class ConcertDetailScreen extends StatefulWidget {
  const ConcertDetailScreen({
    super.key,
    required this.artistName,
    required this.concert,
    this.coverUrl,
    this.providerId,
  });

  final String artistName;
  final ArtistConcert concert;
  final String? coverUrl;
  final String? providerId;

  @override
  State<ConcertDetailScreen> createState() => _ConcertDetailScreenState();
}

class _ConcertDetailScreenState extends State<ConcertDetailScreen> {
  ConcertDetail _detail = const ConcertDetail();
  bool _loading = false;
  bool _failed = false;
  bool _calendarOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = widget.providerId;
    final id = widget.concert.detailId;
    if (provider == null || provider.isEmpty || id == null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final result = await PlatformBridge.getProviderMetadata(
        provider,
        'concert',
        id,
      );
      final json = result['concert'];
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Missing concert');
      }
      final detail = ConcertDetail.fromJson(json);
      if (mounted) setState(() => _detail = detail);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    ShellNavigationService.clearChromeBrightness(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = _detail.coverUrl ?? widget.coverUrl;
    if (!context.isMornye) {
      // Material follows the app brightness with a cover-seeded scheme.
      return CoverPaletteBuilder(
        imageSource: source,
        builder: (context, palette) => Theme(
          data: Theme.of(context).copyWith(colorScheme: palette),
          child: Builder(builder: (context) => _materialPage(context, source)),
        ),
      );
    }
    final base = MornyeTheme.fromContext(context, brightness: Brightness.dark);
    return Theme(
      data: base,
      child: CoverPaletteBuilder(
        imageSource: source,
        builder: (context, palette) {
          final color = HSLColor.fromColor(
            source == null
                ? Colors.grey
                : CoverPalette.sourceColor(source, Brightness.dark) ??
                      Colors.grey,
          );
          final top = color
              .withSaturation((color.saturation * 1.2).clamp(0, 0.65))
              .withLightness(0.27)
              .toColor();
          final bottom = color
              .withSaturation((color.saturation * 0.6).clamp(0, 0.4))
              .withLightness(0.36)
              .toColor();
          final route = ModalRoute.of(context);
          if (route != null) {
            ShellNavigationService.setChromeBrightness(
              owner: this,
              route: route,
              brightness: Brightness.dark,
              surface: bottom,
            );
          }
          final scheme = base.colorScheme.copyWith(
            surface: top,
            onSurface: Colors.white,
            onSurfaceVariant: Colors.white70,
            primary: Colors.white,
            onPrimary: top,
          );
          return Theme(
            data: base.copyWith(
              colorScheme: scheme,
              scaffoldBackgroundColor: top,
            ),
            child: Builder(
              builder: (context) => _page(context, source, top, bottom),
            ),
          );
        },
      ),
    );
  }

  Widget _page(BuildContext context, String? source, Color top, Color bottom) {
    final locale = Localizations.localeOf(context).toString();
    final date = widget.concert.date;
    final artist = _detail.artistName ?? widget.artistName;
    final hasSetList = _detail.setListId != null && widget.providerId != null;
    final photoSize = (MediaQuery.sizeOf(context).width * 0.5).clamp(
      144.0,
      220.0,
    );
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [top, bottom],
          ),
        ),
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: top,
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
              actions: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 12),
                  child: Builder(
                    builder: (context) => HeaderCircleButton(
                      icon: CupertinoIcons.share,
                      tooltip: context.l10n.trackMetadataShare,
                      onPressed: () => _share(context),
                    ),
                  ),
                ),
              ],
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
              sliver: SliverToBoxAdapter(
                child: Column(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        AppShapeClip(
                          kind: AppShapes.artist,
                          child: SizedBox.square(
                            dimension: photoSize,
                            child: source == null
                                ? const Icon(Icons.person, size: 96)
                                : CachedCoverImage(
                                    imageUrl: source,
                                    fit: BoxFit.cover,
                                    errorWidget: (_, _, _) =>
                                        const Icon(Icons.person, size: 96),
                                  ),
                          ),
                        ),
                        PositionedDirectional(
                          end: -4,
                          bottom: -4,
                          child: Container(
                            width: 64,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xff202023),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  DateFormat.MMM(locale).format(date),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Color(0xffff646b),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  DateFormat.d(locale).format(date),
                                  style: const TextStyle(
                                    fontSize: 40,
                                    height: 1.05,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 26),
                    Text(
                      artist,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_loading)
                      const ShimmerLoading(
                        child: Column(
                          children: [
                            Row(
                              spacing: 16,
                              children: [
                                Expanded(
                                  child: SkeletonBox(
                                    width: double.infinity,
                                    height: 48,
                                    borderRadius: 28,
                                  ),
                                ),
                                Expanded(
                                  child: SkeletonBox(
                                    width: double.infinity,
                                    height: 48,
                                    borderRadius: 28,
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 20),
                            SkeletonBox(
                              width: double.infinity,
                              height: 164,
                              borderRadius: 28,
                            ),
                          ],
                        ),
                      )
                    else ...[
                      if (_detail.ticketUrl != null || hasSetList) ...[
                        Row(
                          spacing: 16,
                          children: [
                            if (_detail.ticketUrl != null)
                              Expanded(
                                child: _action(
                                  context,
                                  CupertinoIcons.tickets_fill,
                                  context.l10n.concertGetTickets,
                                  () => _openLink(_detail.ticketUrl!),
                                ),
                              ),
                            if (hasSetList)
                              Expanded(
                                child: _action(
                                  context,
                                  CupertinoIcons.play_fill,
                                  context.l10n.concertSetListButton,
                                  _openSetList,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 20),
                      ],
                      Container(
                        decoration: _glassDecoration,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        child: Column(
                          children: [
                            _infoRow(
                              '${DateFormat.yMMMMd(locale).format(date)} · ${DateFormat.EEEE(locale).format(date)}',
                              widget.concert.hasTime
                                  ? DateFormat.Hm(locale).format(date)
                                  : '',
                              CupertinoIcons.calendar_badge_plus,
                              _detail.start == null ? null : _addToCalendar,
                              context.l10n.concertAddToCalendar,
                            ),
                            const Divider(color: Colors.white24, height: 1),
                            _infoRow(
                              _detail.venue ?? widget.concert.venue,
                              _detail.address ?? widget.concert.location,
                              CupertinoIcons.map_pin_ellipse,
                              _detail.mapUrl == null
                                  ? null
                                  : () => _openLink(_detail.mapUrl!),
                              context.l10n.concertOpenMaps,
                            ),
                          ],
                        ),
                      ),
                      if (_detail.attribution != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            _detail.attribution!,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      if (_failed)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Column(
                            children: [
                              Text(
                                context.l10n.concertDetailsUnavailable,
                                textAlign: TextAlign.center,
                              ),
                              ExpressiveButton(
                                text: true,
                                onPressed: _load,
                                child: Text(context.l10n.dialogRetry),
                              ),
                            ],
                          ),
                        ),
                      if (hasSetList) ...[
                        const SizedBox(height: 32),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            context.l10n.concertSetList,
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        InkWell(
                          onTap: _openSetList,
                          borderRadius: BorderRadius.circular(28),
                          child: Container(
                            decoration: _glassDecoration,
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: SizedBox.square(
                                    dimension: 88,
                                    child: _detail.setListCover == null
                                        ? const Icon(Icons.queue_music)
                                        : CachedCoverImage(
                                            imageUrl: _detail.setListCover!,
                                            fit: BoxFit.cover,
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _detail.setListName ??
                                        context.l10n.concertSetList,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(CupertinoIcons.forward, size: 18),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const NavBarSliverSpacer(),
          ],
        ),
      ),
    );
  }

  Widget _materialPage(BuildContext context, String? source) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toString();
    final date = widget.concert.date;
    final artist = _detail.artistName ?? widget.artistName;
    final venue = _detail.venue ?? widget.concert.venue;
    final address = _detail.address ?? widget.concert.location;
    final hasTicket = _detail.ticketUrl != null;
    final hasSetList = _detail.setListId != null && widget.providerId != null;
    final photoSize = (MediaQuery.sizeOf(context).width * 0.5).clamp(
      144.0,
      220.0,
    );
    final placeholder = AppIcon(
      Icons.person,
      size: 96,
      color: scheme.onSurfaceVariant,
    );
    return Scaffold(
      backgroundColor: scheme.surface,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: scheme.surface,
            actions: [
              Builder(
                builder: (context) => AppIconButton(
                  icon: const Icon(Icons.share_outlined),
                  tooltip: context.l10n.trackMetadataShare,
                  onPressed: () => _share(context),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AppShapeClip(
                        kind: AppShapes.artist,
                        child: SizedBox.square(
                          dimension: photoSize,
                          child: source == null
                              ? ColoredBox(
                                  color: scheme.surfaceContainerHigh,
                                  child: placeholder,
                                )
                              : CachedCoverImage(
                                  imageUrl: source,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, _, _) => placeholder,
                                ),
                        ),
                      ),
                      PositionedDirectional(
                        end: -4,
                        bottom: -4,
                        child: Container(
                          width: 64,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            children: [
                              Text(
                                DateFormat.MMM(locale).format(date),
                                style: textTheme.labelLarge?.copyWith(
                                  color: scheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                DateFormat.d(locale).format(date),
                                style: textTheme.headlineMedium?.copyWith(
                                  color: scheme.onPrimaryContainer,
                                  height: 1.1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    artist,
                    textAlign: TextAlign.center,
                    style: textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (_loading) ...[
                    const SizedBox(height: 24),
                    const ShimmerLoading(
                      child: Column(
                        children: [
                          SkeletonBox(
                            width: double.infinity,
                            height: 48,
                            borderRadius: 24,
                          ),
                          SizedBox(height: 16),
                          SkeletonBox(
                            width: double.infinity,
                            height: 144,
                            borderRadius: 20,
                          ),
                        ],
                      ),
                    ),
                  ] else if (hasTicket || hasSetList) ...[
                    const SizedBox(height: 24),
                    // Tickets are the one filled action; the set list is tonal.
                    Row(
                      spacing: 12,
                      children: [
                        if (hasTicket)
                          Expanded(
                            child: ExpressiveButton(
                              onPressed: () => _openLink(_detail.ticketUrl!),
                              icon: const Icon(
                                Icons.confirmation_number_outlined,
                              ),
                              child: Text(
                                context.l10n.concertGetTickets,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        if (hasSetList)
                          Expanded(
                            child: ExpressiveButton(
                              tonal: true,
                              onPressed: _openSetList,
                              icon: const Icon(Icons.queue_music),
                              child: Text(
                                context.l10n.concertSetListButton,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (!_loading) ...[
            SliverToBoxAdapter(
              child: SettingsGroup(
                connected: true,
                children: [
                  ListTile(
                    leading: const AppIcon(Icons.event_outlined),
                    title: Text(
                      '${DateFormat.yMMMMd(locale).format(date)} · '
                      '${DateFormat.EEEE(locale).format(date)}',
                    ),
                    subtitle: widget.concert.hasTime
                        ? Text(DateFormat.Hm(locale).format(date))
                        : null,
                    trailing: _detail.start == null
                        ? null
                        : AppIconButton(
                            icon: const Icon(Icons.edit_calendar_outlined),
                            tooltip: context.l10n.concertAddToCalendar,
                            onPressed: _addToCalendar,
                          ),
                  ),
                  ListTile(
                    leading: const AppIcon(Icons.place_outlined),
                    title: Text(venue),
                    subtitle: address.isEmpty ? null : Text(address),
                    trailing: _detail.mapUrl == null
                        ? null
                        : AppIconButton(
                            icon: const Icon(Icons.map_outlined),
                            tooltip: context.l10n.concertOpenMaps,
                            onPressed: () => _openLink(_detail.mapUrl!),
                          ),
                  ),
                ],
              ),
            ),
            if (_detail.attribution != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(
                    _detail.attribution!,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            if (_failed)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: ErrorCard(
                    error: context.l10n.concertDetailsUnavailable,
                    colorScheme: scheme,
                    onRetry: _load,
                  ),
                ),
              ),
            if (hasSetList)
              ...settingsSectionSlivers(
                title: context.l10n.concertSetList,
                connected: true,
                children: [
                  ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox.square(
                        dimension: 56,
                        child: _detail.setListCover == null
                            ? ColoredBox(
                                color: scheme.secondaryContainer,
                                child: AppIcon(
                                  Icons.queue_music,
                                  color: scheme.onSecondaryContainer,
                                ),
                              )
                            : CachedCoverImage(
                                imageUrl: _detail.setListCover!,
                                fit: BoxFit.cover,
                              ),
                      ),
                    ),
                    title: Text(
                      _detail.setListName ?? context.l10n.concertSetList,
                    ),
                    trailing: const AppIcon(Icons.chevron_right),
                    onTap: _openSetList,
                  ),
                ],
              ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }

  BoxDecoration get _glassDecoration => BoxDecoration(
    color: Colors.black.withValues(alpha: 0.15),
    borderRadius: BorderRadius.circular(28),
    border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
  );

  Widget _action(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) => ExpressiveButton(
    outlined: true,
    onPressed: onTap,
    icon: Icon(icon, size: 19),
    style: OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      backgroundColor: Colors.black.withValues(alpha: 0.15),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    child: Text(label, textAlign: TextAlign.center),
  );

  Widget _infoRow(
    String title,
    String subtitle,
    IconData icon,
    VoidCallback? onTap,
    String tooltip,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 15, color: Colors.white70),
                ),
            ],
          ),
        ),
        if (onTap != null)
          AppIconButton(
            onPressed: onTap,
            tooltip: tooltip,
            icon: Icon(icon, size: 21),
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.12),
            ),
          ),
      ],
    ),
  );

  void _openSetList() {
    Navigator.of(context).push(
      slidePageRoute<void>(
        page: PlaylistScreen(
          playlistName: _detail.setListName ?? context.l10n.concertSetList,
          coverUrl: _detail.setListCover,
          tracks: const [],
          playlistId: _detail.setListId,
          metadataProviderId: widget.providerId,
        ),
      ),
    );
  }

  Future<void> _openLink(String url) async {
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      /* Keep the detail page open when no handler is installed. */
    }
    if (mounted) _error(context.l10n.announcementUnableToOpenLink);
  }

  Future<void> _share(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text:
            '${_detail.artistName ?? widget.artistName}\n${_detail.venue ?? widget.concert.venue}\n${_detail.url ?? widget.concert.url ?? ''}',
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  Future<void> _addToCalendar() async {
    if (_calendarOpen || _detail.start == null) return;
    _calendarOpen = true;
    try {
      final opened = await ConcertCalendarService.add(
        title: _detail.title ?? widget.artistName,
        location: [
          _detail.venue ?? widget.concert.venue,
          _detail.address ?? widget.concert.location,
        ].join(', '),
        start: _detail.start!.millisecondsSinceEpoch,
        end: _detail.end?.millisecondsSinceEpoch,
        url: _detail.url ?? widget.concert.url,
      );
      if (mounted && opened != true) {
        _error(context.l10n.concertCalendarUnavailable);
      }
    } on PlatformException {
      if (mounted) _error(context.l10n.concertCalendarUnavailable);
    } on MissingPluginException {
      if (mounted) _error(context.l10n.concertCalendarUnavailable);
    } finally {
      _calendarOpen = false;
    }
  }

  void _error(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));
}
