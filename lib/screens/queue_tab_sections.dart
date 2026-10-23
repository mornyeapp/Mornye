part of 'queue_tab.dart';

/// A run of consecutive rows sharing one section label.
class _LibrarySection {
  const _LibrarySection(this.label, this.start, this.end);

  final String label;
  final int start;

  /// Exclusive.
  final int end;

  int get length => end - start;
}

final _letterPattern = RegExp(r'[\p{L}]', unicode: true);

final _monthYearFormats = <String, DateFormat>{};

DateFormat _monthYearFormat(BuildContext context) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  return _monthYearFormats.putIfAbsent(locale, () => DateFormat.yMMMM(locale));
}

/// First letter of [text] for an alphabetical index; digits and symbols
/// share `#`.
String _sectionInitial(String text) {
  final trimmed = text.trimLeft();
  for (final character in trimmed.characters) {
    final upper = character.toUpperCase();
    if (upper != character.toLowerCase()) return upper;
    if (_letterPattern.hasMatch(character)) return upper;
    return '#';
  }
  return '#';
}

const _alphabeticalSorts = {'a-z', 'z-a'};
const _artistSorts = {'artist-asc', 'artist-desc'};
const _albumSorts = {'album-asc', 'album-desc'};
const _dateSorts = {'latest', 'oldest'};

/// Sort choices offered by the Library sort sheet, in display order.
const _librarySortModes = [
  'latest',
  'oldest',
  'size-desc',
  'size-asc',
  'a-z',
  'z-a',
  'artist-asc',
  'artist-desc',
  'album-asc',
  'album-desc',
  'release-newest',
  'release-oldest',
  'genre-asc',
  'genre-desc',
];

extension _QueueTabSections on _QueueTabState {
  Iterable<String> get _availableLibrarySortModes {
    final mode =
        widget.librarySection ?? ref.read(settingsProvider).historyFilterMode;
    return mode == 'playlists'
        ? _librarySortModes.where((sort) => !sort.startsWith('size-'))
        : _librarySortModes;
  }

  String _sortLabel(BuildContext context, String mode) {
    final l10n = context.l10n;
    return switch (mode) {
      'oldest' => l10n.libraryFilterSortOldest,
      'size-desc' => l10n.libraryFilterSortSizeLargest,
      'size-asc' => l10n.libraryFilterSortSizeSmallest,
      'a-z' => l10n.searchSortTitleAZ,
      'z-a' => l10n.searchSortTitleZA,
      'artist-asc' => l10n.searchSortArtistAZ,
      'artist-desc' => l10n.searchSortArtistZA,
      'album-asc' => l10n.libraryFilterSortAlbumAsc,
      'album-desc' => l10n.libraryFilterSortAlbumDesc,
      'release-newest' => l10n.searchSortDateNewest,
      'release-oldest' => l10n.searchSortDateOldest,
      'genre-asc' => l10n.libraryFilterSortGenreAsc,
      'genre-desc' => l10n.libraryFilterSortGenreDesc,
      _ => l10n.libraryFilterSortLatest,
    };
  }

  /// Section label of [item] under the current sort, or null when the sort
  /// has no readable sections (genre and release dates are not loaded).
  String? _trackSectionLabel(BuildContext context, UnifiedLibraryItem item) {
    if (_alphabeticalSorts.contains(_sortMode)) {
      return _sectionInitial(item.trackName);
    }
    if (_artistSorts.contains(_sortMode)) {
      return _sectionInitial(item.artistName);
    }
    if (_albumSorts.contains(_sortMode)) {
      return _sectionInitial(item.albumName);
    }
    if (_dateSorts.contains(_sortMode)) {
      return _monthYearFormat(context).format(item.addedAt);
    }
    return null;
  }

  String? _albumSectionLabel(
    BuildContext context, {
    required String album,
    required String artist,
    required DateTime added,
  }) {
    if (_alphabeticalSorts.contains(_sortMode) ||
        _albumSorts.contains(_sortMode)) {
      return _sectionInitial(album);
    }
    if (_artistSorts.contains(_sortMode)) return _sectionInitial(artist);
    if (_dateSorts.contains(_sortMode)) {
      return _monthYearFormat(context).format(added);
    }
    return null;
  }

  /// Splits [items] into runs that share a section label.
  List<_LibrarySection> _trackSections(
    BuildContext context,
    List<UnifiedLibraryItem> items,
  ) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    if (identical(items, _sectionItems) &&
        _sortMode == _sectionSort &&
        locale == _sectionLocale) {
      return _cachedTrackSections;
    }
    final sections = <_LibrarySection>[];
    // Date labels name only the month, so each month is formatted once.
    final monthLabels = _dateSorts.contains(_sortMode) ? <int, String>{} : null;
    String? label;
    var start = 0;
    for (var i = 0; i < items.length; i++) {
      final added = items[i].addedAt;
      final next = monthLabels != null
          ? monthLabels.putIfAbsent(
              added.year * 12 + added.month,
              () => _trackSectionLabel(context, items[i]) ?? '',
            )
          : _trackSectionLabel(context, items[i]) ?? '';
      if (i == 0) {
        label = next;
      } else if (next != label) {
        sections.add(_LibrarySection(label!, start, i));
        label = next;
        start = i;
      }
    }
    if (items.isNotEmpty) {
      sections.add(_LibrarySection(label!, start, items.length));
    }
    _sectionItems = items;
    _sectionSort = _sortMode;
    _sectionLocale = locale;
    return _cachedTrackSections = sections;
  }

  /// Track rows grouped under pinned section headers. Each section is its own
  /// connected run of rows.
  Widget _buildSectionedTrackSlivers({
    required BuildContext context,
    required List<UnifiedLibraryItem> items,
    required Widget Function(int index) rowBuilder,
    required int leadCount,
    required Widget Function(int index) leadBuilder,
  }) {
    final sections = _trackSections(context, items);
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: _LibrarySectionList(
        sections: sections,
        leadCount: leadCount,
        leadBuilder: leadBuilder,
        rowBuilder: (index, section) => TrackCardSegment.at(
          key: ValueKey(items[index].id),
          index: index - section.start,
          count: section.length,
          child: rowBuilder(index),
        ),
      ),
    );
  }

  /// Quick sort control beside a page's count.
  Widget _buildSortButton(BuildContext context) => Builder(
    builder: (context) => ExpressiveButton(
      text: true,
      onPressed: () => _showSortSheet(context),
      icon: const AppIcon(Icons.sort, size: 18),
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      child: Text(_sortLabel(context, _sortMode)),
    ),
  );

  void _setSortMode(String mode) {
    if (mode == _sortMode || !mounted) return;
    _setState(() {
      _sortMode = mode;
      _resetLibraryPaging();
    });
  }

  /// The sort modes as a checked menu below the sort button, on desktop.
  /// [anchor] is the button when [context] is not.
  bool _showSortMenu(BuildContext context, {BuildContext? anchor}) {
    final position = isDesktopPlatform
        ? contextMenuPositionBelow(anchor ?? context)
        : null;
    if (position == null) return false;
    showContextMenu(
      context,
      position: position,
      groups: [
        [
          for (final mode in _availableLibrarySortModes)
            ContextMenuAction(
              icon: switch (mode) {
                'a-z' || 'z-a' => Icons.sort_by_alpha,
                'artist-asc' || 'artist-desc' => Icons.person_outline,
                'album-asc' || 'album-desc' => Icons.album_outlined,
                'release-newest' || 'release-oldest' => Icons.event_outlined,
                'genre-asc' || 'genre-desc' => Icons.category_outlined,
                'size-desc' || 'size-asc' => Icons.storage_outlined,
                _ => Icons.schedule,
              },
              label: _sortLabel(context, mode),
              checked: mode == _sortMode,
              onSelected: () => _setSortMode(mode),
            ),
        ],
      ],
    );
    return true;
  }

  /// Sort, filter and, given a [viewMode], the list/grid switch of a Library
  /// page. Material 3 Expressive joins them in one connected button group
  /// with the labels and tooltips of the separate buttons, which Mornye and
  /// reduced motion keep.
  List<Widget> _buildLibraryTools(BuildContext context, {String? viewMode}) {
    if (!materialExpressiveEnabled(context)) {
      return [
        _buildSortButton(context),
        _buildFilterButton(context),
        if (viewMode != null) _buildViewModeButton(context, viewMode),
      ];
    }
    final l10n = context.l10n;
    final filterCount = _activeFilterCount;
    final grid = viewMode == 'grid';
    return [
      _LibraryToolGroup(
        tools: [
          _LibraryTool(
            icon: const AppIcon(Icons.sort),
            label: _sortLabel(context, _sortMode),
            // The menu anchors below the button but opens from the page, so
            // it does not inherit the button's text and icon styles.
            onPressed: (button) => _showSortSheet(context, anchor: button),
          ),
          _LibraryTool(
            icon: Badge(
              isLabelVisible: filterCount > 0,
              label: Text('$filterCount'),
              child: const AppIcon(Icons.filter_list),
            ),
            label: l10n.libraryFilterTitle,
            onPressed: (_) => _showFilterSheet(context),
            onLongPress: filterCount > 0 ? _resetFilters : null,
          ),
          if (viewMode != null)
            _LibraryTool(
              icon: AppIcon(grid ? Icons.view_list : Icons.grid_view),
              tooltip: grid
                  ? l10n.appearanceHistoryViewList
                  : l10n.appearanceHistoryViewGrid,
              onPressed: (_) => ref
                  .read(settingsProvider.notifier)
                  .setHistoryViewMode(grid ? 'list' : 'grid'),
            ),
        ],
      ),
    ];
  }

  /// Switches song pages between the list and the cover grid.
  Widget _buildViewModeButton(BuildContext context, String viewMode) {
    final grid = viewMode == 'grid';
    return AppIconButton(
      tooltip: grid
          ? context.l10n.appearanceHistoryViewList
          : context.l10n.appearanceHistoryViewGrid,
      icon: AppIcon(grid ? Icons.view_list : Icons.grid_view),
      onPressed: () => ref
          .read(settingsProvider.notifier)
          .setHistoryViewMode(grid ? 'list' : 'grid'),
    );
  }

  Future<T?> _showLibraryOptionsSheet<T>(
    BuildContext context, {
    required ScrollableWidgetBuilder builder,
  }) => showAppModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (context) => AppScrollableSheet(builder: builder),
  );

  Future<void> _showSortSheet(
    BuildContext context, {
    BuildContext? anchor,
  }) async {
    if (_showSortMenu(context, anchor: anchor)) return;
    final selected = await _showLibraryOptionsSheet<String>(
      context,
      builder: (sheetContext, scrollController) => AppBottomSheet(
        title: sheetContext.l10n.libraryFilterSort,
        child: SingleChildScrollView(
          controller: scrollController,
          padding: EdgeInsets.only(bottom: sheetContext.tokens.gapLg),
          child: SettingsGroup(
            children: [
              for (final mode in _availableLibrarySortModes)
                if (sheetContext.isMornye)
                  SettingsItem(
                    title: _sortLabel(sheetContext, mode),
                    selected: mode == _sortMode,
                    trailing: mode == _sortMode
                        ? AppIcon(
                            Icons.check,
                            color: Theme.of(sheetContext).colorScheme.primary,
                          )
                        : const SizedBox.shrink(),
                    showDivider: mode != _availableLibrarySortModes.last,
                    onTap: () => Navigator.pop(sheetContext, mode),
                  )
                else
                  ListTile(
                    dense: true,
                    minTileHeight: sheetContext.tokens.minTouchTarget,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: sheetContext.tokens.rowPaddingH,
                    ),
                    titleTextStyle: Theme.of(sheetContext).textTheme.bodyLarge,
                    title: Text(_sortLabel(sheetContext, mode)),
                    selected: mode == _sortMode,
                    trailing: mode == _sortMode
                        ? AppIcon(
                            Icons.check,
                            color: Theme.of(sheetContext).colorScheme.primary,
                          )
                        : null,
                    onTap: () => Navigator.pop(sheetContext, mode),
                  ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) _setSortMode(selected);
  }

  /// Albums | Singles switch at the top of the Albums page.
  Widget _buildAlbumsModeToggle(BuildContext context) {
    final l10n = context.l10n;
    final labels = [l10n.historyFilterAlbums, l10n.historyFilterSingles];
    final selected = _albumsShowSingles ? 1 : 0;
    final Widget toggle;
    if (materialExpressiveEnabled(context)) {
      toggle = MaterialExpressiveScope(
        skipAutofocus: true,
        child: M3EButtonGroup(
          type: M3EButtonGroupType.connected,
          style: M3EButtonStyle.filled,
          // Connected segments get no inflated target; keep 48 dp.
          size: M3EButtonSize.sm.copyWith(height: 48),
          selectedIndex: selected,
          selectionRequired: true,
          onSelectedIndexChanged: (index) {
            if (index != null) _setAlbumsShowSingles(index == 1);
          },
          actions: [
            for (final label in labels)
              M3EButtonGroupAction(label: Text(label)),
          ],
        ),
      );
    } else {
      toggle = SegmentedButton<int>(
        showSelectedIcon: false,
        segments: [
          for (final (index, label) in labels.indexed)
            ButtonSegment(value: index, label: Text(label)),
        ],
        selected: {selected},
        onSelectionChanged: (value) => _setAlbumsShowSingles(value.first == 1),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Align(alignment: AlignmentDirectional.centerStart, child: toggle),
    );
  }

  /// Artists across downloaded and scanned music, alphabetically under
  /// pinned letter headers. Tapping one opens that artist's albums.
  Widget _buildArtistsPage(BuildContext context, ColorScheme colorScheme) {
    const request = (
      artists: true,
      artist: null,
      search: '',
      sort: 'a-z',
      limit: 80,
      completeness: null,
    );
    return Consumer(
      builder: (context, ref, _) {
        final state = ref.watch(libraryBrowseProvider(request));
        final entries = state.value?.entries ?? const <LibraryBrowseEntry>[];
        final sections = <_LibrarySection>[];
        for (var i = 0; i < entries.length; i++) {
          final label = _sectionInitial(entries[i].artist);
          if (sections.isEmpty || sections.last.label != label) {
            if (sections.isNotEmpty) {
              final last = sections.removeLast();
              sections.add(_LibrarySection(last.label, last.start, i));
            }
            sections.add(_LibrarySection(label, i, entries.length));
          }
        }
        void openArtist(String artist) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: MornyeLibraryScreen(
                page: MornyeLibraryPage.albums,
                artist: artist,
                onOpenSection: (_) {},
              ),
            ),
          ),
        );
        final content = CustomScrollView(
          slivers: [
            if (state.isLoading && entries.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: AppLoadingIndicator()),
              )
            else if (entries.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      context.l10n.libraryArtistsEmpty,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  wideListInset(context),
                  8,
                  wideListInset(context),
                  0,
                ),
                sliver: SliverMainAxisGroup(
                  slivers: [
                    _LibrarySectionList(
                      sections: sections,
                      rowBuilder: (index, section) {
                        final entry = entries[index];
                        return _ArtistRow(
                          key: ValueKey('artist_${entry.key}'),
                          entry: entry,
                          first: index == section.start,
                          last: index == section.end - 1,
                          onTap: () => openArtist(entry.artist),
                        );
                      },
                    ),
                    if (state.value?.isLoadingMore ?? false)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: AppLoadingIndicator(size: 22)),
                        ),
                      ),
                  ],
                ),
              ),
            const NavBarSliverSpacer(),
          ],
        );
        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.depth == 0 &&
                notification.metrics.extentAfter < 800 &&
                (state.value?.hasMore ?? false)) {
              ref.read(libraryBrowseProvider(request).notifier).loadMore();
            }
            return false;
          },
          child: LibraryFastScroller(
            topPadding: MediaQuery.paddingOf(context).top + kToolbarHeight,
            bottomPadding: context.navBarBottomInset,
            // Artist totals are unknown; the thumb spans the loaded rows.
            labelAt: (fraction) => entries.isEmpty
                ? null
                : _sectionInitial(
                    entries[(fraction * (entries.length - 1)).round()].artist,
                  ),
            child: content,
          ),
        );
      },
    );
  }
}

class _LibrarySectionList extends StatelessWidget {
  const _LibrarySectionList({
    required this.sections,
    required this.rowBuilder,
    this.leadCount = 0,
    this.leadBuilder,
  });

  final List<_LibrarySection> sections;
  final Widget Function(int index, _LibrarySection section) rowBuilder;
  final int leadCount;
  final Widget Function(int index)? leadBuilder;

  @override
  Widget build(BuildContext context) {
    final starts = <int>[];
    final headers = <int>[];
    var count = leadCount;
    for (final section in sections) {
      starts.add(count);
      if (section.label.isNotEmpty) headers.add(count++);
      count += section.length;
    }
    return PinnedSectionSliverList(
      headerIndexes: headers,
      delegate: SliverChildBuilderDelegate((context, index) {
        if (index < leadCount) return leadBuilder!(index);
        var low = 0;
        var high = starts.length;
        while (low < high) {
          final middle = (low + high) ~/ 2;
          if (starts[middle] <= index) {
            low = middle + 1;
          } else {
            high = middle;
          }
        }
        final section = sections[low - 1];
        final hasHeader = section.label.isNotEmpty;
        final offset = index - starts[low - 1];
        if (hasHeader && offset == 0) {
          return _LibrarySectionHeader(label: section.label);
        }
        final row = offset - (hasHeader ? 1 : 0);
        return rowBuilder(section.start + row, section);
      }, childCount: count),
    );
  }
}

/// Pinned label above a section of library rows, aligned with their start.
class _LibrarySectionHeader extends StatelessWidget {
  const _LibrarySectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Opaque, so the pinned header covers the rows scrolling under it.
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
        child: Semantics(
          header: true,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtistRow extends StatelessWidget {
  const _ArtistRow({
    super.key,
    required this.entry,
    required this.first,
    required this.last,
    required this.onTap,
  });

  final LibraryBrowseEntry entry;
  final bool first;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cover = entry.cover;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, first ? 0 : 1, 16, last ? 4 : 1),
      child: Material(
        color: settingsGroupColor(context),
        borderRadius: connectedRowRadius(context, first: first, last: last),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                AppShapeClip(
                  kind: AppShapes.artist,
                  child: SizedBox.square(
                    dimension: 52,
                    child: cover == null || cover.isEmpty
                        ? ColoredBox(
                            color: colors.surfaceContainerHighest,
                            child: AppIcon(
                              Icons.person,
                              color: colors.onSurfaceVariant,
                            ),
                          )
                        : PlayerArtwork(
                            artUri: cover,
                            colorScheme: colors,
                            cacheWidth:
                                (52 * MediaQuery.devicePixelRatioOf(context))
                                    .ceil(),
                            iconSize: 24,
                          ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        context.l10n.tracksCount(entry.trackCount),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                AppIcon(Icons.chevron_right, color: colors.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
