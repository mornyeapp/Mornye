import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/widgets/album_track_tile.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/now_playing_indicator.dart';
import 'package:mornye/widgets/track_card.dart';

/// Long enough for the effect and spatial springs to settle.
const _settle = Duration(seconds: 1);

/// Every cover has [scheme], without decoding an image.
class _CachedPalette extends PlayerArtworkPalette {
  const _CachedPalette(this.scheme);

  final ColorScheme scheme;

  @override
  ColorScheme? peek(String source, Brightness brightness) => scheme;

  @override
  Future<ColorScheme?> resolve(String source, Brightness brightness) async =>
      scheme;
}

Widget _app(
  Widget child, {
  bool mornye = false,
  String? currentId,
  String? artUri,
  bool playing = true,
  bool reduceMotion = false,
}) => ProviderScope(
  overrides: [
    currentMediaItemProvider.overrideWithBuild(
      (ref, notifier) => Stream.value(
        currentId == null
            ? null
            : MediaItem(
                id: currentId,
                title: 'Song',
                artUri: artUri == null ? null : Uri.parse(artUri),
              ),
      ),
    ),
    playbackPlayingProvider.overrideWith((ref) => playing),
    playbackLoadingProvider.overrideWith((ref) => false),
  ],
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: Scaffold(body: child),
  ),
);

/// Pumps in bounded steps: a playing indicator loops, so the tree never
/// settles.
Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  const step = Duration(milliseconds: 50);
  for (var elapsed = Duration.zero; elapsed < duration; elapsed += step) {
    await tester.pump(step);
  }
}

ColorScheme _scheme(WidgetTester tester, Finder finder) =>
    Theme.of(tester.element(finder)).colorScheme;

/// The surface of the table row that shows [title].
Material _rowSurface(WidgetTester tester, String title) => tester
    .widgetList<Material>(
      find.ancestor(of: find.text(title), matching: find.byType(Material)),
    )
    .first;

TextStyle? _textStyle(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style;

const _columns = [
  TrackTableColumn.number,
  TrackTableColumn.title,
  TrackTableColumn.artist,
  TrackTableColumn.duration,
];

List<TrackTableRow> _rows({Widget? leading}) => [
  for (final (index, title) in ['Bravo', 'Alpha', 'Charlie'].indexed)
    TrackTableRow(
      id: 'row-$index',
      playback: mediaItemPlaybackUiProvider((id: 'media-$index', path: '')),
      number: index + 1,
      title: title,
      artist: 'Artist',
      duration: const Duration(minutes: 3),
      leading: leading,
    ),
];

Widget _table({
  List<TrackTableColumn> columns = _columns,
  List<TrackTableRow>? rows,
  Set<String> selectedIds = const {},
}) => CustomScrollView(
  slivers: [
    SliverTrackTable(
      rows: rows ?? _rows(),
      columns: columns,
      selectedIds: selectedIds,
      onSelect: (_, _, _) {},
      onActivate: (_) {},
    ),
  ],
);

void main() {
  group('NowPlayingIndicator', () {
    Widget host({required bool playing, bool reduceMotion = false}) =>
        MaterialApp(
          theme: AppTheme.light(),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: Center(child: NowPlayingIndicator(playing: playing)),
          ),
        );

    testWidgets('moves while playing and freezes while paused', (tester) async {
      // The route caches its page, so playback changes come from inside it.
      final playing = ValueNotifier(true);
      addTearDown(playing.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Center(
            child: ValueListenableBuilder<bool>(
              valueListenable: playing,
              builder: (context, value, _) =>
                  NowPlayingIndicator(playing: value),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(DecorativePhase.debugClockRunning, isTrue);

      playing.value = false;
      await tester.pump();
      await tester.pump();
      expect(DecorativePhase.debugClockRunning, isFalse);

      playing.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(DecorativePhase.debugClockRunning, isTrue);
    });

    testWidgets('stays still under reduced motion', (tester) async {
      await tester.pumpWidget(host(playing: true, reduceMotion: true));
      await tester.pump();
      expect(DecorativePhase.debugClockRunning, isFalse);
    });

    testWidgets('stops its ticker while hidden', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const TickerMode(
            enabled: false,
            child: Center(child: NowPlayingIndicator(playing: true)),
          ),
        ),
      );
      await tester.pump();
      expect(DecorativePhase.debugClockRunning, isFalse);
    });

    testWidgets('is a 16dp glyph outside the semantics tree', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(playing: false));

      final indicator = find.byType(NowPlayingIndicator);
      expect(tester.getSize(indicator), const Size.square(16));
      expect(
        find.descendant(of: indicator, matching: find.byType(ExcludeSemantics)),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('Material songs table', () {
    testWidgets('fills the current row and swaps its number for the glyph', (
      tester,
    ) async {
      await tester.pumpWidget(_app(_table(), currentId: 'media-0'));
      await _pumpFor(tester, _settle);

      final scheme = _scheme(tester, find.text('Bravo'));
      expect(find.byType(NowPlayingIndicator), findsOneWidget);
      // Bravo is track 1; its number gives way to the glyph.
      expect(find.text('1'), findsNothing);
      expect(find.text('2'), findsOneWidget);
      expect(_rowSurface(tester, 'Bravo').color, scheme.primaryContainer);
      expect(_rowSurface(tester, 'Alpha').color?.a, 0);

      final title = _textStyle(tester, 'Bravo');
      expect(title?.color, scheme.onPrimaryContainer);
      expect(title?.fontWeight, FontWeight.w700);
      expect(_textStyle(tester, 'Alpha')?.fontWeight, FontWeight.w500);
      // The glyph moves while the track plays.
      expect(DecorativePhase.debugClockRunning, isTrue);
    });

    testWidgets('keeps row height and title alignment', (tester) async {
      const artwork = SizedBox.square(dimension: 32);
      await tester.pumpWidget(
        _app(
          _table(
            columns: const [TrackTableColumn.title, TrackTableColumn.artist],
            rows: _rows(leading: artwork),
          ),
          currentId: 'media-0',
        ),
      );
      await _pumpFor(tester, _settle);

      // Without a number column the glyph sits over the artwork.
      expect(find.byType(NowPlayingIndicator), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Bravo')).dx,
        tester.getTopLeft(find.text('Alpha')).dx,
      );
      expect(
        tester.getSize(find.byType(InkWell).first).height,
        tester.getSize(find.byType(InkWell).at(1)).height,
      );
    });

    testWidgets('a paused current row shows a still glyph', (tester) async {
      await tester.pumpWidget(
        _app(_table(), currentId: 'media-0', playing: false),
      );
      await _pumpFor(tester, _settle);

      expect(find.byType(NowPlayingIndicator), findsOneWidget);
      final scheme = _scheme(tester, find.text('Bravo'));
      expect(_rowSurface(tester, 'Bravo').color, scheme.primaryContainer);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a selected current row keeps the selection fill', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(_table(selectedIds: const {'row-0'}), currentId: 'media-0'),
      );
      await _pumpFor(tester, _settle);

      final scheme = _scheme(tester, find.text('Bravo'));
      expect(_rowSurface(tester, 'Bravo').color, scheme.secondaryContainer);
      expect(_textStyle(tester, 'Bravo')?.color, scheme.onSecondaryContainer);
      expect(find.byType(NowPlayingIndicator), findsOneWidget);
    });

    testWidgets('hover uses the 8% state layer of the content color', (
      tester,
    ) async {
      await tester.pumpWidget(_app(_table(), currentId: 'media-0'));
      await _pumpFor(tester, _settle);

      final scheme = _scheme(tester, find.text('Bravo'));
      final inkWells = tester.widgetList<InkWell>(find.byType(InkWell));
      bool hoverIs(InkWell ink, Color color) =>
          ink.hoverColor == color.withValues(alpha: 0.08);
      expect(
        inkWells.where((ink) => hoverIs(ink, scheme.onPrimaryContainer)),
        hasLength(1),
      );
      expect(
        inkWells.where((ink) => hoverIs(ink, scheme.onSurface)),
        hasLength(2),
      );
    });

    testWidgets('Mornye keeps the plain row', (tester) async {
      await tester.pumpWidget(
        _app(_table(), mornye: true, currentId: 'media-0'),
      );
      await tester.pump();

      expect(find.byType(NowPlayingIndicator), findsNothing);
      expect(find.text('1'), findsOneWidget);
      expect(_rowSurface(tester, 'Bravo').color, Colors.transparent);
      expect(_textStyle(tester, 'Bravo')?.fontWeight, FontWeight.w500);
    });
  });

  group('Material TrackCard', () {
    Widget card({
      bool current = false,
      bool selected = false,
      bool playing = true,
    }) => TrackCard(
      leading: const SizedBox.square(dimension: 56),
      title: 'Song',
      trailing: const SizedBox.square(dimension: 48),
      isCurrent: current,
      isPlaying: playing,
      isSelected: selected,
      leadingArtwork: true,
    );

    ClipPath rowClip(WidgetTester tester) => tester.widget<ClipPath>(
      find
          .ancestor(
            of: find.byType(AppContentCard),
            matching: find.byType(ClipPath),
          )
          .first,
    );

    testWidgets('the current row fills and rounds into a pill', (tester) async {
      await tester.pumpWidget(_app(card(current: true)));
      await _pumpFor(tester, _settle);

      final scheme = _scheme(tester, find.text('Song'));
      final surface = tester.widget<AppContentCard>(
        find.byType(AppContentCard),
      );
      expect(surface.color, scheme.primaryContainer);
      expect(_textStyle(tester, 'Song')?.color, scheme.onPrimaryContainer);
      expect(_textStyle(tester, 'Song')?.fontWeight, FontWeight.w700);
      expect(find.byType(NowPlayingIndicator), findsOneWidget);
      expect(rowClip(tester).clipBehavior, Clip.antiAlias);
    });

    testWidgets('other rows keep their corners and no glyph', (tester) async {
      await tester.pumpWidget(_app(card()));
      await tester.pump();

      expect(find.byType(NowPlayingIndicator), findsNothing);
      expect(rowClip(tester).clipBehavior, Clip.none);
    });

    testWidgets('the current row takes the colours of the playing cover', (
      tester,
    ) async {
      final cover = ColorScheme.fromSeed(seedColor: Colors.orange);
      PlayerArtworkTheme.debugPalette = _CachedPalette(cover);
      addTearDown(() => PlayerArtworkTheme.debugPalette = null);
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              card(current: true),
              TrackCard(
                leading: const SizedBox.square(dimension: 56),
                title: 'Other',
                isSelected: true,
              ),
            ],
          ),
          currentId: 'media',
          artUri: 'https://example.com/cover.jpg',
        ),
      );
      await _pumpFor(tester, _settle);

      final surfaces = tester
          .widgetList<AppContentCard>(find.byType(AppContentCard))
          .toList();
      expect(surfaces.first.color, cover.primaryContainer);
      expect(_textStyle(tester, 'Song')?.color, cover.onPrimaryContainer);
      // Rows that are not current keep the app scheme.
      expect(
        surfaces.last.color,
        _scheme(tester, find.text('Other')).secondaryContainer,
      );
      expect(_scheme(tester, find.text('Other')).primary, isNot(cover.primary));
    });

    testWidgets('text and controls on the fill take its content colour', (
      tester,
    ) async {
      // A black and white cover fills the row with a container close to
      // the app's supporting colour, which would hide uncoloured text.
      final cover = ColorScheme.fromSeed(
        seedColor: Colors.grey,
        brightness: Brightness.dark,
        dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
      );
      PlayerArtworkTheme.debugPalette = _CachedPalette(cover);
      addTearDown(() => PlayerArtworkTheme.debugPalette = null);
      Widget row(String title, String number, {bool current = false}) =>
          TrackCard(
            leading: Text(number),
            title: title,
            subtitle: Text('$title artist'),
            trailing: Icon(Icons.more_vert, key: ValueKey(title)),
            isCurrent: current,
          );
      await tester.pumpWidget(
        _app(
          Column(
            children: [row('Song', '1', current: true), row('Other', '2')],
          ),
          currentId: 'media',
          artUri: 'https://example.com/cover.jpg',
        ),
      );
      await _pumpFor(tester, _settle);

      Color? textColor(String text) => tester
          .renderObject<RenderParagraph>(find.text(text))
          .text
          .style
          ?.color;
      ColorScheme trailing(String title) =>
          _scheme(tester, find.byKey(ValueKey(title)));

      expect(textColor('Song artist'), cover.onPrimaryContainer);
      expect(textColor('1'), cover.onPrimaryContainer);
      expect(trailing('Song').onSurfaceVariant, cover.onPrimaryContainer);
      expect(trailing('Song').primary, cover.onPrimaryContainer);
      expect(trailing('Song').onPrimary, cover.primaryContainer);
      // Other rows keep the app's supporting colour.
      final app = _scheme(tester, find.text('Other'));
      expect(textColor('Other artist'), app.onSurfaceVariant);
      expect(textColor('2'), app.onSurfaceVariant);
      expect(trailing('Other'), app);
    });

    testWidgets('reduced motion switches the shape in place', (tester) async {
      // The route caches its page, so the change comes from inside it.
      final current = ValueNotifier(false);
      addTearDown(current.dispose);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<bool>(
            valueListenable: current,
            builder: (context, value, _) => card(current: value),
          ),
          reduceMotion: true,
        ),
      );
      await tester.pump();
      expect(rowClip(tester).clipBehavior, Clip.none);

      current.value = true;
      await tester.pump();
      expect(rowClip(tester).clipBehavior, Clip.antiAlias);
      // The current row starts reading the player, which takes one frame
      // to flush; after it nothing moves.
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('the pill shape follows the spatial spring', (tester) async {
      final current = ValueNotifier(false);
      addTearDown(current.dispose);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<bool>(
            valueListenable: current,
            // Paused, so only the morph schedules frames.
            builder: (context, value, _) =>
                card(current: value, playing: false),
          ),
        ),
      );
      await tester.pump();

      current.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      // Mid-morph: the clip is on and the row is still moving.
      expect(rowClip(tester).clipBehavior, Clip.antiAlias);
      expect(tester.binding.hasScheduledFrame, isTrue);

      await _pumpFor(tester, _settle);
      expect(tester.binding.hasScheduledFrame, isFalse);

      current.value = false;
      await _pumpFor(tester, _settle);
      expect(rowClip(tester).clipBehavior, Clip.none);
    });

    testWidgets('selection uses solid secondaryContainer', (tester) async {
      await tester.pumpWidget(_app(card(selected: true)));
      await tester.pump();

      final scheme = _scheme(tester, find.text('Song'));
      final surface = tester.widget<AppContentCard>(
        find.byType(AppContentCard),
      );
      expect(surface.color, scheme.secondaryContainer);
      expect(_textStyle(tester, 'Song')?.color, scheme.onSecondaryContainer);
    });

    testWidgets('a selected current row keeps the selection fill', (
      tester,
    ) async {
      await tester.pumpWidget(_app(card(current: true, selected: true)));
      await _pumpFor(tester, _settle);

      final scheme = _scheme(tester, find.text('Song'));
      final surface = tester.widget<AppContentCard>(
        find.byType(AppContentCard),
      );
      expect(surface.color, scheme.secondaryContainer);
      expect(find.byType(NowPlayingIndicator), findsOneWidget);
    });

    testWidgets('Mornye ignores the current track', (tester) async {
      await tester.pumpWidget(_app(card(current: true), mornye: true));
      await tester.pump();

      expect(find.byType(NowPlayingIndicator), findsNothing);
      final surface = tester.widget<AppContentCard>(
        find.byType(AppContentCard),
      );
      expect(surface.color, Colors.transparent);
      expect(_textStyle(tester, 'Song')?.fontWeight, FontWeight.w500);
    });

    testWidgets('Mornye keeps its selection tint', (tester) async {
      await tester.pumpWidget(_app(card(selected: true), mornye: true));
      await tester.pump();

      final scheme = _scheme(tester, find.text('Song'));
      final surface = tester.widget<AppContentCard>(
        find.byType(AppContentCard),
      );
      expect(surface.color, scheme.primaryContainer.withValues(alpha: 0.3));
    });
  });

  group('AlbumTrackTile', () {
    Widget tile({required bool current}) => AlbumTrackTile(
      trackNumber: 1,
      trackName: 'Song',
      subtitle: const Text('Artist'),
      isSelectionMode: false,
      isSelected: false,
      onToggleSelection: () {},
      onOpen: () {},
      onEnterSelectionMode: () {},
      onPlay: () {},
      isCurrent: current,
      isPlaying: current,
    );

    testWidgets('marks the current track and offers pause', (tester) async {
      await tester.pumpWidget(_app(tile(current: true)));
      await _pumpFor(tester, _settle);

      expect(find.byType(NowPlayingIndicator), findsOneWidget);
      expect(find.byTooltip('Pause'), findsOneWidget);
      final button = tester.widget<IconButton>(find.byType(IconButton));
      final scheme = _scheme(tester, find.text('Song'));
      expect(
        button.style?.backgroundColor?.resolve(const {}),
        scheme.secondaryContainer,
      );
    });

    testWidgets('other tracks show no glyph', (tester) async {
      await tester.pumpWidget(_app(tile(current: false)));
      await tester.pump();

      expect(find.byType(NowPlayingIndicator), findsNothing);
      expect(find.byTooltip('Play'), findsOneWidget);
    });
  });
}
