import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/now_playing_indicator.dart';

/// A column of a [SliverTrackTable], in display order.
enum TrackTableColumn { number, title, artist, album, quality, duration }

/// The column a [SliverTrackTable] is sorted by, and its direction.
typedef TrackTableSort = ({TrackTableColumn column, bool ascending});

/// One song in a [SliverTrackTable]. Plain values drive sorting; the widgets
/// only decorate the row.
class TrackTableRow {
  const TrackTableRow({
    required this.id,
    required this.title,
    this.number,
    this.artist,
    this.album,
    this.quality,
    this.duration,
    this.leading,
    this.titleTrailing,
    this.trailing,
    this.playback,
  });

  /// Selection id, unique within the table.
  final String id;
  final String title;
  final int? number;
  final String? artist;
  final String? album;

  /// Format or quality label, such as "FLAC 24-bit/96kHz".
  final String? quality;
  final Duration? duration;

  /// Artwork at the start of the title cell.
  final Widget? leading;

  /// Badges after the title, such as Explicit or In Library.
  final Widget? titleTrailing;

  /// Row actions at the end of the row, such as the options button. They show
  /// on hover, selection, keyboard focus or while the row is current.
  final Widget? trailing;

  /// How this song follows the player, such as
  /// [mediaItemPlaybackUiProvider] for a Library file or
  /// [catalogTrackPlaybackUiProvider] for a catalog track. With one, a
  /// Material row marks itself while it is the current track.
  final ProviderListenable<MediaPlaybackUi>? playback;
}

/// Desktop song list: a header of sortable columns over one row per song.
///
/// Clicking a header sorts by that column, again reverses the order, and a
/// third click restores the original order. Rows follow the desktop list
/// gestures: a click runs [onActivate], Cmd/Ctrl-click toggles, Shift-click
/// selects a range in the shown order, and a right-click runs
/// [onContextMenu]. Wrap the screen in a [DesktopListScope]
/// for the keyboard.
///
/// Lists sorted by their source, such as the paged Library, pass [onSort]:
/// the table then shows [sort] and leaves [rows] in the given order, and only
/// [sortableColumns] take header clicks.
class SliverTrackTable extends StatefulWidget {
  const SliverTrackTable({
    super.key,
    required this.rows,
    required this.columns,
    required this.selectedIds,
    required this.onSelect,
    required this.onActivate,
    this.onContextMenu,
    this.sort,
    this.onSort,
    this.sortableColumns,
    this.albumLayout = false,
    this.albumArtist,
    this.uniformRowHeight = false,
  });

  /// The album page layout of Apple Music: no column headers, the number,
  /// title and duration with a "More" button, the artist under the title only
  /// when it differs from [albumArtist], separators from the title column,
  /// and a play glyph in place of the number under the pointer. [columns],
  /// sorting and the rows' trailing widgets do not apply.
  final bool albumLayout;

  /// The album's artist, which album rows leave out.
  final String? albumArtist;

  /// Uses the first column row as the extent for every row. Callers opt in
  /// only when artwork, badges and actions have uniform height. Album rows
  /// and text scaled above 200% retain variable layout.
  final bool uniformRowHeight;

  final List<TrackTableRow> rows;
  final List<TrackTableColumn> columns;
  final Set<String> selectedIds;

  /// A click of `kind` on the row `id`; `orderedIds` lists the rows in the
  /// order shown.
  final void Function(String id, DesktopClick kind, List<String> orderedIds)
  onSelect;

  /// Plays or opens the row with this id.
  final ValueChanged<String> onActivate;

  /// Opens the row's menu at a global position.
  final void Function(String id, Offset position)? onContextMenu;

  /// The sort shown when [onSort] is set; null is the source's own order.
  final TrackTableSort? sort;

  /// Asks the source to sort by the next state of a clicked header, null
  /// when a third click restores the source's own order.
  final ValueChanged<TrackTableSort?>? onSort;

  /// Columns whose headers sort; all of them when null.
  final Set<TrackTableColumn>? sortableColumns;

  @override
  State<SliverTrackTable> createState() => _SliverTrackTableState();
}

class _SliverTrackTableState extends State<SliverTrackTable> {
  TrackTableSort? _localSort;

  // The shown rows, kept while the rows and the applied sort stay the same,
  // so a selection change does not sort again.
  List<TrackTableRow>? _source;
  TrackTableSort? _sortedBy;
  List<TrackTableRow> _rows = const [];
  List<String> _orderedIds = const [];
  bool _hasTrailing = false;

  TrackTableSort? get _sort => widget.onSort == null ? _localSort : widget.sort;

  void _sortBy(TrackTableColumn column) {
    final current = _sort;
    final TrackTableSort? next;
    if (current?.column != column) {
      next = (column: column, ascending: true);
    } else if (current!.ascending) {
      next = (column: column, ascending: false);
    } else {
      next = null;
    }
    final onSort = widget.onSort;
    if (onSort != null) {
      onSort(next);
    } else {
      setState(() => _localSort = next);
    }
  }

  void _updateRows() {
    final rows = widget.rows;
    final sort = widget.onSort == null ? _localSort : null;
    if (identical(rows, _source) && sort == _sortedBy) return;
    _source = rows;
    _sortedBy = sort;
    _rows = sort == null
        ? rows
        : [for (final i in _sortOrder(rows, sort)) rows[i]];
    _orderedIds = [for (final row in _rows) row.id];
    _hasTrailing = _rows.any((row) => row.trailing != null);
  }

  @override
  Widget build(BuildContext context) {
    _updateRows();
    final rows = _rows;
    final sort = _sort;
    final orderedIds = _orderedIds;
    final hasTrailing = _hasTrailing;
    if (widget.albumLayout) {
      final albumArtist = widget.albumArtist?.trim().toLowerCase();
      return SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, index) {
          final row = rows[index];
          final artist = row.artist?.trim();
          return _AlbumRowView(
            key: ValueKey(row.id),
            row: row,
            artist:
                artist == null ||
                    artist.isEmpty ||
                    artist.toLowerCase() == albumArtist
                ? null
                : artist,
            last: index == rows.length - 1,
            selected: widget.selectedIds.contains(row.id),
            onTap: () => handleDesktopRowClick(
              row.id,
              select: (kind) => widget.onSelect(row.id, kind, orderedIds),
              activate: () => widget.onActivate(row.id),
            ),
            onPlay: () => widget.onActivate(row.id),
            onContextMenu: widget.onContextMenu == null
                ? null
                : (position) => widget.onContextMenu!(row.id, position),
          );
        },
      );
    }
    Widget rowList(IndexedWidgetBuilder builder) {
      if (widget.uniformRowHeight &&
          rows.isNotEmpty &&
          MediaQuery.textScalerOf(context).scale(14) <= 28) {
        return SliverPrototypeExtentList.builder(
          prototypeItem: TickerMode(
            enabled: false,
            child: ExcludeFocus(
              child: ExcludeSemantics(
                child: _TrackTableRowView(
                  row: rows.first,
                  columns: widget.columns,
                  hasTrailing: hasTrailing,
                  selected: false,
                  current: false,
                  playing: false,
                  onTap: () {},
                  onContextMenu: null,
                ),
              ),
            ),
          ),
          itemCount: rows.length,
          itemBuilder: builder,
        );
      }
      return SliverList.builder(itemCount: rows.length, itemBuilder: builder);
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _HeaderDelegate(
            height: TrackTableLayout.headerHeightFor(context),
            child: _TrackTableHeader(
              columns: widget.columns,
              sortColumn: sort?.column,
              ascending: sort?.ascending ?? true,
              sortableColumns: widget.sortableColumns,
              hasTrailing: hasTrailing,
              onSort: _sortBy,
            ),
          ),
        ),
        rowList((context, index) {
          final row = rows[index];
          Widget rowView({
            Key? key,
            bool current = false,
            bool playing = false,
          }) => _TrackTableRowView(
            key: key,
            row: row,
            columns: widget.columns,
            hasTrailing: hasTrailing,
            selected: widget.selectedIds.contains(row.id),
            current: current,
            playing: playing,
            onTap: () => handleDesktopRowClick(
              row.id,
              select: (kind) => widget.onSelect(row.id, kind, orderedIds),
              activate: () => widget.onActivate(row.id),
            ),
            onContextMenu: widget.onContextMenu == null
                ? null
                : (position) => widget.onContextMenu!(row.id, position),
          );
          final rowPlayback = row.playback;
          if (rowPlayback == null || context.isMornye) {
            return rowView(key: ValueKey(row.id));
          }
          // Each row follows only its own track, so a track change
          // rebuilds the two rows involved rather than the whole table.
          return Consumer(
            key: ValueKey(row.id),
            builder: (context, ref, _) {
              final playback = ref.watch(rowPlayback);
              return rowView(
                current: playback.isCurrent,
                playing: playback.isPlaying,
              );
            },
          );
        }),
      ],
    );
  }
}

/// Orders two rows by [column], ascending, with missing values last.
int compareTrackTableRows(
  TrackTableRow a,
  TrackTableRow b,
  TrackTableColumn column,
) => _compareKeys(_sortKey(a, column), _sortKey(b, column));

/// The order of [rows] under [sort], as indexes into [rows]. Each key is
/// computed once rather than in every comparison.
List<int> _sortOrder(List<TrackTableRow> rows, TrackTableSort sort) {
  final (:column, :ascending) = sort;
  final keys = [for (final row in rows) _sortKey(row, column)];
  return List.generate(rows.length, (i) => i)..sort((a, b) {
    final order = _compareKeys(keys[a], keys[b]);
    // Equal keys keep their original order in both directions.
    if (order == 0) return a.compareTo(b);
    return ascending ? order : -order;
  });
}

/// The key [row] sorts by in [column]; null for a missing value.
Comparable<Object?>? _sortKey(TrackTableRow row, TrackTableColumn column) {
  String? text(String? value) =>
      value == null || value.isEmpty ? null : value.toLowerCase();

  return switch (column) {
    TrackTableColumn.number => row.number,
    TrackTableColumn.title => text(row.title),
    TrackTableColumn.artist => text(row.artist),
    TrackTableColumn.album => text(row.album),
    TrackTableColumn.duration => row.duration?.inMilliseconds,
    TrackTableColumn.quality => switch (row.quality) {
      null || '' => null,
      final label => _QualityKey(label),
    },
  };
}

int _compareKeys(Comparable<Object?>? a, Comparable<Object?>? b) {
  if (a == null) return b == null ? 0 : 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

/// Compares quality labels by their numbers (bit depth, then sample rate or
/// bitrate), so "24-bit/96kHz" sorts above "16-bit/44.1kHz".
class _QualityKey implements Comparable<_QualityKey> {
  _QualityKey(String label)
    : numbers = [
        for (final m in _number.allMatches(label)) double.parse(m[0]!),
      ],
      text = label.toLowerCase();

  static final _number = RegExp(r'\d+(?:\.\d+)?');

  final List<double> numbers;
  final String text;

  @override
  int compareTo(_QualityKey other) {
    final y = other.numbers;
    for (var i = 0; i < numbers.length && i < y.length; i++) {
      final order = numbers[i].compareTo(y[i]);
      if (order != 0) return order;
    }
    final order = numbers.length.compareTo(y.length);
    return order != 0 ? order : text.compareTo(other.text);
  }
}

/// How fast a Mornye row's hover actions appear, as in Music.
const _mornyeRowFade = Duration(milliseconds: 100);

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
      : '$minutes:$seconds';
}

/// Shared geometry for loaded tables and their loading placeholders.
class TrackTableLayout {
  const TrackTableLayout._();

  static const double number = 44;
  static const double quality = 132;
  static const double duration = 64;
  static const double trailing = 52;
  static const double gap = 12;
  static const double albumRowHeight = 46;
  static const double albumNumber = 32;
  static const double albumTitleGap = 14;

  // Pointer rows: Music's 40pt, and the M3 compact list density for Material
  // instead of the 48dp touch row.
  static double rowMinHeightFor(BuildContext context) =>
      context.isMornye ? 40 : 44;

  static double headerHeightFor(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(20) + 16;

  static int flex(TrackTableColumn column) => switch (column) {
    TrackTableColumn.title => 5,
    TrackTableColumn.artist || TrackTableColumn.album => 3,
    _ => 0,
  };

  static double? width(TrackTableColumn column) => switch (column) {
    TrackTableColumn.number => number,
    TrackTableColumn.quality => quality,
    TrackTableColumn.duration => duration,
    _ => null,
  };

  static bool alignEnd(TrackTableColumn column) =>
      column == TrackTableColumn.number || column == TrackTableColumn.duration;

  static List<Widget> layout({
    required List<TrackTableColumn> columns,
    required Widget Function(TrackTableColumn column) cell,
    required bool hasTrailing,
    Widget? trailing,
  }) => [
    for (final column in columns) ...[
      if (width(column) case final width?)
        SizedBox(width: width, child: cell(column))
      else
        Expanded(flex: flex(column), child: cell(column)),
      const SizedBox(width: gap),
    ],
    if (hasTrailing)
      SizedBox(width: TrackTableLayout.trailing, child: trailing)
    else
      const SizedBox(width: gap),
  ];
}

class _HeaderDelegate extends SliverPersistentHeaderDelegate {
  const _HeaderDelegate({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => child;

  @override
  bool shouldRebuild(_HeaderDelegate oldDelegate) =>
      height != oldDelegate.height || child != oldDelegate.child;
}

class _TrackTableHeader extends StatelessWidget {
  const _TrackTableHeader({
    required this.columns,
    required this.sortColumn,
    required this.ascending,
    required this.sortableColumns,
    required this.hasTrailing,
    required this.onSort,
  });

  final List<TrackTableColumn> columns;
  final TrackTableColumn? sortColumn;
  final bool ascending;
  final Set<TrackTableColumn>? sortableColumns;
  final bool hasTrailing;
  final ValueChanged<TrackTableColumn> onSort;

  String _label(BuildContext context, TrackTableColumn column) {
    final l10n = context.l10n;
    return switch (column) {
      TrackTableColumn.number => l10n.trackTrackNumber,
      TrackTableColumn.title => l10n.editMetadataFieldTitle,
      TrackTableColumn.artist => l10n.trackArtist,
      TrackTableColumn.album => l10n.trackAlbum,
      TrackTableColumn.quality => l10n.audioInfoQuality,
      TrackTableColumn.duration => l10n.trackDuration,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final style = theme.textTheme.labelMedium?.copyWith(
      color: colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    Widget cell(TrackTableColumn column) {
      final label = _label(context, column);
      final sorted = sortColumn == column;
      final end = TrackTableLayout.alignEnd(column);
      final text = Text(
        column == TrackTableColumn.number ? '#' : label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sorted ? style?.copyWith(color: colorScheme.onSurface) : style,
      );
      final arrow = AppIcon.adaptive(
        ascending ? Icons.arrow_upward : Icons.arrow_downward,
        size: 14,
        color: colorScheme.onSurface,
      );
      final sortable = sortableColumns?.contains(column) ?? true;
      return Semantics(
        button: sortable,
        label: sorted
            ? (ascending
                  ? context.l10n.desktopTableSortedAscending(label)
                  : context.l10n.desktopTableSortedDescending(label))
            : label,
        onTap: sortable ? () => onSort(column) : null,
        excludeSemantics: true,
        child: InkWell(
          onTap: sortable ? () => onSort(column) : null,
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: TrackTableLayout.headerHeightFor(context),
            child: Row(
              mainAxisAlignment: end
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                if (sorted && end) ...[arrow, const SizedBox(width: 2)],
                Flexible(child: text),
                if (sorted && !end) ...[const SizedBox(width: 2), arrow],
              ],
            ),
          ),
        ),
      );
    }

    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.tokens.gapSm),
          child: Row(
            children: TrackTableLayout.layout(
              columns: columns,
              cell: cell,
              hasTrailing: hasTrailing,
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackTableRowView extends StatefulWidget {
  const _TrackTableRowView({
    super.key,
    required this.row,
    required this.columns,
    required this.hasTrailing,
    required this.selected,
    required this.onTap,
    required this.onContextMenu,
    this.current = false,
    this.playing = false,
  });

  final TrackTableRow row;
  final List<TrackTableColumn> columns;
  final bool hasTrailing;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onContextMenu;

  /// The row is the player's current track. Only Material rows pass it.
  final bool current;

  /// The current track is playing, so its equalizer glyph moves.
  final bool playing;

  @override
  State<_TrackTableRowView> createState() => _TrackTableRowViewState();
}

class _TrackTableRowViewState extends State<_TrackTableRowView> {
  // Hover only fades the row actions, so it rebuilds only them.
  final _hovered = ValueNotifier(false);
  bool _trailingFocused = false;

  @override
  void dispose() {
    _hovered.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final columns = widget.columns;
    final hasTrailing = widget.hasTrailing;
    final selected = widget.selected;
    final current = widget.current;
    final onTap = widget.onTap;
    final onContextMenu = widget.onContextMenu;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tokens = context.tokens;
    final material = !context.isMornye;
    // Material text takes the content color of the row's fill. A selected
    // row keeps the selection fill; being current then shows only through
    // the glyph and the title weight.
    final Color? content = !material
        ? null
        : selected
        ? colorScheme.onSecondaryContainer
        : current
        ? colorScheme.onPrimaryContainer
        : null;
    // Row actions appear for the row under the pointer, the selection, the
    // current track, or keyboard focus, so a long list does not repeat them
    // on every row.
    final trailing = row.trailing == null
        ? null
        : Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (focused) =>
                setState(() => _trailingFocused = focused),
            child: ValueListenableBuilder(
              valueListenable: _hovered,
              builder: (context, hovered, child) => AnimatedOpacity(
                opacity: hovered || selected || current || _trailingFocused
                    ? 1
                    : 0,
                duration: material ? tokens.motionFast : _mornyeRowFade,
                curve: material ? Curves.linear : Curves.easeIn,
                child: child,
              ),
              child: row.trailing,
            ),
          );
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: content ?? colorScheme.onSurfaceVariant,
    );
    final indicator = NowPlayingIndicator(
      playing: widget.playing,
      color: content,
    );
    // The glyph replaces the track number. Tables without a number column
    // lay it over the artwork, so no column shifts.
    final markNumber = current && columns.contains(TrackTableColumn.number);
    final markTitle = current && !markNumber;
    var leading = row.leading;
    if (markTitle && leading != null) {
      leading = Stack(
        alignment: Alignment.center,
        children: [
          leading,
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                // A tint of the row's fill, so the glyph reads on any cover.
                color:
                    (selected
                            ? colorScheme.secondaryContainer
                            : colorScheme.primaryContainer)
                        .withValues(alpha: 0.75),
                borderRadius: tokens.borderRadiusThumb,
              ),
            ),
          ),
          indicator,
        ],
      );
    }
    Widget plain(String? value, {bool end = false}) => Text(
      value ?? '',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: end ? TextAlign.end : TextAlign.start,
      style: secondary?.copyWith(
        fontFeatures: end ? const [FontFeature.tabularFigures()] : null,
      ),
    );

    Widget cell(TrackTableColumn column) => switch (column) {
      TrackTableColumn.number =>
        markNumber
            ? Align(alignment: AlignmentDirectional.centerEnd, child: indicator)
            : plain(row.number?.toString(), end: true),
      TrackTableColumn.title => Row(
        children: [
          if (leading != null) ...[
            leading,
            const SizedBox(width: 10),
          ] else if (markTitle) ...[
            indicator,
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Text(
              row.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                color: content,
              ),
            ),
          ),
          if (row.titleTrailing != null) ...[
            const SizedBox(width: 6),
            row.titleTrailing!,
          ],
        ],
      ),
      TrackTableColumn.artist => plain(row.artist),
      TrackTableColumn.album => plain(row.album),
      TrackTableColumn.quality => plain(row.quality),
      TrackTableColumn.duration => plain(
        row.duration == null ? null : _formatDuration(row.duration!),
        end: true,
      ),
    };

    final selectedFill = context.isMornye
        ? colorScheme.primary.withValues(alpha: 0.16)
        : colorScheme.secondaryContainer;
    final ink = InkWell(
      onTap: onTap,
      onHover: (hovered) => _hovered.value = hovered,
      // The M3 hover state layer: 8% of the row's content color.
      hoverColor: material
          ? (content ?? colorScheme.onSurface).withValues(alpha: 0.08)
          : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: TrackTableLayout.rowMinHeightFor(context),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.gapXs),
          child: Row(
            children: TrackTableLayout.layout(
              columns: columns,
              cell: cell,
              hasTrailing: hasTrailing,
              trailing: trailing,
            ),
          ),
        ),
      ),
    );
    Widget surface(Color? color, Widget? child) => Material(
      color: color,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
    final Widget body;
    if (material) {
      // The row keeps its shape; the fill fades between roles. The resting
      // fill is the page surface at zero alpha, so a fade never passes
      // through black.
      final motion = AppMotion.effects(
        context,
        const AppMotionSpec(Duration.zero, Curves.linear),
      );
      body = TweenAnimationBuilder<Color?>(
        tween: ColorTween(
          end: selected
              ? selectedFill
              : current
              ? colorScheme.primaryContainer
              : colorScheme.surface.withValues(alpha: 0),
        ),
        duration: motion.duration,
        curve: motion.curve,
        builder: (context, color, child) => surface(color, child),
        child: ink,
      );
    } else {
      body = surface(selected ? selectedFill : Colors.transparent, ink);
    }
    return Semantics(
      selected: selected,
      label: [row.title, ?row.artist].join(', '),
      child: DesktopContextMenuRegion(
        onContextMenu: onContextMenu,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.gapXs, vertical: 1),
          child: body,
        ),
      ),
    );
  }
}

/// One song of a [SliverTrackTable.albumLayout] list.
class _AlbumRowView extends StatefulWidget {
  const _AlbumRowView({
    super.key,
    required this.row,
    required this.artist,
    required this.last,
    required this.selected,
    required this.onTap,
    required this.onPlay,
    required this.onContextMenu,
  });

  final TrackTableRow row;

  /// Shown under the title; null when it is the album's artist.
  final String? artist;
  final bool last;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final ValueChanged<Offset>? onContextMenu;

  @override
  State<_AlbumRowView> createState() => _AlbumRowViewState();
}

class _AlbumRowViewState extends State<_AlbumRowView> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = context.tokens;
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final active = _hovered || widget.selected || _focused;
    final l10n = MaterialLocalizations.of(context);
    final onContextMenu = widget.onContextMenu;
    final number = SizedBox(
      width: TrackTableLayout.albumNumber,
      child: _hovered
          ? IconButton(
              tooltip: context.l10n.tooltipPlay,
              onPressed: widget.onPlay,
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                minimumSize: const Size.square(28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: AppIcon.adaptive(
                Icons.play_arrow_rounded,
                size: 16,
                color: scheme.primary,
              ),
            )
          : Text(
              row.number?.toString() ?? '',
              textAlign: TextAlign.end,
              style: secondary,
            ),
    );
    final more = onContextMenu == null
        ? const SizedBox(width: 32)
        : Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (focused) => setState(() => _focused = focused),
            child: AnimatedOpacity(
              opacity: active ? 1 : 0,
              duration: context.isMornye ? _mornyeRowFade : tokens.motionFast,
              curve: context.isMornye ? Curves.easeIn : Curves.linear,
              child: Builder(
                builder: (buttonContext) => IconButton(
                  tooltip: l10n.showMenuTooltip,
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: AppIcon.adaptive(
                    Icons.more_horiz,
                    size: 20,
                    color: scheme.primary,
                  ),
                  onPressed: () => onContextMenu(
                    contextMenuPositionBelow(buttonContext) ?? Offset.zero,
                  ),
                ),
              ),
            ),
          );
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                row.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (row.titleTrailing != null) ...[
              const SizedBox(width: 6),
              row.titleTrailing!,
            ],
          ],
        ),
        if (widget.artist != null)
          Text(
            widget.artist!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
    final selectedFill = context.isMornye
        ? scheme.primary.withValues(alpha: 0.16)
        : scheme.secondaryContainer;
    return Semantics(
      selected: widget.selected,
      label: [row.title, ?widget.artist].join(', '),
      child: DesktopContextMenuRegion(
        onContextMenu: onContextMenu,
        child: Material(
          color: widget.selected || _hovered
              ? (widget.selected
                    ? selectedFill
                    : scheme.onSurface.withValues(alpha: 0.05))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (hovered) => setState(() => _hovered = hovered),
            hoverColor: Colors.transparent,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: TrackTableLayout.albumRowHeight,
              ),
              child: Padding(
                padding: EdgeInsetsDirectional.only(start: tokens.gapXs),
                child: Row(
                  children: [
                    number,
                    const SizedBox(width: TrackTableLayout.albumTitleGap),
                    // The separator starts at the title, as in Apple Music.
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: widget.last
                              ? null
                              : Border(
                                  bottom: BorderSide(
                                    color: scheme.outlineVariant.withValues(
                                      alpha: 0.6,
                                    ),
                                    width: 0.5,
                                  ),
                                ),
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: TrackTableLayout.albumRowHeight,
                          ),
                          child: Row(
                            children: [
                              Expanded(child: title),
                              const SizedBox(width: 12),
                              Text(
                                row.duration == null
                                    ? ''
                                    : _formatDuration(row.duration!),
                                style: secondary,
                              ),
                              const SizedBox(width: 8),
                              more,
                              SizedBox(width: tokens.gapXs),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
