part of 'track_metadata_screen.dart';

extension _TrackMetadataHeader on _TrackMetadataScreenState {
  List<Widget> _headerMetadataItems(BuildContext context) => [
    if (_displayAudioQuality != null && _displayAudioQuality!.isNotEmpty)
      HeaderMetaItem(_displayAudioQuality!),
    if (duration != null) HeaderMetaItem(formatClock(duration!)),
    // The header's title is plain text, so the badge sits with the details.
    if (isExplicit)
      Builder(
        builder: (header) =>
            ExplicitBadge(colorScheme: HeaderPalette.of(header)),
      ),
    if (_service == 'local')
      HeaderMetaItem(
        context.l10n.librarySourceLocal,
        icon: context.isMornye ? CupertinoIcons.folder : Icons.folder,
      )
    else if (_service.isNotEmpty)
      HeaderMetaItem(_service[0].toUpperCase() + _service.substring(1)),
  ];

  /// The cover on its way between a list row and the header: this page's
  /// cover, with corners that go from the row thumbnail's to the header's.
  /// Without it the cover would fly with square corners and get them back
  /// on landing. The flight's animation is at 1 on this page both ways.
  Widget _coverFlight(
    BuildContext flight,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext from,
    BuildContext to,
  ) {
    final push = direction == HeroFlightDirection.push;
    final header = push ? to : from;
    // The desktop Mornye header clips with continuous corners instead.
    final headerCorners =
        header.findAncestorWidgetOfExactType<ClipRRect>()?.borderRadius ??
        header.findAncestorWidgetOfExactType<ClipRSuperellipse>()?.borderRadius;
    final corners = BorderRadiusTween(
      begin: flight.tokens.borderRadiusThumb,
      end: headerCorners?.resolve(Directionality.of(flight)),
    ).animate(animation);
    // A row may lay a mark over its picture (where a server's song is
    // kept). The mark is the row's: it never rides on to the header.
    final rowCover = ((push ? from : to).widget as Hero).child;
    final marked = rowCover is OfflineAvailabilityCover ? rowCover : null;
    final rowPicture = marked?.child ?? rowCover;
    if (push) {
      // Kept for the landing: the flight can end before the decode does.
      _flownCover = rowPicture;
      _flownCoverItem = _itemId;
    }
    final cover = AnimatedBuilder(
      animation: corners,
      builder: (context, cover) => ClipRRect(
        borderRadius: corners.value ?? BorderRadius.zero,
        child: cover,
      ),
      // Opening, this page's cover may still be decoding and would fly as
      // nothing: the row's own picture flies under it until it is there.
      child: push
          ? Stack(
              fit: StackFit.expand,
              children: [rowPicture, (header.widget as Hero).child],
            )
          : (header.widget as Hero).child,
    );
    if (marked == null) return cover;
    // The mark fades over the flight's row end, out on the way to the header
    // and in on the way back, instead of being cut with the row's cover.
    return Stack(
      fit: StackFit.expand,
      children: [
        cover,
        FadeTransition(
          opacity: animation.drive(
            Tween<double>(
              begin: 1,
              end: 0,
            ).chain(CurveTween(curve: const Interval(0, 0.4))),
          ),
          child: Stack(children: [marked.badge]),
        ),
      ],
    );
  }

  /// The header albums and playlists have, for one song: its cover, title,
  /// artist and album, the file's quality and the song's main actions. The
  /// rest of the actions stay in the More menu.
  ///
  /// The slivers go straight into the page's scroll view, so the toolbar
  /// stays pinned once the cover and details have scrolled away.
  List<Widget> _buildHeader(BuildContext context, ColorScheme colorScheme) {
    final coverCacheWidth = coverCacheWidthForViewport(context);
    final backdropCacheWidth = metadataBackdropCacheExtent(context);
    // Downloaded-item entry points must await resolveOrExtract before pushing
    // this route. That precondition keeps the Hero, foreground, and backdrop
    // on one source from the first frame; this synchronous lookup also covers
    // cached rebuilds and in-screen swipe navigation.
    final sharedEmbeddedCoverPath = _hasPath(_embeddedCoverPreviewPath)
        ? _embeddedCoverPreviewPath
        : DownloadedEmbeddedCoverResolver.resolve(_filePath);
    final artworkSource = resolveMetadataArtworkSource(
      embeddedCoverPath: sharedEmbeddedCoverPath,
      localCoverPath: _localCoverPath,
      remoteCoverUrl: _coverUrl,
    );

    Widget placeholder(double iconSize) => ColoredBox(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: AppIcon.adaptive(
          Icons.music_note,
          size: iconSize,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );

    // [landing] is the cover a list row's picture flies into: until its own
    // picture is decoded it shows the row's, read when it is built.
    Widget artworkImage({
      required int cacheWidth,
      int? cacheHeight,
      required double iconSize,
      bool landing = false,
    }) {
      final source = artworkSource;
      if (source == null) return placeholder(iconSize);
      if (isHttpCoverUrl(source)) {
        return CachedCoverImage(
          imageUrl: source,
          fit: BoxFit.cover,
          memCacheWidth: cacheWidth,
          memCacheHeight: cacheHeight,
          placeholder: (_, _) =>
              (landing ? _landedCover : null) ??
              ColoredBox(color: colorScheme.surface),
          errorWidget: (_, _, _) => placeholder(iconSize),
        );
      }
      final filePath = coverFilePath(source);
      if (filePath == null) return placeholder(iconSize);
      return Image.file(
        File(filePath),
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        frameBuilder: landing
            ? (_, picture, frame, _) =>
                  frame == null ? _landedCover ?? picture : picture
            : null,
        errorBuilder: (_, _, _) => placeholder(iconSize),
      );
    }

    final backdropKey = (
      _itemId,
      artworkSource,
      backdropCacheWidth,
      colorScheme,
    );
    if (backdropKey != _backdropKey) {
      _backdropKey = backdropKey;
      _backdrop = RepaintBoundary(
        key: ValueKey<String>('metadata_backdrop_$_itemId'),
        child: artworkImage(
          cacheWidth: backdropCacheWidth,
          cacheHeight: backdropCacheWidth,
          iconSize: 80,
        ),
      );
    }

    // Watched here: the header builds its actions outside this build.
    final showPlayer = ref.watch(playerUiEnabledProvider);
    final back = HeaderCircleButton(
      icon: context.isMornye ? CupertinoIcons.back : Icons.arrow_back,
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      onPressed: _popWithMetadataResult,
    );
    return AlbumDetailHeader(
      title: trackName,
      expandedHeight: calculateExpandedHeight(context),
      showTitleInAppBar: false,
      showTitleListenable: showTitleNotifier,
      background: _backdrop!,
      paletteSource: artworkSource == null || isHttpCoverUrl(artworkSource)
          ? artworkSource
          : coverFilePath(artworkSource),
      blurAndScrimBackground: artworkSource != null,
      // The header rounds the cover outside the Hero, so the flight rounds
      // it itself.
      coverBuilder: (context, coverSize) => Hero(
        tag: _coverHeroTag,
        transitionOnUserGestures: heroFollowsBackSwipe(context),
        flightShuttleBuilder: _coverFlight,
        child: SizedBox.square(
          dimension: coverSize,
          child: artworkImage(
            cacheWidth: coverCacheWidth,
            iconSize: 48,
            landing: true,
          ),
        ),
      ),
      // Built inside the header, so it reads the header's artwork scheme.
      subtitle: Builder(builder: _buildHeaderSubtitle),
      meta: HeaderMetaRow(items: _headerMetadataItems(context)),
      actions: Builder(
        builder: (header) => _buildHeaderActions(header, showPlayer),
      ),
      appBarActions: [
        Builder(
          builder: (buttonContext) => HeaderCircleButton(
            icon: context.isMornye ? CupertinoIcons.ellipsis : Icons.more_vert,
            tooltip: MaterialLocalizations.of(context).showMenuTooltip,
            onPressed: () => _showOptionsMenu(
              context,
              ref,
              colorScheme,
              anchor: mornyeMenuAnchor(buttonContext),
            ),
          ),
        ),
      ],
      // Centered so the tight leading slot of Material cannot stretch it.
      leading: context.isMornye || isDesktopPlatform
          ? back
          : Center(child: back),
    ).buildSlivers(context);
  }

  /// The artist with the album on a line below it, each cut short on its
  /// own so a long artist does not push the album out.
  Widget _buildHeaderSubtitle(BuildContext header) {
    final scheme = HeaderPalette.of(header);
    final mornye = header.isMornye;
    final artistStyle = isDesktopPlatform
        ? desktopDetailSubtitleStyle(header)
        : Theme.of(header).textTheme.titleMedium?.copyWith(
            color: mornye
                ? Theme.of(header).colorScheme.primary
                : scheme.onSurfaceVariant,
            fontWeight: mornye ? FontWeight.w400 : FontWeight.w600,
          );
    final album = albumName.trim();
    Text line(String text, {TextStyle? style}) => Text(
      text,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: isDesktopPlatform ? TextAlign.start : TextAlign.center,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: isDesktopPlatform
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        line(artistName, style: artistStyle),
        if (album.isNotEmpty)
          line(
            album,
            style: Theme.of(
              header,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
      ],
    );
  }

  /// Play as the one wide filled button, between a round Edit and a round
  /// Add to queue. A round button is left out where the song cannot take
  /// its action; Play stays, disabled, while the file is missing.
  ///
  /// Until the file has been checked the song is taken to be there, so the
  /// row has its buttons from the first frame of the page's entrance instead
  /// of gaining them a moment later. Edit on a network song still waits to
  /// learn whether its connection accepts writes.
  Widget _buildHeaderActions(BuildContext header, bool showPlayer) {
    final tokens = header.tokens;
    final l10n = header.l10n;
    final unchecked = _fileAccess == null;
    final hasFile = _fileExists || unchecked;
    final play = HeaderFilledButton(
      icon: Icons.play_arrow,
      label: l10n.trackMetadataPlay,
      onPressed: hasFile ? () => _openFile(context, rawFilePath) : null,
    );
    final edit = (unchecked ? !_isNetworkItem : _canEditMetadataFile)
        ? HeaderCircleButton(
            icon: Icons.edit_outlined,
            tooltip: l10n.trackEditMetadata,
            tonal: true,
            onPressed: () => _showEditMetadataSheet(
              context,
              ref,
              Theme.of(context).colorScheme,
            ),
          )
        : null;
    final queue = hasFile && showPlayer
        ? HeaderCircleButton(
            icon: Icons.playlist_add,
            tooltip: l10n.trackAddToQueue,
            tonal: true,
            onPressed: () => _enqueueThis(ref, playNext: false),
          )
        : null;
    if (isDesktopPlatform) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: tokens.gapSm,
        children: [play, ?edit, ?queue],
      );
    }
    if (header.isMornye) {
      return Row(
        spacing: tokens.gapMd,
        children: [
          ?edit,
          Expanded(child: play),
          ?queue,
        ],
      );
    }
    // Tablets keep the row the width it has on a phone.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: ExpressiveButtonGroup(
          flexible: {edit == null ? 0 : 1},
          spacing: tokens.gapMd,
          slotWidth: tokens.minTouchTarget,
          children: [?edit, play, ?queue],
        ),
      ),
    );
  }

  RoundedRectangleBorder _sectionCardShape(
    BuildContext context,
    ColorScheme colorScheme,
  ) {
    return RoundedRectangleBorder(
      borderRadius: context.tokens.borderRadiusCard,
    );
  }

  /// The surface of one section of the page, shared by both styles.
  Widget _metadataSectionSurface(
    BuildContext context,
    ColorScheme scheme, {
    required Widget child,
  }) {
    if (context.isMornye) {
      return Material(
        color: MornyeTheme.controlFill(context),
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: DividerTheme(
          data: DividerTheme.of(
            context,
          ).copyWith(color: MornyeTheme.metadataDividerColor(context)),
          child: child,
        ),
      );
    }
    return AppContentCard(
      elevation: 0,
      color: settingsGroupColor(context),
      shape: _sectionCardShape(context, scheme),
      child: child,
    );
  }
}
