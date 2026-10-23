import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/downloaded_album_screen.dart';
import 'package:mornye/screens/listening_rewind_screen.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/services/album_completeness.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_refresh_indicator.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/hover_play_button.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/local_library_artwork_builder.dart';
import 'package:mornye/widgets/library_search_results.dart';
import 'package:mornye/widgets/sliver_layout_info_builder.dart';

enum MornyeLibraryPage { overview, albums, artists }

class MornyeLibraryScreen extends ConsumerStatefulWidget {
  const MornyeLibraryScreen({
    super.key,
    required this.onOpenSection,
    this.page = MornyeLibraryPage.overview,
    this.artist,
  });

  final ValueChanged<String> onOpenSection;
  final MornyeLibraryPage page;
  final String? artist;

  @override
  ConsumerState<MornyeLibraryScreen> createState() =>
      _MornyeLibraryScreenState();
}

class _MornyeLibraryScreenState extends ConsumerState<MornyeLibraryScreen> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  Timer? _debounce;
  bool _showSearch = false;
  String? _completeness;
  String _query = '';
  late String _sort;
  List<LibraryBrowseEntry> _rows = const [];
  bool _loading = true;

  bool get _overview => widget.page == MornyeLibraryPage.overview;
  bool get _artists => widget.page == MornyeLibraryPage.artists;
  LibraryBrowseRequest get _request => (
    artists: _artists,
    artist: widget.artist,
    search: _query,
    sort: _sort,
    limit: 40,
    completeness: _completeness,
  );

  @override
  void initState() {
    super.initState();
    _sort = _overview ? 'latest' : 'a-z';
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 500 &&
          !_loading &&
          !(_overview && _query.isNotEmpty)) {
        unawaited(
          ref.read(libraryBrowseProvider(_request).notifier).loadMore(),
        );
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _searchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _query == value.trim()) return;
      setState(() {
        _query = value.trim();
        _rows = const [];
      });
    });
  }

  void _openPage(MornyeLibraryPage page, {String? artist}) {
    pushPage<void>(
      context,
      (_) => Scaffold(
        body: MornyeLibraryScreen(
          page: page,
          artist: artist,
          onOpenSection: widget.onOpenSection,
        ),
      ),
    );
  }

  Future<void> _openAlbum(LibraryBrowseEntry entry) async {
    if (entry.source != 'local') {
      await pushPage<void>(
        context,
        (_) => DownloadedAlbumScreen(
          albumName: entry.name,
          artistName: entry.artist,
          coverUrl: entry.cover,
        ),
      );
      return;
    }
    Future<List<LocalLibraryItem>> loadTracks() => _loadLocalAlbum(entry);

    await pushPage<void>(
      context,
      (_) => LocalAlbumScreen(
        albumName: entry.name,
        artistName: entry.artist,
        coverPath: entry.cover,
        loadTracks: loadTracks,
      ),
    );
  }

  Future<List<LocalLibraryItem>> _loadLocalAlbum(
    LibraryBrowseEntry entry,
  ) async {
    final rows = await LibraryDatabase.instance.getQueueLocalAlbumTracksByKey(
      entry.key,
    );
    return rows.map(LocalLibraryItem.fromJson).toList(growable: false);
  }

  /// Desktop shows the choices as a checked menu below [buttonContext];
  /// returns null there and on phones, where the caller opens its sheet.
  Future<String?>? _chooseFromMenu(
    BuildContext buttonContext,
    List<(String, String, IconData)> options,
    String current,
  ) {
    final position = isDesktopPlatform
        ? contextMenuPositionBelow(buttonContext)
        : null;
    if (position == null) return null;
    final chosen = Completer<String?>();
    showContextMenu(
      buttonContext,
      position: position,
      groups: [
        [
          for (final option in options)
            ContextMenuAction(
              icon: option.$3,
              label: option.$2,
              checked: option.$1 == current,
              onSelected: () => chosen.complete(option.$1),
            ),
        ],
      ],
    ).whenComplete(() {
      if (!chosen.isCompleted) chosen.complete(null);
    });
    return chosen.future;
  }

  Future<void> _chooseSort(BuildContext buttonContext) async {
    final options = [
      ('a-z', context.l10n.searchSortTitleAZ, Icons.sort_by_alpha),
      ('latest', context.l10n.libraryRecentlyAdded, Icons.schedule),
      if (!_artists) ...[
        (
          'size-desc',
          context.l10n.libraryFilterSortSizeLargest,
          Icons.storage_outlined,
        ),
        (
          'size-asc',
          context.l10n.libraryFilterSortSizeSmallest,
          Icons.storage_outlined,
        ),
      ],
    ];
    final selected =
        await (_chooseFromMenu(buttonContext, options, _sort) ??
            showAppBottomSheet<String>(
              context: context,
              builder: (context) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final option in options)
                    ListTile(
                      title: Text(option.$2),
                      selected: _sort == option.$1,
                      selectedColor: Theme.of(context).colorScheme.onSurface,
                      trailing: _sort == option.$1
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.pop(context, option.$1),
                    ),
                ],
              ),
            ));
    if (!mounted || selected == null || selected == _sort) return;
    setState(() {
      _sort = selected;
      _rows = const [];
    });
    _scroll.jumpTo(0);
  }

  Future<void> _chooseCompleteness(BuildContext buttonContext) async {
    final options = [
      ('', context.l10n.libraryFilterAll, Icons.album_outlined),
      (
        incompleteAlbumFilter,
        context.l10n.libraryFilterIncompleteAlbums,
        Icons.rule,
      ),
      (
        unknownAlbumCompletenessFilter,
        context.l10n.libraryAlbumCompletenessUnknown,
        Icons.help_outline,
      ),
    ];
    final selected =
        await (_chooseFromMenu(buttonContext, options, _completeness ?? '') ??
            showAppBottomSheet<String>(
              context: context,
              builder: (context) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final option in options)
                    ListTile(
                      title: Text(option.$2),
                      selected: (_completeness ?? '') == option.$1,
                      selectedColor: Theme.of(context).colorScheme.onSurface,
                      trailing: (_completeness ?? '') == option.$1
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.pop(context, option.$1),
                    ),
                ],
              ),
            ));
    if (!mounted || selected == null || selected == (_completeness ?? '')) {
      return;
    }
    setState(() {
      _completeness = selected.isEmpty ? null : selected;
      _rows = const [];
    });
    _scroll.jumpTo(0);
  }

  Widget _buildCompletenessBadge(AlbumCompleteness completeness) {
    final colors = Theme.of(context).colorScheme;
    final expected = completeness.expected;
    final label = completeness.status == 'unknown'
        ? context.l10n.libraryAlbumCompletenessUnknown
        : expected == null
        ? context.l10n.libraryFilterIncompleteAlbums
        : context.l10n.libraryAlbumMissingTracks(
            completeness.present,
            expected,
            expected - completeness.present,
          );
    return Tooltip(
      message: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          completeness.badge,
          style: TextStyle(
            color: colors.onSurface,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final searchingLibrary = _overview && _query.isNotEmpty;
    final listInset = wideListInset(context);
    final result = searchingLibrary
        ? const AsyncData(LibraryBrowseState([], hasMore: false))
        : ref.watch(libraryBrowseProvider(_request));
    _loading = result.isLoading || (result.value?.isLoadingMore ?? false);
    if (result.hasValue) _rows = result.requireValue.entries;
    final title =
        widget.artist ??
        (_overview
            ? context.l10n.navLibrary
            : _artists
            ? context.l10n.searchArtists
            : context.l10n.searchAlbums);
    final actions = <Widget>[
      IconButton(
        tooltip: context.l10n.librarySearchHint,
        icon: const Icon(Icons.search),
        onPressed: () => setState(() => _showSearch = !_showSearch),
      ),
      if (_overview)
        Consumer(
          builder: (context, ref, _) {
            final count = ref.watch(
              downloadQueueLookupProvider.select(
                (s) => s.notCompletedItemIds.length,
              ),
            );
            return TextButton.icon(
              onPressed: () => widget.onOpenSection('downloads'),
              icon: Badge(
                isLabelVisible: count > 0,
                label: Text('$count'),
                child: const Icon(Icons.downloading_outlined),
              ),
              label: Text(context.l10n.libraryDownloads),
            );
          },
        )
      else if (!_artists) ...[
        Builder(
          builder: (buttonContext) => IconButton(
            tooltip: context.l10n.searchSortTitle,
            icon: const Icon(Icons.sort),
            onPressed: () => _chooseSort(buttonContext),
          ),
        ),
        Builder(
          builder: (buttonContext) => IconButton(
            tooltip: context.l10n.libraryFilterTitle,
            icon: Badge(
              isLabelVisible: _completeness != null,
              child: const Icon(Icons.filter_list),
            ),
            onPressed: () => _chooseCompleteness(buttonContext),
          ),
        ),
      ],
    ];
    return AppRefreshIndicator(
      onRefresh: () async {
        if (searchingLibrary) return;
        ref.invalidate(libraryBrowseProvider(_request));
        await ref.read(libraryBrowseProvider(_request).future);
      },
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (_overview)
            AppSliverHeader.tabRoot(
              title: title,
              actions: actions,
              alignToContent: true,
            )
          else
            AppSliverHeader.page(title: title, actions: actions),
          if (_showSearch)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  24 + listInset,
                  8,
                  24 + listInset,
                  16,
                ),
                child: AppSearchField(
                  controller: _search,
                  autofocus: true,
                  hintText: context.l10n.librarySearchHint,
                  clearTooltip: context.l10n.dialogClear,
                  samplesBackdrop: false,
                  onChanged: _searchChanged,
                  onClear: () {
                    _search.clear();
                    _searchChanged('');
                  },
                ),
              ),
            ),
          if (searchingLibrary)
            LibrarySearchResults(
              query: _query,
              onOpenArtist: (artist) =>
                  _openPage(MornyeLibraryPage.albums, artist: artist),
            ),
          if (!searchingLibrary) ...[
            if (_overview && _query.isEmpty)
              SliverPadding(
                // Rows center at the reading width on tablets.
                padding: EdgeInsets.fromLTRB(
                  24 + listInset,
                  0,
                  24 + listInset,
                  20,
                ),
                sliver: SliverList.list(
                  children: [
                    for (final category in [
                      (
                        Icons.queue_music,
                        context.l10n.searchPlaylists,
                        () => widget.onOpenSection('playlists'),
                      ),
                      (
                        Icons.mic_none,
                        context.l10n.searchArtists,
                        () => _openPage(MornyeLibraryPage.artists),
                      ),
                      (
                        Icons.album_outlined,
                        context.l10n.searchAlbums,
                        () => _openPage(MornyeLibraryPage.albums),
                      ),
                      (
                        Icons.music_note_outlined,
                        context.l10n.searchSongs,
                        () => widget.onOpenSection('all'),
                      ),
                    ]) ...[
                      // The desktop shell paints its background without a
                      // Material, which would hide the row's ink.
                      Material(
                        type: MaterialType.transparency,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          minVerticalPadding: 12,
                          leading: Icon(
                            category.$1,
                            color: colors.primary,
                            size: 28,
                          ),
                          title: Text(
                            category.$2,
                            style: const TextStyle(fontSize: 22),
                          ),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: colors.onSurfaceVariant,
                          ),
                          onTap: category.$3,
                        ),
                      ),
                      const Divider(height: 1, indent: 48),
                    ],
                  ],
                ),
              ),
            // The seasonal Rewind, beside the listening history it replays.
            if (_overview &&
                _query.isEmpty &&
                ref.watch(
                  settingsProvider.select((s) => s.listeningStatisticsEnabled),
                ))
              SliverToBoxAdapter(
                child: ListeningRewindBanner(
                  margin: EdgeInsets.fromLTRB(
                    24 + listInset,
                    0,
                    24 + listInset,
                    16,
                  ),
                ),
              ),
            if (_overview)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    24 + listInset,
                    8,
                    24 + listInset,
                    16,
                  ),
                  child: Semantics(
                    header: true,
                    child: Text(
                      _query.isEmpty
                          ? context.l10n.libraryRecentlyAdded
                          : context.l10n.searchAlbums,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            if (_rows.isNotEmpty)
              if (_artists)
                SliverList.builder(
                  itemCount: _rows.length,
                  itemBuilder: (context, index) {
                    final entry = _rows[index];
                    void open() => _openPage(
                      MornyeLibraryPage.albums,
                      artist: entry.artist,
                    );
                    return Column(
                      children: [
                        DesktopContextMenuRegion(
                          onContextMenu: (position) => showContextMenu(
                            context,
                            position: position,
                            groups: [
                              [
                                ContextMenuAction(
                                  icon: Icons.open_in_new,
                                  label: context.l10n.desktopMenuOpen,
                                  onSelected: open,
                                ),
                              ],
                            ],
                          ),
                          child: ListTile(
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 24 + listInset,
                              vertical: 8,
                            ),
                            leading: ClipOval(
                              child: SizedBox.square(
                                dimension: 56,
                                child: _LibraryBrowseArtwork(entry: entry),
                              ),
                            ),
                            title: Text(entry.artist),
                            subtitle: Text(
                              context.l10n.queueTrackCount(entry.trackCount),
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: open,
                          ),
                        ),
                        Divider(
                          height: 1,
                          indent: 96 + listInset,
                          endIndent: 24 + listInset,
                        ),
                      ],
                    );
                  },
                )
              else
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: 24 + listInset),
                  sliver: SliverLayoutInfoBuilder(
                    select: (constraints) => constraints.crossAxisExtent,
                    builder: (context, crossAxisExtent) {
                      // ~160dp covers: two on phones, more columns rather
                      // than giant covers on tablets.
                      final columns = (crossAxisExtent / 160).floor().clamp(
                        2,
                        8,
                      );
                      final width =
                          (crossAxisExtent - 20 * (columns - 1)) / columns;
                      final textHeight =
                          MediaQuery.textScalerOf(context).scale(16) * 3.2 + 24;
                      return SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 20,
                          mainAxisSpacing: 16,
                          mainAxisExtent: width + textHeight,
                        ),
                        itemCount: _rows.length,
                        itemBuilder: (context, index) {
                          final entry = _rows[index];
                          return DesktopContextMenuRegion(
                            onContextMenu: (position) =>
                                _showAlbumMenu(entry, position),
                            child: _buildAlbumTile(entry, colors),
                          );
                        },
                      );
                    },
                  ),
                ),
            if (result.hasError || result.value?.loadMoreError != null)
              SliverToBoxAdapter(
                child: Center(
                  child: TextButton.icon(
                    onPressed: () =>
                        ref.invalidate(libraryBrowseProvider(_request)),
                    icon: const Icon(Icons.refresh),
                    label: Text(context.l10n.dialogRetry),
                  ),
                ),
              )
            else if (_loading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator.adaptive()),
                ),
              )
            else if (_rows.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text(context.l10n.libraryEmptyCollection)),
              ),
          ],
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }

  Future<void> _playAlbum(LibraryBrowseEntry entry) async {
    try {
      if (entry.source == 'local') {
        await playLocalAlbum(ref, await _loadLocalAlbum(entry));
      } else {
        await playDownloadedAlbum(
          ref,
          albumName: entry.name,
          artistName: entry.artist,
        );
      }
    } catch (e) {
      if (mounted) showCannotOpenFileSnackBar(context, e);
    }
  }

  void _showAlbumMenu(LibraryBrowseEntry entry, Offset position) {
    showContextMenu(
      context,
      position: position,
      groups: [
        [
          ContextMenuAction(
            icon: Icons.open_in_new,
            label: context.l10n.desktopMenuOpen,
            onSelected: () => _openAlbum(entry),
          ),
          ContextMenuAction(
            icon: Icons.play_arrow,
            label: context.l10n.tooltipPlay,
            onSelected: () => _playAlbum(entry),
          ),
        ],
      ],
    );
  }

  Widget _buildAlbumTile(LibraryBrowseEntry entry, ColorScheme colors) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openAlbum(entry),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _LibraryBrowseArtwork(entry: entry),
                  ),
                  if (entry.completeness != null)
                    PositionedDirectional(
                      end: 8,
                      bottom: 8,
                      child: _buildCompletenessBadge(entry.completeness!),
                    ),
                  DesktopHoverPlayButton(
                    tooltip: context.l10n.tooltipPlay,
                    onPlay: () => _playAlbum(entry),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16),
            ),
            Text(
              entry.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryBrowseArtwork extends StatefulWidget {
  const _LibraryBrowseArtwork({required this.entry});
  final LibraryBrowseEntry entry;

  @override
  State<_LibraryBrowseArtwork> createState() => _LibraryBrowseArtworkState();
}

class _LibraryBrowseArtworkState extends State<_LibraryBrowseArtwork> {
  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    Widget fallback(BuildContext context) => ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.album_outlined,
          size: 40,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
    if (entry.source == 'local') {
      return LocalLibraryArtworkBuilder(
        coverPath: entry.cover,
        filePath: entry.samplePath,
        builder: (context, cover) => cover == null
            ? fallback(context)
            : LocalOrNetworkCoverImage(url: cover, placeholder: fallback),
      );
    }
    final embedded = entry.cover?.isNotEmpty == true
        ? null
        : DownloadedEmbeddedCoverResolver.resolve(
            entry.samplePath,
            onChanged: () {
              if (mounted) setState(() {});
            },
          );
    final cover = entry.cover?.isNotEmpty == true ? entry.cover! : embedded;
    return cover == null
        ? fallback(context)
        : LocalOrNetworkCoverImage(url: cover, placeholder: fallback);
  }
}
