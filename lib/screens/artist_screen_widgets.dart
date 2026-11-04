// ignore_for_file: invalid_use_of_protected_member
part of 'artist_screen.dart';

/// Side margin of the artist page's desktop sections.
const double _mornyeSectionInset = 24;

/// Space between the columns of the artist page's desktop highlights.
const double _mornyeHighlightGap = 16;

/// Width of a highlight column: two fit the pane, and the right margin shows
/// the edge of the next one.
double _mornyeHighlightColumn(double paneWidth) => math.max(
  (paneWidth - _mornyeSectionInset * 2 - _mornyeHighlightGap) / 2,
  260,
);

/// Settles a sideways scroll on the nearest column of [extent].
class _ColumnSnapPhysics extends ScrollPhysics {
  const _ColumnSnapPhysics({required this.extent, super.parent});

  final double extent;

  @override
  _ColumnSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _ColumnSnapPhysics(extent: extent, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    final projected = position.pixels + velocity * 0.18;
    final target = ((projected / extent).round() * extent).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < toleranceFor(position).distance) {
      return null;
    }
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: toleranceFor(position),
    );
  }
}

extension _ArtistScreenSections on _ArtistScreenState {
  Widget _concertsButton() => ArtistConcertsButton(
    artistName: widget.artistName,
    concerts: _concerts,
    coverUrl: widget.coverUrl ?? _headerImageUrl,
    providerId: _directMetadataProviderId(),
  );

  List<Widget> _buildHeader(
    BuildContext context,
    ColorScheme colorScheme, {
    required List<ArtistAlbum> albums,
    required bool hasDiscography,
  }) {
    String? imageUrl = _headerImageUrl;
    if (imageUrl == null || imageUrl.isEmpty) {
      imageUrl = widget.headerImageUrl;
    }
    if (imageUrl == null || imageUrl.isEmpty) {
      imageUrl = widget.coverUrl;
    }

    final hasValidImage =
        imageUrl != null &&
        imageUrl.isNotEmpty &&
        Uri.tryParse(imageUrl)?.hasAuthority == true;

    String? headerVideoUrl = _headerVideoUrl;
    if (headerVideoUrl == null || headerVideoUrl.isEmpty) {
      headerVideoUrl = widget.headerVideoUrl;
    }
    final hasMotionBanner =
        headerVideoUrl != null &&
        headerVideoUrl.isNotEmpty &&
        Uri.tryParse(headerVideoUrl)?.hasAuthority == true;

    String? listenersText;
    final listeners = _monthlyListeners ?? widget.monthlyListeners;
    if (listeners != null && listeners > 0) {
      final formatter = NumberFormat.compact();
      listenersText = context.l10n.artistMonthlyListeners(
        formatter.format(listeners),
      );
    }

    final favoriteProviderId = _directMetadataProviderId();
    final favoriteArtistId = _metadataResourceId(favoriteProviderId ?? '');
    final isFavoriteArtist = ref.watch(
      libraryCollectionsProvider.select(
        (state) => state.isFavoriteArtist(
          artistId: favoriteArtistId,
          providerId: favoriteProviderId,
        ),
      ),
    );

    // Mornye keeps its Apple Music hero on desktop, filling the pane.
    if (isDesktopPlatform && !context.isMornye) {
      return _buildDesktopHeader(
        context,
        colorScheme,
        albums: albums,
        hasDiscography: hasDiscography,
        imageUrl: hasValidImage ? imageUrl : null,
        listenersText: listenersText,
        isFavoriteArtist: isFavoriteArtist,
      );
    }

    if (context.isMornye) {
      final artwork = hasValidImage
          ? DownloadableCover(
              coverUrl: imageUrl,
              baseName: widget.artistName,
              child: CachedCoverImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                // The desktop hero spans the content pane.
                memCacheWidth: isDesktopPlatform ? 1600 : 800,
                errorWidget: (_, _, _) =>
                    const Center(child: Icon(CupertinoIcons.person, size: 80)),
              ),
            )
          : const Center(child: Icon(CupertinoIcons.person, size: 80));
      return MornyeArtistHeader(
        name: widget.artistName,
        logoUrl: _headerLogoUrl ?? widget.headerLogoUrl,
        badge: _concerts.isEmpty || isSelectionMode ? null : _concertsButton(),
        listeners: listenersText,
        showTitle: false,
        showTitleListenable: _showTitleInAppBar,
        artwork: hasMotionBanner
            ? MotionHeaderBanner(videoUrl: headerVideoUrl, fallback: artwork)
            : artwork,
        toolbarActions: isSelectionMode
            ? const []
            : [
                HeaderCircleButton(
                  icon: CupertinoIcons.square_arrow_up,
                  tooltip: context.l10n.openInOtherServices,
                  onPressed: () => _showShareSheet(context),
                ),
                HeaderMoreButton(
                  groups: () => [
                    [
                      ContextMenuAction(
                        icon: isFavoriteArtist
                            ? CupertinoIcons.star_fill
                            : CupertinoIcons.star,
                        label: isFavoriteArtist
                            ? context.l10n.artistOptionRemoveFromFavorites
                            : context.l10n.artistOptionAddToFavorites,
                        onSelected: () => _toggleFavoriteArtist(context),
                      ),
                      if (hasDiscography)
                        ContextMenuAction(
                          icon: CupertinoIcons.arrow_down,
                          label: context.l10n.discographyDownload,
                          onSelected: () => _showDiscographyOptions(
                            context,
                            colorScheme,
                            albums,
                          ),
                        ),
                    ],
                  ],
                ),
              ],
        actions: isSelectionMode
            ? const []
            : [
                // Keeps the larger button on the page's center line.
                if (_isLoadingDiscography || hasDiscography)
                  const SizedBox.square(dimension: 50),
                if (_isLoadingDiscography)
                  const ShimmerLoading(
                    child: SkeletonBox(width: 74, height: 74, borderRadius: 37),
                  )
                else if (hasDiscography)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    borderRadius: BorderRadius.circular(37),
                    color: colorScheme.primary,
                    onPressed: () =>
                        _showDiscographyOptions(context, colorScheme, albums),
                    child: SizedBox.square(
                      dimension: 74,
                      child: Semantics(
                        label: context.l10n.discographyDownload,
                        child: Icon(
                          CupertinoIcons.arrow_down,
                          size: 34,
                          color: colorScheme.onPrimary,
                        ),
                      ),
                    ),
                  ),
                HeaderCircleButton(
                  icon: isFavoriteArtist
                      ? CupertinoIcons.star_fill
                      : CupertinoIcons.star,
                  buttonSize: 50,
                  iconSize: 24,
                  iconColor: colorScheme.primary,
                  glassTintColor: Colors.white,
                  glassTintOpacity: 0.10,
                  tooltip: isFavoriteArtist
                      ? context.l10n.artistOptionRemoveFromFavorites
                      : context.l10n.artistOptionAddToFavorites,
                  onPressed: () => _toggleFavoriteArtist(context),
                ),
              ],
      ).buildSlivers(context);
    }
    return [
      CoverPaletteBuilder(
        imageSource: hasValidImage ? imageUrl : null,
        builder: (context, headerScheme) => _buildArtistAppBar(
          context,
          colorScheme,
          headerScheme,
          albums: albums,
          hasDiscography: hasDiscography,
          imageUrl: imageUrl,
          hasValidImage: hasValidImage,
          headerVideoUrl: headerVideoUrl,
          hasMotionBanner: hasMotionBanner,
          listenersText: listenersText,
          isFavoriteArtist: isFavoriteArtist,
        ),
      ),
    ];
  }

  /// Desktop: the round photo beside the name and actions, under a pinned
  /// toolbar, in the same column as the discography.
  List<Widget> _buildDesktopHeader(
    BuildContext context,
    ColorScheme colorScheme, {
    required List<ArtistAlbum> albums,
    required bool hasDiscography,
    required String? imageUrl,
    required String? listenersText,
    required bool isFavoriteArtist,
  }) {
    final mornye = context.isMornye;
    final placeholder = ColoredBox(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          mornye ? CupertinoIcons.person : Icons.person,
          size: 64,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return desktopDetailHeaderSlivers(
      context,
      title: widget.artistName,
      circularArtwork: true,
      paletteSource: imageUrl,
      artwork: (context, size) => imageUrl == null
          ? placeholder
          : DownloadableCover(
              coverUrl: imageUrl,
              baseName: widget.artistName,
              child: CachedCoverImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                memCacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                errorWidget: (_, _, _) => placeholder,
              ),
            ),
      // Subtitle and actions are built inside the header, so they read the
      // artist image's scheme.
      subtitle: listenersText == null
          ? null
          : Builder(
              builder: (header) => Text(
                listenersText,
                style: Theme.of(header).textTheme.bodyMedium?.copyWith(
                  color: HeaderPalette.of(header).onSurfaceVariant,
                ),
              ),
            ),
      meta: _concerts.isEmpty || isSelectionMode ? null : _concertsButton(),
      actions: isSelectionMode
          ? null
          : Builder(
              builder: (header) {
                final headerScheme = HeaderPalette.of(header);
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 10,
                  children: [
                    HeaderCircleButton(
                      tonal: true,
                      icon: isFavoriteArtist
                          ? (mornye ? CupertinoIcons.star_fill : Icons.favorite)
                          : (mornye
                                ? CupertinoIcons.star
                                : Icons.favorite_border),
                      iconColor: isFavoriteArtist && !mornye
                          ? headerScheme.error
                          : headerScheme.primary,
                      tooltip: isFavoriteArtist
                          ? context.l10n.artistOptionRemoveFromFavorites
                          : context.l10n.artistOptionAddToFavorites,
                      onPressed: () => _toggleFavoriteArtist(context),
                    ),
                    if (hasDiscography && !_isLoadingDiscography)
                      HeaderCircleButton(
                        tonal: true,
                        icon: mornye
                            ? CupertinoIcons.arrow_down
                            : Icons.download_rounded,
                        iconColor: headerScheme.primary,
                        tooltip: context.l10n.discographyDownload,
                        onPressed: () => _showDiscographyOptions(
                          context,
                          colorScheme,
                          albums,
                        ),
                      ),
                  ],
                );
              },
            ),
      appBarActions: isSelectionMode
          ? const []
          : [
              HeaderCircleButton(
                icon: mornye
                    ? CupertinoIcons.square_arrow_up
                    : Icons.open_in_new_rounded,
                tooltip: context.l10n.openInOtherServices,
                onPressed: () => _showShareSheet(context),
              ),
            ],
    );
  }

  Widget _buildArtistAppBar(
    BuildContext context,
    ColorScheme colorScheme,
    ColorScheme headerScheme, {
    required List<ArtistAlbum> albums,
    required bool hasDiscography,
    required String? imageUrl,
    required bool hasValidImage,
    required String? headerVideoUrl,
    required bool hasMotionBanner,
    required String? listenersText,
    required bool isFavoriteArtist,
  }) {
    final edgeInset = detailHeaderEdgeInset(context);
    const fallbackMotion = AppMotionSpec(
      Duration(milliseconds: 200),
      Curves.linear,
    );
    final titleFade = AppMotion.effects(context, fallbackMotion);
    final titleSlide = materialExpressiveEnabled(context)
        ? AppMotion.spatial(context, fallbackMotion)
        : null;
    final toolbarTitle = ValueListenableBuilder(
      valueListenable: _showTitleInAppBar,
      builder: (_, showTitle, text) {
        final Widget title = AnimatedOpacity(
          duration: titleFade.duration,
          curve: titleFade.curve,
          opacity: showTitle ? 1.0 : 0.0,
          child: text,
        );
        return titleSlide == null
            ? title
            : AnimatedSlide(
                duration: titleSlide.duration,
                curve: titleSlide.curve,
                offset: showTitle ? Offset.zero : const Offset(0, 0.6),
                child: title,
              );
      },
      child: Text(
        widget.artistName,
        style: TextStyle(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: 16,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    return SliverAppBar(
      expandedHeight: hasDiscography ? 420 : 380,
      pinned: true,
      stretch: true,
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      title: toolbarTitle,
      flexibleSpace: FlexibleSpaceBar(
        collapseMode: CollapseMode.none,
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (hasMotionBanner)
              MotionHeaderBanner(
                videoUrl: headerVideoUrl!,
                fallback: hasValidImage
                    ? DownloadableCover(
                        coverUrl: imageUrl,
                        baseName: widget.artistName,
                        child: CachedCoverImage(
                          imageUrl: imageUrl!,
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          memCacheWidth: 800,
                          placeholder: (context, url) => Container(
                            color: colorScheme.surfaceContainerHighest,
                          ),
                          errorWidget: (context, url, error) => Container(
                            color: colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.person,
                              size: 80,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    : Container(
                        color: colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.person,
                          size: 80,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
              )
            else if (hasValidImage)
              DownloadableCover(
                coverUrl: imageUrl,
                baseName: widget.artistName,
                child: CachedCoverImage(
                  imageUrl: imageUrl!,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  memCacheWidth: 800,
                  placeholder: (context, url) =>
                      Container(color: colorScheme.surfaceContainerHighest),
                  errorWidget: (context, url, error) => Container(
                    color: colorScheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.person,
                      size: 80,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              Container(
                color: colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.person,
                  size: 80,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    headerScheme.surface.withValues(alpha: 0),
                    headerScheme.surface.withValues(alpha: 0.35),
                    headerScheme.surface.withValues(alpha: 0.75),
                    headerScheme.surface,
                  ],
                  stops: const [0.0, 0.5, 0.75, 1.0],
                ),
              ),
            ),
            Positioned(
              left: 16 + edgeInset,
              right: 16 + edgeInset,
              bottom: 16,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_concerts.isNotEmpty && !isSelectionMode) ...[
                          _concertsButton(),
                          const SizedBox(height: 8),
                        ],
                        Text(
                          widget.artistName,
                          style: Theme.of(context).textTheme.headlineLarge
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: headerScheme.onSurface,
                              ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (listenersText != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            listenersText,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: headerScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (!isSelectionMode) ...[
                    const SizedBox(width: 12),
                    if (materialExpressiveEnabled(context))
                      // Favourite morphs to a square while selected, and the
                      // pair squishes like a button group when pressed.
                      ExpressiveButtonGroup(
                        slotWidth: 52,
                        children: [
                          ExpressiveIconButton(
                            onPressed: () => _toggleFavoriteArtist(context),
                            icon: Icon(
                              isFavoriteArtist
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                            ),
                            selected: isFavoriteArtist,
                            size: 52,
                            iconSize: 26,
                            backgroundColor: headerScheme.primaryContainer,
                            foregroundColor: isFavoriteArtist
                                ? headerScheme.error
                                : headerScheme.onPrimaryContainer,
                            tooltip: isFavoriteArtist
                                ? context.l10n.artistOptionRemoveFromFavorites
                                : context.l10n.artistOptionAddToFavorites,
                          ),
                          if (hasDiscography)
                            ExpressiveIconButton(
                              onPressed: () => _showDiscographyOptions(
                                context,
                                colorScheme,
                                albums,
                              ),
                              icon: const Icon(Icons.download_rounded),
                              size: 52,
                              iconSize: 26,
                              backgroundColor: headerScheme.primaryContainer,
                              foregroundColor: headerScheme.onPrimaryContainer,
                              tooltip: context.l10n.discographyDownload,
                            ),
                        ],
                      )
                    else ...[
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: headerScheme.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: AppIconButton(
                          onPressed: () => _toggleFavoriteArtist(context),
                          icon: Icon(
                            isFavoriteArtist
                                ? Icons.favorite
                                : Icons.favorite_border,
                            size: 26,
                          ),
                          color: isFavoriteArtist
                              ? headerScheme.error
                              : headerScheme.onPrimaryContainer,
                          tooltip: isFavoriteArtist
                              ? context.l10n.artistOptionRemoveFromFavorites
                              : context.l10n.artistOptionAddToFavorites,
                        ),
                      ),
                      if (hasDiscography) ...[
                        const SizedBox(width: 12),
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: headerScheme.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: AppIconButton(
                            onPressed: () => _showDiscographyOptions(
                              context,
                              colorScheme,
                              albums,
                            ),
                            icon: const Icon(Icons.download_rounded, size: 26),
                            color: headerScheme.onPrimaryContainer,
                            tooltip: context.l10n.discographyDownload,
                          ),
                        ),
                      ],
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
        stretchModes: const [StretchMode.zoomBackground],
      ),
      leadingWidth: kToolbarHeight + edgeInset,
      leading: Padding(
        padding: EdgeInsetsDirectional.only(start: edgeInset),
        child: HeaderCircleButton(
          icon: Icons.arrow_back,
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.pop(context),
        ),
      ),
      actionsPadding: EdgeInsetsDirectional.only(end: edgeInset),
      actions: [
        HeaderCircleButton(
          icon: Icons.open_in_new_rounded,
          tooltip: context.l10n.openInOtherServices,
          onPressed: () => _showShareSheet(context),
        ),
      ],
    );
  }

  void _showShareSheet(BuildContext context) {
    CrossExtensionShareSheet.show(
      context,
      name: widget.artistName,
      artists: '',
      type: 'artist',
      sourceExtensionId: _directMetadataProviderId() ?? '',
    );
  }

  Widget _buildMornyeFeaturedAlbum(BuildContext context, ArtistAlbum album) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Material(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _navigateToAlbum(album),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: SizedBox.square(
                    dimension: 76,
                    child: album.coverUrl != null
                        ? CachedCoverImage(
                            imageUrl: album.coverUrl!,
                            fit: BoxFit.cover,
                          )
                        : const Icon(CupertinoIcons.square_stack, size: 32),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (album.releaseDate.isNotEmpty)
                        Text(
                          album.releaseDate.split('-').first,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        album.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (album.totalTracks > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          context.l10n.tracksCount(album.totalTracks),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  CupertinoIcons.forward,
                  size: 14,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Music on the Mac: Latest Release and Top Songs share one row of equal
  /// columns that scroll sideways together, each snapping to the left edge.
  Widget _buildMornyeDesktopHighlights(
    BuildContext context,
    ColorScheme colorScheme,
    ArtistAlbum? latest,
  ) {
    const rowsPerColumn = 3;
    const rowExtent = 56.0;
    const contentExtent = rowsPerColumn * rowExtent;
    const headingExtent = 44.0;
    final tracks = _topTracks ?? const <Track>[];
    _historySnapshot.update(tracks);
    final historyKeys = _historySnapshot.lookupKeys;
    final existingHistoryKeys = ref.watch(
      downloadHistoryVisibleBatchExistsProvider(_historySnapshot.request),
    );
    final titleStyle = Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold);
    Widget column({required String? heading, required Widget child}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: headingExtent,
          child: heading == null
              ? null
              : Text(heading, maxLines: 1, style: titleStyle),
        ),
        SizedBox(height: contentExtent, child: child),
      ],
    );
    final columns = [
      if (latest != null)
        column(
          heading: context.l10n.artistLatestRelease,
          child: _buildMornyeLatestRelease(context, latest, contentExtent),
        ),
      for (var start = 0; start < tracks.length; start += rowsPerColumn)
        column(
          heading: start == 0 ? context.l10n.artistTopSongs : null,
          child: Column(
            children: [
              for (
                var index = start;
                index < math.min(start + rowsPerColumn, tracks.length);
                index++
              )
                SizedBox(
                  height: rowExtent,
                  child: _buildPopularTrackItem(
                    index + 1,
                    tracks[index],
                    colorScheme,
                    existingHistoryKeys.contains(historyKeys[index]),
                    compact: true,
                  ),
                ),
            ],
          ),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = _mornyeHighlightColumn(constraints.maxWidth);
          return SizedBox(
            height: headingExtent + contentExtent,
            child: DesktopScrollArrows(
              builder: (context, controller) => ListView.separated(
                key: const ValueKey('artist-highlights'),
                controller: controller,
                scrollDirection: Axis.horizontal,
                physics: _ColumnSnapPhysics(
                  extent: width + _mornyeHighlightGap,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: _mornyeSectionInset,
                ),
                itemCount: columns.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: _mornyeHighlightGap),
                itemBuilder: (context, index) =>
                    SizedBox(width: width, child: columns[index]),
              ),
            ),
          );
        },
      ),
    );
  }

  /// The newest release, cover first with its details beside it.
  Widget _buildMornyeLatestRelease(
    BuildContext context,
    ArtistAlbum album,
    double extent,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    final released = DateTime.tryParse(album.releaseDate);
    final date = released == null
        ? album.releaseDate
        : DateFormat.yMMMd(
            Localizations.localeOf(context).toLanguageTag(),
          ).format(released);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _navigateToAlbum(album),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox.square(
                dimension: extent,
                child: album.coverUrl != null
                    ? CachedCoverImage(
                        imageUrl: album.coverUrl!,
                        fit: BoxFit.cover,
                      )
                    : const Icon(CupertinoIcons.square_stack, size: 32),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (date.isNotEmpty)
                    Text(
                      date,
                      maxLines: 1,
                      style: textTheme.bodySmall?.copyWith(
                        color: secondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  Text(
                    album.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyLarge,
                  ),
                  if (album.totalTracks > 0)
                    Text(
                      context.l10n.tracksCount(album.totalTracks),
                      maxLines: 1,
                      style: textTheme.bodyMedium?.copyWith(color: secondary),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPopularSection(BuildContext context, ColorScheme colorScheme) {
    if (_topTracks == null || _topTracks!.isEmpty) {
      return const SizedBox.shrink();
    }

    final tracks = _topTracks!;
    _historySnapshot.update(tracks);
    final historyKeys = _historySnapshot.lookupKeys;
    final existingHistoryKeys = ref.watch(
      downloadHistoryVisibleBatchExistsProvider(_historySnapshot.request),
    );
    const tracksPerPage = 5;
    final pageCount = (tracks.length / tracksPerPage).ceil();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
          child: Text(
            context.l10n.artistPopular,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        SizedBox(
          height: tracksPerPage * 64.0,
          child: PageView.builder(
            controller: _popularPageController,
            itemCount: pageCount,
            onPageChanged: (page) {
              setState(() {
                _popularCurrentPage = page;
              });
            },
            itemBuilder: (context, pageIndex) {
              final startIndex = pageIndex * tracksPerPage;
              final endIndex = (startIndex + tracksPerPage).clamp(
                0,
                tracks.length,
              );
              final pageTracks = tracks.sublist(startIndex, endIndex);

              return Column(
                children: pageTracks.asMap().entries.map((entry) {
                  final globalIndex = startIndex + entry.key;
                  return _buildPopularTrackItem(
                    globalIndex + 1,
                    entry.value,
                    colorScheme,
                    existingHistoryKeys.contains(historyKeys[globalIndex]),
                  );
                }).toList(),
              );
            },
          ),
        ),
        if (pageCount > 1)
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(pageCount, (index) {
                  final isActive = _popularCurrentPage == index;
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: isActive ? 8 : 6,
                    height: isActive ? 8 : 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isActive
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                    ),
                  );
                }),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPopularTrackItem(
    int rank,
    Track track,
    ColorScheme colorScheme,
    bool isInHistory, {
    bool compact = false,
  }) {
    return Consumer(
      builder: (context, ref, child) {
        final queueItem = ref.watch(
          downloadQueueLookupProvider.select(
            (lookup) => lookup.byTrackId[track.id],
          ),
        );

        final showLocalLibraryIndicator = ref.watch(
          settingsProvider.select(
            (s) => s.localLibraryEnabled && s.localLibraryShowDuplicates,
          ),
        );
        final isInLocalLibrary = showLocalLibraryIndicator
            ? ref.watch(
                localLibraryProvider.select(
                  (state) => state.existsInLibrary(
                    isrc: track.isrc,
                    trackName: track.name,
                    artistName: track.artistName,
                  ),
                ),
              )
            : false;

        final isQueued = queueItem != null;

        final row = DesktopContextMenuRegion(
          onContextMenu: (position) =>
              TrackCollectionQuickActions.showTrackOptionsSheet(
                context,
                ref,
                track,
                position: position,
                hasLocalPlaybackCandidate: isInHistory || isInLocalLibrary,
              ),
          child: InkWell(
            onTap: () => _handlePopularTrackTap(
              track,
              isQueued: isQueued,
              isInHistory: isInHistory,
              isInLocalLibrary: isInLocalLibrary,
            ),
            onLongPress: () =>
                TrackCollectionQuickActions.showTrackOptionsSheet(
                  context,
                  ref,
                  track,
                  hasLocalPlaybackCandidate: isInHistory || isInLocalLibrary,
                ),
            child: Padding(
              padding: compact
                  ? const EdgeInsets.symmetric(vertical: 4)
                  : EdgeInsetsDirectional.fromSTEB(
                      context.isMornye ? 20 : 16,
                      8,
                      10,
                      8,
                    ),
              child: Row(
                children: [
                  if (!context.isMornye) ...[
                    SizedBox(
                      width: 24,
                      child: Text(
                        '$rank',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  track.coverUrl != null
                      ? DownloadableCover(
                          coverUrl: track.coverUrl,
                          baseName: '${track.artistName} - ${track.name}',
                          child: CachedCoverImage(
                            imageUrl: track.coverUrl!,
                            width: 48,
                            height: 48,
                            borderRadius: BorderRadius.circular(4),
                            placeholder: (context, url) => ShimmerLoading(
                              child: Container(
                                width: 48,
                                height: 48,
                                color: colorScheme.surfaceContainerHighest,
                              ),
                            ),
                            errorWidget: (context, url, error) => Container(
                              width: 48,
                              height: 48,
                              color: colorScheme.surfaceContainerHighest,
                              child: Icon(
                                Icons.music_note,
                                color: colorScheme.onSurfaceVariant,
                                size: 24,
                              ),
                            ),
                          ),
                        )
                      : Container(
                          width: 48,
                          height: 48,
                          color: colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.music_note,
                            color: colorScheme.onSurfaceVariant,
                            size: 24,
                          ),
                        ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.name,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                fontSize: compact
                                    ? 14
                                    : context.isMornye
                                    ? 17
                                    : null,
                                fontWeight: context.isMornye
                                    ? FontWeight.w400
                                    : FontWeight.w500,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (track.albumName.isNotEmpty ||
                            isInLocalLibrary ||
                            isInHistory)
                          Row(
                            children: [
                              if (track.albumName.isNotEmpty)
                                Expanded(
                                  child: ClickableAlbumName(
                                    albumName: track.albumName,
                                    albumId: track.albumId,
                                    artistName: track.artistName,
                                    coverUrl: track.coverUrl,
                                    extensionId: widget.extensionId,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                          fontSize: compact
                                              ? 13
                                              : context.isMornye
                                              ? 15
                                              : null,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              if (isInLocalLibrary || isInHistory) ...[
                                if (track.albumName.isNotEmpty)
                                  const SizedBox(width: 6),
                                const InLibraryBadge(),
                              ],
                            ],
                          ),
                      ],
                    ),
                  ),
                  TrackCollectionQuickActions(
                    track: track,
                    hasLocalPlaybackCandidate: isInHistory || isInLocalLibrary,
                  ),
                ],
              ),
            ),
          ),
        );
        if (!context.isMornye) return row;
        return Stack(
          children: [
            row,
            PositionedDirectional(
              start: compact ? 60 : 80,
              end: compact ? 0 : 20,
              bottom: 0,
              child: Divider(
                height: 1,
                thickness: 0.5,
                color: Colors.white.withValues(alpha: 0.12),
              ),
            ),
          ],
        );
      },
    );
  }

  void _handlePopularTrackTap(
    Track track, {
    required bool isQueued,
    required bool isInHistory,
    required bool isInLocalLibrary,
  }) async {
    if (isQueued) return;

    final settings = ref.read(settingsProvider);
    if (settings.allowQualityVariants && (isInHistory || isInLocalLibrary)) {
      _downloadTrack(track);
      return;
    }

    final playedLocal = await playLocalIfAvailable(context, ref, track);
    if (playedLocal) {
      return;
    }

    _downloadTrack(track);
  }

  void _downloadTrack(Track track) {
    final settings = ref.read(settingsProvider);
    ref.read(settingsProvider.notifier).setHasSearchedBefore();

    void enqueue(String service, {String? quality}) {
      ref
          .read(downloadQueueProvider.notifier)
          .addToQueue(track, service, qualityOverride: quality);
      showAddedToQueueSnackBar(context, track.name);
    }

    if (settings.askQualityBeforeDownload || settings.allowQualityVariants) {
      DownloadServicePicker.show(
        context,
        recommendedService: _recommendedDownloadService(),
        onSelect: (quality, service) {
          if (!mounted) return;
          enqueue(service, quality: quality);
        },
      );
      return;
    }

    final extensionState = ref.read(extensionProvider);
    final service = resolveEffectiveDownloadService(
      settings.defaultService,
      extensionState,
    );
    if (service.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.extensionsNoDownloadProvider)),
      );
      return;
    }
    enqueue(service);
  }

  Widget _buildAlbumSection(
    BuildContext context,
    String title,
    List<ArtistAlbum> albums,
    ColorScheme colorScheme, {
    bool showTypeBadge = false,
  }) {
    if (isDesktopPlatform && context.isMornye) {
      // Four covers to the pane's width: two line up under each highlight
      // column above, as in Music.
      return LayoutBuilder(
        builder: (context, constraints) {
          final column = _mornyeHighlightColumn(constraints.maxWidth);
          final tile = (column - _mornyeHighlightGap) / 2;
          return _albumShelf(
            context,
            title,
            albums,
            colorScheme,
            showTypeBadge: showTypeBadge,
            tileSize: tile,
            sectionHeight:
                tile +
                artistAlbumSectionHeight(context) -
                artistAlbumTileSize(context),
            headingStyle: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            headingPadding: const EdgeInsets.fromLTRB(
              _mornyeSectionInset,
              28,
              _mornyeSectionInset,
              12,
            ),
            listPadding: _mornyeSectionInset - 4,
          );
        },
      );
    }
    return _albumShelf(
      context,
      '$title (${albums.length})',
      albums,
      colorScheme,
      showTypeBadge: showTypeBadge,
      tileSize: artistAlbumTileSize(context),
      sectionHeight: artistAlbumSectionHeight(context),
      headingStyle: Theme.of(
        context,
      ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
      headingPadding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
      listPadding: 12,
    );
  }

  Widget _albumShelf(
    BuildContext context,
    String title,
    List<ArtistAlbum> albums,
    ColorScheme colorScheme, {
    required bool showTypeBadge,
    required double tileSize,
    required double sectionHeight,
    required TextStyle? headingStyle,
    required EdgeInsets headingPadding,
    required double listPadding,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: headingPadding,
          child: Text(title, style: headingStyle),
        ),
        NotificationListener<ScrollNotification>(
          onNotification: _onAlbumsScroll,
          child: SizedBox(
            height: sectionHeight,
            child: DesktopListScope(
              onSelectAll: () => selectAll(
                (_albums ?? const <ArtistAlbum>[]).map((album) => album.id),
              ),
              onClearSelection: showsSelectionBar ? exitSelectionMode : null,
              child: DesktopScrollArrows(
                builder: (context, controller) => ListView.builder(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(horizontal: listPadding),
                  itemCount: albums.length,
                  itemBuilder: (context, index) {
                    final album = albums[index];
                    return KeyedSubtree(
                      key: ValueKey(album.id),
                      child: _buildAlbumCard(
                        context,
                        album,
                        colorScheme,
                        sectionAlbums: albums,
                        tileSize: tileSize,
                        sectionHeight: sectionHeight,
                        showTypeBadge: showTypeBadge,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumCard(
    BuildContext context,
    ArtistAlbum album,
    ColorScheme colorScheme, {
    required List<ArtistAlbum> sectionAlbums,
    required double tileSize,
    required double sectionHeight,
    bool showTypeBadge = false,
  }) {
    final isSelected = selectedIds.contains(album.id);

    return DesktopContextMenuRegion(
      onContextMenu: (position) => showSelectionMenu(
        album.id,
        () => _showAlbumMenu(context, album, position),
      ),
      child: _buildAlbumCardBody(
        context,
        album,
        colorScheme,
        sectionAlbums: sectionAlbums,
        isSelected: isSelected,
        tileSize: tileSize,
        sectionHeight: sectionHeight,
        showTypeBadge: showTypeBadge,
      ),
    );
  }

  /// The desktop menu of an album card: open it, or act on the selection
  /// the album joins, as the selection bar does.
  Future<bool> _showAlbumMenu(
    BuildContext context,
    ArtistAlbum album,
    Offset position,
  ) {
    final l10n = context.l10n;
    final selected = [
      for (final candidate in _albums ?? const <ArtistAlbum>[])
        if (selectedIds.contains(candidate.id)) candidate,
    ];
    if (selected.isEmpty) selected.add(album);
    return showContextMenu(
      context,
      position: position,
      groups: [
        [
          if (selected.length == 1)
            ContextMenuAction(
              icon: Icons.open_in_new,
              label: l10n.desktopMenuOpen,
              onSelected: () {
                exitSelectionMode();
                _navigateToAlbum(album);
              },
            ),
          if (!showsSelectionBar)
            ContextMenuAction(
              icon: Icons.checklist,
              label: l10n.discographySelectAlbums,
              onSelected: () => enterSelectionMode(album.id),
            ),
          ContextMenuAction(
            icon: Icons.playlist_add,
            label: l10n.collectionAddToPlaylist,
            onSelected: _isFetchingDiscography
                ? null
                : () {
                    exitSelectionMode();
                    _fetchAndQueueAlbums(
                      selected,
                      ref.read(settingsProvider).defaultService,
                      null,
                      addToPlaylist: true,
                    );
                  },
          ),
          ContextMenuAction(
            icon: Icons.download,
            label: l10n.discographyDownloadSelected,
            onSelected: () => _downloadSelectedAlbums(this.context, selected),
          ),
        ],
      ],
    );
  }

  Widget _buildAlbumCardBody(
    BuildContext context,
    ArtistAlbum album,
    ColorScheme colorScheme, {
    required List<ArtistAlbum> sectionAlbums,
    required bool isSelected,
    required double tileSize,
    required double sectionHeight,
    required bool showTypeBadge,
  }) {
    return Semantics(
      button: true,
      selected: isSelectionMode && isSelected,
      label: showsSelectionBar
          ? context.l10n.a11ySelectAlbum(album.name)
          : context.l10n.a11yOpenAlbum(album.name),
      child: GestureDetector(
        onTap: () {
          final kind = isDesktopPlatform
              ? desktopClickKind()
              : DesktopClick.replace;
          if (isDesktopPlatform &&
              (isSelectionMode || kind != DesktopClick.replace)) {
            applyDesktopClick(
              album.id,
              kind == DesktopClick.replace ? DesktopClick.toggle : kind,
              kind == DesktopClick.extend
                  ? sectionAlbums.map((album) => album.id).toList()
                  : const [],
            );
          } else if (isSelectionMode) {
            toggleSelection(album.id);
          } else {
            _navigateToAlbum(album);
          }
        },
        onLongPress: () {
          if (!isSelectionMode) {
            enterSelectionMode(album.id);
          }
        },
        child: Container(
          width: tileSize,
          height: sectionHeight,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: tileSize,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DownloadableCover(
                      coverUrl: album.coverUrl,
                      baseName: '${album.artists} - ${album.name}',
                      enabled: !isSelectionMode,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: album.coverUrl != null
                            ? CachedCoverImage(
                                imageUrl: album.coverUrl!,
                                width: tileSize,
                                height: tileSize,
                                fit: BoxFit.cover,
                                memCacheWidth: (tileSize * 2).round(),
                                memCacheHeight: (tileSize * 2).round(),
                                placeholder: (context, url) => ShimmerLoading(
                                  child: Container(
                                    color: colorScheme.surfaceContainerHighest,
                                  ),
                                ),
                                errorWidget: (context, url, error) => Container(
                                  color: colorScheme.surfaceContainerHighest,
                                  child: Icon(
                                    Icons.album,
                                    color: colorScheme.onSurfaceVariant,
                                    size: 40,
                                  ),
                                ),
                              )
                            : Container(
                                color: colorScheme.surfaceContainerHighest,
                                child: Icon(
                                  Icons.album,
                                  color: colorScheme.onSurfaceVariant,
                                  size: 40,
                                ),
                              ),
                      ),
                    ),
                    if (isSelected || showsSelectionBar)
                      Positioned.fill(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: isSelected
                                ? colorScheme.primary.withValues(alpha: 0.3)
                                : Colors.black.withValues(alpha: 0.1),
                            border: isSelected
                                ? Border.all(
                                    color: colorScheme.primary,
                                    width: 3,
                                  )
                                : null,
                          ),
                        ),
                      ),
                    if (showsSelectionBar)
                      PositionedDirectional(
                        top: 8,
                        end: 8,
                        child: AnimatedSelectionCheckbox(
                          selected: isSelected,
                          colorScheme: colorScheme,
                          size: 28,
                          unselectedColor: colorScheme.surface.withValues(
                            alpha: 0.9,
                          ),
                        ),
                      ),
                    if (showTypeBadge)
                      PositionedDirectional(
                        start: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            album.albumType == 'ep'
                                ? context.l10n.releaseTypeEp
                                : context.l10n.releaseTypeSingle,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        album.name,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      album.totalTracks > 0
                          ? '${album.releaseDate.length >= 4 ? album.releaseDate.substring(0, 4) : album.releaseDate} ${context.l10n.tracksCount(album.totalTracks)}'
                          : album.releaseDate.length >= 4
                          ? album.releaseDate.substring(0, 4)
                          : album.releaseDate,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _navigateToAlbum(ArtistAlbum album) {
    ref.read(settingsProvider.notifier).setHasSearchedBefore();

    if (album.providerId != null && album.providerId!.isNotEmpty) {
      pushPage<void>(
        context,
        (context) => ExtensionAlbumScreen(
          extensionId: album.providerId!,
          albumId: album.id,
          albumName: album.name,
          coverUrl: album.coverUrl,
          initialAlbumType: album.albumType,
          initialTotalTracks: album.totalTracks,
        ),
      );
    } else {
      pushPage<void>(
        context,
        (context) => AlbumScreen(
          albumId: album.id,
          albumName: album.name,
          coverUrl: album.coverUrl,
        ),
      );
    }
  }
}
