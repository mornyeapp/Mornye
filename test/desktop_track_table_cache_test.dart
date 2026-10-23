import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/track_list_table.dart';
import 'package:mornye/widgets/desktop/track_table.dart';

import 'support/fixed_settings.dart';

Widget _app(Widget child, {bool mornye = false}) => ProviderScope(
  overrides: [
    settingsProvider.overrideWith(
      () =>
          FixedSettingsNotifier(const AppSettings(localLibraryEnabled: false)),
    ),
  ],
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

/// The comparator the table sorted with before sort keys were precomputed.
int _legacyCompare(TrackTableRow a, TrackTableRow b, TrackTableColumn column) {
  int text(String? x, String? y) {
    if (x == null || x.isEmpty) return y == null || y.isEmpty ? 0 : 1;
    if (y == null || y.isEmpty) return -1;
    return x.toLowerCase().compareTo(y.toLowerCase());
  }

  int number(num? x, num? y) {
    if (x == null) return y == null ? 0 : 1;
    if (y == null) return -1;
    return x.compareTo(y);
  }

  int quality(String? a, String? b) {
    if (a == null || a.isEmpty) return b == null || b.isEmpty ? 0 : 1;
    if (b == null || b.isEmpty) return -1;
    final pattern = RegExp(r'\d+(?:\.\d+)?');
    final x = [for (final m in pattern.allMatches(a)) double.parse(m[0]!)];
    final y = [for (final m in pattern.allMatches(b)) double.parse(m[0]!)];
    for (var i = 0; i < x.length && i < y.length; i++) {
      final order = x[i].compareTo(y[i]);
      if (order != 0) return order;
    }
    final order = x.length.compareTo(y.length);
    return order != 0 ? order : a.toLowerCase().compareTo(b.toLowerCase());
  }

  return switch (column) {
    TrackTableColumn.number => number(a.number, b.number),
    TrackTableColumn.title => text(a.title, b.title),
    TrackTableColumn.artist => text(a.artist, b.artist),
    TrackTableColumn.album => text(a.album, b.album),
    TrackTableColumn.duration => number(
      a.duration?.inMilliseconds,
      b.duration?.inMilliseconds,
    ),
    TrackTableColumn.quality => quality(a.quality, b.quality),
  };
}

/// The order the table showed before sort keys were precomputed.
List<String> _legacyOrder(List<TrackTableRow> rows, TrackTableSort sort) {
  final indexed = rows.indexed.toList();
  indexed.sort((a, b) {
    final order = _legacyCompare(a.$2, b.$2, sort.column);
    if (order == 0) return a.$1.compareTo(b.$1);
    return sort.ascending ? order : -order;
  });
  return [for (final entry in indexed) entry.$2.id];
}

/// Rows with ties, case variants, missing and empty values in every column.
List<TrackTableRow> _syntheticRows(int count) {
  final random = Random(7);
  T? pick<T>(List<T?> values) => values[random.nextInt(values.length)];
  const words = ['alpha', 'Alpha', 'bravo', 'BRAVO', 'charlie', 'Ünïcode'];
  const qualities = [
    'FLAC 24-bit/96kHz',
    'FLAC 24-bit/192kHz',
    'flac 16-bit/44.1kHz',
    'FLAC 16-bit/44.1kHz',
    '16-bit/48kHz',
    'Hi-Res 24/96',
    'MP3 320kbps',
    'MP3 128kbps',
    'AAC',
    'aac',
    'Opus 1.5',
    '',
    null,
  ];
  return [
    for (var i = 0; i < count; i++)
      TrackTableRow(
        id: 'row-$i',
        number: pick([null, 1, 2, 3, 10, 11, -1]),
        title: '${pick(['', ...words])}${random.nextInt(4)}',
        artist: pick(['', null, ...words]),
        album: pick(['', null, ...words]),
        quality: pick(qualities),
        duration: pick([
          null,
          Duration.zero,
          const Duration(seconds: 90),
          const Duration(seconds: 90, microseconds: 400),
          const Duration(minutes: 3),
          const Duration(milliseconds: 179999),
        ]),
      ),
  ];
}

const _labels = {
  TrackTableColumn.number: '#',
  TrackTableColumn.title: 'Title',
  TrackTableColumn.artist: 'Artist',
  TrackTableColumn.album: 'Album',
  TrackTableColumn.quality: 'Quality',
  TrackTableColumn.duration: 'Duration',
};

/// A row that counts reads of the value the quality sort uses.
class _CountingRow extends TrackTableRow {
  _CountingRow(TrackTableRow row)
    : super(
        id: row.id,
        title: row.title,
        quality: row.quality,
        trailing: const SizedBox.square(dimension: 8),
      );

  int reads = 0;

  @override
  String? get quality {
    reads++;
    return super.quality;
  }
}

class _Host extends StatefulWidget {
  const _Host({required this.rows, required this.freshRows, this.onSelect});

  final List<TrackTableRow> rows;

  /// Rebuilds the rows as new objects with the same values on every build,
  /// as screens that build rows inline do.
  final bool freshRows;
  final void Function(List<String> orderedIds)? onSelect;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  Set<String> selected = const {};
  late List<TrackTableRow> rows = widget.rows;

  @override
  Widget build(BuildContext context) {
    if (widget.freshRows) rows = [for (final row in rows) _CountingRow(row)];
    return CustomScrollView(
      slivers: [
        SliverTrackTable(
          rows: rows,
          columns: TrackTableColumn.values,
          selectedIds: selected,
          onSelect: (id, kind, orderedIds) {
            widget.onSelect?.call(orderedIds);
            setState(() => selected = {id});
          },
          onActivate: (_) {},
        ),
      ],
    );
  }
}

/// Shift-clicks a row, so the table reports its shown order.
Future<void> _rangeClick(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  final gesture = await tester.startGesture(
    tester.getTopLeft(find.byType(CustomScrollView)) + const Offset(300, 60),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
}

void main() {
  setUp(() {
    debugDesktopPlatformOverride = true;
    DesktopDoubleClick.reset();
  });

  tearDown(() {
    debugDesktopPlatformOverride = null;
    DesktopDoubleClick.reset();
  });

  test('compareTrackTableRows matches the previous comparator', () {
    final rows = _syntheticRows(160);
    for (final column in TrackTableColumn.values) {
      for (final a in rows) {
        for (final b in rows) {
          expect(
            compareTrackTableRows(a, b, column).sign,
            _legacyCompare(a, b, column).sign,
            reason: '$column ${a.id} ${b.id}',
          );
        }
      }
    }
  });

  testWidgets('every column and direction shows the previous order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rows = _syntheticRows(300);
    final shown = <List<String>>[];
    await tester.pumpWidget(
      _app(_Host(rows: rows, freshRows: false, onSelect: shown.add)),
    );
    for (final column in TrackTableColumn.values) {
      for (final ascending in [true, false]) {
        await tester.tap(find.text(_labels[column]!));
        await tester.pump();
        await _rangeClick(tester);
        expect(
          shown.last,
          _legacyOrder(rows, (column: column, ascending: ascending)),
          reason: '$column ascending: $ascending',
        );
      }
    }
    expect(tester.takeException(), isNull);
  });

  for (final freshRows in [false, true]) {
    final effect = freshRows
        ? 'reads each sort key once'
        : 'does not sort again';
    testWidgets('a selection click $effect', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final shown = <List<String>>[];
      final source = [for (final row in _syntheticRows(300)) _CountingRow(row)];
      await tester.pumpWidget(
        _app(_Host(rows: source, freshRows: freshRows, onSelect: shown.add)),
      );
      await tester.tap(find.text('Quality'));
      await tester.pump();
      await _rangeClick(tester);

      final state = tester.state<_HostState>(find.byType(_Host));
      for (final row in state.rows) {
        (row as _CountingRow).reads = 0;
      }
      await _rangeClick(tester);
      final reads = state.rows.fold(
        0,
        (sum, row) => sum + (row as _CountingRow).reads,
      );
      expect(shown.last, shown.first);
      // Kept rows are not sorted again, so only the built rows read their
      // quality. New rows are sorted by keys read once per row, where the
      // previous comparator read each row about 20 times.
      expect(reads, lessThan(freshRows ? 2 * source.length : source.length));
    });
  }

  testWidgets('hovering a row fades its actions without rebuilding it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        _Host(
          rows: [
            _CountingRow(const TrackTableRow(id: 'a', title: 'Hovered')),
            _CountingRow(const TrackTableRow(id: 'b', title: 'Other')),
          ],
          freshRows: false,
        ),
      ),
    );
    final title = find.text('Hovered');
    final opacity = find.descendant(
      of: find.ancestor(of: title, matching: find.byType(InkWell)).first,
      matching: find.byType(AnimatedOpacity),
    );
    final text = tester.widget<Text>(title);
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(title));
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
    expect(identical(tester.widget<Text>(title), text), isTrue);

    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
    expect(identical(tester.widget<Text>(title), text), isTrue);
  });

  testWidgets('TrackListTable keeps its rows across a selection change', (
    tester,
  ) async {
    const tracks = [
      Track(id: 'a', name: 'One', artistName: 'A', albumName: 'B', duration: 9),
      Track(id: 'b', name: 'Two', artistName: 'A', albumName: 'B', duration: 9),
    ];
    Widget table(Set<String> selected, {bool inHistory = false}) => _app(
      CustomScrollView(
        slivers: [
          TrackListTable(
            tracks: [...tracks],
            ids: const ['a', 'b'],
            isInHistory: [inHistory, false],
            selectedIds: selected,
            onSelect: (_, _, _) {},
            onActivate: (_) {},
          ),
        ],
      ),
      mornye: true,
    );
    List<TrackTableRow> rows() =>
        tester.widget<SliverTrackTable>(find.byType(SliverTrackTable)).rows;

    await tester.pumpWidget(table(const {}));
    final first = rows();
    await tester.pumpWidget(table(const {'a'}));
    expect(identical(rows(), first), isTrue);
    await tester.pumpWidget(table(const {'a'}, inHistory: true));
    expect(identical(rows(), first), isFalse);
    expect(tester.takeException(), isNull);
  });
}
